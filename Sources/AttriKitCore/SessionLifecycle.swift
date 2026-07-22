import Foundation

#if canImport(UIKit) && os(iOS)
import UIKit
#endif

enum ApplicationLifecycleEvent: Sendable {
    case didBecomeActive
    case willResignActive
}

protocol ApplicationLifecycleObserving: Sendable {
    func start(_ handler: @escaping @Sendable (ApplicationLifecycleEvent) async -> Void)
    func stop()
}

/// Notification-only lifecycle observation keeps the core safe in app extensions:
/// it never reaches through `UIApplication.shared`, which is unavailable there.
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
                queue: nil
            ) { _ in
                Self.deliver(.didBecomeActive, to: handler)
            },
            center.addObserver(
                forName: UIApplication.willResignActiveNotification,
                object: nil,
                queue: nil
            ) { _ in
                Self.deliver(.willResignActive, to: handler)
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
    /// Never run SDK state transitions inline on a host notification callback.
    private static func deliver(
        _ event: ApplicationLifecycleEvent,
        to handler: @escaping @Sendable (ApplicationLifecycleEvent) async -> Void
    ) {
        Task { await handler(event) }
    }
    #endif

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}
