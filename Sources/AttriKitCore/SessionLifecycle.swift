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
    func start(_ handler: @escaping @Sendable (ApplicationLifecycleEvent) async -> Void)
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

    func start(_ handler: @escaping @Sendable (ApplicationLifecycleEvent) async -> Void) {
        #if canImport(UIKit) && os(iOS)
        // Extensions must remain a complete no-op even if UIKit is linked into the host.
        guard Bundle.main.bundleURL.pathExtension.lowercased() != "appex" else { return }

        let center = NotificationCenter.default
        let installed = [
            center.addObserver(
                forName: UIApplication.didBecomeActiveNotification,
                object: nil,
                queue: .main
            ) { _ in
                Self.deliverAsynchronously(.didBecomeActive, to: handler)
            },
            center.addObserver(
                forName: UIApplication.willResignActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.bumpActivationGeneration()
                    Self.deliverWithBackgroundTime(.willResignActive, to: handler)
                }
            },
            center.addObserver(
                forName: UIApplication.willTerminateNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.bumpActivationGeneration()
                    Self.deliverWithBackgroundTime(.willTerminate, to: handler)
                }
            },
        ]

        let previous = locked {
            let previous = tokens
            tokens = installed
            subscriptionGeneration &+= 1
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
        let capturedSubscription = currentSubscriptionGeneration()
        Task { @MainActor in
            guard sharedApplicationIfAvailable()?.applicationState == .active,
                  currentSubscriptionGeneration() == capturedSubscription else { return }
            let captured = currentActivationGeneration()
            Task {
                let stillCurrent = await MainActor.run {
                    sharedApplicationIfAvailable()?.applicationState == .active
                        && currentActivationGeneration() == captured
                        && currentSubscriptionGeneration() == capturedSubscription
                }
                guard stillCurrent else { return }
                await handler(.didBecomeActive)
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

    private func currentSubscriptionGeneration() -> Int {
        locked { subscriptionGeneration }
    }

    func stop() {
        #if canImport(UIKit) && os(iOS)
        let installed = locked {
            let installed = tokens
            tokens.removeAll()
            subscriptionGeneration &+= 1
            return installed
        }
        for token in installed { NotificationCenter.default.removeObserver(token) }
        #endif
    }

    #if canImport(UIKit) && os(iOS)
    private static func deliverAsynchronously(
        _ event: ApplicationLifecycleEvent,
        to handler: @escaping @Sendable (ApplicationLifecycleEvent) async -> Void
    ) {
        Task { await handler(event) }
    }

    @MainActor
    private static func deliverWithBackgroundTime(
        _ event: ApplicationLifecycleEvent,
        to handler: @escaping @Sendable (ApplicationLifecycleEvent) async -> Void
    ) {
        guard let application = sharedApplicationIfAvailable() else {
            Task { await handler(event) }
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
        Task {
            // The lifecycle handler does not finish until the session_end envelope has
            // crossed the actor boundary and reached durable SDK storage. The UIKit
            // notification itself stays nonblocking on the main thread.
            await handler(event)
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
