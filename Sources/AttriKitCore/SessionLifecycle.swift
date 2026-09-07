import Foundation

#if canImport(UIKit) && os(iOS)
import UIKit
#endif

enum ApplicationLifecycleEvent: Sendable {
    case didBecomeActive
    case willResignActive
    case willTerminate
}

protocol ApplicationLifecycleObserving: Sendable {
    func start(_ handler: @escaping @Sendable (ApplicationLifecycleEvent, Date?) async -> Void)
    func stop()
}

/// Notification-only lifecycle observation remains a complete no-op in app extensions.
final class ApplicationLifecycleObserver: ApplicationLifecycleObserving, @unchecked Sendable {
    typealias ApplicationIsActive = @MainActor @Sendable () -> Bool

    private let lock = NSLock()
    /// Serializes observer registration/publication with stop(). The state lock alone protects
    /// individual fields but cannot make the multi-step NotificationCenter installation atomic.
    private let installationLock = NSLock()
    private var tokens: [NSObjectProtocol] = []
    /// Bumped on every resign/terminate so a synthesized "active" captured before the
    /// resign is dropped instead of starting a phantom background session.
    private var activationGeneration = 0
    /// Bumped on every start()/stop() so a synthesized delivery scheduled under one
    /// subscription can never invoke a stale handler after observation stops or
    /// a new handler is installed.
    private var subscriptionGeneration = 0
    private let applicationIsActive: ApplicationIsActive

    init(applicationIsActive: ApplicationIsActive? = nil) {
        self.applicationIsActive = applicationIsActive ?? {
            Self.defaultApplicationIsActive()
        }
    }

    func start(_ handler: @escaping @Sendable (ApplicationLifecycleEvent, Date?) async -> Void) {
        #if canImport(UIKit) && os(iOS)
        // Extensions must remain a complete no-op even if UIKit is linked into the host.
        guard Bundle.main.bundleURL.pathExtension.lowercased() != "appex" else { return }
        #endif
        installationLock.lock()
        defer { installationLock.unlock() }

        // Bump FIRST so every closure below binds to this install: a notification from
        // an older subscription (mid-flight when it was replaced) fails the check.
        let installGen = locked {
            subscriptionGeneration &+= 1
            return subscriptionGeneration
        }

        let center = NotificationCenter.default
        // Each subscription owns its own chain. A stopped handler that never returns therefore
        // cannot block a later start(), and stop() does not need an unordered main-actor reset.
        let deliveryChain = DeliveryChain()
        #if canImport(UIKit) && os(iOS)
        let installed = [
            center.addObserver(
                forName: UIApplication.didBecomeActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                // Skip delivery if stop()/re-start() invalidated this subscription while
                // the notification was in flight — same guard as the synthesized path.
                MainActor.assumeIsolated {
                    guard let self, self.isCurrentSubscription(installGen) else { return }
                    Self.deliverAsynchronously(
                        .didBecomeActive, at: Date(), to: handler, through: deliveryChain,
                        while: self, subscriptionGeneration: installGen
                    )
                }
            },
            center.addObserver(
                forName: UIApplication.willResignActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.isCurrentSubscription(installGen) else { return }
                    self.bumpActivationGeneration()
                    Self.deliverWithBackgroundTime(
                        .willResignActive, at: Date(), to: handler, through: deliveryChain,
                        while: self, subscriptionGeneration: installGen
                    )
                }
            },
            center.addObserver(
                forName: UIApplication.willTerminateNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.isCurrentSubscription(installGen) else { return }
                    self.bumpActivationGeneration()
                    Self.deliverWithBackgroundTime(
                        .willTerminate, at: Date(), to: handler, through: deliveryChain,
                        while: self, subscriptionGeneration: installGen
                    )
                }
            },
        ]

        let previous = locked {
            let previous = tokens
            tokens = installed
            return previous
        }
        for token in previous { center.removeObserver(token) }
        #endif

        // Cold-launch race: the OS can deliver didBecomeActive BEFORE this subscription
        // exists (the SDK actor subscribes asynchronously after start()). A notification
        // missed that way used to mean applicationIsActive stayed false and the install's
        // first session was silently lost. Synthesize the active state at subscription
        // time, gated on the activation generation: a resign/terminate between capture
        // and delivery invalidates it, so no phantom session can start in the background.
        // The subscription generation additionally drops the delivery if stop() or a
        // re-start() replaced the handler while the task was pending. The runtime's
        // activeSession == nil guard keeps a later OS duplicate benign.
        Task { @MainActor in
            guard applicationIsActive(),
                  isCurrentSubscription(installGen) else { return }
            let captured = currentActivationGeneration()
            // No notification was posted for this one — that is why it is being synthesized — so
            // there is no post instant to carry. The earliest evidence the app IS active is this
            // observation, which is a closer approximation of the real activation than the
            // processing time `nil` would fall back to.
            let observedAt = Date()
            // Serialized through the SAME tail as real notifications. This delivery used to be the
            // one that bypassed `deliverInOrder`, which meant the synthesized activation could
            // overtake, or be overtaken by, a genuine resign — reintroducing exactly the inversion
            // the tail exists to prevent, on the path that only runs when a notification was
            // already missed. The generation re-check stays inside the ordered work, so a
            // resign/terminate that lands while this is queued still invalidates it.
            deliveryChain.deliver { [weak self] in
                guard let self,
                      self.applicationIsActive(),
                      self.currentActivationGeneration() == captured,
                      self.isCurrentSubscription(installGen) else { return }
                await handler(.didBecomeActive, observedAt)
            }
        }
    }

    @MainActor
    private func bumpActivationGeneration() {
        // Under the same lock currentActivationGeneration() reads through: the bump runs on the
        // main actor, the re-check runs inside the ordered delivery tail on whatever executor
        // carries it, and an unlocked write against a locked read is a data race on a plain Int.
        locked { activationGeneration &+= 1 }
    }

    private func currentActivationGeneration() -> Int {
        locked { activationGeneration }
    }

    private func isCurrentSubscription(_ installGen: Int) -> Bool {
        // Observers become live one by one before the token array is published. Generation is the
        // atomic subscription identity; requiring tokens to be non-empty dropped notifications in
        // that installation window even though their closures belonged to the current start().
        locked { subscriptionGeneration == installGen }
    }

    func stop() {
        installationLock.lock()
        defer { installationLock.unlock() }
        let installed = locked {
            let installed = tokens
            tokens.removeAll()
            subscriptionGeneration &+= 1
            return installed
        }
        #if canImport(UIKit) && os(iOS)
        for token in installed { NotificationCenter.default.removeObserver(token) }
        #else
        _ = installed
        #endif
    }

    /// Tail of one subscription's serial delivery chain.
    ///
    /// Every lifecycle notification used to spawn its OWN unstructured Task, and unstructured
    /// Tasks carry no ordering guarantee between them. A resign and the activation that physically
    /// followed it could therefore reach the runtime in the opposite order, at which point the
    /// runtime invalidated the live activation and the foregrounded app sat without a session
    /// until the next one arrived. Every observer here is registered on the main queue, so it
    /// already runs in post order: chaining each delivery onto the previous one is what carries
    /// that order across the actor boundary.
    private final class DeliveryChain: @unchecked Sendable {
        @MainActor private var tail: Task<Void, Never>?

        @MainActor
        func deliver(_ work: @escaping @MainActor () async -> Void) {
            let previous = tail
            tail = Task { @MainActor in
                await previous?.value
                await work()
            }
        }
    }

    #if canImport(UIKit) && os(iOS)
    @MainActor
    private static func deliverAsynchronously(
        _ event: ApplicationLifecycleEvent,
        at occurredAt: Date,
        to handler: @escaping @Sendable (ApplicationLifecycleEvent, Date?) async -> Void,
        through deliveryChain: DeliveryChain,
        while observer: ApplicationLifecycleObserver,
        subscriptionGeneration installGen: Int
    ) {
        deliveryChain.deliver { [weak observer] in
            guard let observer, observer.isCurrentSubscription(installGen) else { return }
            await handler(event, occurredAt)
        }
    }

    @MainActor
    private static func deliverWithBackgroundTime(
        _ event: ApplicationLifecycleEvent,
        at occurredAt: Date,
        to handler: @escaping @Sendable (ApplicationLifecycleEvent, Date?) async -> Void,
        through deliveryChain: DeliveryChain,
        while observer: ApplicationLifecycleObserver,
        subscriptionGeneration installGen: Int
    ) {
        guard let application = sharedApplicationIfAvailable() else {
            deliveryChain.deliver { [weak observer] in
                guard let observer, observer.isCurrentSubscription(installGen) else { return }
                await handler(event, occurredAt)
            }
            return
        }
        let name: String
        switch event {
        case .willTerminate:
            name = "io.attrikit.sdk.termination-flush"
        case .willResignActive:
            name = "io.attrikit.sdk.background-flush"
        case .didBecomeActive:
            name = "io.attrikit.sdk.lifecycle-flush"
        }
        let backgroundTask = BackgroundTaskLease.start(
            application: application,
            name: name
        )
        deliveryChain.deliver { [weak observer] in
            defer { backgroundTask.end() }
            guard let observer, observer.isCurrentSubscription(installGen) else { return }
            // The lifecycle handler does not finish until the session_end envelope has
            // crossed the actor boundary and reached durable SDK storage. The UIKit
            // notification itself stays nonblocking on the main thread.
            await handler(event, occurredAt)
        }
    }

    @MainActor
    private final class BackgroundTaskLease {
        private let application: UIApplication
        private var identifier: UIBackgroundTaskIdentifier = .invalid
        private var ended = false

        private init(application: UIApplication) {
            self.application = application
        }

        static func start(application: UIApplication, name: String) -> BackgroundTaskLease {
            let lease = BackgroundTaskLease(application: application)
            // UIApplication.h declares this block `NS_SWIFT_UI_ACTOR`, so it is already isolated to
            // the main actor and the system runs it synchronously on the main thread. The task has
            // to be ENDED before the handler returns; a `Task { @MainActor in ... }` hop returns
            // first and ends the task on a later main-actor turn, which is exactly the window in
            // which the system terminates the app for not having ended it.
            let identifier = application.beginBackgroundTask(withName: name) { [weak lease] in
                lease?.end()
            }
            lease.adopt(identifier)
            return lease
        }

        /// `beginBackgroundTask` can only hand back its identifier once the handler is installed, so
        /// a handler that fires before it returns finds `.invalid` and marks the lease ended. Ending
        /// the identifier here rather than dropping it keeps that ordering from leaking a background
        /// task the app then has no way to end.
        private func adopt(_ identifier: UIBackgroundTaskIdentifier) {
            guard !ended else {
                if identifier != .invalid { application.endBackgroundTask(identifier) }
                return
            }
            self.identifier = identifier
        }

        func end() {
            guard !ended else { return }
            ended = true
            guard identifier != .invalid else { return }
            application.endBackgroundTask(identifier)
            identifier = .invalid
        }
    }

    /// `UIApplication.shared` is compile-time unavailable to app extensions. The observer
    /// is already disabled for `.appex` bundles, so a runtime lookup lets host applications
    /// request best-effort background time without making AttriKitCore unlinkable there.
    @MainActor
    private static func sharedApplicationIfAvailable() -> UIApplication? {
        let selector = NSSelectorFromString("sharedApplication")
        guard let applicationClass = NSClassFromString("UIApplication") as? NSObject.Type,
              applicationClass.responds(to: selector),
              let unmanaged = applicationClass.perform(selector) else { return nil }
        return unmanaged.takeUnretainedValue() as? UIApplication
    }
    #endif

    @MainActor
    private static func defaultApplicationIsActive() -> Bool {
        #if canImport(UIKit) && os(iOS)
        return sharedApplicationIfAvailable()?.applicationState == .active
        #else
        return false
        #endif
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}
