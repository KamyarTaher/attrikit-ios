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
    private let lock = NSLock()
    private var tokens: [NSObjectProtocol] = []
    /// Bumped on every resign/terminate so a synthesized "active" captured before the
    /// resign is dropped instead of starting a phantom background session.
    private var activationGeneration = 0
    /// Bumped on every start()/stop() so a synthesized delivery scheduled under one
    /// subscription can never invoke a stale handler after observation stops or
    /// a new handler is installed.
    private var subscriptionGeneration = 0

    func start(_ handler: @escaping @Sendable (ApplicationLifecycleEvent, Date?) async -> Void) {
        #if canImport(UIKit) && os(iOS)
        // Extensions must remain a complete no-op even if UIKit is linked into the host.
        guard Bundle.main.bundleURL.pathExtension.lowercased() != "appex" else { return }

        // Bump FIRST so every closure below binds to this install: a notification from
        // an older subscription (mid-flight when it was replaced) fails the check.
        let installGen = locked {
            subscriptionGeneration &+= 1
            return subscriptionGeneration
        }

        let center = NotificationCenter.default
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
                    Self.deliverAsynchronously(.didBecomeActive, at: Date(), to: handler)
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
                    Self.deliverWithBackgroundTime(.willResignActive, at: Date(), to: handler)
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
                    Self.deliverWithBackgroundTime(.willTerminate, at: Date(), to: handler)
                }
            },
        ]

        let previous = locked {
            let previous = tokens
            tokens = installed
            return previous
        }
        for token in previous { center.removeObserver(token) }

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
            guard Self.sharedApplicationIfAvailable()?.applicationState == .active,
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
            Self.deliverInOrder { [weak self] in
                guard let self,
                      Self.sharedApplicationIfAvailable()?.applicationState == .active,
                      self.currentActivationGeneration() == captured,
                      self.isCurrentSubscription(installGen) else { return }
                await handler(.didBecomeActive, observedAt)
            }
        }
        #else
        _ = handler
        #endif
    }

    @MainActor
    private func bumpActivationGeneration() {
        activationGeneration &+= 1
    }

    private func currentActivationGeneration() -> Int {
        locked { activationGeneration }
    }

    private func isCurrentSubscription(_ installGen: Int) -> Bool {
        locked { subscriptionGeneration == installGen && !tokens.isEmpty }
    }

    func stop() {
        #if canImport(UIKit) && os(iOS)
        let installed = locked {
            let installed = tokens
            tokens.removeAll()
            subscriptionGeneration &+= 1
            return installed
        }
        // Drop the delivery chain with the subscription. The tail is process-wide, so a handler
        // that never returns would otherwise block every lifecycle event after a restart too.
        //
        // HOP, do not assume. `stop()` is a plain protocol method and its only caller is
        // `CoreRuntime.shutdown()`, which runs on the CoreRuntime ACTOR — not the main actor — so
        // `MainActor.assumeIsolated` here would TRAP. The three sites above are safe because they
        // are NotificationCenter callbacks delivered on `queue: .main`; this one has no such
        // guarantee. It never crashed only because the whole `#if canImport(UIKit)` block has never
        // been executable: compiled out on macOS, and uncompilable on iOS from 0a97ebc until the
        // fix in this change. Making the block compile is exactly what would have made the trap
        // reachable, so it is fixed in the same commit.
        //
        // Ordering still holds across a stop()/start() pair: this clear and the subsequent
        // `deliverInOrder` are both main-actor work, so the main actor runs them in submission order.
        Task { @MainActor in Self.deliveryTail = nil }
        for token in installed { NotificationCenter.default.removeObserver(token) }
        #endif
    }

    #if canImport(UIKit) && os(iOS)
    /// Tail of the serial delivery chain.
    ///
    /// Every lifecycle notification used to spawn its OWN unstructured Task, and unstructured
    /// Tasks carry no ordering guarantee between them. A resign and the activation that physically
    /// followed it could therefore reach the runtime in the opposite order, at which point the
    /// runtime invalidated the live activation and the foregrounded app sat without a session
    /// until the next one arrived. Every observer here is registered on the main queue, so it
    /// already runs in post order: chaining each delivery onto the previous one is what carries
    /// that order across the actor boundary.
    @MainActor
    private static var deliveryTail: Task<Void, Never>?

    @MainActor
    private static func deliverInOrder(_ work: @escaping @MainActor () async -> Void) {
        let previous = deliveryTail
        deliveryTail = Task { @MainActor in
            await previous?.value
            await work()
        }
    }

    @MainActor
    private static func deliverAsynchronously(
        _ event: ApplicationLifecycleEvent,
        at occurredAt: Date,
        to handler: @escaping @Sendable (ApplicationLifecycleEvent, Date?) async -> Void
    ) {
        deliverInOrder { await handler(event, occurredAt) }
    }

    @MainActor
    private static func deliverWithBackgroundTime(
        _ event: ApplicationLifecycleEvent,
        at occurredAt: Date,
        to handler: @escaping @Sendable (ApplicationLifecycleEvent, Date?) async -> Void
    ) {
        guard let application = sharedApplicationIfAvailable() else {
            deliverInOrder { await handler(event, occurredAt) }
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
        deliverInOrder {
            // The lifecycle handler does not finish until the session_end envelope has
            // crossed the actor boundary and reached durable SDK storage. The UIKit
            // notification itself stays nonblocking on the main thread.
            await handler(event, occurredAt)
            backgroundTask.end()
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
            lease.identifier = application.beginBackgroundTask(withName: name) { [weak lease] in
                Task { @MainActor in lease?.end() }
            }
            return lease
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

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}
