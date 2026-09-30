import Foundation

public enum AttriKit {
    /// Identifier used for the SDK's best-effort first-open background retry.
    /// Host apps must list it under BGTaskSchedulerPermittedIdentifiers in Info.plist.
    public static let backgroundRetryTaskIdentifier = "io.attrikit.sdk.retry"

    private static let facade = AttriKitFacade()
    private static let deviceEvidenceRegistry = DeviceEvidenceRegistry()

    public static func start(apiKey: String, consent: AttriKitConsent) {
        facade.enqueue { core in await core.start(apiKey: apiKey, consent: consent) }
    }

    /// The installation id the SDK is measuring under, in the exact lowercase spelling it sends to
    /// AttriKit, or nil when it is not measuring.
    ///
    /// Pass it to your own backend wherever a purchase is recorded, so revenue AttriKit did not see
    /// on the device can still be joined to this install: RevenueCat's `appUserID` (AttriKit
    /// matches a RevenueCat webhook whose `app_user_id` equals this value directly), Stripe
    /// checkout `metadata`, or your server's user record.
    ///
    /// It is the id the SDK's own initialization established in this process, never one it reads
    /// or creates on the side, so it always equals the id on the SDK's requests. It is nil until
    /// `start(apiKey:consent:)` has run with measurement consent (`start` returns before it has
    /// run: read `await AttriKit.installID()` after it), nil while a `deleteData()` request is
    /// pending, and nil whenever consent does not allow measurement (unknown, denied or revoked),
    /// from the moment consent changes. Between launches it changes only when
    /// the SDK's own measurement does: a reinstall that did not keep the Keychain, a completed
    /// deletion, or a launch whose Keychain could not be read.
    public static var installID: String? {
        facade.currentRuntime().hostInstallationID()
    }

    /// `installID` once every call made before this one has run, `start` included: the way to read
    /// it at launch, since `start(apiKey:consent:)` returns before measurement has started.
    ///
    /// - Parameter queueTimeout: Bounds the wait for previously enqueued operations to drain. When nil, queued operations drain without a separate time bound. A wait that runs out or is cancelled answers nil.
    public static func installID(queueTimeout: Duration? = nil) async -> String? {
        let outcome = await facade.withRuntime(queueTimeout: queueTimeout) { core in
            core.hostInstallationID()
        }
        switch outcome {
        case .completed(let installID):
            return installID
        case .timedOut, .cancelled:
            return nil
        }
    }

    /// Updates the host's measurement/tracking consent state.
    ///
    /// Revocation clears queued measurement data, rotates the install epoch, and resets
    /// the session sequence. The stable installation ID is retained only as the erasure
    /// anchor required by `deleteData()`; a confirmed deletion removes that anchor too.
    public static func setConsent(_ consent: AttriKitConsent) {
        facade.enqueue { core in await core.setConsent(consent) }
    }

    /// The user's answers to Google's EU consent questions: whether EEA, UK or Swiss rules apply
    /// to them, and their `ad_user_data` and `ad_personalization` consents. Google requires these
    /// for every user in those regions. They go to Google with every event from now on, win over
    /// the IAB TCF consent AttriKit otherwise reads, and are kept across launches until
    /// `clearGoogleConsent()`. AttriKit's own consent (`setConsent`) is separate and unchanged.
    public static func setGoogleConsent(eea: Bool, adUserData: Bool, adPersonalization: Bool) {
        let values = DMAConsent(eea: eea, adUserData: adUserData, adPersonalization: adPersonalization, source: .manual)
        facade.enqueue { core in await core.setManualDMAConsent(values) }
    }

    /// Forgets the values set with `setGoogleConsent`, so the IAB TCF consent applies again.
    public static func clearGoogleConsent() {
        facade.enqueue { core in await core.setManualDMAConsent(nil) }
    }

    /// AttriKit reads the IAB TCF consent your consent management platform stores on the device
    /// (the standard `IABTCF_` keys) and passes Google the answers it gives. Pass `false` before
    /// `start` to stop reading it.
    public static func setTCFDataCollectionEnabled(_ enabled: Bool) {
        facade.enqueue { core in await core.setTCFConsentReading(enabled) }
    }

    /// Enables or disables automatic foreground-session measurement.
    ///
    /// Session tracking is enabled by default. Disable it before `start` to prevent
    /// `session_end` events, or change it later to stop or resume future sessions.
    public static func setSessionTrackingEnabled(_ enabled: Bool) {
        facade.enqueue { core in await core.setSessionTrackingEnabled(enabled) }
    }

    public static func track(_ event: AttriKitEvent, properties: [String: AttriKitValue] = [:]) {
        facade.enqueue { core in await core.track(event, properties: properties) }
    }

    /// Makes AttriKit the single writer of this app's SKAdNetwork and AdAttributionKit conversion
    /// values, under `schema`. Tracked events then raise the value on their own: the schema's
    /// activation event, `trial_started` or `intro_started`, and `purchase`, `purchase_completed`,
    /// `subscription_started` or `subscription_renewed` carrying a numeric `value` and a `currency`
    /// equal to the schema's. Call it before `start`, and do not call SKAdNetwork or
    /// AdAttributionKit update APIs yourself. Requires measurement consent, like every other write.
    public static func configureConversionValues(_ schema: AttriKitConversionSchema) {
        facade.enqueue { core in await core.configureConversionValues(schema) }
    }

    /// Raises the conversion value for a milestone the SDK cannot see as an event, for example
    /// revenue your server received from RevenueCat. A no-op until `configureConversionValues`.
    public static func recordConversion(_ milestone: AttriKitConversionMilestone) {
        facade.enqueue { core in await core.recordConversion(milestone) }
    }

    /// Returns the resolved attribution result for this install.
    ///
    /// Queued operations drain without a separate time bound before the attribution
    /// polling loop begins.
    ///
    /// - Parameter timeout: Bounds the attribution polling loop once execution begins. It does not bound the wait for previously enqueued operations to drain.
    /// - Returns: The resolved `AttributionResult`, or `.timedOut` if timeout elapses before attribution resolves.
    public static func attribution(timeout: Duration = .seconds(2)) async -> AttributionResult {
        await attribution(timeout: timeout, queueTimeout: nil)
    }

    /// Returns the resolved attribution result for this install.
    ///
    /// - Parameters:
    ///   - timeout: Bounds the attribution polling loop once execution begins. It does not bound the wait for previously enqueued operations to drain.
    ///   - queueTimeout: Bounds the wait for previously enqueued operations to drain before the polling loop begins. When nil, queued operations drain without a separate time bound.
    /// - Returns: The resolved `AttributionResult`, or `.timedOut` if either `queueTimeout` or `timeout` elapses before attribution resolves, or `.failed` if cancelled.
    public static func attribution(timeout: Duration = .seconds(2), queueTimeout: Duration?) async -> AttributionResult {
        let outcome = await facade.withRuntime(queueTimeout: queueTimeout) { core in
            await core.attribution(timeout: timeout)
        }
        switch outcome {
        case .completed(let result):
            return result
        case .timedOut:
            return .timedOut
        case .cancelled:
            return .failed
        }
    }

    /// Returns the resolved attribution result for this install.
    ///
    /// - Parameters:
    ///   - timeout: Bounds the attribution polling loop once execution begins. It does not bound the wait for previously enqueued operations to drain.
    ///   - queueBound: Bounds the wait for previously enqueued operations to drain before the polling loop begins. When nil, queued operations drain without a separate time bound.
    /// - Returns: The resolved `AttributionResult`, or `.timedOut` if either `queueBound` or `timeout` elapses before attribution resolves, or `.failed` if cancelled.
    public static func attribution(timeout: Duration = .seconds(2), queueBound: Duration?) async -> AttributionResult {
        await attribution(timeout: timeout, queueTimeout: queueBound)
    }

    /// Returns deterministic attribution as placement parameters for Superwall or another
    /// paywall/user-attribute SDK: `attrkit_method`, `attrkit_network`, `attrkit_campaign_id`,
    /// `attrkit_source_type`, `attrkit_finality`, and, when the server has them,
    /// `attrkit_campaign_name`, `attrkit_network_campaign_id`, `attrkit_adset_id` and
    /// `attrkit_ad_id`. Device-matched, organic, unresolved, or consent-blocked attribution
    /// returns an empty dictionary. For a dictionary that always says WHY, use `userAttributes`.
    ///
    /// Queued operations drain without a separate time bound before the attribution
    /// polling loop begins.
    ///
    /// - Parameter timeout: Bounds the attribution polling loop once execution begins. It does not bound the wait for previously enqueued operations to drain.
    /// - Returns: Placement parameter dictionary, or empty if attribution is unresolved, timed out, or non-deterministic.
    public static func placementParameters(timeout: Duration = .seconds(2)) async -> [String: String] {
        await placementParameters(timeout: timeout, queueTimeout: nil)
    }

    /// Returns deterministic attribution as placement parameters for Superwall or another
    /// paywall/user-attribute SDK; see `placementParameters(timeout:)` for the keys.
    /// Non-deterministic, unresolved, or consent-blocked attribution returns an empty dictionary.
    ///
    /// - Parameters:
    ///   - timeout: Bounds the attribution polling loop once execution begins. It does not bound the wait for previously enqueued operations to drain.
    ///   - queueTimeout: Bounds the wait for previously enqueued operations to drain before the polling loop begins. When nil, queued operations drain without a separate time bound.
    /// - Returns: Placement parameter dictionary, or empty if attribution is unresolved, timed out, cancelled, or non-deterministic.
    public static func placementParameters(timeout: Duration = .seconds(2), queueTimeout: Duration?) async -> [String: String] {
        guard case .attributed(let attribution) = await attribution(timeout: timeout, queueTimeout: queueTimeout) else { return [:] }
        return attribution.placementParameters
    }

    /// Returns deterministic attribution as placement parameters for Superwall or another
    /// paywall/user-attribute SDK; see `placementParameters(timeout:)` for the keys.
    /// Non-deterministic, unresolved, or consent-blocked attribution returns an empty dictionary.
    ///
    /// - Parameters:
    ///   - timeout: Bounds the attribution polling loop once execution begins. It does not bound the wait for previously enqueued operations to drain.
    ///   - queueBound: Bounds the wait for previously enqueued operations to drain before the polling loop begins. When nil, queued operations drain without a separate time bound.
    /// - Returns: Placement parameter dictionary, or empty if attribution is unresolved, timed out, cancelled, or non-deterministic.
    public static func placementParameters(timeout: Duration = .seconds(2), queueBound: Duration?) async -> [String: String] {
        await placementParameters(timeout: timeout, queueTimeout: queueBound)
    }

    /// Attribution as Superwall user attributes, never empty: `attrkit_status` is always present
    /// (`attributed`, `device_matched`, `organic`, `pending`, `consent_required`, `timed_out`), so a
    /// context without campaign keys still says why. `attrkit_finality` follows once the server
    /// answered, and a deterministic match adds every key of `placementParameters`. Every other
    /// `attrkit_` key is present with a `nil` value, which Superwall's merging `setUserAttributes`
    /// reads as "remove": a key an earlier answer set never outlives the answer that set it.
    ///
    /// The answer can improve after this returns: subscribe to `attributionUpdates()` and pass each
    /// update's `userAttributes` to `Superwall.shared.setUserAttributes(_:)`.
    ///
    /// - Parameters:
    ///   - timeout: Bounds the attribution polling loop once execution begins. It does not bound the wait for previously enqueued operations to drain.
    ///   - queueTimeout: Bounds the wait for previously enqueued operations to drain. When nil, queued operations drain without a separate time bound. A wait that runs out or is cancelled answers `attrkit_status: pending`.
    public static func userAttributes(timeout: Duration = .seconds(2), queueTimeout: Duration? = nil) async -> [String: String?] {
        let outcome = await facade.withRuntime(queueTimeout: queueTimeout) { core in
            await core.attributionUpdate(timeout: timeout)
        }
        switch outcome {
        case .completed(let update):
            return update.userAttributes
        case .timedOut, .cancelled:
            return AttributionUpdate(status: .pending, attribution: nil).userAttributes
        }
    }

    /// Every change of this install's attribution state, starting with the current one.
    ///
    /// The first answer the server gives is provisional for 72 hours, and the SDK keeps asking while
    /// it is: an install first answered `organic` can become `attributed` once its Apple Ads
    /// exchange or its link token is processed. Use this to refresh paywall user attributes when
    /// that happens:
    ///
    /// ```swift
    /// Task {
    ///     for await update in AttriKit.attributionUpdates() {
    ///         Superwall.shared.setUserAttributes(update.userAttributes)
    ///     }
    /// }
    /// ```
    ///
    /// Only real changes are published; re-reading the same answer publishes nothing.
    public static func attributionUpdates() -> AsyncStream<AttributionUpdate> {
        AsyncStream { continuation in
            let id = UUID()
            continuation.onTermination = { _ in
                facade.enqueue { core in await core.removeAttributionObserver(id) }
            }
            facade.enqueue { core in await core.addAttributionObserver(id, continuation) }
        }
    }


    /// Where this install's Apple Ads (AdServices) token got to: how its collection ended, and
    /// whether the first-open carrying it was delivered. Nil before measurement starts and for an
    /// install whose first-open was built by an SDK older than 2.5.0.
    public static func appleAdsTokenStatus() async -> AppleAdsTokenStatus? {
        await facade.withRuntime { core in await core.appleAdsTokenStatus() }
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
    public static func acceptExplicitLinkToken(_ token: String, kind: String = "owned_deferred") async -> DeepLinkResult {
        await facade.withRuntime { core in await core.acceptExactToken(token, kind: kind) }
    }

    @_spi(AttriKitLinkToken)
    public static func canReadLinkTokenPasteboard() async -> Bool {
        await facade.withRuntime { core in await core.canReadLinkTokenPasteboard() }
    }

    /// Whether `track` would accept this one property. A companion module that builds properties
    /// from another SDK's data uses it to drop a single unacceptable value, because `track` refuses
    /// the WHOLE event on the first one it rejects.
    @_spi(AttriKitSuperwall)
    public static func acceptsProperty(_ key: String, _ value: AttriKitValue) -> Bool {
        (try? validateProperties([key: value])) != nil
    }

    @_spi(AttriKitTracking)
    public static func registerTrackingEvidenceProvider(
        idfa: @escaping @Sendable () -> UUID?,
        idfv: @escaping @Sendable () -> UUID?
    ) {
        deviceEvidenceRegistry.install(
            idfa: idfa,
            idfv: idfv
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

    static func enqueueForTesting(_ operation: @escaping @Sendable (CoreRuntime) async -> Void) {
        facade.enqueue(operation)
    }

    static func registeredWaitersCountForTesting() -> Int {
        facade.registeredWaitersCountForTesting()
    }

    static func resolveTimeoutCountForTesting() -> Int {
        facade.resolveTimeoutCountForTesting()
    }

    #if DEBUG
    static func withRuntimeForTesting<T: Sendable>(_ operation: @escaping @Sendable (CoreRuntime) async -> T) async -> T {
        await facade.withRuntime(operation)
    }
    #endif
}

private final class DeviceEvidenceRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var idfa: @Sendable () -> UUID? = { nil }
    private var idfv: @Sendable () -> UUID? = { nil }

    func install(
        idfa: @escaping @Sendable () -> UUID?,
        idfv: @escaping @Sendable () -> UUID?
    ) {
        lock.lock()
        self.idfa = idfa
        self.idfv = idfv
        lock.unlock()
    }

    func current() -> DeviceEvidence {
        let providers = locked { (idfa, idfv) }
        return DeviceEvidence(idfa: providers.0(), idfv: providers.1())
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

private enum DrainResult: Sendable {
    case completed
    case timedOut
    case cancelled
}

private enum BoundedRuntimeOutcome<T: Sendable>: Sendable {
    case completed(T)
    case timedOut
    case cancelled
}

private final class DrainWaiter: @unchecked Sendable {
    let id: UInt64
    let targetGeneration: UInt64
    private let lock = NSLock()
    private var continuation: CheckedContinuation<DrainResult, Never>?
    private var timerTask: Task<Void, Never>?
    private var isResolved = false

    init(id: UInt64, targetGeneration: UInt64, continuation: CheckedContinuation<DrainResult, Never>) {
        self.id = id
        self.targetGeneration = targetGeneration
        self.continuation = continuation
    }

    func attach(timerTask: Task<Void, Never>) {
        lock.lock()
        if isResolved {
            lock.unlock()
            timerTask.cancel()
            return
        }
        self.timerTask = timerTask
        lock.unlock()
    }

    func resolve(result: DrainResult) -> (continuation: CheckedContinuation<DrainResult, Never>, timerTask: Task<Void, Never>?)? {
        lock.lock()
        guard !isResolved, let cont = continuation else {
            lock.unlock()
            return nil
        }
        isResolved = true
        continuation = nil
        let timer = timerTask
        timerTask = nil
        lock.unlock()
        return (cont, timer)
    }
}

private final class DrainCoordinator: @unchecked Sendable {
    private let lock = NSLock()
    private var isCancelled = false
    private var waiterID: UInt64?
    private let facade: AttriKitFacade

    init(facade: AttriKitFacade) {
        self.facade = facade
    }

    func onCancel() {
        var toCancelID: UInt64?
        lock.lock()
        isCancelled = true
        toCancelID = waiterID
        lock.unlock()

        if let id = toCancelID {
            facade.resolveCancellation(waiterID: id)
        }
    }

    func run(
        targetGeneration: UInt64,
        timeout: Duration?,
        continuation: CheckedContinuation<DrainResult, Never>
    ) {
        lock.lock()
        if isCancelled || Task.isCancelled {
            lock.unlock()
            continuation.resume(returning: .cancelled)
            return
        }

        guard let (id, waiter) = facade.registerWaiter(
            targetGeneration: targetGeneration,
            continuation: continuation
        ) else {
            // Already drained in facade!
            lock.unlock()
            continuation.resume(returning: .completed)
            return
        }

        // No bound: the waiter resolves when the queue drains or the caller is cancelled.
        guard let timeout else {
            self.waiterID = id
            lock.unlock()
            return
        }

        if timeout <= .zero {
            lock.unlock()
            facade.resolveTimeout(waiterID: id)
            return
        }

        self.waiterID = id
        lock.unlock()

        let timerTask = Task { [weak facade] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else { return }
            facade?.resolveTimeout(waiterID: id)
        }
        waiter.attach(timerTask: timerTask)
    }
}

private final class AttriKitFacade: @unchecked Sendable {
    private let lock = NSLock()
    private var runtime = CoreRuntime(configuration: .live)
    private var tail: Task<Void, Never>?
    private var enqueueGeneration: UInt64 = 0
    private var completedGeneration: UInt64 = 0
    private var nextWaiterID: UInt64 = 0
    private var waiters: [UInt64: DrainWaiter] = [:]

    /// The runtime a synchronous accessor reads from. Not ordered behind the queue on purpose: the
    /// `installID` property answers at once with whatever the runtime has established so far.
    func currentRuntime() -> CoreRuntime {
        locked { runtime }
    }

    func enqueue(_ operation: @escaping @Sendable (CoreRuntime) async -> Void) {
        lock.lock()
        enqueueGeneration &+= 1
        let generation = enqueueGeneration
        let previous = tail
        let current = runtime
        let task = Task {
            if let previous { await previous.value }
            await operation(current)
            self.markCompleted(generation: generation)
        }
        tail = task
        lock.unlock()
    }

    private func markCompleted(generation: UInt64) {
        var toResume: [(continuation: CheckedContinuation<DrainResult, Never>, timerTask: Task<Void, Never>?)] = []
        lock.lock()
        if generation > completedGeneration {
            completedGeneration = generation
        }
        if completedGeneration == enqueueGeneration {
            tail = nil
        }
        var remainingWaiters: [UInt64: DrainWaiter] = [:]
        for (id, waiter) in waiters {
            if waiter.targetGeneration <= completedGeneration {
                if let resolution = waiter.resolve(result: .completed) {
                    toResume.append(resolution)
                }
            } else {
                remainingWaiters[id] = waiter
            }
        }
        waiters = remainingWaiters
        lock.unlock()

        for item in toResume {
            item.timerTask?.cancel()
            item.continuation.resume(returning: .completed)
        }
    }

    func registerWaiter(
        targetGeneration: UInt64,
        continuation: CheckedContinuation<DrainResult, Never>
    ) -> (id: UInt64, waiter: DrainWaiter)? {
        lock.lock()
        defer { lock.unlock() }
        if completedGeneration >= targetGeneration {
            return nil
        }
        nextWaiterID &+= 1
        let id = nextWaiterID
        let waiter = DrainWaiter(id: id, targetGeneration: targetGeneration, continuation: continuation)
        waiters[id] = waiter
        return (id, waiter)
    }

    private func resolveWaiter(waiterID: UInt64, result: DrainResult) {
        var resolution: (continuation: CheckedContinuation<DrainResult, Never>, timerTask: Task<Void, Never>?)?
        lock.lock()
        if let waiter = waiters.removeValue(forKey: waiterID) {
            resolution = waiter.resolve(result: result)
        }
        lock.unlock()

        if let (continuation, timer) = resolution {
            timer?.cancel()
            continuation.resume(returning: result)
        }
    }

    private var resolveTimeoutCallCount: Int = 0

    func resolveTimeout(waiterID: UInt64) {
        lock.lock()
        resolveTimeoutCallCount += 1
        lock.unlock()
        resolveWaiter(waiterID: waiterID, result: .timedOut)
    }

    func resolveTimeoutCountForTesting() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return resolveTimeoutCallCount
    }

    func resolveCancellation(waiterID: UInt64) {
        resolveWaiter(waiterID: waiterID, result: .cancelled)
    }

    func registeredWaitersCountForTesting() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return waiters.count
    }

    private var inFlightOperations: [ObjectIdentifier: (count: Int, waiters: [CheckedContinuation<Void, Never>])] = [:]

    private struct RuntimeLease {
        let runtime: CoreRuntime
        let release: () -> Void
    }

    private func acquireRuntimeLease() -> RuntimeLease {
        lock.lock()
        let current = runtime
        let id = ObjectIdentifier(current)
        let inFlight = inFlightOperations[id] ?? (count: 0, waiters: [])
        inFlightOperations[id] = (count: inFlight.count + 1, waiters: inFlight.waiters)
        lock.unlock()
        return RuntimeLease(runtime: current) { [self] in
            self.endOperation(for: current)
        }
    }

    private func endOperation(for target: CoreRuntime) {
        var toResume: [CheckedContinuation<Void, Never>] = []
        lock.lock()
        let id = ObjectIdentifier(target)
        if var current = inFlightOperations[id] {
            current.count -= 1
            if current.count <= 0 {
                toResume = current.waiters
                inFlightOperations.removeValue(forKey: id)
            } else {
                inFlightOperations[id] = current
            }
        }
        lock.unlock()
        for continuation in toResume {
            continuation.resume()
        }
    }

    private func awaitOperations(for target: CoreRuntime) async {
        let id = ObjectIdentifier(target)
        let shouldWait: Bool = locked {
            (inFlightOperations[id]?.count ?? 0) > 0
        }
        guard shouldWait else { return }

        await withCheckedContinuation { continuation in
            lock.lock()
            if let current = inFlightOperations[id], current.count > 0 {
                var currentWaiters = current.waiters
                currentWaiters.append(continuation)
                inFlightOperations[id] = (count: current.count, waiters: currentWaiters)
                lock.unlock()
            } else {
                lock.unlock()
                continuation.resume()
            }
        }
    }

    func withRuntime<T: Sendable>(_ operation: @escaping @Sendable (CoreRuntime) async -> T) async -> T {
        let snapshot: (Task<Void, Never>?, CoreRuntime) = locked { (tail, runtime) }
        if let tail = snapshot.0 { await tail.value }
        let lease = acquireRuntimeLease()
        defer { lease.release() }
        return await operation(lease.runtime)
    }

    func withRuntime<T: Sendable>(
        queueTimeout: Duration?,
        _ operation: @escaping @Sendable (CoreRuntime) async -> T
    ) async -> BoundedRuntimeOutcome<T> {
        guard let queueTimeout else {
            // Unbounded, but not deaf to cancellation. Awaiting the tail task directly could not
            // be interrupted, so a cancelled caller waited out every queued operation and then
            // got an answer the documentation says it does not get. The drain waiter resolves on
            // the drain or on this caller's cancellation, and cancelling it never cancels the
            // queued operations, which belong to the app.
            let target: UInt64? = locked { completedGeneration >= enqueueGeneration ? nil : enqueueGeneration }
            if let target, await drainGeneration(target, timeout: nil) != .completed { return .cancelled }
            if Task.isCancelled { return .cancelled }
            let lease = acquireRuntimeLease()
            defer { lease.release() }
            return .completed(await operation(lease.runtime))
        }

        let snapshot: (targetGen: UInt64, isDrained: Bool, lease: RuntimeLease?) = locked {
            let isDrained = completedGeneration >= enqueueGeneration
            if isDrained {
                let current = runtime
                let id = ObjectIdentifier(current)
                let inFlight = inFlightOperations[id] ?? (count: 0, waiters: [])
                inFlightOperations[id] = (count: inFlight.count + 1, waiters: inFlight.waiters)
                let lease = RuntimeLease(runtime: current) { [self] in
                    self.endOperation(for: current)
                }
                return (enqueueGeneration, true, lease)
            }
            return (enqueueGeneration, false, nil)
        }

        if let lease = snapshot.lease {
            if Task.isCancelled {
                lease.release()
                return .cancelled
            }
            defer { lease.release() }
            return .completed(await operation(lease.runtime))
        }

        let drainResult = await drainGeneration(snapshot.targetGen, timeout: queueTimeout)
        switch drainResult {
        case .completed:
            let lease = acquireRuntimeLease()
            defer { lease.release() }
            return .completed(await operation(lease.runtime))
        case .timedOut:
            return .timedOut
        case .cancelled:
            return .cancelled
        }
    }

    private func drainGeneration(_ targetGeneration: UInt64, timeout: Duration?) async -> DrainResult {
        let coordinator = DrainCoordinator(facade: self)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                coordinator.run(
                    targetGeneration: targetGeneration,
                    timeout: timeout,
                    continuation: continuation
                )
            }
        } onCancel: {
            coordinator.onCancel()
        }
    }

    func withRuntimeThrowing<T: Sendable>(_ operation: @escaping @Sendable (CoreRuntime) async throws -> T) async throws -> T {
        let snapshot: (Task<Void, Never>?, CoreRuntime) = locked { (tail, runtime) }
        if let tail = snapshot.0 { await tail.value }
        let lease = acquireRuntimeLease()
        defer { lease.release() }
        return try await operation(lease.runtime)
    }

    func replace(with newRuntime: CoreRuntime) async {
        var toResume: [(continuation: CheckedContinuation<DrainResult, Never>, timerTask: Task<Void, Never>?)] = []
        let old: (Task<Void, Never>?, CoreRuntime) = locked {
            let old = (tail, runtime)
            tail = nil
            completedGeneration = enqueueGeneration
            resolveTimeoutCallCount = 0
            for (_, waiter) in waiters {
                if let resolution = waiter.resolve(result: .completed) {
                    toResume.append(resolution)
                }
            }
            waiters.removeAll()
            runtime = newRuntime
            return old
        }
        for item in toResume {
            item.timerTask?.cancel()
            item.continuation.resume(returning: .completed)
        }
        old.0?.cancel()
        if let oldTail = old.0 { await oldTail.value }
        await awaitOperations(for: old.1)
        await old.1.shutdown()
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}
