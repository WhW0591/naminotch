import XCTest
import SwiftUI
@testable import Codenotch

@MainActor
final class DeepSeekUsageTests: XCTestCase {
    func testSwitchGateIgnoresTheExistingSession() {
        var gate = WebSessionAuthenticationGate(baselineFingerprint: "old")

        XCTAssertFalse(gate.observe(authenticated: true, fingerprint: "old"))
        XCTAssertFalse(gate.observe(authenticated: false, fingerprint: nil))
        XCTAssertFalse(gate.observe(authenticated: true, fingerprint: "old"))
        XCTAssertFalse(gate.observe(authenticated: true, fingerprint: "old"))
    }

    func testNormalSignInDoesNotCommitAnExistingSessionBeforeLogout() {
        var gate = WebSessionAuthenticationGate(
            baselineFingerprint: "old",
            requiresNewFingerprint: false
        )

        XCTAssertFalse(gate.observe(authenticated: true, fingerprint: "old"))
        XCTAssertFalse(gate.observe(authenticated: false, fingerprint: nil))
        XCTAssertTrue(gate.observe(authenticated: true, fingerprint: "old"))
    }

    func testManualCloseCanCommitACompletedNormalSignIn() {
        let gate = WebSessionAuthenticationGate(
            baselineFingerprint: "old",
            requiresNewFingerprint: false
        )

        XCTAssertTrue(gate.acceptsAuthenticatedStateOnManualClose(
            authenticated: true,
            fingerprint: "old"
        ))
        XCTAssertFalse(gate.acceptsAuthenticatedStateOnManualClose(
            authenticated: false,
            fingerprint: nil
        ))
    }

    func testManualCloseCannotCommitTheExistingAccountDuringASwitch() {
        let gate = WebSessionAuthenticationGate(baselineFingerprint: "old")

        XCTAssertFalse(gate.acceptsAuthenticatedStateOnManualClose(
            authenticated: true,
            fingerprint: "old"
        ))
        XCTAssertTrue(gate.acceptsAuthenticatedStateOnManualClose(
            authenticated: true,
            fingerprint: "new"
        ))
    }

    func testDeepSeekAuthenticationProbeUsesThePlatformHeader() {
        let probe = try! XCTUnwrap(Sites.deepSeek.authProbeScript)

        XCTAssertTrue(probe.contains("'x-client-platform': 'web'"))
    }

    func testSwitchGateCommitsOnlyAfterLogoutAndANewSession() {
        var gate = WebSessionAuthenticationGate(baselineFingerprint: "old")

        XCTAssertFalse(gate.observe(authenticated: false, fingerprint: nil))
        XCTAssertFalse(gate.observe(authenticated: false, fingerprint: nil))
        XCTAssertTrue(gate.observe(authenticated: true, fingerprint: "new"))
    }

    func testSignedInSessionAppearsAsAnAccountInSettings() {
        let key = "deepseek.signedIn"
        let previous = UserDefaults.standard.object(forKey: key)
        defer {
            if let previous {
                UserDefaults.standard.set(previous, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }

        UserDefaults.standard.set(true, forKey: key)
        let provider = WebSessionProvider(site: Sites.deepSeek)
        let account = provider.account()

        XCTAssertNotNil(account)
        XCTAssertEqual(account?.source, "DeepSeek")
        XCTAssertEqual(account?.manageURL?.absoluteString, "https://platform.deepseek.com/usage")
    }

    func testPlatformSummaryBuildsMoneyWindow() throws {
        let json = #"{"data":{"biz_data":{"normal_wallets":[{"currency":"CNY","balance":"10.87"}],"total_costs":[{"currency":"CNY","amount":"9.20"}],"total_available_token_estimation":"3300000"}}}"#
        let reading = try DeepSeekUsage.reading(fromJSON: json)
        XCTAssertEqual(reading.currency, "CNY")
        XCTAssertEqual(reading.spent, 9.20, accuracy: 0.001)
        XCTAssertEqual(reading.balance, 10.87, accuracy: 0.001)
        XCTAssertEqual(reading.usedFraction, 9.20 / 20.07, accuracy: 0.001)
        XCTAssertEqual(reading.availableTokens, 3_300_000)
    }
}
