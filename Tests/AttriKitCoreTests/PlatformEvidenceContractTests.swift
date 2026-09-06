import Foundation
import XCTest
@testable import AttriKitCore

private func uncommentedFunctionBody(named name: String, in source: String) -> String? {
    guard let provider = source.range(of: "struct ApplePlatformEvidenceProvider"),
          let signature = source.range(of: "func \(name)(", range: provider.upperBound..<source.endIndex),
          let opening = source[signature.upperBound...].firstIndex(of: "{") else { return nil }
    var depth = 1
    var index = source.index(after: opening)
    var body = ""
    var inLineComment = false
    var inBlockComment = false
    var inString = false
    while index < source.endIndex {
        let next = source.index(after: index)
        let character = source[index]
        let following = next < source.endIndex ? source[next] : "\0"
        if inLineComment || inBlockComment {
            let comment = consumeComment(character, following, inLineComment, inBlockComment)
            inLineComment = comment.inLine
            inBlockComment = comment.inBlock
            if comment.append { body.append(character) }
            if comment.skipFollowing { index = next }
        } else if let comment = startsComment(character, following, inString) {
            inLineComment = comment.inLine
            inBlockComment = comment.inBlock
            index = next
        } else {
            if character == "\"" { inString.toggle() }
            if !inString && character == "{" { depth += 1 }
            if !inString && character == "}" {
                depth -= 1
                if depth == 0 { return body }
            }
            body.append(character)
        }
        index = source.index(after: index)
    }
    return nil
}

private func consumeComment(_ character: Character, _ following: Character, _ inLine: Bool, _ inBlock: Bool) -> (inLine: Bool, inBlock: Bool, append: Bool, skipFollowing: Bool) {
    if inLine { return (character != "\n", false, character == "\n", false) }
    return (false, !(character == "*" && following == "/"), false, character == "*" && following == "/")
}

private func startsComment(_ character: Character, _ following: Character, _ inString: Bool) -> (inLine: Bool, inBlock: Bool)? {
    guard !inString && character == "/" else { return nil }
    if following == "/" { return (true, false) }
    if following == "*" { return (false, true) }
    return nil
}

private func productionLocaleGuardIsLive(in source: String) -> Bool {
    guard let body = uncommentedFunctionBody(named: "coarseContext", in: source) else { return false }
    let assignment = "let locale = tag.count <= CoarseContext.localeMaxLength ? tag : nil"
    guard body.components(separatedBy: assignment).count == 2,
          let assignmentRange = body.range(of: assignment),
          let returnRange = body.range(of: "return CoarseContext(") else { return false }
    guard assignmentRange.lowerBound < returnRange.lowerBound,
          body[returnRange.lowerBound...].contains("locale: locale"),
          !body[..<assignmentRange.lowerBound].contains("return ") else { return false }

    guard body.range(of: "let tag =") != nil else { return false }
    let prefix = body[..<assignmentRange.lowerBound]
    return sourceBraceDepth(prefix) == 0 && conditionalCompilationIsBalanced(prefix)
}

private func sourceBraceDepth(_ source: Substring) -> Int {
    var depth = 0
    var inString = false
    for character in source {
        if character == "\"" { inString.toggle() }
        if !inString && character == "{" { depth += 1 }
        if !inString && character == "}" { depth -= 1 }
    }
    return depth
}

private func conditionalCompilationIsBalanced(_ source: Substring) -> Bool {
    var depth = 0
    for line in source.split(separator: "\n", omittingEmptySubsequences: false) {
        let directive = line.trimmingCharacters(in: .whitespaces)
        if directive.hasPrefix("#if ") || directive == "#if" { depth += 1 }
        else if directive == "#endif" { depth -= 1; if depth < 0 { return false } }
    }
    return depth == 0
}

/// True when the blocking AdServices call is reached only through a global-queue dispatch, so no
/// Swift-concurrency cooperative thread is held for the duration of a network-backed call.
private func attributionTokenIsDispatchedOffTheCooperativePool(in source: String) -> Bool {
    guard let ladder = uncommentedFunctionBody(named: "adServicesToken", in: source),
          let helper = uncommentedFunctionBody(named: "attributionToken", in: source) else { return false }
    guard !ladder.contains("AAAttribution.attributionToken("),
          ladder.contains("attributionToken()") else { return false }
    guard let dispatch = helper.range(of: "DispatchQueue.global("),
          let call = helper.range(of: "AAAttribution.attributionToken("),
          helper.contains(".async {") else { return false }
    return dispatch.lowerBound < call.lowerBound
}

/// The wire contract for `coarse_context.locale`, tested against the REAL provider.
///
/// Every other test in this package injects a stub returning `"en-CH"`, so the one thing that could
/// go wrong here — the value the device actually produces — was the one thing nothing looked at.
/// `Locale.current.identifier` is the ICU form, not a language tag: `th_TH@calendar=buddhist;
/// numbers=thai` is 36 characters once `_` becomes `-`, `ar_EG@calendar=islamic-umalqura;
/// numbers=arab` is 44, and `coarseContextSchema` caps the field at 35 inside a `.strict()` object.
/// Past the cap the whole first-open is a 422, `isPermanentClientFailure` treats 422 as permanent,
/// and the persisted body is re-sent verbatim on every later launch — so the install is lost
/// silently and forever.
///
/// TEST-LANE CAVEAT, stated because it bounds what these greens mean: this package tests as
/// arm64e-apple-macos, so `coarseContext()`'s `#if os(iOS)` device-class branch is not in this
/// binary. The locale line is NOT inside that conditional, which is why it can be tested here at
/// all; the retry ladder in `adServicesToken()` is, and cannot be RUN here -- which is why its one
/// remaining contract, that the blocking AdServices call never runs on the cooperative pool, is
/// asserted on the production source text below rather than on behaviour.
final class PlatformEvidenceContractTests: XCTestCase {
    private func productionSource() throws -> String {
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/AttriKitCore/PlatformEvidence.swift")
        return try String(contentsOf: source, encoding: .utf8)
    }

    /// `AAAttribution.attributionToken()` is synchronous and network-backed. Awaiting it directly
    /// blocks a cooperative thread for up to the whole 2s evidence budget, three times over, and the
    /// `Task.sleep` that enforces that budget in `CoreRuntime.boundedEvidence` needs a cooperative
    /// thread of its own to resume on.
    func testTheBlockingAdServicesCallNeverRunsOnTheCooperativePool() throws {
        let text = try productionSource()
        XCTAssertTrue(
            attributionTokenIsDispatchedOffTheCooperativePool(in: text),
            "the blocking AdServices token call must be dispatched to a global queue"
        )

        let inlineMutant = text.replacingOccurrences(
            of: "if let token = await Self.attributionToken() { return token }",
            with: "if let token = try? AAAttribution.attributionToken() { return token }"
        )
        XCTAssertFalse(
            attributionTokenIsDispatchedOffTheCooperativePool(in: inlineMutant),
            "calling AAAttribution straight from the async ladder must not satisfy the contract"
        )

        let commentedDispatchMutant = text.replacingOccurrences(
            of: "DispatchQueue.global(qos: .utility).async {",
            with: "// DispatchQueue.global(qos: .utility).async {"
        )
        XCTAssertFalse(
            attributionTokenIsDispatchedOffTheCooperativePool(in: commentedDispatchMutant),
            "a dispatch preserved only in a comment must not satisfy the contract"
        )
    }

    func testProductionLocaleAssignmentContainsTheServerCapGuard() throws {
        let testFile = URL(fileURLWithPath: #filePath)
        let source = testFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/AttriKitCore/PlatformEvidence.swift")
        let text = try String(contentsOf: source, encoding: .utf8)
        XCTAssertTrue(
            productionLocaleGuardIsLive(in: text),
            "the real locale provider must omit an over-cap tag instead of shipping a 422"
        )

        let commentedMutant = text.replacingOccurrences(
            of: "let locale = tag.count <= CoarseContext.localeMaxLength ? tag : nil",
            with: "let locale = tag // tag.count <= CoarseContext.localeMaxLength ? tag : nil"
        )
        XCTAssertFalse(
            productionLocaleGuardIsLive(in: commentedMutant),
            "a guard preserved only in a comment must not satisfy the production contract"
        )
        let deadBranchMutant = text.replacingOccurrences(
            of: "let locale = tag.count <= CoarseContext.localeMaxLength ? tag : nil",
            with: "let locale = tag\n        if false {\n            let locale = tag.count <= CoarseContext.localeMaxLength ? tag : nil\n            _ = locale\n        }"
        )
        XCTAssertFalse(
            productionLocaleGuardIsLive(in: deadBranchMutant),
            "a guard preserved only in an unused branch must not satisfy the production contract"
        )
        let conditionallyCompiledMutant = text
            .replacingOccurrences(of: "let tag =", with: "#if DEBUG\n        let tag =")
            .replacingOccurrences(
                of: "let locale = tag.count <= CoarseContext.localeMaxLength ? tag : nil",
                with: "let locale = tag.count <= CoarseContext.localeMaxLength ? tag : nil\n        #endif"
            )
        XCTAssertFalse(
            productionLocaleGuardIsLive(in: conditionallyCompiledMutant),
            "a release-compiled-out locale guard must not satisfy the production contract"
        )
    }

    func testCurrentLocaleIsProducedAndFitsTheServersCap() throws {
        let context = ApplePlatformEvidenceProvider().coarseContext()
        let locale = try XCTUnwrap(
            context.locale,
            "the real provider must produce the host's BCP-47 locale"
        )
        XCTAssertLessThanOrEqual(
            locale.count,
            CoarseContext.localeMaxLength,
            "coarse_context.locale exceeds the server's cap, which 422s the whole first-open"
        )
    }

    /// The producer must emit a language TAG, not the ICU identifier. Asserted on the characters
    /// that distinguish them, because they are also the characters that make it long: a keyword
    /// section always begins with `@` and separates with `;` and `=`.
    func testCurrentLocaleCarriesNoIcuKeywordSection() throws {
        let context = ApplePlatformEvidenceProvider().coarseContext()
        let locale = try XCTUnwrap(
            context.locale,
            "the ICU-keyword assertion is vacuous when locale production disappears"
        )
        for forbidden in ["@", ";", "="] {
            XCTAssertFalse(
                locale.contains(forbidden),
                "coarse_context.locale carries an ICU keyword section: \(locale)"
            )
        }
    }

    /// The rule itself, on the inputs this host cannot be made to produce. `identifier(.bcp47)`
    /// renders a keyword-bearing identifier as a tag; the cap is then a real bound rather than a
    /// hope, and the drop-rather-than-truncate rule is exercised on a value that exceeds it.
    func testKeywordBearingIdentifiersRenderAsTagsWithinTheCap() {
        for identifier in [
            "th_TH@calendar=buddhist;numbers=thai",
            "zh_Hans_CN@calendar=chinese;numbers=hanidec",
            "ar_EG@calendar=islamic-umalqura;numbers=arab",
        ] {
            let raw = identifier.replacingOccurrences(of: "_", with: "-")
            XCTAssertGreaterThan(
                raw.count,
                CoarseContext.localeMaxLength,
                "this fixture no longer exceeds the cap, so it no longer tests anything"
            )
            let tag = Locale(identifier: identifier).identifier(.bcp47)
            XCTAssertLessThanOrEqual(
                tag.count,
                CoarseContext.localeMaxLength,
                "the BCP-47 rendering of \(identifier) still exceeds the server's cap"
            )
            XCTAssertFalse(tag.contains("@"), "the BCP-47 rendering kept an ICU keyword section")
        }
    }
}
