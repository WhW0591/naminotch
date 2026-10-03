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

    // MARK: - Today

    private func fixedCalendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 39_600)!   // UTC+11, no DST
        return calendar
    }

    /// The card's row is the account's, not one API key's: several series share
    /// a day, and every kind of token counts toward it.
    func testDailyUsageSumsEverySeriesAndEveryTokenKindIntoItsDay() throws {
        let calendar = fixedCalendar()
        let day = calendar.startOfDay(for: Date(timeIntervalSince1970: 1_800_000_000))
        let next = calendar.date(byAdding: .day, value: 1, to: day)!
        let a = Int(day.timeIntervalSince1970), b = Int(next.timeIntervalSince1970)

        let json = """
        {"code":0,"data":{"biz_code":0,"biz_data":{"series":[\
        {"api_key":{"name":"main"},"model":"deepseek-chat","buckets":[\
        {"time":\(a),"usage":{"PROMPT_CACHE_HIT_TOKEN":100,"PROMPT_CACHE_MISS_TOKEN":50,"RESPONSE_TOKEN":25,"REQUEST":2}}]},\
        {"api_key":{"name":"other"},"model":"deepseek-reasoner","buckets":[\
        {"time":\(a),"usage":{"PROMPT_CACHE_HIT_TOKEN":"10","PROMPT_CACHE_MISS_TOKEN":5,"RESPONSE_TOKEN":5,"REQUEST":1}},\
        {"time":\(b),"usage":{"RESPONSE_TOKEN":7,"REQUEST":1}}]}\
        ]}}}
        """
        let usage = try DSHUsage.dailyUsage(amountJSON: json, now: day, calendar: calendar,
                                            dayStartHour: 0)
        XCTAssertEqual(usage.dailyUsageBuckets.map(\.tokens), [195, 7])

        // The day key this writes has to be the one `AccountTokenUsage` looks
        // its own up by, or the row reads "Pending" forever.
        XCTAssertEqual(usage.usageToday(now: day, calendar: calendar), 195)
        XCTAssertEqual(usage.usageInLast30Days(now: next, calendar: calendar), 202)
    }

    func testTheAmountQueryCoversThirtyDaysInTheLocalZone() {
        let calendar = fixedCalendar()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let query = DSHUsage.amountQuery(now: now, timeZone: calendar.timeZone,
                                         calendar: calendar, dayStartHour: 6)

        let fields = query.split(separator: "&").map { $0.split(separator: "=")[1] }
        // The window opens on the app's day, not on midnight: the platform cuts
        // its buckets wherever `start` says, so this is what decides whether the
        // card's day is six-to-six or the calendar's.
        let boundary = UsageDay.start(of: now, calendar: calendar, hour: 6)
        XCTAssertEqual(Int(fields[0]), Int(boundary.timeIntervalSince1970) - 29 * 86_400,
                       "start is 29 days back, from the day's own beginning")
        XCTAssertEqual(Int(fields[1]), Int(boundary.timeIntervalSince1970) + 86_400,
                       "end is tomorrow")
        XCTAssertEqual(Int(fields[2]), 39_600, "tz is seconds east of UTC")
    }

    /// **A series cut at six is looked up at six.**
    ///
    /// At four in the morning the day that is running began at six the previous
    /// morning. Looking it up from local midnight would ask for a bucket the
    /// platform never made, and the row would read "Pending" every night until
    /// breakfast — so the boundary travels with the buckets rather than being
    /// read fresh from the setting.
    func testASixCutSeriesIsLookedUpAtSix() throws {
        let calendar = fixedCalendar()
        let six = calendar.date(bySettingHour: 6, minute: 0, second: 0,
                                of: calendar.startOfDay(for: Date(timeIntervalSince1970: 1_800_000_000)))!
        let sixYesterday = calendar.date(byAdding: .day, value: -1, to: six)!
        let a = Int(sixYesterday.timeIntervalSince1970), b = Int(six.timeIntervalSince1970)

        let amount = """
        {"code":0,"data":{"biz_code":0,"biz_data":{"series":[\
        {"buckets":[{"time":\(a),"usage":{"RESPONSE_TOKEN":40}},\
        {"time":\(b),"usage":{"RESPONSE_TOKEN":7}}]}\
        ]}}}
        """
        let usage = try DSHUsage.dailyUsage(amountJSON: amount, calendar: calendar,
                                            dayStartHour: 6)

        // Inside the day that began at six yesterday.
        XCTAssertEqual(usage.usageToday(now: sixYesterday.addingTimeInterval(4 * 3_600),
                                        calendar: calendar), 40)
        // Inside the one that began at six today.
        XCTAssertEqual(usage.usageToday(now: six.addingTimeInterval(2 * 3_600),
                                        calendar: calendar), 7)
    }

    /// A series this app did not cut — Codex's — keeps being looked up on the
    /// calendar day, because nothing here knows where its server drew the line.
    func testASeriesWithNoStatedBoundaryIsLookedUpOnTheCalendarDay() throws {
        let calendar = fixedCalendar()
        let usage = AccountTokenUsage(
            dailyUsageBuckets: [.init(startDate: "2026-10-02", tokens: 12)])
        let onThatDay = calendar.date(from: DateComponents(year: 2026, month: 10, day: 2,
                                                           hour: 3))!
        XCTAssertEqual(usage.usageToday(now: onThatDay, calendar: calendar), 12)
    }

    /// A day the account never used is absent, not zero — which is what makes
    /// the card say "Pending" rather than invent a figure.
    func testADayWithNoBucketIsAbsent() throws {
        let calendar = fixedCalendar()
        let day = calendar.startOfDay(for: Date(timeIntervalSince1970: 1_800_000_000))
        let json = #"{"code":0,"data":{"biz_code":0,"biz_data":{"series":[]}}}"#
        let usage = try DSHUsage.dailyUsage(amountJSON: json, now: day, calendar: calendar,
                                            dayStartHour: 0)
        XCTAssertTrue(usage.dailyUsageBuckets.isEmpty)
        XCTAssertNil(usage.usageToday(now: day, calendar: calendar))
    }

    /// The money half. Summed across series the same way the tokens are — and a
    /// day the platform never priced keeps a nil cost, so the card can tell
    /// "nothing spent" from "nothing said".
    func testCostIsSummedAcrossSeriesAndUnpricedDaysStayNil() throws {
        let calendar = fixedCalendar()
        let day = calendar.startOfDay(for: Date(timeIntervalSince1970: 1_800_000_000))
        let next = calendar.date(byAdding: .day, value: 1, to: day)!
        let a = Int(day.timeIntervalSince1970), b = Int(next.timeIntervalSince1970)

        let amount = """
        {"code":0,"data":{"biz_code":0,"biz_data":{"series":[\
        {"buckets":[{"time":\(a),"usage":{"RESPONSE_TOKEN":10}}]},\
        {"buckets":[{"time":\(a),"usage":{"RESPONSE_TOKEN":5}},{"time":\(b),"usage":{"RESPONSE_TOKEN":7}}]}\
        ]}}}
        """
        let cost = """
        {"code":0,"data":{"biz_code":0,"biz_data":{"data":[\
        {"currency":"CNY","series":[\
        {"buckets":[{"time":\(a),"cost":"1.50"}]},\
        {"buckets":[{"time":\(a),"cost":"0.25"},{"time":\(b),"cost":"2"}]}\
        ]}]}}}
        """
        let usage = try DSHUsage.dailyUsage(amountJSON: amount, costJSON: cost,
                                            now: day, calendar: calendar, dayStartHour: 0)
        XCTAssertEqual(usage.currency, "CNY")
        XCTAssertEqual(usage.usageToday(now: day, calendar: calendar), 15)
        XCTAssertEqual(try XCTUnwrap(usage.costToday(now: day, calendar: calendar)),
                       1.75, accuracy: 0.001)
        XCTAssertEqual(usage.costToday(now: next, calendar: calendar), 2.0)

        // Without the money the tokens still land, and no cost is invented.
        let bare = try DSHUsage.dailyUsage(amountJSON: amount, now: day, calendar: calendar,
                                           dayStartHour: 0)
        XCTAssertEqual(bare.usageToday(now: day, calendar: calendar), 15)
        XCTAssertNil(bare.costToday(now: day, calendar: calendar))
        XCTAssertNil(bare.currency)
    }

    /// The symbol follows the currency the platform named; an amount with no
    /// currency to name it in is left unwritten rather than guessed at.
    func testMoneyIsWrittenInItsOwnCurrency() {
        XCTAssertEqual(UsageFormat.money(3.3091, currency: "CNY"), "¥3.31")
        XCTAssertEqual(UsageFormat.money(12.5, currency: "USD"), "$12.50")
        XCTAssertEqual(UsageFormat.money(1, currency: "SEK"), "SEK 1.00")
        XCTAssertNil(UsageFormat.money(nil, currency: "CNY"))
        XCTAssertNil(UsageFormat.money(1, currency: nil))
    }
}
