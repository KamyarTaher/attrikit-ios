import Foundation

public enum AttriKit {
    private static let facade = AttriKitFacade()
    private static let deviceEvidenceRegistry = DeviceEvidenceRegistry()

    public static func start(apiKey: String, consent: AttriKitConsent) {
        facade.enqueue { core in await core.start(apiKey: apiKey, consent: consent) }
    }

    public static func setConsent(_ consent: AttriKitConsent) {
        facade.enqueue { core in await core.setConsent(consent) }
    }

    public static func track(_ event: AttriKitEvent, properties: [String: AttriKitValue] = [:]) {
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

    /// Supplies first-party funnel identifiers for deterministic matching.
    ///
    /// Values are normalized and SHA-256 hashed synchronously on-device. The raw
    /// email address and phone number are never persisted or captured by async work.
    public static func setFunnelIdentity(email: String? = nil, phone: String? = nil) {
        let identity = FunnelIdentity(email: email, phone: phone)
        facade.enqueue { core in await core.setFunnelIdentity(identity) }
    }

    public static func deleteData() async throws {
        try await facade.withRuntimeThrowing { core in try await core.deleteData() }
    }

    @_spi(AttriKitLinkToken)
    /// Accepts an exact deferred-link token minted by the server in `ak1_`-prefixed form.
    public static func acceptExplicitLinkToken(_ token: String, kind: String = "clipboard") async -> DeepLinkResult {
        await facade.withRuntime { core in await core.acceptExactToken(token, kind: kind) }
    }

    @_spi(AttriKitLinkToken)
    public static func canReadLinkTokenPasteboard() async -> Bool {
        await facade.withRuntime { core in await core.canReadLinkTokenPasteboard() }
    }

    @_spi(AttriKitTracking)
    public static func registerTrackingEvidenceProvider(
        advertisingIdentifier: @escaping @Sendable () -> UUID?,
        vendorIdentifier: @escaping @Sendable () -> UUID?
    ) {
        deviceEvidenceRegistry.install(
            advertisingIdentifier: advertisingIdentifier,
            vendorIdentifier: vendorIdentifier
        )
    }

    @_spi(AttriKitTracking)
    public static func refreshTrackingEvidence() {
        facade.enqueue { core in await core.refreshTrackingEvidence() }
    }

    static func currentDeviceEvidence() -> DeviceEvidence {
        deviceEvidenceRegistry.current()
    }

    static func configureForTesting(_ configuration: AttriKitTestingConfiguration) async {
        await facade.replace(with: CoreRuntime(configuration: configuration))
    }
}

private final class DeviceEvidenceRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var advertisingIdentifier: @Sendable () -> UUID? = { nil }
    private var vendorIdentifier: @Sendable () -> UUID? = { nil }

    func install(
        advertisingIdentifier: @escaping @Sendable () -> UUID?,
        vendorIdentifier: @escaping @Sendable () -> UUID?
    ) {
        lock.lock()
        self.advertisingIdentifier = advertisingIdentifier
        self.vendorIdentifier = vendorIdentifier
        lock.unlock()
    }

    func current() -> DeviceEvidence {
        let providers = locked { (advertisingIdentifier, vendorIdentifier) }
        return DeviceEvidence(idfa: providers.0(), idfv: providers.1())
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

private final class AttriKitFacade: @unchecked Sendable {
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
