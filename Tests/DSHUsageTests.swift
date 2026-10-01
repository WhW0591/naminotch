import XCTest
@testable import Codenotch

/// Harness talks to Platform with a grant header and five client headers the
/// owning package owns. The envelope that comes back is the website's own, so
/// the numbers are `DeepSeekUsage`'s to read — these pin that they still are.
final class DSHUsageTests: XCTestCase {
    /// A balance response in the shape Platform returns it.
    private let summary = """
    {"code":0,"msg":"","data":{"biz_code":0,"biz_msg":"","biz_data":{
      "normal_wallets":[{"currency":"USD","balance":"12.34","token_estimation":"1000000"}],
      "bonus_wallets":[{"currency":"USD","balance":"1.00","token_estimation":"1000"}],
      "total_costs":[{"currency":"USD","amount":"7.66"}],
      "total_available_token_estimation":"2500000"}}}
    """

    func testBuildsTheGrantAndClientHeaders() {
        let headers = DSHUsage.clientHeaders(
            locale: Locale(identifier: "en_US"),
            timeZone: TimeZone(secondsFromGMT: 39600)!,
            version: "9.9.9"
        )
        XCTAssertEqual(headers["x-client-platform"], "desktop-mac")
        // Empty on purpose in the owning package, not an omission here.
        XCTAssertEqual(headers["x-client-bundle-id"], "")
        XCTAssertEqual(headers["x-client-version"], "9.9.9")
        XCTAssertEqual(headers["x-client-locale"], "en_US")
        // Whole seconds east of UTC, not a name.
        XCTAssertEqual(headers["x-client-timezone-offset"], "39600")
    }

    func testTheWireLocaleIsReducedToTheTwoPlatformServes() {
        XCTAssertEqual(DSHUsage.wireLocale(Locale(identifier: "zh-Hans-CN")), "zh_CN")
        XCTAssertEqual(DSHUsage.wireLocale(Locale(identifier: "zh-Hant-TW")), "zh_CN")
        XCTAssertEqual(DSHUsage.wireLocale(Locale(identifier: "en_GB")), "en_US")
        // A third language reports as English rather than as itself.
        XCTAssertEqual(DSHUsage.wireLocale(Locale(identifier: "ja_JP")), "en_US")
    }

    func testReadsTheAccountWindowFromTheBalanceEnvelope() throws {
        let windows = try DSHUsage.windows(fromJSON: summary)
        let spend = try XCTUnwrap(windows.first { $0.id == "spend" })
        XCTAssertEqual(spend.label, "Account usage (USD)")
        XCTAssertEqual(spend.money?.currency, "USD")
        XCTAssertEqual(spend.money?.spent, 7.66)
        XCTAssertEqual(spend.money?.remaining, 12.34)
        // spent / (spent + balance) — the balance is the wallet's own, not the
        // bonus wallet's, which is a separate pot.
        XCTAssertEqual(try XCTUnwrap(spend.usedFraction), 7.66 / 20.0, accuracy: 0.0001)
    }

    /// The wallet's own token estimate is not the account-level one this window
    /// reads, so its absence is a missing window rather than a zero.
    func testNoAccountLevelEstimateMeansNoSecondWindow() throws {
        let without = summary.replacingOccurrences(
            of: "\"total_available_token_estimation\":\"2500000\"",
            with: "\"total_available_token_estimation\":null")
        XCTAssertEqual(try DSHUsage.windows(fromJSON: without).count, 1)
        XCTAssertEqual(try DSHUsage.windows(fromJSON: summary).count, 2)
    }

    /// A rejected grant rides under HTTP 200 with `code: 40003`, which is the
    /// same event the owning package clears its stored grant for.
    func testARejectedGrantIsNamedInTheEnvelope() {
        XCTAssertTrue(DSHUsage.rejection(
            inJSON: #"{"code":40003,"msg":"Authorization Failed (invalid token)","data":null}"#))
        XCTAssertFalse(DSHUsage.rejection(inJSON: summary))
        XCTAssertFalse(DSHUsage.rejection(inJSON: "{}"))
        XCTAssertFalse(DSHUsage.rejection(inJSON: "not json at all"))
    }

    func testTheSummaryPathIsTheAccountsOwn() {
        XCTAssertEqual(DSHUsage.summaryPath, "/api/v0/users/get_user_summary")
    }
}
