import Foundation
import XCTest
@testable import AttriKitCore

/// The encoder and decoder used to build an `ISO8601DateFormatter` per Date. Caching one is only
/// admissible if the bytes on the wire are unchanged, if it stays correct when several threads
/// encode at once, and if it actually removes the cost that motivated it. One test each.
final class DateEncodingTests: XCTestCase {
    /// Dates chosen for the parts of the format that can differ between two formatters: a whole
    /// second, every fractional-second rounding boundary, a pre-1970 instant, and a year outside
    /// the current century.
    private static let probeDates: [Date] = {
        var dates: [Date] = [
            Date(timeIntervalSince1970: 0),
            Date(timeIntervalSince1970: -1),
            Date(timeIntervalSince1970: -86_400.75),
            Date(timeIntervalSince1970: 1_780_000_000),
            Date(timeIntervalSince1970: 1_780_000_000.001),
            Date(timeIntervalSince1970: 1_780_000_000.009),
            Date(timeIntervalSince1970: 1_780_000_000.0999),
            Date(timeIntervalSince1970: 1_780_000_000.5),
            Date(timeIntervalSince1970: 1_780_000_000.999),
            Date(timeIntervalSince1970: 4_102_444_800.125),
        ]
        dates.append(contentsOf: (0..<200).map {
            Date(timeIntervalSince1970: 1_700_000_000 + Double($0) * 137.017)
        })
        return dates
    }()

    /// What the code did before it shared one formatter: build one, use it once, throw it away.
    private static func perCallFormatted(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    /// `attriKitJSONEncoder()` as it stood before the formatter was shared, so the timing test
    /// below compares the two implementations rather than one implementation to a clock.
    private static func perCallEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(perCallFormatted(date))
        }
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    func testEncodedTimestampsAreByteIdenticalToAPerCallFormatter() throws {
        for date in Self.probeDates {
            let encoded = try attriKitJSONEncoder().encode([date])
            XCTAssertEqual(
                String(decoding: encoded, as: UTF8.self),
                "[\"\(Self.perCallFormatted(date))\"]",
                "the shared formatter must emit the bytes the per-Date formatter emitted"
            )
        }
    }

    func testDecodesEveryTimestampItEncodes() throws {
        let encoded = try attriKitJSONEncoder().encode(Self.probeDates)
        let decoded = try attriKitJSONDecoder().decode([Date].self, from: encoded)
        XCTAssertEqual(decoded.count, Self.probeDates.count)
        for (decodedDate, originalDate) in zip(decoded, Self.probeDates) {
            XCTAssertEqual(
                decodedDate.timeIntervalSince1970,
                originalDate.timeIntervalSince1970,
                accuracy: 0.0005,
                "a round trip must land on the same instant, to the millisecond the format carries"
            )
        }
    }

    /// A shared formatter is shared state inside somebody else's app. Encoding and decoding from
    /// many threads at once must produce exactly the single-threaded answer.
    func testConcurrentEncodesAndDecodesAgreeWithTheSingleThreadedAnswer() throws {
        let dates = Array(Self.probeDates.prefix(64))
        let expected = try dates.map { String(decoding: try attriKitJSONEncoder().encode([$0]), as: UTF8.self) }
        let results = ConcurrentResults(count: dates.count)

        DispatchQueue.concurrentPerform(iterations: dates.count * 4) { iteration in
            let index = iteration % dates.count
            guard let encoded = try? attriKitJSONEncoder().encode([dates[index]]),
                  let decoded = try? attriKitJSONDecoder().decode([Date].self, from: encoded),
                  decoded.count == 1 else {
                results.record(index: index, encoded: "encode or decode failed")
                return
            }
            results.record(index: index, encoded: String(decoding: encoded, as: UTF8.self))
        }

        XCTAssertEqual(results.snapshot(), expected)
    }

    /// The point of the cache, measured against the behaviour it replaced RATHER than against a
    /// wall-clock budget: both halves run in this process, on this machine, over the same dates,
    /// best of five, so a slow or loaded host slows both and the ratio survives. Measured 81.9x
    /// in this debug test build (0.159s against 0.0019s for 2000 dates) and 86x optimised; the bar
    /// is 5x, and it goes red at ratio 1 if the strategies go back to a formatter per Date.
    func testSharingTheFormatterIsCheaperThanBuildingOnePerDate() {
        let dates = (0..<2_000).map { Date(timeIntervalSince1970: 1_780_000_000 + Double($0) * 0.137) }
        let perCall = Self.bestOfFive { _ = try? Self.perCallEncoder().encode(dates) }
        let shared = Self.bestOfFive { _ = try? attriKitJSONEncoder().encode(dates) }

        XCTAssertGreaterThan(
            perCall / shared,
            5,
            "encoding \(dates.count) dates through the shared formatter took \(shared)s "
                + "against \(perCall)s for one formatter per date"
        )
    }

    private static func bestOfFive(_ body: () -> Void) -> Double {
        var best = Double.infinity
        for _ in 0..<5 {
            let start = DispatchTime.now().uptimeNanoseconds
            body()
            best = min(best, Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9)
        }
        return best
    }
}

private final class ConcurrentResults: @unchecked Sendable {
    private let lock = NSLock()
    private var encoded: [String]

    init(count: Int) {
        encoded = Array(repeating: "", count: count)
    }

    func record(index: Int, encoded value: String) {
        lock.lock()
        encoded[index] = value
        lock.unlock()
    }

    func snapshot() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return encoded
    }
}
