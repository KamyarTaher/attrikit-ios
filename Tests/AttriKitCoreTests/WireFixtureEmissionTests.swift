import Foundation
import XCTest
@testable import AttriKitCore

/// Validates that payloads serialized by the iOS SDK through its PRODUCTION encoders
/// (attriKitJSONEncoder) match the tracked wire fixtures in `packages/shared/wire-fixtures/ios/`.
///
/// OD1 §1 item 29: validate payloads REALLY serialized by Swift and Kotlin against the
/// server schema as executed, across supported wire versions, absent and null fields,
/// limits, and edge cases.
final class WireFixtureEmissionTests: XCTestCase {
    private static var wireFixturesDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Tests/AttriKitCoreTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // packages/sdk-ios
            .deletingLastPathComponent() // packages
            .appendingPathComponent("shared")
            .appendingPathComponent("wire-fixtures")
            .appendingPathComponent("ios")
    }

    private static func stringify<T: Encodable>(_ value: T) throws -> String {
        let encoder = attriKitJSONEncoder()
        let data = try encoder.encode(value)
        return String(decoding: data, as: UTF8.self) + "\n"
    }

    private func assertEmissionMatchesFixture<T: Encodable>(
        payload: T,
        filename: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let serialized = try Self.stringify(payload)
        try assertSerializedMatchesFixture(serialized: serialized, filename: filename, file: file, line: line)
    }

    private func assertEmissionDataMatchesFixture(
        data: Data,
        filename: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let serialized = String(decoding: data, as: UTF8.self) + "\n"
        try assertSerializedMatchesFixture(serialized: serialized, filename: filename, file: file, line: line)
    }

    private func assertSerializedMatchesFixture(
        serialized: String,
        filename: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let fixtureURL = Self.wireFixturesDirectory.appendingPathComponent(filename)

        if ProcessInfo.processInfo.environment["UPDATE_WIRE_FIXTURES"] == "1" {
            try FileManager.default.createDirectory(at: Self.wireFixturesDirectory, withIntermediateDirectories: true)
            try serialized.write(to: fixtureURL, atomically: true, encoding: .utf8)
        }

        XCTAssertTrue(
            FileManager.default.fileExists(atPath: fixtureURL.path),
            "Wire fixture missing at \(fixtureURL.path); run with UPDATE_WIRE_FIXTURES=1 to generate",
            file: file,
            line: line
        )

        let fixtureContent = try String(contentsOf: fixtureURL, encoding: .utf8)
        XCTAssertEqual(
            serialized,
            fixtureContent,
            "Emitted wire payload drifted from committed fixture \(filename)",
            file: file,
            line: line
        )
    }

    func testEmitFirstOpenStandard() throws {
        let envelope = FirstOpenEnvelope(
            installationID: UUID(uuidString: "c0ffee00-1111-4111-8111-111111111111")!,
            installEpochID: UUID(uuidString: "c0ffee00-2222-4222-8222-222222222222")!,
            occurredAt: Date(timeIntervalSince1970: 1_780_000_000),
            appVersion: "2.3.3",
            coarseContext: CoarseContext(countryCode: "CH", osMajor: "17.0", deviceClass: "phone", locale: "en-CH"),
            consent: ConsentPayload(state: .measurementGranted, policyVersion: 1),
            appTransactionJWS: "verified-jws-payload-value",
            asaToken: "sample-asa-token-value",
            exactTokenReference: ExactTokenReference(
                token: "ak1_0123456789012345678901234567890123456789012",
                kind: "owned_deferred",
                clipboardOptIn: true
            ),
            webFirstParty: WebFirstPartyIdentity(FunnelIdentity(
                emailHash: "a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2",
                phoneHash: "b1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6b1b2"
            )),
            idfa: nil,
            idfv: LowercaseUUID(wrappedValue: UUID(uuidString: "33333333-3333-4333-8333-333333333333")!),
            localLineagePresent: true,
            localEpochPresent: true
        )
        try assertEmissionMatchesFixture(payload: envelope, filename: "first-open-standard.json")
    }

    func testEmitFirstOpenMinimal() throws {
        let envelope = FirstOpenEnvelope(
            installationID: UUID(uuidString: "c0ffee00-1111-4111-8111-111111111111")!,
            installEpochID: UUID(uuidString: "c0ffee00-2222-4222-8222-222222222222")!,
            occurredAt: Date(timeIntervalSince1970: 1_780_000_000),
            appVersion: "2.3.3",
            coarseContext: CoarseContext(countryCode: nil, osMajor: "17.0", deviceClass: "phone", locale: nil),
            consent: ConsentPayload(state: .unknown, policyVersion: 1),
            appTransactionJWS: nil,
            asaToken: nil,
            exactTokenReference: nil,
            webFirstParty: nil,
            idfa: nil,
            idfv: nil,
            localLineagePresent: false,
            localEpochPresent: false
        )
        try assertEmissionMatchesFixture(payload: envelope, filename: "first-open-minimal.json")
    }

    func testEmitFirstOpenLimits() throws {
        let envelope = FirstOpenEnvelope(
            installationID: UUID(uuidString: "c0ffee00-1111-4111-8111-111111111111")!,
            installEpochID: UUID(uuidString: "c0ffee00-2222-4222-8222-222222222222")!,
            occurredAt: Date(timeIntervalSince1970: 1_780_000_000),
            appVersion: String(repeating: "1", count: 128),
            coarseContext: CoarseContext(
                countryCode: "US",
                osMajor: "17.4",
                deviceClass: "phone",
                locale: "en-US-u-ca-buddhist-nu-thai-tz-us"
            ),
            consent: ConsentPayload(state: .trackingGranted, policyVersion: 1),
            appTransactionJWS: String(repeating: "j", count: 1024),
            asaToken: String(repeating: "a", count: 512),
            exactTokenReference: ExactTokenReference(
                token: "ak1_" + String(repeating: "X", count: 508),
                kind: "owned_deferred",
                clipboardOptIn: true
            ),
            webFirstParty: WebFirstPartyIdentity(FunnelIdentity(
                emailHash: String(repeating: "0", count: 64),
                phoneHash: String(repeating: "1", count: 64)
            )),
            idfa: LowercaseUUID(wrappedValue: UUID(uuidString: "44444444-4444-4444-8444-444444444444")!),
            idfv: LowercaseUUID(wrappedValue: UUID(uuidString: "55555555-5555-4555-8555-555555555555")!),
            localLineagePresent: true,
            localEpochPresent: true
        )
        try assertEmissionMatchesFixture(payload: envelope, filename: "first-open-limits.json")
    }

    func testEmitEventBatchStandard() throws {
        let event = EventEnvelope(
            eventID: UUID(uuidString: "aaaaaaaa-aaaa-4aaa-8aaa-000000000001")!,
            eventName: "cart_checkout",
            eventVersion: 1,
            occurredAt: Date(timeIntervalSince1970: 1_780_000_000),
            sentAt: Date(timeIntervalSince1970: 1_780_000_001),
            installationID: UUID(uuidString: "c0ffee00-1111-4111-8111-111111111111")!,
            installEpochID: UUID(uuidString: "c0ffee00-2222-4222-8222-222222222222")!,
            sessionID: UUID(uuidString: "bbbbbbbb-bbbb-4bbb-8bbb-000000000001")!,
            consent: EventConsent(measurement: "granted", tracking: "denied", policyVersion: 1),
            properties: [
                "item_count": 2,
                "amount": 49.99,
                "currency": "CHF",
                "is_premium": true,
            ]
        )
        let batch = EventBatch(
            batchID: "01900000-0000-7000-8000-000000000001",
            events: [event]
        )
        try assertEmissionMatchesFixture(payload: batch, filename: "event-batch-standard.json")
    }

    func testEmitEventBatchMinimal() throws {
        let event = EventEnvelope(
            eventID: UUID(uuidString: "aaaaaaaa-aaaa-4aaa-8aaa-000000000002")!,
            eventName: "app_foregrounded",
            eventVersion: 1,
            occurredAt: Date(timeIntervalSince1970: 1_780_000_000),
            sentAt: Date(timeIntervalSince1970: 1_780_000_001),
            installationID: UUID(uuidString: "c0ffee00-1111-4111-8111-111111111111")!,
            installEpochID: UUID(uuidString: "c0ffee00-2222-4222-8222-222222222222")!,
            sessionID: UUID(uuidString: "bbbbbbbb-bbbb-4bbb-8bbb-000000000002")!,
            consent: EventConsent(measurement: "granted", tracking: "denied", policyVersion: 1),
            properties: [:]
        )
        let batch = EventBatch(
            batchID: "01900000-0000-7000-8000-000000000002",
            events: [event]
        )
        try assertEmissionMatchesFixture(payload: batch, filename: "event-batch-minimal.json")
    }

    func testEmitEventBatchLimits() throws {
        var properties: [String: AttriKitValue] = [:]
        for i in 1...64 {
            let key = String(format: "prop_%02d", i)
            if i == 1 {
                properties[key] = .string(String(repeating: "x", count: 1024))
            } else if i == 2 {
                properties[key] = .number(999999.99)
            } else if i == 3 {
                properties[key] = .bool(false)
            } else {
                properties[key] = .number(Double(i))
            }
        }
        let event = EventEnvelope(
            eventID: UUID(uuidString: "aaaaaaaa-aaaa-4aaa-8aaa-000000000003")!,
            eventName: "limit_reached",
            eventVersion: 1,
            occurredAt: Date(timeIntervalSince1970: 1_780_000_000),
            sentAt: Date(timeIntervalSince1970: 1_780_000_001),
            installationID: UUID(uuidString: "c0ffee00-1111-4111-8111-111111111111")!,
            installEpochID: UUID(uuidString: "c0ffee00-2222-4222-8222-222222222222")!,
            sessionID: UUID(uuidString: "bbbbbbbb-bbbb-4bbb-8bbb-000000000003")!,
            consent: EventConsent(measurement: "granted", tracking: "denied", policyVersion: 1),
            properties: properties
        )
        let batch = EventBatch(
            batchID: "01900000-0000-7000-8000-000000000003",
            events: [event]
        )
        try assertEmissionMatchesFixture(payload: batch, filename: "event-batch-limits.json")
    }

    func testEmitIdentifyStandard() throws {
        let envelope = IdentifyEnvelope(
            installationID: UUID(uuidString: "c0ffee00-1111-4111-8111-111111111111")!,
            installEpochID: UUID(uuidString: "c0ffee00-2222-4222-8222-222222222222")!,
            occurredAt: Date(timeIntervalSince1970: 1_780_000_000),
            customerUserID: "usr_authenticated_42",
            emailHash: "a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2",
            phoneHash: "b1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6b1b2",
            exactTokenReference: nil,
            idfa: nil,
            idfv: LowercaseUUID(wrappedValue: UUID(uuidString: "33333333-3333-4333-8333-333333333333")!)
        )
        try assertEmissionMatchesFixture(payload: envelope, filename: "identify-standard.json")
    }

    func testEmitIdentifyMinimal() throws {
        let envelope = IdentifyEnvelope(
            installationID: UUID(uuidString: "c0ffee00-1111-4111-8111-111111111111")!,
            installEpochID: UUID(uuidString: "c0ffee00-2222-4222-8222-222222222222")!,
            occurredAt: Date(timeIntervalSince1970: 1_780_000_000),
            customerUserID: "usr_minimal_only",
            emailHash: nil,
            phoneHash: nil,
            exactTokenReference: nil,
            idfa: nil,
            idfv: nil
        )
        try assertEmissionMatchesFixture(payload: envelope, filename: "identify-minimal.json")
    }

    func testEmitIdentifyLimits() throws {
        let envelope = IdentifyEnvelope(
            installationID: UUID(uuidString: "c0ffee00-1111-4111-8111-111111111111")!,
            installEpochID: UUID(uuidString: "c0ffee00-2222-4222-8222-222222222222")!,
            occurredAt: Date(timeIntervalSince1970: 1_780_000_000),
            customerUserID: String(repeating: "u", count: 256),
            emailHash: String(repeating: "e", count: 64),
            phoneHash: String(repeating: "f", count: 64),
            exactTokenReference: ExactTokenReference(
                token: "ak1_" + String(repeating: "T", count: 508),
                kind: "owned_deferred",
                clipboardOptIn: nil
            ),
            idfa: LowercaseUUID(wrappedValue: UUID(uuidString: "44444444-4444-4444-8444-444444444444")!),
            idfv: LowercaseUUID(wrappedValue: UUID(uuidString: "55555555-5555-4555-8555-555555555555")!)
        )
        try assertEmissionMatchesFixture(payload: envelope, filename: "identify-limits.json")
    }

    func testEmitConsentReceiptGranted() throws {
        let data = try CoreRuntime.encodedConsentReceiptForTesting(
            installationID: UUID(uuidString: "c0ffee00-1111-4111-8111-111111111111")!,
            installEpochID: UUID(uuidString: "c0ffee00-2222-4222-8222-222222222222")!,
            scope: "tracking",
            consentState: .trackingGranted,
            policyVersion: 1,
            occurredAt: Date(timeIntervalSince1970: 1_780_000_000)
        )
        try assertEmissionDataMatchesFixture(data: data, filename: "consent-receipt-granted.json")
    }

    func testEmitConsentReceiptRevoked() throws {
        let data = try CoreRuntime.encodedConsentReceiptForTesting(
            installationID: UUID(uuidString: "c0ffee00-1111-4111-8111-111111111111")!,
            installEpochID: UUID(uuidString: "c0ffee00-2222-4222-8222-222222222222")!,
            scope: "measurement",
            consentState: .revoked,
            policyVersion: 1,
            occurredAt: Date(timeIntervalSince1970: 1_780_000_000)
        )
        try assertEmissionDataMatchesFixture(data: data, filename: "consent-receipt-revoked.json")
    }

    func testEmitConsentReceiptMeasurementGranted() throws {
        let data = try CoreRuntime.encodedConsentReceiptForTesting(
            installationID: UUID(uuidString: "c0ffee00-1111-4111-8111-111111111111")!,
            installEpochID: UUID(uuidString: "c0ffee00-2222-4222-8222-222222222222")!,
            scope: "tracking",
            consentState: .measurementGranted,
            policyVersion: 1,
            occurredAt: Date(timeIntervalSince1970: 1_780_000_000)
        )
        try assertEmissionDataMatchesFixture(data: data, filename: "consent-receipt-measurement-granted.json")
    }
}
