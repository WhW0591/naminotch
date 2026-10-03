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

    /// A dormant wallet above the funded one must not become the account.
    ///
    /// Taken as `normal_wallets.first`, this exact shape — an empty USD wallet
    /// listed above a funded CNY one, which is what a real account returned —
    /// produced `spent 0, balance 0`; `usedFraction` is guarded on `funded > 0`,
    /// so the ring drew an empty circle for an account with money in it.
    func testTheFundedWalletIsTheOneRead() throws {
        let json = #"{"data":{"biz_data":{"normal_wallets":[{"currency":"USD","balance":"0.00"},{"currency":"CNY","balance":"10.87"}],"total_costs":[{"currency":"USD","amount":"0.00"},{"currency":"CNY","amount":"9.20"}]}}}"#
        let reading = try DeepSeekUsage.reading(fromJSON: json)
        XCTAssertEqual(reading.currency, "CNY", "the empty USD wallet was read instead")
        XCTAssertEqual(reading.spent, 9.20, accuracy: 0.001)
        XCTAssertEqual(reading.balance, 10.87, accuracy: 0.001)
        XCTAssertEqual(reading.usedFraction, 9.20 / 20.07, accuracy: 0.001)
    }

    /// Every wallet empty is a true zero, not a failure — and the first is
    /// still the one named, because a currency has to be reported either way.
    func testAnAccountWithNothingInAnyWalletStillReads() throws {
        let json = #"{"data":{"biz_data":{"normal_wallets":[{"currency":"USD","balance":"0.00"},{"currency":"CNY","balance":"0"}],"total_costs":[]}}}"#
        let reading = try DeepSeekUsage.reading(fromJSON: json)
        XCTAssertEqual(reading.currency, "USD")
        XCTAssertEqual(reading.balance, 0, accuracy: 0.001)
        XCTAssertEqual(reading.usedFraction, 0, accuracy: 0.001)
    }
}
