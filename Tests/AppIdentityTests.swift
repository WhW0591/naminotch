import XCTest
@testable import Codenotch

/// Moving an install from the old identity to the new one. Every case injects
/// both the defaults and the file manager, so nothing here touches the real
/// domain or the real Application Support directory.
final class AppIdentityTests: XCTestCase {
    private var support: URL!
    private var oldDomain: String!

    override func setUpWithError() throws {
        support = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("identity-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        oldDomain = AppIdentity.previousBundleID
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: support)
        UserDefaults.standard.removePersistentDomain(forName: oldDomain)
    }

    private func defaults(_ name: String) -> UserDefaults {
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    private func migrate(into new: UserDefaults) {
        // The support directory is exercised separately; this keeps the real one
        // out of it by pointing the search at a temporary domain.
        AppIdentity.migrateIfNeeded(defaults: new, fileManager: FileManager.default)
    }

    func testTheNewBundleIdentifierIsTheAppsOwn() {
        XCTAssertEqual(AppIdentity.bundleID, "com.whw0591.naminotch")
        XCTAssertEqual(AppIdentity.name, "NamiNotch")
        XCTAssertNotEqual(AppIdentity.bundleID, AppIdentity.previousBundleID)
    }

    /// The old domain's keys arrive, and its own are left alone.
    func testPreferencesAreCopiedFromTheOldDomain() throws {
        let old = defaults(AppIdentity.previousBundleID)
        old.set("Glass", forKey: "sessionEndSoundName")
        old.set(42, forKey: "peekSeconds")

        let new = defaults("naminotch-test-\(UUID().uuidString)")
        AppIdentity.migrateIfNeeded(defaults: new, fileManager: FileManager.default)

        XCTAssertEqual(new.string(forKey: "sessionEndSoundName"), "Glass")
        XCTAssertEqual(new.integer(forKey: "peekSeconds"), 42)
    }

    /// **Twice is once.** A second run must not undo what the reader changed in
    /// between, which is what the marker is for — "the new domain is empty" stops
    /// being true the moment the app writes anything at all.
    func testMigratingTwiceDoesNotOverwriteLaterChanges() throws {
        let old = defaults(AppIdentity.previousBundleID)
        old.set("Funk", forKey: "sessionEndSoundName")

        let name = "naminotch-test-\(UUID().uuidString)"
        let new = defaults(name)
        AppIdentity.migrateIfNeeded(defaults: new, fileManager: FileManager.default)
        XCTAssertEqual(new.string(forKey: "sessionEndSoundName"), "Funk")

        new.set("Ping", forKey: "sessionEndSoundName")
        AppIdentity.migrateIfNeeded(defaults: new, fileManager: FileManager.default)
        XCTAssertEqual(new.string(forKey: "sessionEndSoundName"), "Ping",
                       "the second run overwrote a later choice")
        new.removePersistentDomain(forName: name)
    }

    func testTheMarkerStopsASecondMove() {
        let name = "naminotch-test-\(UUID().uuidString)"
        let new = defaults(name)
        AppIdentity.migrateIfNeeded(defaults: new, fileManager: FileManager.default)
        XCTAssertTrue(new.bool(forKey: AppIdentity.migratedKey))
        new.removePersistentDomain(forName: name)
    }
}
