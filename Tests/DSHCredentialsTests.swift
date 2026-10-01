import XCTest
@testable import Codenotch

/// The grant is borrowed from DeepSeek Harness's own credential store, and the
/// store holds more than one record — so only the account record may ever be
/// claimed, and only from a file that actually parses.
final class DSHCredentialsTests: XCTestCase {
    private func file(_ text: String) throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("dsh-credentials-\(UUID().uuidString).yaml")
        try text.data(using: .utf8)!.write(to: url)
        return url
    }

    /// The real shape, as Harness writes it: a browser session, a device
    /// identity and the account grant sharing one store.
    private let store = """
    version: 1
    records:
      client-connection/browser-session:
        kind: grant
        payload:
          version: 1
          secret: not-ours-to-send
      deepseek-account-platform/device:
        kind: grant
        payload:
          id: 6F1B0B0B-0000-0000-0000-000000000000
      deepseek-account-platform/default:
        kind: grant
        payload:
          version: 1
          token: tok-abc
          issuer: https://platform.deepseek.com
    """

    func testReadsTheAccountGrant() throws {
        let credentials = try DSHCredentials.load(from: try file(store))
        XCTAssertEqual(credentials.token, "tok-abc")
        XCTAssertEqual(credentials.issuer.absoluteString, "https://platform.deepseek.com")
    }

    func testOnlyTheAccountRecordIsClaimed() throws {
        // The browser session's secret sits in the same store, a few lines up.
        // Reading whichever record came first would send it to Platform.
        let credentials = try DSHCredentials.load(from: try file(store))
        XCTAssertNotEqual(credentials.token, "not-ours-to-send")
    }

    func testTheIssuerDecidesTheOrigin() throws {
        // A grant is only good on the origin that issued it, so a private
        // deployment has to be followed rather than overridden.
        let private_ = store.replacingOccurrences(of: "https://platform.deepseek.com",
                                                  with: "https://platform.example.test")
        let credentials = try DSHCredentials.load(from: try file(private_))
        XCTAssertEqual(credentials.issuer.host, "platform.example.test")
    }

    func testAPlaintextIssuerIsRefused() throws {
        // A grant is never sent to a plaintext origin on a file's say-so. The
        // owning package allows loopback HTTP only behind a development opt-in.
        let insecure = store.replacingOccurrences(of: "https://platform.deepseek.com",
                                                  with: "http://platform.deepseek.com")
        XCTAssertThrowsError(try DSHCredentials.load(from: try file(insecure)))
    }

    func testAnEmptiedOrMissingRecordIsNotACredential() throws {
        let emptied = try file(store.replacingOccurrences(of: "token: tok-abc", with: "token: ''"))
        XCTAssertThrowsError(try DSHCredentials.load(from: emptied))

        let noIssuer = try file(store.replacingOccurrences(
            of: "issuer: https://platform.deepseek.com", with: "issuer: ''"))
        XCTAssertThrowsError(try DSHCredentials.load(from: noIssuer))

        // A store that has never signed in carries the device record alone.
        let deviceOnly = try file("""
        version: 1
        records:
          deepseek-account-platform/device:
            kind: grant
            payload:
              id: 6F1B0B0B-0000-0000-0000-000000000000
        """)
        XCTAssertThrowsError(try DSHCredentials.load(from: deviceOnly))
    }

    func testQuotedScalarsAreUnwrapped() throws {
        let quoted = store
            .replacingOccurrences(of: "token: tok-abc", with: "token: \"tok-abc\"")
            .replacingOccurrences(of: "issuer: https://platform.deepseek.com",
                                  with: "issuer: 'https://platform.deepseek.com'")
        let credentials = try DSHCredentials.load(from: try file(quoted))
        XCTAssertEqual(credentials.token, "tok-abc")
        XCTAssertEqual(credentials.issuer.host, "platform.deepseek.com")
    }

    /// A record is bounded by its own indent: the next record at the same level
    /// ends it, so a `token:` belonging to somebody else is never picked up.
    func testASiblingRecordEndsTheOneBeingRead() throws {
        let trailing = """
        version: 1
        records:
          deepseek-account-platform/default:
            kind: grant
            payload:
              version: 1
              token: ours
              issuer: https://platform.deepseek.com
          deepseek-account-platform/elsewhere:
            kind: grant
            payload:
              token: theirs
              issuer: https://platform.example.test
        """
        let credentials = try DSHCredentials.load(from: try file(trailing))
        XCTAssertEqual(credentials.token, "ours")
    }

    func testTheDefaultPathIsTheHarnessHome() {
        // `DSH_HOME` moves the root; with it unset the answer is the dotfolder.
        guard ProcessInfo.processInfo.environment["DSH_HOME"] == nil else { return }
        XCTAssertEqual(DSHCredentials.credentialsURL.path,
                       NSHomeDirectory() + "/.dsh/.credentials.yaml")
    }
}
