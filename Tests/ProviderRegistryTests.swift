import XCTest
import AppKit
@testable import Codenotch

/// The surfaces a change has to keep in step, held to it by a test rather than
/// by a note somebody has to remember to read.
///
/// Both of these are registration surfaces in the NamiNotch sense: a glyph and a
/// document are declared in one place and referenced from another, and a
/// mismatch is silent. A document with no front matter is a document nothing
/// routes to; a glyph with neither an asset nor an outline is a mark that draws
/// nothing at all.
final class ProviderRegistryTests: XCTestCase {
    private var root: URL {
        // Tests/<this file> → the package root is two levels up.
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func documents() throws -> [URL] {
        let enumerator = FileManager.default.enumerator(
            at: root.appendingPathComponent("docs"),
            includingPropertiesForKeys: nil
        )
        var found: [URL] = []
        while let url = enumerator?.nextObject() as? URL {
            if url.pathExtension == "md" { found.append(url) }
        }
        return found.sorted { $0.path < $1.path }
    }

    /// **Every document says what it is and when to read it.**
    ///
    /// The routing table at the top of `TASKS.md` is only as good as this front
    /// matter: it is what a reader — or an agent — is matched against, and a
    /// document without it is one nobody is told to open. The convention is the
    /// one `docs/providers/dsh.md` set.
    func testEveryDocumentDeclaresWhenItShouldBeRead() throws {
        let docs = try documents()
        XCTAssertFalse(docs.isEmpty, "the docs directory has gone missing")

        for url in docs {
            let text = try String(contentsOf: url, encoding: .utf8)
            let name = url.lastPathComponent
            XCTAssertTrue(text.hasPrefix("---\n"), "\(name) has no front matter")

            let body = text.index(text.startIndex, offsetBy: 4)
            guard let close = text.range(of: "\n---", range: body..<text.endIndex) else {
                XCTFail("\(name) never closes its front matter")
                continue
            }
            let header = text[text.startIndex..<close.lowerBound]
            XCTAssertTrue(header.contains("summary:"), "\(name) declares no summary")
            XCTAssertTrue(header.contains("read_when:"), "\(name) declares no read_when")
        }
    }

    /// **A document the routing table does not reach is a document nobody
    /// finds.**
    ///
    /// `TASKS.md` is the entry point every contributor and agent is pointed at,
    /// so every document has to be named from it. This catches the note written,
    /// added to `docs/providers/`, and never linked.
    func testEveryDocumentIsReachableFromTheEntryPoint() throws {
        let entry = try String(
            contentsOf: root.appendingPathComponent("TASKS.md"), encoding: .utf8)

        for url in try documents() {
            let relative = url.path.replacingOccurrences(of: root.path + "/", with: "")
            XCTAssertTrue(
                entry.contains(relative),
                "\(relative) is not named in TASKS.md, so nothing routes to it"
            )
        }
    }

    /// **A provider that nothing registers is a type that is never read.**
    ///
    /// `AppDelegate.allProviders` is a runtime array inside a function, so no
    /// test can ask it what it holds. What a test *can* do is ask whether each
    /// catalogued provider's type is named where that array is built — which is
    /// the check `docs/providers/README.md` sends a new provider to do by hand.
    /// The grep is the guard; the document is the explanation.
    func testEveryCataloguedProviderIsRegistered() throws {
        let delegate = try String(
            contentsOf: root.appendingPathComponent("Sources/App/AppDelegate.swift"),
            encoding: .utf8)

        for entry in ProviderCatalog.all {
            guard let type = entry.type else { continue }   // registered wholesale
            XCTAssertTrue(
                delegate.contains(type),
                "\(entry.id) is catalogued but AppDelegate names no \(type)"
            )
        }
    }

    /// **The README's provider table is the one a reader trusts**, and it is
    /// hand-written beside a list that is also hand-written. This is what keeps
    /// the two from drifting.
    func testEveryCataloguedProviderIsInTheReadme() throws {
        let readme = try String(
            contentsOf: root.appendingPathComponent("README.md"), encoding: .utf8)

        // The README names every provider it can read; it does not have to do it
        // in a table. It used to be one row per provider in bold, and this
        // checked for that shape — so rewriting the README as prose failed
        // twenty-three times for a reason that had nothing to do with whether a
        // provider was documented. The intent is that no provider is missing from
        // the README; the form is the README's business.
        for entry in ProviderCatalog.all {
            XCTAssertTrue(
                readme.contains(entry.label),
                "\(entry.id) is catalogued but the README never names \(entry.label)"
            )
        }
    }

    /// A note is worth writing only if something routes to it, and an id is
    /// worth cataloguing only once. Both are cheap to get wrong and silent when
    /// wrong.
    func testTheCatalogIsItselfSound() throws {
        let ids = ProviderCatalog.all.map(\.id)
        XCTAssertEqual(ids.count, Set(ids).count, "two catalogued providers share an id")

        let entry = try String(
            contentsOf: root.appendingPathComponent("TASKS.md"), encoding: .utf8)
        for entryWithNote in ProviderCatalog.all {
            guard let note = entryWithNote.note else { continue }
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: root.appendingPathComponent(note).path),
                "\(entryWithNote.id) points at \(note), which is not there"
            )
            XCTAssertTrue(
                entry.contains(note),
                "\(note) is not named in TASKS.md, so nothing routes to it"
            )
        }
    }

    /// **A glyph that draws nothing is a provider with no mark.**
    ///
    /// `GlyphShape` fills `ProviderGlyph.outline`, and an empty outline is a
    /// perfectly valid path: it renders as nothing, with no error anywhere.
    /// Everything else in the enum traces a fallback, so a missing asset only
    /// costs those a nicer drawing — but the cases whose outline is empty have
    /// the asset and nothing else. `ProviderGlyph.assetName` derives the name to
    /// look for, so this is the whole check.
    ///
    /// The catalogue is read from disk rather than through `NSImage(named:)`,
    /// which searches the *main* bundle: under `xcodebuild` that is the app and
    /// the lookup works, and run any other way it is the test bundle and every
    /// named image comes back nil. A guard whose answer depends on how it was
    /// launched is not a guard.
    func testEveryGlyphWithoutAnOutlineHasArtwork() {
        let catalogue = root.appendingPathComponent("Sources/Assets.xcassets")
        var unbacked: [String] = []
        for glyph in ProviderGlyph.allCases where glyph.outline.isEmpty {
            let artwork = catalogue.appendingPathComponent("\(glyph.assetName).imageset")
            if !FileManager.default.fileExists(atPath: artwork.path) {
                unbacked.append("\(glyph.rawValue) wants \(glyph.assetName).imageset")
            }
        }
        XCTAssertEqual(
            unbacked, [],
            "these glyphs have neither an outline nor an asset, so they draw nothing"
        )
    }
}
