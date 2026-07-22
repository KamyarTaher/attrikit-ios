import Foundation
#if os(iOS)
import BackgroundTasks
#endif

private final class EvidenceResultRace: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<String?, Never>?

    init(continuation: CheckedContinuation<String?, Never>) {
        self.continuation = continuation
    }

    func resolve(with result: String?) {
        lock.lock()
        guard let continuation else {
            lock.unlock()
            return
        }
        self.continuation = nil
        lock.unlock()
        continuation.resume(returning: result)
    }
}

struct AttriKitTestingConfiguration: Sendable {
    let baseURL: URL
    let transport: HTTPTransport
    let storage: SDKStorage
    let evidence: PlatformEvidenceProviding
    let deviceEvidence: @Sendable () -> DeviceEvidence
    let now: @Sendable () -> Date
    let lifecycle: ApplicationLifecycleObserving

    init(
        baseURL: URL,
        transport: HTTPTransport,
        storage: SDKStorage,
        evidence: PlatformEvidenceProviding,
        deviceEvidence: @escaping @Sendable () -> DeviceEvidence,
        now: @escaping @Sendable () -> Date,
        lifecycle: ApplicationLifecycleObserving = ApplicationLifecycleObserver()
    ) {
        self.baseURL = baseURL
        self.transport = transport
        self.storage = storage
        self.evidence = evidence
        self.deviceEvidence = deviceEvidence
        self.now = now
        self.lifecycle = lifecycle
    }

    static let live = AttriKitTestingConfiguration(
        baseURL: liveEndpoint(),
        transport: URLSessionTransport(),
        storage: SDKStorage(),
        evidence: ApplePlatformEvidenceProvider(),
        deviceEvidence: { AttriKit.currentDeviceEvidence() },
        now: { Date() },
        lifecycle: ApplicationLifecycleObserver()
    )

    /// The ingestion endpoint comes from the host app's Info.plist (`AttriKitEndpoint`) —
    /// the SDK ships no compiled-in hostname (base-URL portability; the production domain
    /// is not final). A missing/invalid key resolves to a reserved `.invalid` host so
    /// requests fail fast and visibly instead of silently targeting a wrong server.
    private static func liveEndpoint() -> URL {
        #if DEBUG
        if let raw = Bundle.main.object(forInfoDictionaryKey: "AttriKitEndpoint") as? String, let url = URL(string: raw), url.scheme == "http", ["127.0.0.1", "localhost"].contains(url.host ?? "") { return url }
        #endif
        if let raw = Bundle.main.object(forInfoDictionaryKey: "AttriKitEndpoint") as? String,
           let url = URL(string: raw), url.scheme == "https" {
            return url
        }
        return URL(string: "https://attrikit-endpoint-not-configured.invalid")
            ?? URL(fileURLWithPath: "/attrikit-endpoint-not-configured")
    }
}

private struct BufferedEvent: Sendable {
    let event: AttriKitEvent
    let properties: [String: AttriKitValue]
    let occurredAt: Date
}

actor CoreRuntime {
    private struct ActiveSession {
        let index: Int
        let startedAt: Date
    }

    private static let sessionGap: TimeInterval = 30

    private let configuration: AttriKitTestingConfiguration
    private var apiKey: String?
    private var consent: AttriKitConsent = .unknown
    private var identity: InstallationIdentity?
    private var sessionID = UUID()
    private var bufferedBeforeStart: [BufferedEvent] = []
    private var pendingUserID: String?
    private var funnelIdentity = FunnelIdentity()
    private var exactToken: ExactTokenReference?
    private var attributionCache: AttributionResult?
    private var firstOpenTask: Task<Void, Never>?
    private var pollTask: Task<Void, Never>?
    private var queueTask: Task<Void, Never>?
    private var attributionETag: String?
    private var sessionTrackingEnabled = true
    private var lifecycleObservationStarted = false
    private var applicationIsActive = false
    private var activeSession: ActiveSession?
    private var lastSessionEndedAt: Date?
    private var lastSessionIndex: Int?
    private var deletionPending = false
    private var activeNetworkRequestCount = 0
    private var networkQuiescenceWaiters: [CheckedContinuation<Void, Never>] = []

    init(configuration: AttriKitTestingConfiguration) {
        self.configuration = configuration
    }

    func start(apiKey: String, consent: AttriKitConsent) async {
        guard self.apiKey == nil else {
            if self.consent != consent { await setConsent(consent) }
            return
        }
        guard (16...512).contains(apiKey.utf8.count) else { return }
        try? await configuration.storage.recoverPendingRevocationIfNeeded()
        let previouslyStoredConsent = await configuration.storage.storedConsent()
        self.apiKey = apiKey
        self.consent = consent
        startLifecycleObservation()
        if await configuration.storage.deletionTombstone() != nil {
            deletionPending = true
            bufferedBeforeStart.removeAll()
            return
        }
        if consent == .revoked, previouslyStoredConsent != .revoked {
            try? await configuration.storage.beginRevocationTransition()
            await stopAndWipe(finalizeRevocation: true)
            return
        }
        await configuration.storage.storeConsent(consent)
        guard consent.allowsMeasurement else {
            if consent == .denied || consent == .revoked {
                await stopAndWipe(finalizeRevocation: false)
            }
            return
        }
        await beginMeasurement()
    }

    func setConsent(_ newConsent: AttriKitConsent) async {
        let previous = consent
        consent = newConsent
        if newConsent == .revoked {
            let startsRevocation = !deletionPending && previous != .revoked
            if startsRevocation {
                try? await configuration.storage.beginRevocationTransition()
            } else {
                await configuration.storage.storeConsent(newConsent)
            }
            resetSessionState()
            await stopAndWipe(finalizeRevocation: startsRevocation)
            return
        }
        await configuration.storage.storeConsent(newConsent)
        if newConsent == .denied {
            resetSessionState()
            await stopAndWipe(finalizeRevocation: false)
            return
        }
        guard newConsent.allowsMeasurement, apiKey != nil, !deletionPending else { return }
        if !previous.allowsMeasurement {
            await beginMeasurement()
        } else if previous != newConsent {
            scheduleConsentReceipt(scope: "tracking")
        }
    }

    func track(_ event: AttriKitEvent, properties: [String: AttriKitValue]) async {
        guard (try? validateProperties(properties)) != nil else { return }
        let now = configuration.now()
        guard apiKey != nil else {
            bufferedBeforeStart.append(BufferedEvent(event: event, properties: properties, occurredAt: now))
            if bufferedBeforeStart.count > 100 { bufferedBeforeStart.removeFirst() }
            return
        }
        guard !deletionPending, consent.allowsMeasurement, let identity else { return }
        await enqueue(event, properties: properties, occurredAt: now, identity: identity)
    }

    func setSessionTrackingEnabled(_ enabled: Bool) async {
        sessionTrackingEnabled = enabled
        if enabled, applicationIsActive {
            await applicationDidBecomeActive()
        } else if !enabled {
            resetSessionState()
        }
    }

    func applicationDidBecomeActive() async {
        applicationIsActive = true
        guard apiKey != nil, sessionTrackingEnabled, consent.allowsMeasurement, identity != nil else { return }
        guard activeSession == nil else { return }

        let now = configuration.now()
        let canResumeRecentSession = lastSessionEndedAt.map {
            let gap = now.timeIntervalSince($0)
            return gap >= 0 && gap <= Self.sessionGap
        } ?? false

        let index: Int
        if canResumeRecentSession, let lastSessionIndex {
            index = lastSessionIndex
        } else {
            index = await configuration.storage.nextSessionIndex()
            sessionID = UUID()
        }
        activeSession = ActiveSession(index: index, startedAt: now)
    }

    func applicationWillResignActive() async {
        applicationIsActive = false
        guard sessionTrackingEnabled, consent.allowsMeasurement,
              let identity, let activeSession else { return }

        let endedAt = configuration.now()
        self.activeSession = nil
        lastSessionEndedAt = endedAt
        lastSessionIndex = activeSession.index

        let elapsed = max(0, endedAt.timeIntervalSince(activeSession.startedAt))
        let roundedMilliseconds = min(Double(Int.max), (elapsed * 1_000).rounded())
        guard roundedMilliseconds.isFinite,
              let event = try? AttriKitEvent("session_end", version: 1) else { return }
        let durationMilliseconds = Int(roundedMilliseconds)
        await enqueue(
            event,
            properties: [
                "duration_ms": .number(Double(durationMilliseconds)),
                "session_index": .number(Double(activeSession.index)),
            ],
            occurredAt: endedAt,
            identity: identity
        )
    }

    func attribution(timeout: Duration) async -> AttributionResult {
        guard apiKey != nil else { return .notStarted }
        guard !deletionPending else { return .failed }
        guard consent.allowsMeasurement else { return .consentRequired }
        if let attributionCache { return attributionCache }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if let attributionCache { return attributionCache }
            if Task.isCancelled { return .failed }
            try? await Task.sleep(for: .milliseconds(25))
        }
        return attributionCache ?? .timedOut
    }

    func handle(_ url: URL) async -> DeepLinkResult {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let token = components.queryItems?.first(where: { $0.name == "attrkit_token" })?.value else {
            return .ignored
        }
        return await acceptExactToken(token, kind: "owned_deferred")
    }

    func acceptExactToken(_ token: String, kind: String) async -> DeepLinkResult {
        guard Self.isVersionedLinkToken(token),
              ["clipboard", "owned_deferred", "customer_signed"].contains(kind) else { return .invalid }
        guard !deletionPending else { return .ignored }
        if kind == "clipboard" {
            guard consent.allowsTracking else { return .consentRequired }
        } else {
            guard consent.allowsMeasurement else { return .consentRequired }
        }
        guard await configuration.storage.consumeExactTokenIfNew(token) else { return .ignored }
        exactToken = ExactTokenReference(token: token, kind: kind, clipboardOptIn: kind == "clipboard" ? true : nil)
        await submitIdentify()
        var consumedTokenURL = URLComponents()
        consumedTokenURL.scheme = "attrikit"
        consumedTokenURL.host = "token"
        consumedTokenURL.path = "/consumed"
        guard let url = consumedTokenURL.url else { return .invalid }
        return .handled(url)
    }

    func canReadLinkTokenPasteboard() -> Bool { consent.allowsTracking }

    private static func isVersionedLinkToken(_ token: String) -> Bool {
        let bytes = token.utf8
        guard bytes.count == 47, token.hasPrefix("ak1_") else { return false }
        return bytes.dropFirst(4).allSatisfy { byte in
            (48...57).contains(byte)
                || (65...90).contains(byte)
                || (97...122).contains(byte)
                || byte == 45
                || byte == 95
        }
    }

    func setUserID(_ opaqueID: String?) async {
        let sanitized = opaqueID.flatMap { value -> String? in
            guard !value.isEmpty, value.utf8.count <= 256,
                  !value.contains("@") else { return nil }
            return value
        }
        pendingUserID = sanitized
        guard consent.allowsMeasurement, !deletionPending else { return }
        await configuration.storage.setUserID(sanitized)
    }

    func setFunnelIdentity(_ identity: FunnelIdentity) async {
        funnelIdentity = identity
        await submitIdentify()
    }

    func refreshTrackingEvidence() async {
        await submitIdentify()
    }

    func deleteData() async throws {
        guard let apiKey else { throw AttriKitError.notStarted }
        let tombstone: DeletionTombstone
        if let pending = await configuration.storage.deletionTombstone() {
            tombstone = pending
        } else {
            let currentIdentity: InstallationIdentity
            if let identity {
                currentIdentity = identity
            } else {
                currentIdentity = try await configuration.storage.initializeIdentities()
            }
            tombstone = DeletionTombstone(
                installationID: currentIdentity.installationID,
                installEpochID: currentIdentity.installEpochID
            )
            try await configuration.storage.storeDeletionTombstone(tombstone)
        }

        deletionPending = true
        firstOpenTask?.cancel()
        pollTask?.cancel()
        queueTask?.cancel()
        firstOpenTask = nil
        pollTask = nil
        queueTask = nil
        attributionCache = nil
        exactToken = nil
        funnelIdentity = FunnelIdentity()
        bufferedBeforeStart.removeAll()
        resetSessionState()
        await waitForNetworkQuiescence()

        let body = try attriKitJSONEncoder().encode(tombstone)
        let request = RequestFactory(baseURL: configuration.baseURL, apiKey: apiKey)
            .post(
                path: "v1/privacy/delete",
                body: body,
                idempotencyKey: tombstone.installEpochID.uuidString.lowercased()
            )
        let response = try await configuration.transport.send(request)
        guard (200..<300).contains(response.statusCode) else {
            throw AttriKitError.deletionFailed(response.statusCode)
        }
        try await configuration.storage.completeDeletion()

        identity = nil
        pendingUserID = nil
        sessionID = UUID()
        consent = .unknown
        self.apiKey = nil
        deletionPending = false
    }

    func shutdown() async {
        configuration.lifecycle.stop()
        lifecycleObservationStarted = false
        applicationIsActive = false
        resetSessionState()
        firstOpenTask?.cancel()
        pollTask?.cancel()
        queueTask?.cancel()
    }

    private func beginMeasurement() async {
        guard !deletionPending else { return }
        do {
            identity = try await configuration.storage.initializeIdentities()
        } catch {
            attributionCache = .failed
            return
        }
        guard let identity else { return }
        if let pendingUserID {
            await configuration.storage.setUserID(pendingUserID)
        } else {
            pendingUserID = await configuration.storage.storedUserID()
        }
        let pending = bufferedBeforeStart
        bufferedBeforeStart.removeAll()
        for buffered in pending {
            await enqueue(buffered.event, properties: buffered.properties, occurredAt: buffered.occurredAt, identity: identity)
        }
        await startOrResumeFirstOpen()
        scheduleQueueFlush()
        if applicationIsActive { await applicationDidBecomeActive() }
    }

    private func startLifecycleObservation() {
        guard !lifecycleObservationStarted else { return }
        lifecycleObservationStarted = true
        configuration.lifecycle.start { [weak self] event in
            guard let self else { return }
            switch event {
            case .didBecomeActive:
                await self.applicationDidBecomeActive()
            case .willResignActive:
                await self.applicationWillResignActive()
            case .willTerminate:
                await self.applicationWillTerminate()
            }
        }
    }

    private func applicationWillTerminate() async {
        if activeSession != nil { await applicationWillResignActive() }
        guard canUseNetwork() else { return }
        _ = await flushQueueOnce()
    }

    private func resetSessionState() {
        activeSession = nil
        lastSessionEndedAt = nil
        lastSessionIndex = nil
    }

    private func enqueue(_ event: AttriKitEvent, properties: [String: AttriKitValue], occurredAt: Date, identity: InstallationIdentity) async {
        let envelope = EventEnvelope(
            eventID: UUID(),
            eventName: event.name,
            eventVersion: event.version,
            occurredAt: occurredAt,
            sentAt: occurredAt,
            installationID: identity.installationID,
            installEpochID: identity.installEpochID,
            sessionID: sessionID,
            consent: eventConsent(),
            properties: properties
        )
        do {
            _ = try await configuration.storage.enqueue(envelope, now: configuration.now())
            scheduleQueueFlush()
        } catch {
            // Protected revenue events are refused rather than silently evicting an older protected event.
        }
    }

    private func submitFirstOpen() async {
        guard consent.allowsMeasurement, !deletionPending, let apiKey, let identity else { return }
        // Platform evidence is best-effort and BOUNDED: AppTransaction.shared can hang on
        // simulators/sandboxes (it does not throw), and a slow StoreKit must never delay the
        // first-open envelope — click-to-install timing is the product's accuracy substrate.
        let evidence = configuration.evidence
        let deviceEvidence = configuration.deviceEvidence()
        async let transaction = Self.boundedEvidence { await evidence.appTransactionJWS() }
        async let adServices = Self.boundedEvidence { await evidence.adServicesToken() }
        let envelope = FirstOpenEnvelope(
            installationID: identity.installationID,
            installEpochID: identity.installEpochID,
            occurredAt: configuration.now(),
            appVersion: configuration.evidence.appVersion(),
            coarseContext: configuration.evidence.coarseContext(),
            consent: ConsentPayload(state: consent, policyVersion: 1),
            appTransactionJWS: await transaction,
            asaToken: await adServices,
            exactTokenReference: exactToken,
            webFirstParty: funnelIdentity.isEmpty ? nil : WebFirstPartyIdentity(funnelIdentity),
            // Server rule (firstOpenEnvelopeSchema refine): idfa requires
            // tracking_granted — sending it under measurement consent is a 422
            // and the first-open is permanently lost. Gate client-side on the
            // same rule. IDFV is consent-free. (wire-review P0-1, 2026-07-22)
            idfa: consent.allowsTracking ? deviceEvidence.idfa.map(LowercaseUUID.init(wrappedValue:)) : nil,
            idfv: deviceEvidence.idfv.map(LowercaseUUID.init(wrappedValue:)),
            localLineagePresent: identity.localLineagePresent,
            localEpochPresent: identity.localEpochPresent
        )
        do {
            let data = try attriKitJSONEncoder().encode(envelope)
            let request = RequestFactory(baseURL: configuration.baseURL, apiKey: apiKey)
                .post(path: "v1/ingest/first-open", body: data, idempotencyKey: identity.installEpochID.uuidString.lowercased())
            let response = try await sendMeasurementRequest(request)
            guard consent.allowsMeasurement, !deletionPending else { return }
            switch response.statusCode {
            case 200:
                let decoded = try attriKitJSONDecoder().decode(FirstOpenResponse.self, from: response.data)
                attributionCache = decoded.attribution.map(AttributionResult.attributed) ?? .unattributed
                try? await configuration.storage.setRetryState(nil)
            case 202:
                let decoded = try attriKitJSONDecoder().decode(FirstOpenResponse.self, from: response.data)
                startPolling(after: decoded.retryAfterMilliseconds ?? 500)
                try? await configuration.storage.setRetryState(nil)
            case 204:
                startPolling(after: 0)
                try? await configuration.storage.setRetryState(nil)
            case 400..<500 where response.statusCode != 429:
                attributionCache = .failed
                try? await configuration.storage.setRetryState(nil)
            default:
                await scheduleFirstOpenRetry()
            }
        } catch {
            await scheduleFirstOpenRetry()
        }
    }

    private func submitIdentify() async {
        guard consent.allowsMeasurement, !deletionPending, let apiKey, let identity else { return }
        let deviceEvidence = configuration.deviceEvidence()
        guard !funnelIdentity.isEmpty || exactToken != nil
                || deviceEvidence.idfa != nil || deviceEvidence.idfv != nil else { return }
        let envelope = IdentifyEnvelope(
            installationID: identity.installationID,
            installEpochID: identity.installEpochID,
            occurredAt: configuration.now(),
            emailHash: funnelIdentity.emailHash,
            phoneHash: funnelIdentity.phoneHash,
            exactTokenReference: exactToken,
            // Same consent gate as first-open (wire-review P1-1): the identifier must
            // never travel without ATT authorization, even if the server would drop it.
            idfa: consent.allowsTracking ? deviceEvidence.idfa.map(LowercaseUUID.init(wrappedValue:)) : nil,
            idfv: deviceEvidence.idfv.map(LowercaseUUID.init(wrappedValue:))
        )
        guard let body = try? attriKitJSONEncoder().encode(envelope) else { return }
        let request = RequestFactory(baseURL: configuration.baseURL, apiKey: apiKey)
            .post(path: "v1/ingest/identify", body: body, idempotencyKey: UUID().uuidString.lowercased())
        _ = try? await sendMeasurementRequest(request)
    }

    private func startPolling(after milliseconds: Int) {
        pollTask?.cancel()
        pollTask = Task {
            if milliseconds > 0 { try? await Task.sleep(for: .milliseconds(milliseconds)) }
            var delay = 250
            while !Task.isCancelled, self.canUseNetwork() {
                await self.pollAttributionOnce()
                if self.hasAttributionResult() { return }
                let jitter = Int.random(in: 0...max(1, delay / 4))
                try? await Task.sleep(for: .milliseconds(delay + jitter))
                delay = min(delay * 2, 5_000)
            }
        }
    }

    private func pollAttributionOnce() async {
        guard consent.allowsMeasurement, !deletionPending, let apiKey, let identity else { return }
        do {
            let request = RequestFactory(baseURL: configuration.baseURL, apiKey: apiKey)
                .get(path: "v1/attribution/\(identity.installEpochID.uuidString.lowercased())", etag: attributionETag)
            let response = try await sendMeasurementRequest(request)
            guard consent.allowsMeasurement, !deletionPending else { return }
            if let etag = response.headers["etag"] { attributionETag = etag }
            switch response.statusCode {
            case 200:
                let decoded = try attriKitJSONDecoder().decode(AttributionResponse.self, from: response.data)
                attributionCache = decoded.attribution.map(AttributionResult.attributed) ?? .unattributed
            case 204:
                attributionCache = .unattributed
            case 400..<500 where response.statusCode != 429 && response.statusCode != 304:
                attributionCache = .failed
            default:
                break
            }
        } catch {}
    }

    private func scheduleQueueFlush() {
        guard queueTask == nil else { return }
        queueTask = Task {
            var delayMilliseconds = 1_000
            while !Task.isCancelled, self.canUseNetwork() {
                let outcome = await self.flushQueueOnce()
                if outcome == .empty { break }
                if outcome == .sent {
                    delayMilliseconds = 1_000
                    continue
                }
                let jitter = Int.random(in: 0...max(1, delayMilliseconds / 4))
                try? await Task.sleep(for: .milliseconds(delayMilliseconds + jitter))
                delayMilliseconds = min(delayMilliseconds * 2, 60_000)
            }
            self.clearQueueTask()
        }
    }

    private enum QueueFlushOutcome { case empty, sent, retry }

    private func flushQueueOnce() async -> QueueFlushOutcome {
        guard consent.allowsMeasurement, !deletionPending, let apiKey else { return .empty }
        do {
            guard let batch = try await configuration.storage.nextEventBatch(now: configuration.now()) else {
                return .empty
            }
            let data = try attriKitJSONEncoder().encode(EventBatch(batchID: batch.batchID, events: batch.events))
            let request = RequestFactory(baseURL: configuration.baseURL, apiKey: apiKey)
                .post(path: "v1/ingest/events:batch", body: data, idempotencyKey: batch.batchID)
            let response = try await sendMeasurementRequest(request)
            guard consent.allowsMeasurement, !deletionPending else { return .empty }
            if (200..<300).contains(response.statusCode) || Self.isPermanentClientFailure(response.statusCode) {
                try await configuration.storage.acknowledgeEventBatch(batchID: batch.batchID)
                return .sent
            }
            return .retry
        } catch {
            return .retry
        }
    }

    private func clearQueueTask() { queueTask = nil }

    static func isPermanentClientFailure(_ statusCode: Int) -> Bool {
        (400..<500).contains(statusCode) && ![401, 403, 408, 429].contains(statusCode)
    }

    private func sendMeasurementRequest(_ request: URLRequest) async throws -> HTTPResult {
        guard !deletionPending else { throw CancellationError() }
        activeNetworkRequestCount += 1
        defer {
            activeNetworkRequestCount -= 1
            if activeNetworkRequestCount == 0 {
                let waiters = networkQuiescenceWaiters
                networkQuiescenceWaiters.removeAll()
                for waiter in waiters { waiter.resume() }
            }
        }
        return try await configuration.transport.send(request)
    }

    private func waitForNetworkQuiescence() async {
        guard activeNetworkRequestCount > 0 else { return }
        await withCheckedContinuation { continuation in
            networkQuiescenceWaiters.append(continuation)
        }
    }

    private func scheduleConsentReceipt(scope: String) {
        guard consent.allowsMeasurement, !deletionPending, let apiKey, let identity else { return }
        Task {
            let payload = ConsentReceipt(
                installationID: identity.installationID,
                installEpochID: identity.installEpochID,
                scope: scope,
                consent: ConsentPayload(state: consent, policyVersion: 1),
                occurredAt: configuration.now()
            )
            guard let body = try? attriKitJSONEncoder().encode(payload) else { return }
            let request = RequestFactory(baseURL: configuration.baseURL, apiKey: apiKey)
                .post(path: "v1/ingest/consent", body: body, idempotencyKey: UUID().uuidString.lowercased())
            _ = try? await self.sendMeasurementRequest(request)
        }
    }

    private func scheduleFirstOpenRetry() async {
        guard consent.allowsMeasurement, !deletionPending else { return }
        let current = await configuration.storage.retryState()
        let now = configuration.now()
        let attempt = (current?.attempt ?? 0) + 1
        guard attempt <= 6, now.timeIntervalSince(current?.firstAttemptAt ?? now) < 86_400 else {
            attributionCache = .unattributed
            try? await configuration.storage.setRetryState(nil)
            return
        }
        let delays: [TimeInterval] = [5, 30, 300, 3_600, 10_800, 21_600]
        let delay = delays[min(attempt - 1, delays.count - 1)]
        let state = RetryState(attempt: attempt, firstAttemptAt: current?.firstAttemptAt ?? now, nextAttemptAt: now.addingTimeInterval(delay))
        try? await configuration.storage.setRetryState(state)
        requestBackgroundRetry(earliest: state.nextAttemptAt)
        firstOpenTask = Task {
            try? await Task.sleep(for: .seconds(delay))
            if !Task.isCancelled { await self.submitFirstOpen() }
        }
    }

    private func startOrResumeFirstOpen() async {
        guard !deletionPending else { return }
        firstOpenTask?.cancel()
        if let retry = await configuration.storage.retryState(), retry.nextAttemptAt > configuration.now() {
            let delay = retry.nextAttemptAt.timeIntervalSince(configuration.now())
            requestBackgroundRetry(earliest: retry.nextAttemptAt)
            firstOpenTask = Task {
                try? await Task.sleep(for: .seconds(delay))
                if !Task.isCancelled { await self.submitFirstOpen() }
            }
        } else {
            firstOpenTask = Task { await self.submitFirstOpen() }
        }
    }

    private nonisolated func requestBackgroundRetry(earliest: Date) {
        #if os(iOS)
        let request = BGProcessingTaskRequest(identifier: "io.attrikit.sdk.retry")
        request.earliestBeginDate = earliest
        request.requiresNetworkConnectivity = true
        try? BGTaskScheduler.shared.submit(request)
        #endif
    }

    /// Races a best-effort evidence provider against a wall-clock bound; nil on timeout.
    private static func boundedEvidence(seconds: Int = 2, _ operation: @escaping @Sendable () async -> String?) async -> String? {
        await withCheckedContinuation { continuation in
            let race = EvidenceResultRace(continuation: continuation)
            Task {
                race.resolve(with: await operation())
            }
            Task {
                try? await Task.sleep(for: .seconds(seconds))
                race.resolve(with: nil)
            }
        }
    }

    private func stopAndWipe(finalizeRevocation: Bool) async {
        firstOpenTask?.cancel()
        pollTask?.cancel()
        queueTask?.cancel()
        firstOpenTask = nil
        pollTask = nil
        queueTask = nil
        attributionCache = nil
        identity = nil
        sessionID = UUID()
        bufferedBeforeStart.removeAll()
        exactToken = nil
        pendingUserID = nil
        funnelIdentity = FunnelIdentity()
        resetSessionState()
        try? await configuration.storage.wipeQueue()
        await configuration.storage.setUserID(nil)
        try? await configuration.storage.setRetryState(nil)
        if finalizeRevocation {
            _ = try? await configuration.storage.finishRevocationTransition()
        }
    }

    private func canUseNetwork() -> Bool { consent.allowsMeasurement && !deletionPending }
    private func hasAttributionResult() -> Bool { attributionCache != nil }

    private func eventConsent() -> EventConsent {
        EventConsent(
            measurement: consent.allowsMeasurement ? "granted" : "denied",
            tracking: consent.allowsTracking ? "granted" : (consent == .unknown ? "unknown" : "denied"),
            policyVersion: 1
        )
    }
}

private struct ConsentReceipt: Codable {
    let installationID: UUID
    let installEpochID: UUID
    let scope: String
    let consent: ConsentPayload
    let occurredAt: Date
    let source = "ios_sdk"

    enum CodingKeys: String, CodingKey {
        case installationID = "installation_id"
        case installEpochID = "install_epoch_id"
        case scope, consent
        case occurredAt = "occurred_at"
        case source
    }
}
