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

    /// Updates the host's measurement/tracking consent state.
    ///
    /// Revocation clears queued measurement data, rotates the install epoch, and resets
    /// the session sequence. The stable installation ID is retained only as the erasure
    /// anchor required by `deleteData()`; a confirmed deletion removes that anchor too.
    public static func setConsent(_ consent: AttriKitConsent) {
        facade.enqueue { core in await core.setConsent(consent) }
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
    /// paywall/user-attribute SDK. Call before the first campaign-sensitive placement.
    /// Non-deterministic, unresolved, or consent-blocked attribution returns an empty dictionary.
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
    /// paywall/user-attribute SDK. Call before the first campaign-sensitive placement.
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
    /// paywall/user-attribute SDK. Call before the first campaign-sensitive placement.
    /// Non-deterministic, unresolved, or consent-blocked attribution returns an empty dictionary.
    ///
    /// - Parameters:
    ///   - timeout: Bounds the attribution polling loop once execution begins. It does not bound the wait for previously enqueued operations to drain.
    ///   - queueBound: Bounds the wait for previously enqueued operations to drain before the polling loop begins. When nil, queued operations drain without a separate time bound.
    /// - Returns: Placement parameter dictionary, or empty if attribution is unresolved, timed out, cancelled, or non-deterministic.
    public static func placementParameters(timeout: Duration = .seconds(2), queueBound: Duration?) async -> [String: String] {
        await placementParameters(timeout: timeout, queueTimeout: queueBound)
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
        timeout: Duration,
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
            let snapshot: (Task<Void, Never>?, CoreRuntime) = locked { (tail, runtime) }
            if let tail = snapshot.0 { await tail.value }
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

    private func drainGeneration(_ targetGeneration: UInt64, timeout: Duration) async -> DrainResult {
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
