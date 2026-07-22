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
            ) { _ in
                // The session-end envelope must reach durable SDK storage before the
                // host notification callback returns. A detached task avoids inheriting
                // the main actor while this callback waits for actor-backed persistence.
                Self.deliverSynchronously(.willResignActive, to: handler)
            },
            center.addObserver(
                forName: UIApplication.willTerminateNotification,
                object: nil,
                queue: .main
            ) { _ in
                MainActor.assumeIsolated {
                    Self.deliverTermination(to: handler)
                }
            },
        ]

        let previous = locked {
            let previous = tokens
            tokens = installed
            return previous
        }
        for token in previous { center.removeObserver(token) }
        #else
        _ = handler
        #endif
    }

    func stop() {
        #if canImport(UIKit) && os(iOS)
        let installed = locked {
            let installed = tokens
            tokens.removeAll()
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

    private static func deliverSynchronously(
        _ event: ApplicationLifecycleEvent,
        to handler: @escaping @Sendable (ApplicationLifecycleEvent) async -> Void
    ) {
        let completed = DispatchSemaphore(value: 0)
        Task.detached {
            await handler(event)
            completed.signal()
        }
        completed.wait()
    }

    @MainActor
    private static func deliverTermination(
        to handler: @escaping @Sendable (ApplicationLifecycleEvent) async -> Void
    ) {
        guard let application = sharedApplicationIfAvailable() else {
            Task.detached { await handler(.willTerminate) }
            return
        }
        let backgroundTask = application.beginBackgroundTask(
            withName: "io.attrikit.sdk.termination-flush",
            expirationHandler: nil
        )
        Task.detached {
            await handler(.willTerminate)
            await MainActor.run {
                guard backgroundTask != .invalid else { return }
                application.endBackgroundTask(backgroundTask)
            }
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
