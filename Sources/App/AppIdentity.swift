import Foundation

/// What this app is called, and what it used to be called.
///
/// The name changed — NamiNotch, from Codenotch — and a name is an *identity*
/// here rather than a label: the bundle id decides which `UserDefaults` domain
/// is read, the support directory holds the accounts, prices and plans, and the
/// keychain service holds the custom endpoints' tokens. Changing all three
/// without moving the data would look exactly like a fresh install, so
/// `migrateIfNeeded()` moves it.
///
/// The old strings are written out here rather than derived, because after the
/// first launch the app has no other way to know what it was called.
enum AppIdentity {
    static let name = "NamiNotch"
    static let bundleID = "com.whw0591.naminotch"

    /// The support directory's name under `Application Support`.
    static let supportDirectory = name

    // MARK: - What it was

    static let previousName = "Codenotch"
    static let previousBundleID = "com.vinz.codenotch"
    static let previousSupportDirectory = previousName
    static let previousKeychainService = "com.vinzdg.codenotch.custom-endpoint"

    /// The one key that says the move has happened. Written last, so a migration
    /// interrupted halfway runs again rather than being assumed done.
    static let migratedKey = "identityMigratedToNamiNotch"

    // MARK: - Migrating

    /// Moves an existing install's data to the new identity, once.
    ///
    /// Idempotent by a marker rather than by looking for emptiness: the new
    /// domain fills up with defaults the moment the app writes anything, so
    /// "empty" stops meaning "not migrated yet" almost immediately. Doing this
    /// twice would undo whatever the reader changed in between.
    ///
    /// Must run before anything reads `UserDefaults.standard`, which is why the
    /// app calls it at the top of launch.
    static func migrateIfNeeded(defaults: UserDefaults = .standard,
                                fileManager: FileManager = .default) {
        guard !defaults.bool(forKey: migratedKey) else { return }

        migratePreferences(into: defaults)
        migrateSupportDirectory(fileManager: fileManager)
        migrateEndpointTokens(defaults: defaults)

        defaults.set(true, forKey: migratedKey)
        defaults.synchronize()
    }

    /// Every key the old domain held, copied across. The old domain is then left
    /// alone rather than deleted: it costs nothing, and it is the only way back
    /// if the new bundle id turns out to be wrong.
    private static func migratePreferences(into defaults: UserDefaults) {
        guard let old = UserDefaults(suiteName: previousBundleID),
              let domain = old.persistentDomain(forName: previousBundleID),
              !domain.isEmpty else { return }
        for (key, value) in domain where defaults.object(forKey: key) == nil {
            defaults.set(value, forKey: key)
        }
    }

    /// The custom endpoints' tokens, from the old keychain service to the new.
    ///
    /// A service name is independent of the bundle id, so the old items are
    /// still readable and the move is a read and a write. The endpoint ids come
    /// from the preferences just migrated — which is why this runs last.
    ///
    /// Written as the literal key rather than through `Preferences.Keys`: those
    /// are private, and reaching into the store here would mean constructing it,
    /// which reads the domain this is still filling.
    private static func migrateEndpointTokens(defaults: UserDefaults) {
        guard let data = defaults.data(forKey: "customEndpoints"),
              let endpoints = try? JSONDecoder().decode([CustomEndpoint].self, from: data)
        else { return }
        for endpoint in endpoints {
            let account = CustomEndpoint.keychainAccount(for: endpoint.id)
            guard let token = KeychainItem.read(service: previousKeychainService,
                                                account: account) else { continue }
            _ = KeychainItem.store(service: CustomEndpoint.keychainService,
                                   account: account, value: token)
        }
    }

    /// `Application Support/Codenotch` becomes `Application Support/NamiNotch`.
    ///
    /// Moved only when the old directory is there and the new one is not, so a
    /// half-finished move is never merged into a directory already in use.
    private static func migrateSupportDirectory(fileManager: FileManager) {
        guard let support = fileManager.urls(for: .applicationSupportDirectory,
                                             in: .userDomainMask).first else { return }
        let old = support.appendingPathComponent(previousSupportDirectory, isDirectory: true)
        let new = support.appendingPathComponent(supportDirectory, isDirectory: true)
        guard fileManager.fileExists(atPath: old.path),
              !fileManager.fileExists(atPath: new.path) else { return }
        try? fileManager.moveItem(at: old, to: new)
    }
}
