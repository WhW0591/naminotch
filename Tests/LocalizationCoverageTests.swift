import XCTest
@testable import Codenotch

/// **A string the source asks for has a Chinese translation, or is on the list.**
///
/// Every user-facing string in this app goes through `L10n.t(...)` and is
/// expected in `Localizable.xcstrings` with a `zh-Hans` value beside it. Being
/// expected is not the same as being done: 306 of the 642 keys in use had no
/// translation when this test was written, most of them older than the work that
/// noticed the gap.
///
/// So the list is the backlog and the test is the rule. A new key with no
/// translation fails here — which is the whole of "remember to do it", expressed
/// as something that cannot be forgotten — and the list may only ever shrink.
final class LocalizationCoverageTests: XCTestCase {
    private var root: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    /// The same pattern the baseline was generated with, deliberately: whatever
    /// it does or does not see is already baked into the list, so the two agree
    /// by construction and this only ever catches something new.
    private static let ask = try! NSRegularExpression(
        pattern: #"L10n\.t\("((?:[^"\\]|\\.)*)"\)"#)

    private func keysTheSourceAsksFor() throws -> [String: String] {
        var found: [String: String] = [:]
        let enumerator = FileManager.default.enumerator(
            at: root.appendingPathComponent("Sources"), includingPropertiesForKeys: nil)
        while let url = enumerator?.nextObject() as? URL {
            guard url.pathExtension == "swift" else { continue }
            let text = try String(contentsOf: url, encoding: .utf8)
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            for match in Self.ask.matches(in: text, range: range) {
                guard let r = Range(match.range(at: 1), in: text) else { continue }
                found[String(text[r])] = url.lastPathComponent
            }
        }
        return found
    }

    private func catalogue() throws -> [String: Any] {
        let data = try Data(contentsOf: root.appendingPathComponent(
            "Sources/Localizable.xcstrings"))
        let root = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any])
        return try XCTUnwrap(root["strings"] as? [String: Any])
    }

    private func baseline() throws -> Set<String> {
        let text = try String(contentsOf: root.appendingPathComponent(
            "Tests/untranslated-baseline.txt"), encoding: .utf8)
        return Set(text.split(separator: "\n")
            .map(String.init)
            .filter { !$0.hasPrefix("#") && !$0.isEmpty })
    }

    func testEveryStringTheSourceAsksForIsTranslatedOrOnTheList() throws {
        let catalogue = try catalogue()
        let baseline = try baseline()
        let asked = try keysTheSourceAsksFor()

        XCTAssertGreaterThan(asked.count, 100, "the source scan found almost nothing")

        var untranslated: [String] = []
        for (key, file) in asked.sorted(by: { $0.key < $1.key }) {
            let entry = catalogue[key] as? [String: Any]
            let localisations = entry?["localizations"] as? [String: Any]
            let translated = localisations?["zh-Hans"] != nil
            if !translated && !baseline.contains(key) {
                untranslated.append("\(key)  (\(file))")
            }
        }
        XCTAssertEqual(untranslated, [],
                       "these strings have no zh-Hans and are not on the backlog list")
    }

    /// The list may only shrink, so a key that has since been translated has to
    /// leave it. Without this the backlog would quietly become permanent.
    func testTheBacklogDoesNotListAnythingAlreadyTranslated() throws {
        let catalogue = try catalogue()
        var stale: [String] = []
        for key in try baseline().sorted() {
            let entry = catalogue[key] as? [String: Any]
            let localisations = entry?["localizations"] as? [String: Any]
            if localisations?["zh-Hans"] != nil { stale.append(key) }
        }
        XCTAssertEqual(stale, [], "these are translated now, so remove them from the list")
    }
}
