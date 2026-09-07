import Foundation
#if os(iOS)
import BackgroundTasks
#endif
#if canImport(os)
import os
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
    let backgroundRetryScheduler: BackgroundRetryScheduler
    let diagnostic: @Sendable (String) -> Void

    init(
        baseURL: URL,
        transport: HTTPTransport,
        storage: SDKStorage,
        evidence: PlatformEvidenceProviding,
        deviceEvidence: @escaping @Sendable () -> DeviceEvidence,
        now: @escaping @Sendable () -> Date,
        lifecycle: ApplicationLifecycleObserving = ApplicationLifecycleObserver(),
        backgroundRetryScheduler: BackgroundRetryScheduler = .live,
        diagnostic: @escaping @Sendable (String) -> Void = { AttriKitTestingConfiguration.logDiagnostic($0) }
    ) {
        self.baseURL = baseURL
        self.transport = transport
        self.storage = storage
        self.evidence = evidence
        self.deviceEvidence = deviceEvidence
        self.now = now
        self.lifecycle = lifecycle
        self.backgroundRetryScheduler = backgroundRetryScheduler
        self.diagnostic = diagnostic
    }

    static let live = AttriKitTestingConfiguration(
        baseURL: validatedLiveEndpoint(),
        transport: URLSessionTransport(),
        storage: SDKStorage(),
        evidence: ApplePlatformEvidenceProvider(),
        deviceEvidence: { AttriKit.currentDeviceEvidence() },
        now: { Date() },
        lifecycle: ApplicationLifecycleObserver(),
        backgroundRetryScheduler: .live,
        diagnostic: { logDiagnostic($0) }
    )

    private static func logDiagnostic(_ message: String) {
        #if canImport(os)
        os_log(.error, "%{public}@", message)
        #endif
    }

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
        // No valid endpoint: attribution is impossible for this process. Fail loudly — os_log(.fault)
        // plus a DEBUG trap — and then return the reserved .invalid host, so every request fails
        // fast instead of silently reaching a wrong server. The caller still has to survive a URL
        // that never resolves; this path does not throw or abort in a shipping build.
        #if canImport(os)
        os_log(
            .fault,
            "AttriKit: missing or invalid Info.plist 'AttriKitEndpoint' (must be an https URL); attribution is DISABLED for this build."
        )
        #endif
        // Trap in a host app's DEBUG build so a forgotten AttriKitEndpoint is caught before
        // shipping. Skipped under XCTest: the shared facade eagerly builds `.live` without a
        // host Info.plist, and every unit test overrides the runtime via configureForTesting.
        if NSClassFromString("XCTest") == nil {
            assertionFailure("AttriKit: missing or invalid Info.plist 'AttriKitEndpoint' (must be an https URL); attribution is disabled.")
        }
        return URL(string: "https://attrikit-endpoint-not-configured.invalid")
            ?? URL(fileURLWithPath: "/attrikit-endpoint-not-configured")
    }

    private static func validatedLiveEndpoint() -> URL {
        let url = liveEndpoint()
        #if DEBUG
        // The same loopback exception liveEndpoint() grants: an http 127.0.0.1/localhost endpoint
        // in a DEBUG build is a valid live endpoint, and requiring https here discarded it (F-12250).
        if url.scheme == "http", ["127.0.0.1", "localhost"].contains(url.host ?? "") { return url }
        #endif
        guard url.scheme == "https", let host = url.host, !host.isEmpty else {
            return URL(string: "https://attrikit-endpoint-not-configured.invalid")
                ?? URL(fileURLWithPath: "/attrikit-endpoint-not-configured")
        }
        return url
    }
}

struct BackgroundRetryScheduler: Sendable {
    let submit: @Sendable (Date) throws -> Void

    static let live = BackgroundRetryScheduler { earliest in
        #if os(iOS)
        let request = BGProcessingTaskRequest(identifier: AttriKit.backgroundRetryTaskIdentifier)
        request.earliestBeginDate = earliest
        request.requiresNetworkConnectivity = true
        try BGTaskScheduler.shared.submit(request)
        #endif
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

    /// The published retry contract (docs/sdk-ios "Delivery guarantees", packages/sdk-ios/README.md,
    /// apps/web/public/llms.txt): one initial first-open attempt plus up to six scheduled retries on
    /// 5s, 30s, 5m, 1h, 3h, 6h, inside a ~24h window. These are the numbers the docs print, so they
    /// live here once and are pinned by RetryLadderTests.
    static let firstOpenRetryDelays: [TimeInterval] = [5, 30, 300, 3_600, 10_800, 21_600]
    static let firstOpenRetryWindow: TimeInterval = 86_400

    /// The attribution poll shares that window. It ramps fast (250ms doubling to a 5s ceiling) while
    /// a match can still land in seconds, then falls back to the published ladder. The attempt cap
    /// bounds the fast phase without trusting the wall clock, so the loop terminates in at most
    /// `attributionPollFastAttempts + firstOpenRetryDelays.count` requests even if `now()` never moves.
    private static let attributionPollFastWindow: TimeInterval = 60
    private static let attributionPollFastCeiling = 5_000
    private static let attributionPollFastAttempts = 20
    /// Upper bound on a server-declared cooldown; never wait longer than the ladder's own ceiling.
    private static let maximumRetryAfterSeconds = 21_600
    /// A consent-off drain must terminate even if actor reentrancy adds more receipts while a
    /// request is in flight. Later foregrounds and launches can attempt the remaining durable rows.
    private static let maximumConsentReceiptsPerDrain = 20

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
    private var selectedFirstOpenBody: (installEpochID: UUID, consent: AttriKitConsent, body: Data)?
    /// Guards the slot against a STALE clear. submitFirstOpen can install a retry task into
    /// `firstOpenTask` before its own caller's `clearFirstOpenTask` runs, so a clear must prove it
    /// still owns the slot it is about to nil. Compared by generation rather than by Task identity
    /// so the check does not depend on Task's equality semantics.
    private var firstOpenTaskGeneration = 0
    private var pollTask: Task<Void, Never>?
    private var queueTask: Task<Void, Never>?
    /// Whether the server has REGISTERED this epoch's first-open — a 2xx, and nothing else.
    ///
    /// Everything the SDK sends about an install (`events:batch`, `identify`, `consent`) is
    /// meaningless until the epoch exists server-side; the API answers those a retriable
    /// `unknown_install_epoch` until it does. `start()` spawns first-open in a detached Task and
    /// returns immediately, so without this gate the queue flush races it and — while the API
    /// still answered 422 — every event tracked during a cold launch was DELETED as a permanent
    /// failure. The retry path made it worse: a first-open awaiting its ladder can be hours away
    /// while the flush starts in one second. Reported by a customer against production, Aug 2026.
    ///
    /// Read the name literally. This is NOT "the server has decided": a refusal and an exhausted
    /// ladder both leave it false ON PURPOSE, because neither registers the epoch and opening the
    /// gate for them would retry an impossible request forever instead of delivering anything.
    private var firstOpenRegistered = false
    private var consentReceiptTask: Task<Void, Never>?
    private var consentReceiptTaskGeneration = 0
    /// An identify raised before registration. Only a flag, not a queue: identify always posts the
    /// CURRENT user id, funnel identity, token and device evidence, so one replay after
    /// registration carries everything the intermediate calls would have.
    private var deferredIdentify = false
    private var attributionETag: String?
    private var sessionTrackingEnabled = true
    private var lifecycleObservationStarted = false
    private var applicationIsActive = false
    private var activeSession: ActiveSession?
    private var sessionStartInFlight = false
    /// Bumped by every wipe of session state. A start that suspends on the storage actor
    /// captures this and refuses to install its session if it changed while it was away.
    private var sessionStateGeneration = 0
    /// Bumped every time the app leaves the foreground. `applicationIsActive` alone is a LEVEL,
    /// so a parked activation cannot tell "never backgrounded" from "backgrounded and came back":
    /// a resign followed by a re-activation restores the flag to true, and the parked activation
    /// then installs a session whose startedAt predates the background interval, inflating
    /// duration_ms by however long the app was away. This makes that history visible.
    private var foregroundEpoch = 0
    /// An activation that arrived while a start was already in flight. It is not dropped: the
    /// in-flight start re-fires it on the way out, so a stale start cannot cost the app its live
    /// session. It carries its OWN arrival time, because the session began when the user actually
    /// foregrounded the app, not whenever the parked start happened to unwind. Replaying it with
    /// the later time under-reports the foreground interval.
    private var pendingActivation: (startedAt: Date, epoch: Int, generation: Int)?
    private var lastSessionEndedAt: Date?
    private var lastSessionIndex: Int?
    private var deletionPending = false
    private var activeNetworkRequestCount = 0
    private var networkQuiescenceWaiters: [CheckedContinuation<Void, Never>] = []

    init(configuration: AttriKitTestingConfiguration) {
        self.configuration = configuration
    }

    private enum DeletionTombstoneState {
        case none
        case pending(DeletionTombstone)
        case corrupt
    }

    private func haltCollectionForPendingDeletion() {
        deletionPending = true
        bufferedBeforeStart.removeAll()
    }

    private func deletionTombstoneState() async -> DeletionTombstoneState {
        do {
            if let tombstone = try await configuration.storage.deletionTombstone() {
                return .pending(tombstone)
            }
            return .none
        } catch {
            return .corrupt
        }
    }

    func start(apiKey: String, consent: AttriKitConsent) async {
        guard self.apiKey == nil else {
            if self.consent != consent { await setConsent(consent) }
            return
        }
        guard (16...512).contains(apiKey.utf8.count) else {
            // A key outside 16...512 bytes cannot authenticate, so this returned having done
            // nothing: no first-open, no events, and nothing in the log for the life of the
            // process. That is indistinguishable from a working integration whose installs are
            // simply not converting, which is the worst way for this to fail. Fail loudly for
            // the same reason liveEndpoint() does, with the same XCTest exemption.
            #if canImport(os)
            os_log(
                .fault,
                "AttriKit: start(apiKey:) rejected an api key outside 16...512 bytes; attribution is DISABLED for this process."
            )
            #endif
            // Deliberately NOT assertionFailure, unlike liveEndpoint() above. That guards an
            // Info.plist value fixed at build time, so trapping catches it before shipping. An api
            // key is a RUNTIME value a host app may read from its own remote config, so trapping
            // here would crash a customer's DEBUG build on data we do not control.
            return
        }
        try? await configuration.storage.recoverPendingRevocationIfNeeded()
        let previouslyStoredConsent = await configuration.storage.storedConsent()
        self.apiKey = apiKey
        self.consent = consent
        startLifecycleObservation()
        switch await deletionTombstoneState() {
        case .none:
            break
        case .pending, .corrupt:
            haltCollectionForPendingDeletion()
            return
        }
        if consent == .denied || consent == .revoked {
            let endsMeasurement = previouslyStoredConsent.allowsMeasurement
            let previousIdentity = endsMeasurement
                ? try? await configuration.storage.initializeIdentities()
                : nil
            if endsMeasurement, let previousIdentity {
                identity = previousIdentity
                await scheduleConsentReceipt(
                    scope: "measurement",
                    state: consent,
                    identity: previousIdentity,
                    startDrain: false
                )
            }
            let startsRevocation = consent == .revoked && previouslyStoredConsent != .revoked
            if startsRevocation {
                try? await configuration.storage.beginRevocationTransition()
            } else {
                await configuration.storage.storeConsent(consent)
            }
            await drainConsentReceiptsBeforeWipe()
            await stopAndWipe(finalizeRevocation: startsRevocation)
            return
        }
        await configuration.storage.storeConsent(consent)
        guard consent.allowsMeasurement else { return }
        await beginMeasurement()
    }

    func setConsent(_ newConsent: AttriKitConsent) async {
        let previous = consent
        let previousIdentity = identity
        consent = newConsent
        if newConsent == .revoked {
            let startsRevocation = !deletionPending && previous != .revoked
            if previous.allowsMeasurement, let previousIdentity {
                await scheduleConsentReceipt(
                    scope: "measurement",
                    state: newConsent,
                    identity: previousIdentity,
                    startDrain: false
                )
            }
            if startsRevocation {
                try? await configuration.storage.beginRevocationTransition()
            } else {
                await configuration.storage.storeConsent(newConsent)
            }
            await drainConsentReceiptsBeforeWipe()
            resetSessionState()
            await stopAndWipe(finalizeRevocation: startsRevocation)
            return
        }
        if newConsent == .denied {
            if previous.allowsMeasurement, let previousIdentity {
                await scheduleConsentReceipt(
                    scope: "measurement",
                    state: newConsent,
                    identity: previousIdentity,
                    startDrain: false
                )
            }
            await configuration.storage.storeConsent(newConsent)
            await drainConsentReceiptsBeforeWipe()
            resetSessionState()
            await stopAndWipe(finalizeRevocation: false)
            return
        }
        await configuration.storage.storeConsent(newConsent)
        if !newConsent.allowsMeasurement {
            // Measurement just stopped with a session possibly open. It can never be closed now:
            // applicationWillResignActive requires consent.allowsMeasurement and early-returns
            // without clearing, so an activeSession left here would fail the `activeSession == nil`
            // check forever and block every later start for the process lifetime. .denied and
            // .revoked already reset below and above; .unknown reached neither.
            resetSessionState()
        }
        guard newConsent.allowsMeasurement, apiKey != nil, !deletionPending else { return }
        if !previous.allowsMeasurement {
            await beginMeasurement()
        } else if previous != newConsent {
            await scheduleConsentReceipt(scope: "tracking", state: newConsent)
        }
    }

    func track(_ event: AttriKitEvent, properties: [String: AttriKitValue]) async {
        do {
            try validateProperties(properties)
        } catch {
            // The WHOLE event was dropped here, silently, on any property that fails validation.
            // The integrator sees nothing arrive and has no way to learn why; during an integration
            // that is indistinguishable from a broken SDK.
            //
            // Every KEY on the refused event is named, because that is what the caller must
            // change. It is not narrowed to the offending one: `validateProperties` throws a bare
            // `AttriKitError.invalidProperty` carrying no key, and giving that case an associated
            // value is a public-API change. The VALUE is never logged: this guard exists precisely
            // because a value may be an email or a phone number, and a log line is not a safe
            // place to put one.
            //
            // Note the guard is a SUBSTRING match on email|e-mail|phone|mobile|address|name, so
            // ordinary analytics keys like product_name, campaign_name and mobile_os are refused
            // along with the PII it targets. Loosening that is a privacy decision rather than a
            // bug fix, and it is recorded in the audit; naming the key at least makes the refusal
            // actionable instead of invisible.
            #if canImport(os)
            let rejected = properties.keys.sorted().joined(separator: ", ")
            os_log(
                .error,
                "AttriKit: track(_:properties:) refused an event because a property failed validation, so NOTHING was recorded for it. Property keys on the refused event: %{public}@. Values are deliberately not logged.",
                rejected
            )
            #endif
            return
        }
        let now = configuration.now()
        guard apiKey != nil else {
            bufferedBeforeStart.append(BufferedEvent(event: event, properties: properties, occurredAt: now))
            if bufferedBeforeStart.count > 100 {
                bufferedBeforeStart.removeFirst()
                // Silently discarded the OLDEST event held before start(). An app that tracks
                // before configuring the SDK loses its earliest events - the ones nearest the
                // install, which are the ones attribution cares about most - and nothing said so.
                #if canImport(os)
                os_log(
                    .error,
                    "AttriKit: more than 100 events were tracked before start(apiKey:consent:) was called, so the OLDEST is being discarded. Call start() earlier in your launch path; events buffered before it are capped and the earliest are lost first."
                )
                #endif
            }
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

    /// `occurredAt` is when the notification was POSTED, not when this call got to run.
    ///
    /// Delivery is serialized to preserve notification order, and a handler is not considered
    /// done until its envelope reaches durable storage, so an event can wait behind a storage
    /// roundtrip. Timestamping at processing time therefore charged that wait to the user's
    /// session: a 100ms foreground reported as 300ms. The post instant is captured on the main
    /// queue, in order, and carried through. Nil means no observer supplied one (tests driving
    /// the runtime directly), and the configured clock is authoritative.
    func applicationDidBecomeActive(occurredAt: Date? = nil) async {
        applicationIsActive = true
        // Re-arm registration if it is still outstanding and nothing is trying. The first-open
        // ladder can exhaust (24h) or be refused while the process keeps running, and until now
        // nothing inside a live process ever attempted it again — so a device that regained
        // connectivity, or a server that was fixed, still delivered nothing until the user killed
        // and relaunched the app. A foreground is the cheapest honest moment to try again, and the
        // ladder's own bounds still apply.
        if !firstOpenRegistered, firstOpenTask == nil, !deletionPending, apiKey != nil, consent.allowsMeasurement {
            await startOrResumeFirstOpen()
        }
        scheduleConsentReceiptDrain()
        await beginSessionIfNeeded(
            startedAt: occurredAt ?? configuration.now(),
            epoch: foregroundEpoch,
            generation: sessionStateGeneration
        )
    }

    /// Shared body of a real activation and of the replay of one that was dropped mid-start.
    ///
    /// It deliberately does NOT touch `applicationIsActive`. The replay runs from an unstructured
    /// Task, so a resign or a shutdown can land between scheduling it and running it; going back
    /// through the public entry point would set the flag true again and mark a backgrounded app
    /// as foregrounded. Instead the caller's foreground epoch is carried in and revalidated here,
    /// which is what makes a replay that lost its race harmless.
    private func beginSessionIfNeeded(startedAt: Date, epoch: Int, generation entryGeneration: Int) async {
        // Both contexts, not just the foreground one. A replay held across a consent denial and
        // restoration would otherwise run once identity came back and install its pre-denial
        // startedAt, reporting the disabled interval as foreground time.
        guard applicationIsActive,
              foregroundEpoch == epoch,
              sessionStateGeneration == entryGeneration else { return }
        guard apiKey != nil, sessionTrackingEnabled, consent.allowsMeasurement, identity != nil else { return }
        // A deleteData in flight must not let an interleaved activation create a session
        // that outlives the wipe: identity/apiKey are still set until the roundtrip ends,
        // and a session created here would stale-block every later start (activeSession
        // == nil guard) for the process lifetime.
        guard !deletionPending else { return }
        // Actor reentrancy: `nextSessionIndex()` below suspends on the storage actor, so a
        // second delivery of the SAME activation can pass an `activeSession == nil` guard
        // while the first is still awaiting. Both would advance the persisted counter and the
        // later assignment would win, burning a session index and mislabelling session_end.
        // The in-flight flag is set BEFORE the first suspension point and cleared on every
        // exit path, so a duplicate delivery is dropped instead of opening a second session.
        guard activeSession == nil else { return }
        if sessionStartInFlight {
            // Do not simply drop it. If the in-flight start turns out to be stale it returns
            // without installing anything, and this activation is then the only one left.
            if let existing = pendingActivation,
               existing.epoch == epoch,
               existing.generation == entryGeneration {
                // Same foreground period: the session began when the user FIRST came back, so
                // the earliest arrival wins. Last-writer-wins silently shortened the interval.
                if startedAt < existing.startedAt {
                    pendingActivation = (startedAt: startedAt, epoch: epoch, generation: entryGeneration)
                }
            } else {
                // A different foreground period or a different state generation: the older slot
                // describes a context that is gone, so it is replaced rather than merged.
                pendingActivation = (startedAt: startedAt, epoch: epoch, generation: entryGeneration)
            }
            return
        }

        sessionStartInFlight = true
        defer {
            sessionStartInFlight = false
            if let pending = pendingActivation {
                pendingActivation = nil
                // Replayed with the arrival time and epoch it had when it was dropped. The
                // foreground re-check lives in beginSessionIfNeeded, where it is re-evaluated
                // at RUN time rather than here at schedule time.
                Task {
                    await self.beginSessionIfNeeded(
                        startedAt: pending.startedAt,
                        epoch: pending.epoch,
                        generation: pending.generation
                    )
                }
            }
        }

        let now = startedAt
        let canResumeRecentSession = lastSessionEndedAt.map {
            let gap = now.timeIntervalSince($0)
            return gap >= 0 && gap <= Self.sessionGap
        } ?? false

        let generation = sessionStateGeneration
        let epoch = foregroundEpoch
        let index: Int
        // Held rather than assigned: a start that goes stale on the storage actor must not leave
        // a new sessionID behind. Events stamped between that abandoned start and the next real
        // one would carry the ID of a session that never opened.
        var freshSessionID: UUID?
        if canResumeRecentSession, let lastSessionIndex {
            index = lastSessionIndex
        } else {
            index = await configuration.storage.nextSessionIndex()
            freshSessionID = UUID()
        }
        // TOCTOU: every guard above ran BEFORE the suspension. deleteData, a consent
        // revocation, stop() or shutdown() can all complete while we are awaiting the storage
        // actor, and the app can background. Re-validate the whole precondition set before
        // installing the session, or a wipe gets resurrected and sessions die for the rest of
        // the process. The generation check covers state cleared without a flag of its own.
        guard sessionStateGeneration == generation,
              foregroundEpoch == epoch,
              !deletionPending,
              consent.allowsMeasurement,
              sessionTrackingEnabled,
              apiKey != nil,
              identity != nil,
              applicationIsActive,
              activeSession == nil else { return }
        if let freshSessionID { sessionID = freshSessionID }
        activeSession = ActiveSession(index: index, startedAt: now)
    }

    func applicationWillResignActive(occurredAt: Date? = nil) async {
        applicationIsActive = false
        // Bumped before the early-returns below: backgrounding happened whether or not there was
        // a session to close, and a start parked mid-flight has to be able to see it.
        foregroundEpoch &+= 1
        guard sessionTrackingEnabled, consent.allowsMeasurement, !deletionPending,
              let identity, let activeSession else { return }

        let endedAt = occurredAt ?? configuration.now()
        self.activeSession = nil
        lastSessionEndedAt = endedAt
        lastSessionIndex = activeSession.index

        let elapsed = max(0, endedAt.timeIntervalSince(activeSession.startedAt))
        let roundedMilliseconds = (elapsed * 1_000).rounded()
        guard roundedMilliseconds.isFinite,
              let event = try? AttriKitEvent("session_end", version: 1) else { return }
        // The clamp used to be `min(Double(Int.max), ...)`. `Double(Int.max)` rounds UP to 2^63,
        // which is NOT representable as an Int, so any value that actually reached the clamp
        // produced exactly 2^63 and the conversion below TRAPPED — the clamp crashed the host app
        // on the one input it existed to survive. Converting through `Int(exactly:)` clamps.
        let durationMilliseconds = Int(exactly: roundedMilliseconds) ?? Int.max
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
        // CHECKED, not consumed. The token is marked spent only once an identify carrying it has
        // been acknowledged (see submitIdentify), because consuming first meant a process killed
        // between here and the network call burned the only deterministic attribution signal the
        // SDK has, permanently and with no failure for anything to react to. A relaunch can now
        // re-accept the same token and deliver it; the server treats a repeat from the SAME
        // occurrence as valid and reserves "replay" for a different one
        // (apps/link/src/ingestion/repository.ts:421).
        guard await configuration.storage.isExactTokenNew(token) else { return .ignored }
        exactToken = ExactTokenReference(token: token, kind: kind, clipboardOptIn: kind == "clipboard" ? true : nil)
        // Nothing is consumed on disk yet: the guard above only CHECKED the token. It used to be
        // marked consumed here, BEFORE the call that delivers it, so any failure below burned the
        // only deterministic attribution signal the SDK has and downgraded the install to
        // probabilistic matching with nothing to show for it. The mark now lands in submitIdentify,
        // once the identify carrying the token is acknowledged, and is released when it is not.
        //
        // `exactToken` stays set in memory either way: when this returns false because first-open
        // has not registered yet, the deferred identify still sends it within this launch, and the
        // release only restores the ability to re-accept the same token after a relaunch.
        // The release lives inside submitIdentify's failed path now, so the DEFERRED re-fire is
        // covered too. Releasing here as well would be harmless but would hide where it belongs.
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
        if opaqueID != nil, sanitized == nil {
            // A REFUSED id is not a logout. Mapping it to nil and persisting that erased an id set
            // earlier and re-submitted identify with no user, so a bad value silently DESTROYED the
            // RevenueCat join key instead of being rejected. The published contract says rejected
            // (apps/web/components/marketing/content.ts, "Identify users"); nil still clears.
            configuration.diagnostic(
                "AttriKit: setUserID(_:) refused an id that is empty, longer than 256 UTF-8 bytes, or contains '@'. The id already set is unchanged; pass nil explicitly to clear it."
            )
            return
        }
        pendingUserID = sanitized
        guard consent.allowsMeasurement, !deletionPending else { return }
        await configuration.storage.setUserID(sanitized)
        await submitIdentify()
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
        switch await deletionTombstoneState() {
        case .pending(let pending):
            tombstone = pending
        case .corrupt:
            haltCollectionForPendingDeletion()
            throw StorageError.corruptDeletionTombstone
        case .none:
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
        firstOpenRegistered = false
        deferredIdentify = false
        firstOpenTask?.cancel()
        pollTask?.cancel()
        queueTask?.cancel()
        consentReceiptTask?.cancel()
        firstOpenTask = nil
        pollTask = nil
        queueTask = nil
        consentReceiptTask = nil
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
        // Defense in depth: nothing session-shaped may survive the wipe, even if an
        // activation interleaved with the roundtrip before the lifecycle guards learned
        // about deletionPending.
        resetSessionState()
    }

    func shutdown() async {
        configuration.lifecycle.stop()
        lifecycleObservationStarted = false
        applicationIsActive = false
        resetSessionState()
        firstOpenTask?.cancel()
        pollTask?.cancel()
        queueTask?.cancel()
        consentReceiptTask?.cancel()
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
        configuration.lifecycle.start { [weak self] event, occurredAt in
            guard let self else { return }
            switch event {
            case .didBecomeActive:
                await self.applicationDidBecomeActive(occurredAt: occurredAt)
            case .willResignActive:
                await self.applicationWillResignActive(occurredAt: occurredAt)
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
        // A replay scheduled before the wipe describes a context that no longer exists.
        pendingActivation = nil
        // Invalidate any start currently suspended on the storage actor. Without this it
        // resumes and installs a session built from pre-wipe state, which both leaves session
        // data behind after a requested deletion and permanently blocks every later start,
        // because willResignActive early-returns on a nil identity and never clears it.
        sessionStateGeneration &+= 1
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
        } catch StorageError.queueFullForProtectedEvent {
            // Refusing a protected event beats silently evicting an older protected one. Expected,
            // bounded, and not a fault.
        } catch {
            // Anything else here is the queue file being UNREADABLE, which on iOS usually means the
            // device has not been unlocked since boot: writeQueue sets
            // NSFileProtectionCompleteUntilFirstUserAuthentication. `enqueue` propagates that rather
            // than resetting the queue, which is correct - dropping one event beats dropping every
            // stored one - but this catch then discarded the event in SILENCE, and a purchase is the
            // event most likely to arrive from a background launch before first unlock.
            //
            // It stays dropped, because retaining it needs a durable pre-unlock buffer that does not
            // exist yet and inventing one here would be a larger change than this catch. What it no
            // longer is, is invisible.
            #if canImport(os)
            os_log(
                .error,
                "AttriKit: an event was dropped because the offline queue could not be read. This is expected before the first device unlock after a reboot; if it repeats while unlocked, the queue file is unreadable and events are being lost."
            )
            #endif
        }
    }

    private func submitFirstOpen() async {
        guard consent.allowsMeasurement, !deletionPending, let apiKey, let identity else { return }
        // A persisted body wins over a rebuilt one. The server hashes the WHOLE envelope, so a
        // relaunch that re-sends the stored bytes is the clean `duplicate` it always was; a
        // relaunch that rebuilds with `occurredAt: configuration.now()` hashes differently and
        // 409s (handled, but needlessly — see the 409 case below). The stored body is scoped to
        // this epoch and producing consent by the storage layer, so a rotated epoch or a consent
        // change can never replay it.
        var persistedBody = await configuration.storage.firstOpenBody(
            installEpochID: identity.installEpochID,
            consent: consent
        )
        if persistedBody == nil,
           let selectedFirstOpenBody,
           selectedFirstOpenBody.installEpochID == identity.installEpochID,
           selectedFirstOpenBody.consent == consent {
            persistedBody = selectedFirstOpenBody.body
        }
        // The storage read above handles every producing-consent mismatch. Keep the narrower IDFA
        // rule as defense in depth for a corrupted or migrated record that claims the current
        // consent while carrying an advertising identifier that consent does not allow.
        if let stored = persistedBody, !consent.allowsTracking, Self.bodyCarriesIdfa(stored) {
            persistedBody = nil
            try? await configuration.storage.setFirstOpenBody(
                nil,
                installEpochID: nil,
                consent: nil
            )
        }
        // Platform evidence is best-effort and BOUNDED: AppTransaction.shared can hang on
        // simulators/sandboxes (it does not throw), and a slow StoreKit must never delay the
        // first-open envelope — click-to-install timing is the product's accuracy substrate.
        let evidence = configuration.evidence
        let deviceEvidence = configuration.deviceEvidence()
        async let transaction = Self.boundedEvidence { await evidence.appTransactionJWS() }
        async let adServices = Self.boundedEvidence { await evidence.adServicesToken() }
        // ONE consent snapshot builds the envelope AND records it below. `consent` was read twice
        // across the evidence suspension — once for the declared state, once for the idfa gate —
        // so a grant landing in that window built a body DECLARING measurement_granted while
        // CARRYING an idfa: the exact 422 the rule below exists to prevent, and that body was then
        // persisted and cached under the new consent, so every later attempt replayed it. The
        // snapshot is taken AFTER the awaits, so a withdrawal during them still drops the idfa.
        var producingConsent = consent
        var envelope: FirstOpenEnvelope?
        if persistedBody == nil {
            let occurredAt = configuration.now()
            let appVersion = configuration.evidence.appVersion()
            let coarseContext = configuration.evidence.coarseContext()
            let appTransactionJWS = await transaction
            let asaToken = await adServices
            producingConsent = consent
            envelope = FirstOpenEnvelope(
                installationID: identity.installationID,
                installEpochID: identity.installEpochID,
                occurredAt: occurredAt,
                appVersion: appVersion,
                coarseContext: coarseContext,
                consent: ConsentPayload(state: producingConsent, policyVersion: 1),
                appTransactionJWS: appTransactionJWS,
                asaToken: asaToken,
                exactTokenReference: exactToken,
                webFirstParty: funnelIdentity.isEmpty ? nil : WebFirstPartyIdentity(funnelIdentity),
                // Server rule (firstOpenEnvelopeSchema refine): idfa requires
                // tracking_granted — sending it under measurement consent is a 422
                // and the first-open is permanently lost. Gate client-side on the
                // same rule. IDFV is consent-free. (wire-review P0-1, 2026-07-22)
                idfa: producingConsent.allowsTracking ? deviceEvidence.idfa.map(LowercaseUUID.init(wrappedValue:)) : nil,
                idfv: deviceEvidence.idfv.map(LowercaseUUID.init(wrappedValue:)),
                localLineagePresent: identity.localLineagePresent,
                localEpochPresent: identity.localEpochPresent
            )
        }
        do {
            let data: Data
            if let persistedBody {
                data = persistedBody
            } else if let envelope {
                // Re-read BEFORE encoding and persisting. Task cancellation is cooperative and
                // nothing in this function checks it: a superseded attempt that was suspended
                // on evidence runs to completion. Measured race (adversarial review, 5bd2620):
                // attempt A persists+ sends bodyA (200); attempt B, suspended, wakes LATER,
                // persists bodyB over bodyA, and every relaunch then resends bodyB — which the
                // server has never seen — a 409 forever, the exact symptom this persistence
                // exists to remove. Preferring a concurrently persisted body collapses the race
                // into the duplicate it should have been.
                if let concurrentlyPersisted = await configuration.storage.firstOpenBody(
                    installEpochID: identity.installEpochID,
                    consent: consent
                ) {
                    data = concurrentlyPersisted
                } else if let selectedFirstOpenBody,
                          selectedFirstOpenBody.installEpochID == identity.installEpochID,
                          selectedFirstOpenBody.consent == consent {
                    data = selectedFirstOpenBody.body
                } else {
                    let encoded = try attriKitJSONEncoder().encode(envelope)
                    // Recorded under the consent that BUILT these bytes, not under whatever the
                    // consent is now: a change landing on the storage read above would otherwise
                    // file an idfa-carrying body under a consent that forbids it, and the
                    // fallback two branches up would replay it on every later attempt.
                    selectedFirstOpenBody = (
                        installEpochID: identity.installEpochID,
                        consent: producingConsent,
                        body: encoded
                    )
                    // Persist BEFORE the send: a retry after a crash must re-send these exact
                    // bytes, not a rebuild. A persistence failure degrades to the pre-existing
                    // behaviour (rebuild per launch), which the 409 case already covers.
                    try? await configuration.storage.setFirstOpenBody(
                        encoded,
                        installEpochID: identity.installEpochID,
                        consent: producingConsent
                    )
                    data = encoded
                }
            } else {
                return
            }
            let request = RequestFactory(baseURL: configuration.baseURL, apiKey: apiKey)
                .post(path: "v1/ingest/first-open", body: data, idempotencyKey: identity.installEpochID.uuidString.lowercased())
            let submittedEpoch = identity.installEpochID
            let response = try await sendMeasurementRequest(request)
            guard consent.allowsMeasurement, !deletionPending else { return }
            // The epoch can rotate while this request is in flight — a revocation, a wipe, a
            // re-grant — and Task cancellation is cooperative, so an in-flight transport call
            // finishes and resumes here regardless. Without this check an OLD epoch's 2xx would
            // open the gate for the NEW one, which the server has never seen: the queue would
            // then flush against an unregistered epoch, and the old attribution and identify
            // would be applied to the wrong install.
            guard self.identity?.installEpochID == submittedEpoch else { return }
            switch response.statusCode {
            // The gate opens on the STATUS, before any decoding. A 2xx means the server has
            // registered the epoch, and that — not the parseability of the body — is the fact the
            // event queue is waiting on. A non-conforming 2xx body deliberately throws to the
            // first-open retry path (see the wire contract: "a 2xx whose body does not match this
            // schema is a retriable failure, not success"), so settling after the decode would
            // strand every queued event behind a parse failure on a request the server ACCEPTED.
            case 200:
                registerFirstOpen()
                let decoded = try attriKitJSONDecoder().decode(FirstOpenResponse.self, from: response.data)
                attributionCache = decoded.attribution.map(AttributionResult.attributed) ?? .unattributed
                try? await configuration.storage.setRetryState(nil)

            case 202:
                registerFirstOpen()
                let decoded = try attriKitJSONDecoder().decode(FirstOpenResponse.self, from: response.data)
                startPolling(after: decoded.retryAfterMilliseconds ?? 500)
                try? await configuration.storage.setRetryState(nil)

            // 409 idempotency_conflict PROVES the epoch exists: the server only answers it after
            // finding an occurrence already stored under this install_epoch_id whose payload hash
            // differs from ours. That is a registration, not a refusal, and the queue must be
            // released — the events will be accepted, because the epoch they name is there.
            //
            // It used to be reached on ordinary relaunches: `submitFirstOpen` rebuilt the envelope
            // with `occurredAt: configuration.now()` every time, so launch 2 hashed differently
            // from launch 1 and conflicted. The persistence above now replays the stored bytes, so
            // a relaunch normally repeats the SAME hash; a 409 is left for the cases persistence
            // cannot cover (a failed write, a consent change, a body built by an older build).
            // Treating it as a terminal refusal parked the queue for the rest of the install's
            // life — a regression
            // introduced by this fix's own gate, since before the gate existed the flush simply
            // proceeded and succeeded. Caught by the 360 audit before the SDK was tagged.
            case 409:
                registerFirstOpen()
                startPolling(after: 0)
                try? await configuration.storage.setRetryState(nil)

            case 204:
                registerFirstOpen()
                startPolling(after: 0)
                try? await configuration.storage.setRetryState(nil)

            // One classifier for both paths. This used to be `400..<500 where != 429`, which made
            // first-open give up permanently on 401, 403 and 408 — the three the event queue
            // deliberately spares as transient. A single timed-out first-open therefore abandoned
            // registration forever, and from that moment every event that install would ever
            // produce was undeliverable. The retry ladder is bounded (6 attempts inside 24h), so
            // retrying a genuinely bad key costs little and a transient blip costs nothing.
            case let code where Self.isPermanentClientFailure(code):
                attributionCache = .failed
                try? await configuration.storage.setRetryState(nil)
                // Does NOT open the gate. An earlier version of this fix did, on the reasoning that
                // the events would then "drop loudly" — that reasoning was wrong, and two
                // independent reviewers caught it. The server answers an unregistered epoch with a
                // RETRIABLE status, so releasing the queue here would not drop anything: it would
                // retry an impossible request every 60 seconds for the life of the install, with
                // the head of the queue blocking every later event. Refused is not registered.
                // Parking is the honest outcome — the events stay on disk, cost no radio, age out
                // on the normal 72h schedule, and a later launch re-submits first-open from
                // scratch, so a server-side or SDK-side correction still recovers them.
                #if canImport(os)
                os_log(
                    .error,
                    "AttriKit: the server refused this install's first-open with HTTP \(code, privacy: .public). The epoch was never registered, so queued events cannot be delivered and are held rather than sent. A later launch will retry registration."
                )
                #endif
            default:
                await scheduleFirstOpenRetry()
            }
        } catch {
            // Same staleness rule as the response path: a request belonging to a rotated-away
            // epoch must not schedule retries against the current one.
            guard self.identity?.installEpochID == identity.installEpochID else { return }
            await scheduleFirstOpenRetry()
        }
    }

    /// Why this is not a Bool: `false` conflated "the request failed" with "not sent yet", and the
    /// exact-token caller released a token on BOTH. A deferred identify is re-fired within the same
    /// launch, so releasing there disarmed the device's replay guard for a token that was about to
    /// be delivered successfully — and the deferred re-fire discards its result, so nothing ever
    /// marked it consumed again.
    private enum IdentifyOutcome {
        /// A request was made and acknowledged with a 2xx.
        case delivered
        /// first-open has not registered yet. `deferredIdentify` re-fires this within the launch.
        case deferred
        /// No request was made: preconditions absent, nothing to send, or the body would not encode.
        case notAttempted
        /// A request was made and was not acknowledged.
        case failed
    }

    @discardableResult
    private func submitIdentify() async -> IdentifyOutcome {
        guard consent.allowsMeasurement, !deletionPending, let apiKey, let identity else { return .notAttempted }
        // identify mutates an occurrence rather than creating one, so before registration the
        // server can only answer unknown_install_epoch — and this call discards its response
        // entirely, which made that a SILENT no-op. setUserID, setFunnelIdentity,
        // refreshTrackingEvidence and acceptExactToken are all public and all reachable during a
        // cold launch, so this is not a rare path: it is where a deterministic ak1_ token or the
        // RevenueCat join key would have been lost.
        guard firstOpenRegistered else {
            deferredIdentify = true
            return .deferred
        }
        let deviceEvidence = configuration.deviceEvidence()
        guard pendingUserID != nil || !funnelIdentity.isEmpty || exactToken != nil
                || deviceEvidence.idfa != nil || deviceEvidence.idfv != nil else { return .notAttempted }
        let envelope = IdentifyEnvelope(
            installationID: identity.installationID,
            installEpochID: identity.installEpochID,
            occurredAt: configuration.now(),
            customerUserID: pendingUserID,
            emailHash: funnelIdentity.emailHash,
            phoneHash: funnelIdentity.phoneHash,
            exactTokenReference: exactToken,
            // Same consent gate as first-open (wire-review P1-1): the identifier must
            // never travel without ATT authorization, even if the server would drop it.
            idfa: consent.allowsTracking ? deviceEvidence.idfa.map(LowercaseUUID.init(wrappedValue:)) : nil,
            idfv: deviceEvidence.idfv.map(LowercaseUUID.init(wrappedValue:))
        )
        guard let body = try? attriKitJSONEncoder().encode(envelope) else { return .notAttempted }
        let request = RequestFactory(baseURL: configuration.baseURL, apiKey: apiKey)
            .post(path: "v1/ingest/identify", body: body, idempotencyKey: UUID().uuidString.lowercased())
        // Best-effort, as it always was — identify has no durable queue — but no longer SILENT.
        // It mostly self-heals: the user id is persisted and identify re-fires after every
        // successful first-open. An exact ak1_ token is NOT lost on failure: acceptExactToken only
        // checks it and the token is spent below, on acknowledgement, so an unacknowledged identify
        // leaves it re-acceptable on the next launch. Making identify durable is the real fix and
        // is not this change.
        let outcome = try? await sendMeasurementRequest(request)
        let delivered = outcome != nil && (200..<300).contains(outcome?.statusCode ?? -1)
        if !delivered {
            #if canImport(os)
            os_log(
                .error,
                "AttriKit: identify was not acknowledged (HTTP \(outcome?.statusCode ?? -1, privacy: .public)). It is not retried within this launch."
            )
            #endif
        }
        // The token is spent HERE, on acknowledgement, and nowhere else. acceptExactToken only
        // CHECKS it, so nothing is burned until the server has the signal: a process killed before
        // this line leaves the token re-acceptable on the next launch instead of losing it.
        //
        // Centralised for the same reason the release used to be: the DEFERRED re-fire discards
        // its result (`Task { await self.submitIdentify() }`), so a call site could never see the
        // outcome of the send that actually carried the token.
        if delivered, let spent = exactToken {
            _ = await configuration.storage.consumeExactTokenIfNew(spent.token)
        }
        return delivered ? .delivered : .failed
    }

    private func startPolling(after milliseconds: Int) {
        pollTask?.cancel()
        let startedAt = configuration.now()
        pollTask = Task {
            if milliseconds > 0 { try? await Task.sleep(for: .milliseconds(milliseconds)) }
            var fastDelay = 250
            var fastAttempts = 0
            var ladderIndex = 0
            while !Task.isCancelled, self.canUseNetwork() {
                let serverCooldown = await self.pollAttributionOnce()
                if self.hasAttributionResult() { return }
                guard self.configuration.now().timeIntervalSince(startedAt) < Self.firstOpenRetryWindow else {
                    self.finishExhaustedPoll()
                    return
                }
                var delay: Int
                if fastAttempts < Self.attributionPollFastAttempts,
                   self.configuration.now().timeIntervalSince(startedAt) < Self.attributionPollFastWindow {
                    delay = fastDelay
                    fastDelay = min(fastDelay * 2, Self.attributionPollFastCeiling)
                    fastAttempts += 1
                } else {
                    guard ladderIndex < Self.firstOpenRetryDelays.count else {
                        self.finishExhaustedPoll()
                        return
                    }
                    delay = Int(Self.firstOpenRetryDelays[ladderIndex] * 1_000)
                    ladderIndex += 1
                }
                if let serverCooldown { delay = max(delay, serverCooldown) }
                let jitter = Int.random(in: 0...max(1, delay / 4))
                try? await Task.sleep(for: .milliseconds(delay + jitter))
            }
            // Falling out of the loop is NOT always exhaustion. Cancellation is a deliberate stop
            // (shutdown, reset, a replacement poll) and stays quiet. Losing network permission is
            // not: the poll simply stops, at entry or mid-ladder, and attribution(timeout:) then
            // answers .timedOut forever with nothing in the log to explain why. Same doctrine as
            // finishExhaustedPoll, different cause, so it gets its own message.
            if !Task.isCancelled { self.finishUnreachablePoll() }
        }
    }

    /// The poll stopped because measurement networking became unavailable mid-flight.
    ///
    /// Distinct from `finishExhaustedPoll`: the window did not run out, we lost the ability to ask.
    /// Like exhaustion it must not write `.unattributed`, for exactly the reasons documented there,
    /// but it must not be silent either.
    private func finishUnreachablePoll() {
        guard attributionCache == nil else { return }
        configuration.diagnostic(
            "AttriKit: attribution poll stopped because measurement networking is unavailable. The result stays UNKNOWN, not unattributed, and attribution(timeout:) will answer .timedOut."
        )
    }

    /// The poll gave up inside its published window.
    ///
    /// It deliberately does NOT write `.unattributed`. That is a claim about the INSTALL ("this
    /// install had no attribution"), whereas exhaustion is a fact about OUR POLLING ("we stopped
    /// asking"). Only the second is true here, and `attribution(timeout:)` returns the cache
    /// forever once it is set, so a premature `.unattributed` would convert a match that simply had
    /// not landed yet into a permanent wrong answer that no later 200 can correct. Leaving the
    /// cache nil makes `attribution(timeout:)` answer `.timedOut`, which is the honest state, and
    /// the give-up is logged so a lost match is diagnosable instead of silent.
    private func finishExhaustedPoll() {
        guard consent.allowsMeasurement, !deletionPending, attributionCache == nil else { return }
        #if canImport(os)
        os_log(
            .error,
            "AttriKit: attribution poll gave up inside its published window. The result stays UNKNOWN, not unattributed, and attribution(timeout:) will answer .timedOut."
        )
        #endif
    }

    /// Returns a server-declared cooldown in milliseconds when the answer carries a `Retry-After`.
    private func pollAttributionOnce() async -> Int? {
        guard consent.allowsMeasurement, !deletionPending, let apiKey, let identity else { return nil }
        do {
            let request = RequestFactory(baseURL: configuration.baseURL, apiKey: apiKey)
                .get(path: "v1/attribution/\(identity.installEpochID.uuidString.lowercased())", etag: attributionETag)
            let response = try await sendMeasurementRequest(request)
            guard consent.allowsMeasurement, !deletionPending else { return nil }
            switch response.statusCode {
            case 200:
                let decoded = try attriKitJSONDecoder().decode(AttributionResponse.self, from: response.data)
                attributionCache = decoded.attribution.map(AttributionResult.attributed) ?? .unattributed
            case 204:
                attributionCache = .unattributed
            // `.failed` is a TERMINAL answer for this process: nothing clears the cache until the
            // app is relaunched, so the host shows "attribution failed" for the rest of the
            // session. It belongs only to a status that will still be wrong on the next launch.
            //
            // Every 4xx used to land here. 401 and 403 are the ones that cost: an app key rotated
            // between launches, or a `disabled_app_key` 403 during a billing lapse the customer
            // then fixes, permanently poisoned a session that would have succeeded on the next
            // poll. 408 is a timeout — the definition of transient. The route's only permanent 4xx
            // is 400 `invalid_install_epoch_id` (apps/link/src/ingestion/routes.ts), which this
            // build will keep sending; it answers 202 `pending` rather than 404 for an epoch it
            // does not know yet, so there is no not-found shape to treat as permanent either.
            //
            // Everything else falls through to `default`, which leaves the cache alone — the state
            // is "we do not know yet", which is what the UI should show, and the poll ladder tries
            // again. Deliberately asymmetric: a wrongly-permanent answer is unrecoverable within
            // the session, a wrongly-transient one costs another request.
            case 400:
                attributionCache = .failed
            default:
                break
            }
            // Retained only AFTER the body was applied. Stored before the decode, a 200 whose body
            // fails to parse threw to `catch` with the ETag kept: the next poll's If-None-Match then
            // earned a 304, which falls to `default: break`, so the cache stayed nil for the rest of
            // the session and attribution(timeout:) answered .timedOut against a server that had a
            // match. A throw above skips this line, so a body we never applied leaves no validator.
            if let etag = response.headers["etag"] { attributionETag = etag }
            return Self.retryAfterMilliseconds(response.headers["retry-after"])
        } catch {}
        return nil
    }

    /// True when a persisted first-open body contains an advertising identifier.
    ///
    /// Decodes rather than substring-matching: `idfa` appears in prose and in other field names,
    /// and a false positive here silently discards a legitimate persisted body on every relaunch.
    /// A body that cannot be decoded is treated as carrying one, because an undecodable record is
    /// exactly the case where we cannot prove it is safe to replay.
    static func bodyCarriesIdfa(_ body: Data) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else { return true }
        guard let value = object["idfa"] else { return false }
        return !(value is NSNull)
    }

    /// Parses the delta-seconds form of `Retry-After` (the only form the AttrKit API emits, see
    /// apps/web/lib/api-route.ts) and clamps it to the ladder's own ceiling. An HTTP-date, a
    /// non-numeric value or a non-positive value returns nil, so the caller falls back to its local
    /// schedule, which is never slower than a hostile header could make it.
    static func retryAfterMilliseconds(_ raw: String?) -> Int? {
        guard let seconds = raw.flatMap({ Int($0.trimmingCharacters(in: .whitespaces)) }), seconds > 0 else { return nil }
        return min(seconds, maximumRetryAfterSeconds) * 1_000
    }

    /// Records that the server has decided about this epoch and releases the event queue. Kicking
    /// the flush here is what turns the gate from a delay into a handoff: without it the queue
    /// would wait for the next lifecycle event to notice first-open had landed.
    private func registerFirstOpen() {
        guard !firstOpenRegistered else { return }
        firstOpenRegistered = true
        scheduleConsentReceiptDrain()
        // identify is gated the same way and for the same reason: it mutates an occurrence that
        // does not exist yet, and its response is discarded, so a pre-registration send is a
        // silent no-op rather than a delayed one.
        // ONE identify per registration. This used to fire here AND again from each 2xx branch
        // when a userID was pending, producing two posts with different idempotency keys.
        if deferredIdentify || pendingUserID != nil {
            deferredIdentify = false
            Task { await self.submitIdentify() }
        }
        scheduleQueueFlush()
    }

    private func scheduleQueueFlush() {
        // Do not spin the loop before the epoch is decided. An earlier version of this fix let
        // the task start and no-op its way up the exponential backoff instead; by the time
        // first-open landed the loop was asleep, `queueTask == nil` was false, and the kick from
        // registerFirstOpen() did nothing — so the events were merely delayed by up to the backoff
        // ceiling rather than raced. Refusing to create the task keeps the handoff immediate.
        guard firstOpenRegistered else { return }
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
        // Never offer a batch to an epoch the server has not decided about yet: it would come
        // back 422 unknown_install_epoch and be destroyed as a permanent failure. `.retry` (not
        // `.empty`) keeps the queue task alive on its backoff so nothing is lost if the
        // settle-time kick is ever missed.
        guard firstOpenRegistered else { return .retry }
        do {
            guard let batch = try await configuration.storage.nextEventBatch(now: configuration.now()) else {
                return .empty
            }
            let data = try attriKitJSONEncoder().encode(EventBatch(batchID: batch.batchID, events: batch.events))
            let request = RequestFactory(baseURL: configuration.baseURL, apiKey: apiKey)
                .post(path: "v1/ingest/events:batch", body: data, idempotencyKey: batch.batchID)
            let response = try await sendMeasurementRequest(request)
            guard consent.allowsMeasurement, !deletionPending else { return .empty }
            if (200..<300).contains(response.statusCode) {
                try await configuration.storage.acknowledgeEventBatch(batchID: batch.batchID)
                return .sent
            }
            // Belt to the first-open gate's braces. 422 is overloaded: it carries both
            // `validation_failed` (genuinely permanent — the event is malformed and will be
            // malformed forever) and `unknown_install_epoch` (a RACE — the same bytes succeed
            // once first-open lands). Classifying on the status alone cannot tell those apart,
            // so it destroyed the retriable one. Discriminate on the error body instead.
            if Self.isUnknownInstallEpoch(response) { return .retry }
            if Self.isPermanentClientFailure(response.statusCode) {
                if batch.events.count <= 1 {
                    // Genuine single poison/oversized event: ack it so the queue can drain.
                    // The row is destroyed here and can never be recovered, so the drop must
                    // never be silent: a lost session_end is otherwise indistinguishable from
                    // a session that never happened. Event names are schema identifiers
                    // (validated against ^[a-z][a-z0-9_.-]{0,127}$), never user data.
                    // The live diagnostic sink emits this message as public device-local
                    // diagnostics: naming the destroyed event is the entire value of the report,
                    // and redacting it would recreate the silent-drop class this message exists to
                    // end. The injected sink also makes this invariant testable without depending
                    // on OSLogStore availability in a host test process.
                    configuration.diagnostic(
                        "AttriKit: permanently dropping event '\(batch.events.first?.eventName ?? "unknown")' after HTTP \(response.statusCode). It is deleted from the queue and will never be delivered."
                    )
                    try await configuration.storage.acknowledgeEventBatch(batchID: batch.batchID)
                    return .sent
                }
                // A permanent 4xx (413/422 etc.) on a multi-event batch must not delete the
                // valid siblings alongside the offending event. Bisect and retry so the bad
                // event is isolated to a single-event batch before it is ever dropped.
                try await configuration.storage.splitPendingBatch(batchID: batch.batchID)
                return .retry
            }
            return .retry
        } catch {
            return .retry
        }
    }

    private func clearQueueTask() { queueTask = nil }

    /// Releases the first-open task slot when its work is over. Without this the slot stayed
    /// occupied by a COMPLETED task forever, so the `firstOpenTask == nil` condition on the
    /// foreground re-arm was never true and the re-arm was dead code — a long-lived process that
    /// regained connectivity after a refusal or an exhausted ladder would never try again, and its
    /// parked events would simply age out.
    /// A clear from an OUTDATED generation is a no-op: it belongs to a task whose slot has since
    /// been taken over by a scheduled retry, and niling it there orphaned a LIVE task. The slot
    /// then read as empty, so the foreground re-arm at `applicationDidBecomeActive` started a
    /// second chain beside the first and every `firstOpenTask?.cancel()` missed the orphan, which
    /// is how one install could burn several rungs of the retry ladder at once.
    private func clearFirstOpenTask(generation: Int) {
        guard generation == firstOpenTaskGeneration else { return }
        firstOpenTask = nil
    }

    static func isPermanentClientFailure(_ statusCode: Int) -> Bool {
        (400..<500).contains(statusCode) && ![401, 403, 408, 429].contains(statusCode)
    }

    private struct IngestErrorEnvelope: Decodable { let error: String? }

    /// True when the server refused a batch only because it has not registered this install epoch
    /// yet. Deliberately narrow: it matches ONE error string on ONE status, so every other 422
    /// keeps the permanent-failure semantics the retry ladder was built around. Decoding failure
    /// answers false — an unparseable body must never be promoted into an infinite retry.
    /// Accepts BOTH encodings on purpose. The API now answers this race 503, because that is the
    /// only class every already-installed SDK retries rather than deletes; it answered 422 before,
    /// and an app in the field can meet either during a rollout, or a pinned older server forever.
    /// The 422 arm is therefore not dead code — it is the arm that matters to the installed base.
    static func isUnknownInstallEpoch(_ response: HTTPResult) -> Bool {
        guard response.statusCode == 422 || response.statusCode == 503, !response.data.isEmpty else { return false }
        guard let decoded = try? JSONDecoder().decode(IngestErrorEnvelope.self, from: response.data) else { return false }
        return decoded.error == "unknown_install_epoch"
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

    /// Persists the transition before scheduling any network work. The stored identity, epoch,
    /// state, timestamp, and idempotency key all describe the moment the transition was raised.
    private func scheduleConsentReceipt(
        scope: String,
        state: AttriKitConsent,
        identity receiptIdentity: InstallationIdentity? = nil,
        startDrain: Bool = true
    ) async {
        guard !deletionPending, apiKey != nil else { return }
        guard state != .unknown else { return }
        if state.allowsMeasurement {
            guard consent.allowsMeasurement else { return }
        }
        guard let receiptIdentity = receiptIdentity ?? identity else { return }
        let receipt = StoredConsentReceipt(
            idempotencyKey: UUID(),
            installationID: receiptIdentity.installationID,
            installEpochID: receiptIdentity.installEpochID,
            scope: scope,
            state: state,
            occurredAt: configuration.now()
        )
        do {
            try await configuration.storage.enqueueConsentReceipt(receipt)
        } catch {
            configuration.diagnostic(
                "AttriKit: a consent receipt could not be persisted, so delivery was not attempted. Error: \(error)"
            )
            return
        }
        if startDrain { scheduleConsentReceiptDrain() }
    }

    private func scheduleConsentReceiptDrain() {
        guard !deletionPending else { return }
        let mayDrainGrant = consent.allowsMeasurement && firstOpenRegistered
        // Same terms as the drain's own `deliverWithdrawals` below. Omitting `allowsMeasurement`
        // here meant that after a re-grant, and before first-open registers, neither gate was true,
        // so no drain was scheduled for a withdrawal the drain would have delivered.
        let mayDrainWithdrawal = consent.allowsMeasurement || consent == .denied || consent == .revoked
        guard mayDrainGrant || mayDrainWithdrawal else { return }
        guard consentReceiptTask == nil else { return }
        consentReceiptTaskGeneration += 1
        let generation = consentReceiptTaskGeneration
        consentReceiptTask = Task {
            await self.drainConsentReceipts()
            self.clearConsentReceiptTask(generation: generation)
        }
    }

    /// Drains the oldest eligible receipt. A withdrawal can bypass a grant that is gated while
    /// consent is off. Each receipt stays stored until a 2xx acknowledgement, and a relaunch reuses
    /// the same idempotency key after a crash or failed attempt.
    private func drainConsentReceipts() async {
        guard !deletionPending, let apiKey else { return }
        for _ in 0..<Self.maximumConsentReceiptsPerDrain {
            guard !Task.isCancelled, !deletionPending else { return }
            let deliverGrants = consent.allowsMeasurement && firstOpenRegistered
            let deliverWithdrawals = consent.allowsMeasurement || consent == .denied || consent == .revoked
            guard deliverGrants || deliverWithdrawals else { return }
            guard let receipt = await nextConsentReceipt(deliverGrants: deliverGrants) else { return }
            guard await deliverConsentReceipt(receipt, apiKey: apiKey, deliverWithdrawals: deliverWithdrawals) else { return }
        }
    }

    private func nextConsentReceipt(deliverGrants: Bool) async -> StoredConsentReceipt? {
        do { return try await configuration.storage.nextConsentReceipt(deliverGrants: deliverGrants) }
        catch {
            configuration.diagnostic("AttriKit: the durable consent receipt queue could not be read. No receipt was removed. Error: \(error)")
            return nil
        }
    }

    private func deliverConsentReceipt(_ receipt: StoredConsentReceipt, apiKey: String, deliverWithdrawals: Bool) async -> Bool {
        guard receiptIsEligible(receipt, deliverWithdrawals: deliverWithdrawals) else { return false }
        do {
            let body = try attriKitJSONEncoder().encode(ConsentReceipt(installationID: receipt.installationID, installEpochID: receipt.installEpochID, scope: receipt.scope, consent: ConsentPayload(state: receipt.state, policyVersion: 1), occurredAt: receipt.occurredAt))
            guard receipt.kind != .withdrawal || !Self.bodyCarriesIdfa(body) else { configuration.diagnostic("AttriKit: a withdrawal receipt unexpectedly carried IDFA. It remains queued and was not sent."); return false }
            let request = RequestFactory(baseURL: configuration.baseURL, apiKey: apiKey).post(path: "v1/ingest/consent", body: body, idempotencyKey: receipt.idempotencyKey.uuidString.lowercased())
            let outcome = try await sendMeasurementRequest(request)
            guard (200..<300).contains(outcome.statusCode) else { configuration.diagnostic("AttriKit: consent receipt for scope '\(receipt.scope)' was not acknowledged (HTTP \(outcome.statusCode)). It remains queued."); return false }
            try await configuration.storage.acknowledgeConsentReceipt(idempotencyKey: receipt.idempotencyKey)
            return true
        } catch {
            configuration.diagnostic("AttriKit: consent receipt for scope '\(receipt.scope)' was not delivered. It remains queued. Error: \(error)")
            return false
        }
    }

    private func receiptIsEligible(_ receipt: StoredConsentReceipt, deliverWithdrawals: Bool) -> Bool {
        switch receipt.kind {
        case .grant: return consent.allowsMeasurement && firstOpenRegistered
        case .withdrawal: return deliverWithdrawals
        case nil: return false
        }
    }

    /// Waits for at most the existing drain plus one fresh bounded drain. The withdrawal receipt
    /// is attempted before stopAndWipe clears the in-memory identity or rotates the stored epoch.
    private func drainConsentReceiptsBeforeWipe() async {
        if let existingTask = consentReceiptTask {
            await existingTask.value
        }
        guard !deletionPending else { return }
        scheduleConsentReceiptDrain()
        if let transitionTask = consentReceiptTask {
            await transitionTask.value
        }
    }

    private func clearConsentReceiptTask(generation: Int) {
        guard generation == consentReceiptTaskGeneration else { return }
        consentReceiptTask = nil
    }

    private func scheduleFirstOpenRetry() async {
        guard consent.allowsMeasurement, !deletionPending else { return }
        let current = await configuration.storage.retryState()
        let now = configuration.now()
        let attempt = (current?.attempt ?? 0) + 1
        guard attempt <= Self.firstOpenRetryDelays.count,
              now.timeIntervalSince(current?.firstAttemptAt ?? now) < Self.firstOpenRetryWindow else {
            // Same reasoning as the poll's finishExhaustedPoll: exhausting the DELIVERY
            // schedule says we stopped trying, not that the install had no attribution.
            // attribution(timeout:) returns this cache forever once set, so writing
            // .unattributed here makes a first-open we never managed to deliver look like a
            // measured organic install. Leave it unknown and say so.
            #if canImport(os)
            os_log(
                .error,
                "AttriKit: first-open delivery exhausted its retry schedule. The install was never recorded and its attribution stays UNKNOWN, not unattributed. Queued events stay on disk and are not sent until a later launch registers the epoch."
            )
            #endif
            try? await configuration.storage.setRetryState(nil)
            // Deliberately does NOT open the event-queue gate. The epoch was never registered, so
            // no batch can be ingested; releasing the queue here would retry a doomed request every
            // 60s for the rest of the process lifetime and drain the battery to no purpose. Parking
            // is safe rather than lossy: the events are not in a pending batch (none was ever sent),
            // so ordinary 72h age eviction still applies, and clearing the retry state above means
            // the NEXT launch re-submits first-open immediately — which settles the gate and flushes
            // them for real. The only cost is that events raised later in this same process wait for
            // that relaunch, and first-open only exhausts after a 24h window.
            return
        }
        let delays = Self.firstOpenRetryDelays
        let delay = delays[min(attempt - 1, delays.count - 1)]
        let state = RetryState(attempt: attempt, firstAttemptAt: current?.firstAttemptAt ?? now, nextAttemptAt: now.addingTimeInterval(delay))
        try? await configuration.storage.setRetryState(state)
        requestBackgroundRetry(earliest: state.nextAttemptAt)
        firstOpenTaskGeneration += 1
        let generation = firstOpenTaskGeneration
        firstOpenTask = Task {
            try? await Task.sleep(for: .seconds(delay))
            if !Task.isCancelled { await self.submitFirstOpen() }
            await self.clearFirstOpenTask(generation: generation)
        }
    }

    private func startOrResumeFirstOpen() async {
        guard !deletionPending else { return }
        firstOpenTask?.cancel()
        if let retry = await configuration.storage.retryState(), retry.nextAttemptAt > configuration.now() {
            let delay = retry.nextAttemptAt.timeIntervalSince(configuration.now())
            requestBackgroundRetry(earliest: retry.nextAttemptAt)
            firstOpenTaskGeneration += 1
            let generation = firstOpenTaskGeneration
            firstOpenTask = Task {
                try? await Task.sleep(for: .seconds(delay))
                if !Task.isCancelled { await self.submitFirstOpen() }
                await self.clearFirstOpenTask(generation: generation)
            }
        } else {
            firstOpenTaskGeneration += 1
            let generation = firstOpenTaskGeneration
            firstOpenTask = Task {
                await self.submitFirstOpen()
                await self.clearFirstOpenTask(generation: generation)
            }
        }
    }

    private func requestBackgroundRetry(earliest: Date) {
        do {
            try configuration.backgroundRetryScheduler.submit(earliest)
        } catch {
            configuration.diagnostic(
                "AttriKit: background retry submission failed for '\(AttriKit.backgroundRetryTaskIdentifier)'. The host must declare this identifier in BGTaskSchedulerPermittedIdentifiers. Error: \(error)"
            )
        }
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
        // A wipe rotates the epoch, and the server has decided nothing about the new one. Durable
        // receipts retain the identity and epoch they were raised under, so cancellation pauses
        // their drain without rewriting them against the new epoch.
        firstOpenRegistered = false
        deferredIdentify = false
        firstOpenTask?.cancel()
        pollTask?.cancel()
        queueTask?.cancel()
        consentReceiptTask?.cancel()
        firstOpenTask = nil
        pollTask = nil
        queueTask = nil
        consentReceiptTask = nil
        attributionCache = nil
        identity = nil
        sessionID = UUID()
        bufferedBeforeStart.removeAll()
        exactToken = nil
        selectedFirstOpenBody = nil
        pendingUserID = nil
        funnelIdentity = FunnelIdentity()
        resetSessionState()
        var erasureSucceeded = true
        do {
            try await configuration.storage.wipeQueue()
        } catch {
            erasureSucceeded = false
            configuration.diagnostic("AttriKit: queue erasure failed during consent revocation: \(error)")
        }
        await configuration.storage.setUserID(nil)
        do {
            try await configuration.storage.setRetryState(nil)
        } catch {
            erasureSucceeded = false
            configuration.diagnostic("AttriKit: retry-state erasure failed during consent revocation: \(error)")
        }
        // The wipe rotates the epoch; a first-open body kept from the old one would be
        // discarded on read anyway, but dropping it here keeps nothing stale behind a
        // deletion request.
        do {
            try await configuration.storage.setFirstOpenBody(
                nil,
                installEpochID: nil,
                consent: nil
            )
        } catch {
            erasureSucceeded = false
            configuration.diagnostic("AttriKit: first-open erasure failed during consent revocation: \(error)")
        }
        if finalizeRevocation && erasureSucceeded {
            do {
                _ = try await configuration.storage.finishRevocationTransition()
            } catch {
                configuration.diagnostic("AttriKit: revocation transition could not be finalized: \(error)")
            }
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
