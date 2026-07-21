import Foundation

public enum AttrKit {
    private static let facade = AttrKitFacade()

    public static func start(apiKey: String, consent: AttrKitConsent) {
        facade.enqueue { core in await core.start(apiKey: apiKey, consent: consent) }
    }

    public static func setConsent(_ consent: AttrKitConsent) {
        facade.enqueue { core in await core.setConsent(consent) }
    }

    public static func track(_ event: AttrKitEvent, properties: [String: AttrKitValue] = [:]) {
        facade.enqueue { core in await core.track(event, properties: properties) }
    }

    public static func attribution(timeout: Duration = .seconds(2)) async -> AttributionResult {
        await facade.withRuntime { core in await core.attribution(timeout: timeout) }
    }

    public static func handle(_ url: URL) async -> DeepLinkResult {
        await facade.withRuntime { core in await core.handle(url) }
    }

    public static func setUserID(_ opaqueID: String?) {
        facade.enqueue { core in await core.setUserID(opaqueID) }
    }

    public static func deleteData() async throws {
        try await facade.withRuntimeThrowing { core in try await core.deleteData() }
    }

    @_spi(AttrKitLinkToken)
    public static func acceptExplicitLinkToken(_ token: String, kind: String = "clipboard") async -> DeepLinkResult {
        await facade.withRuntime { core in await core.acceptExactToken(token, kind: kind) }
    }

    @_spi(AttrKitLinkToken)
    public static func canReadLinkTokenPasteboard() async -> Bool {
        await facade.withRuntime { core in await core.canReadLinkTokenPasteboard() }
    }

    static func configureForTesting(_ configuration: AttrKitTestingConfiguration) async {
        await facade.replace(with: CoreRuntime(configuration: configuration))
    }
}

private final class AttrKitFacade: @unchecked Sendable {
    private let lock = NSLock()
    private var runtime = CoreRuntime(configuration: .live)
    private var tail: Task<Void, Never>?

    func enqueue(_ operation: @escaping @Sendable (CoreRuntime) async -> Void) {
        lock.lock()
        let previous = tail
        let current = runtime
        let task = Task {
            if let previous { await previous.value }
            await operation(current)
        }
        tail = task
        lock.unlock()
    }

    func withRuntime<T: Sendable>(_ operation: @escaping @Sendable (CoreRuntime) async -> T) async -> T {
        let snapshot: (Task<Void, Never>?, CoreRuntime) = locked { (tail, runtime) }
        if let tail = snapshot.0 { await tail.value }
        return await operation(snapshot.1)
    }

    func withRuntimeThrowing<T: Sendable>(_ operation: @escaping @Sendable (CoreRuntime) async throws -> T) async throws -> T {
        let snapshot: (Task<Void, Never>?, CoreRuntime) = locked { (tail, runtime) }
        if let tail = snapshot.0 { await tail.value }
        return try await operation(snapshot.1)
    }

    func replace(with newRuntime: CoreRuntime) async {
        let old: (Task<Void, Never>?, CoreRuntime) = locked {
            let old = (tail, runtime)
            tail = nil
            runtime = newRuntime
            return old
        }
        old.0?.cancel()
        await old.1.shutdown()
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}
