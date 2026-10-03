import Foundation
import XCTest
@testable import AttriKitCore

private struct SignalingEvidence: PlatformEvidenceProviding {
    let signals: DeviceSignals?

    func appTransactionJWS() async -> String? { nil }
    func adServicesToken() async -> String? { nil }
    func coarseContext() -> CoarseContext {
        CoarseContext(countryCode: "FR", osMajor: "27.0", deviceClass: "phone", locale: "en-US")
    }
    func deviceSignals() -> DeviceSignals? { signals }
    func appVersion() -> String { "1.0 (1)" }
}

/// `device_signals` on the first open: what the server matches an install to its ad click with,
/// beside the IP. Before 2.7.0 iOS sent none (InkLine, 2026-10-02: an iOS 27 install whose own
/// Safari click 36 s earlier could only be compared on IP, timing and language).
final class DeviceSignalsTests: XCTestCase {
    func testFirstOpenCarriesTheProvidersDeviceSignals() async throws {
        let transport = StubTransport { _, _ in successResult() }
        let signals = DeviceSignals(
            deviceModel: "iPhone15,2",
            timezone: "Europe/Paris",
            screen: DeviceSignals.Screen(w: 390, h: 844, scale: 3)
        )
        await AttriKit.configureForTesting(makeTestConfiguration(
            transport: transport,
            evidence: SignalingEvidence(signals: signals)
        ))
        AttriKit.start(apiKey: String(repeating: "k", count: 20), consent: .measurementGranted)
        _ = await AttriKit.attribution(timeout: .seconds(1))

        let firstOpen = await transport.requests().first { $0.url?.path.hasSuffix("/v1/ingest/first-open") == true }
        let body = try gunzipStored(XCTUnwrap(firstOpen?.httpBody))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let sent = try XCTUnwrap(json["device_signals"] as? [String: Any])
        XCTAssertEqual(sent["device_model"] as? String, "iPhone15,2")
        XCTAssertEqual(sent["timezone"] as? String, "Europe/Paris")
        let screen = try XCTUnwrap(sent["screen"] as? [String: Any])
        XCTAssertEqual(screen["w"] as? Int, 390)
        XCTAssertEqual(screen["h"] as? Int, 844)
        XCTAssertEqual(screen["scale"] as? Double, 3)
        XCTAssertEqual(Set(sent.keys), ["device_model", "timezone", "screen"])
    }

    func testAProviderWithNothingToSaySendsNoDeviceSignalsKey() async throws {
        let transport = StubTransport { _, _ in successResult() }
        await AttriKit.configureForTesting(makeTestConfiguration(
            transport: transport,
            evidence: SignalingEvidence(signals: nil)
        ))
        AttriKit.start(apiKey: String(repeating: "k", count: 20), consent: .measurementGranted)
        _ = await AttriKit.attribution(timeout: .seconds(1))

        let firstOpen = await transport.requests().first { $0.url?.path.hasSuffix("/v1/ingest/first-open") == true }
        let body = try gunzipStored(XCTUnwrap(firstOpen?.httpBody))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertNil(json["device_signals"])
    }

    /// The envelope is `.strict()` server-side and a 422 is permanent, so a value past a cap is
    /// dropped on the device rather than sent.
    func testValuesOutsideTheServerCapsAreDropped() {
        let tooLong = String(repeating: "m", count: DeviceSignals.textMaxLength + 1)
        let dropped = DeviceSignals(
            deviceModel: tooLong,
            timezone: "  ",
            screen: DeviceSignals.Screen(w: 0, h: 844, scale: 3)
        )
        XCTAssertNil(dropped.deviceModel)
        XCTAssertNil(dropped.timezone)
        XCTAssertNil(dropped.screen)
        XCTAssertTrue(dropped.isEmpty)

        XCTAssertNil(DeviceSignals(deviceModel: nil, timezone: nil, screen: .init(w: 390, h: 16_385, scale: 3)).screen)
        XCTAssertNil(DeviceSignals(deviceModel: nil, timezone: nil, screen: .init(w: 390, h: 844, scale: 9)).screen)
        XCTAssertNil(DeviceSignals(deviceModel: nil, timezone: nil, screen: .init(w: 390, h: 844, scale: .nan)).screen)

        let kept = DeviceSignals(
            deviceModel: String(repeating: "m", count: DeviceSignals.textMaxLength),
            timezone: "Europe/Paris",
            screen: .init(w: 16_384, h: 1, scale: 8)
        )
        XCTAssertNotNil(kept.deviceModel)
        XCTAssertEqual(kept.timezone, "Europe/Paris")
        XCTAssertNotNil(kept.screen)
    }

    /// A body persisted by 2.6.1 has no `device_signals` and is re-sent verbatim; it must still
    /// decode, and a 2.7.0 body must keep its signals through a decode and re-encode.
    func testPersistedBodiesDecodeWithAndWithoutDeviceSignals() throws {
        let fixtures = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("shared/wire-fixtures/ios")
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let raw = try decoder.singleValueContainer().decode(String.self)
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return try XCTUnwrap(formatter.date(from: raw))
        }
        let minimal = try decoder.decode(
            FirstOpenEnvelope.self,
            from: Data(contentsOf: fixtures.appendingPathComponent("first-open-minimal.json"))
        )
        XCTAssertNil(minimal.deviceSignals)

        let standard = try decoder.decode(
            FirstOpenEnvelope.self,
            from: Data(contentsOf: fixtures.appendingPathComponent("first-open-standard.json"))
        )
        XCTAssertEqual(standard.deviceSignals?.deviceModel, "iPhone15,2")
        let reencoded = try JSONSerialization.jsonObject(with: attriKitJSONEncoder().encode(standard)) as? [String: Any]
        XCTAssertNotNil(reencoded?["device_signals"])
    }

    #if os(macOS)
    func testTheMacProviderHasNoDeviceSignals() {
        XCTAssertNil(ApplePlatformEvidenceProvider().deviceSignals())
    }
    #endif
}
