import XCTest
@testable import Codenotch

/// The cost layer's seams into the app: the hover card reserves room for
/// the project rows, a credit-based Codex seat gets a Credits window, and the
/// money math anchors on the allowance rather than on token prices.
final class CostTests: XCTestCase {
    /// A Business seat reports no rolling windows; the spend control is its ring.
    func testCreditSeatGetsACreditsWindow() throws {
        let json = """
        {"plan_type":"business","rate_limit":null,"additional_rate_limits":null,"code_review_rate_limit":null,
         "spend_control":{"reached":false,"individual_limit":{"unit":"credit","limit":"2500","used":"310.13",
         "used_percent":12,"reset_at":1789430400}}}
        """
        let windows = try CodexUsage.windows(from: Data(json.utf8), now: Date(timeIntervalSince1970: 1_789_000_000))
        let credits = try XCTUnwrap(windows.first { $0.id == "credits" })
        XCTAssertEqual(credits.usedFraction ?? 0, 0.12, accuracy: 0.0001)
        XCTAssertEqual(credits.used, 310)
        XCTAssertEqual(credits.remaining, 2190)
        XCTAssertEqual(credits.resetsAt, Date(timeIntervalSince1970: 1_789_430_400))
    }

    /// Cost rows on the card add exactly what the section draws.
    func testCardHeightGrowsWithCostRows() {
        let base = NotchLayout.cardHeight(windowCount: 2)
        let withRows = NotchLayout.cardHeight(windowCount: 2, costRows: 3)
        let expected = NotchLayout.blockSpacing + NotchLayout.cardBodyLineHeight
            + 3 * (NotchLayout.cardBodyLineHeight + NotchLayout.sessionRowGap)
        XCTAssertEqual(withRows - base, expected, accuracy: 0.01)
        XCTAssertEqual(NotchLayout.cardHeight(windowCount: 2, costRows: 0), base)
    }

    /// Money for subscription work is the weekly share of the plan; a credit
    /// seat prices credits; an API account prices tokens.
    func testCostEstimatorModes() {
        let pricer = Pricer(prices: [ModelPrice(model: "claude-opus-5", input: 5, output: 25, cacheRead: 0.5, cacheWrite: 6.25)], rate: 5)
        let period = (start: 0, end: 7 * 86_400, usedPct: 40.0, weight: 100.0)
        let plan = CostEstimator(billing: .subscription, monthlyPrice: 435, periods: [period], pricer: pricer)
        // Week = 435 ÷ 4.35 = 100; 40 % used = 40; this session was half the week's weight → 20.
        XCTAssertEqual(plan.cost(at: 10, weight: 50, model: "claude-opus-5", input: 0, output: 0, cacheRead: 0, cacheWrite: 0) ?? 0, 20, accuracy: 0.01)
        let credits = CostEstimator(billing: .subscription, monthlyPrice: 0, creditPointValue: 25, periods: [period], pricer: pricer)
        // 40 % of the cycle's credits × 25 per point = 1000; half the weight → 500.
        XCTAssertEqual(credits.cost(at: 10, weight: 50, model: "x", input: 0, output: 0, cacheRead: 0, cacheWrite: 0) ?? 0, 500, accuracy: 0.01)
        let api = CostEstimator(billing: .api, monthlyPrice: 0, periods: [], pricer: pricer)
        // 1M input at $5 + 1M output at $25 = $30 × rate 5 = 150.
        XCTAssertEqual(api.cost(at: 10, weight: 1, model: "claude-opus-5", input: 1_000_000, output: 1_000_000, cacheRead: 0, cacheWrite: 0) ?? 0, 150, accuracy: 0.01)
    }

    /// The card's range follows the account's allowance, never "all time".
    ///
    /// The database goes to a temporary directory that the test removes: this
    /// used to write `agentcost-test-x.sqlite` into the developer's real
    /// Application Support folder, where it outlived the run.
    @MainActor func testCostRangeNeverStartsOnAllTime() {
        UserDefaults.standard.set("allTime", forKey: "costRange")
        defer { UserDefaults.standard.removeObject(forKey: "costRange") }
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cost-model-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let account = CostAccount(id: "test-x", provider: "claude", name: "Test", configDirectory: URL(fileURLWithPath: "/nonexistent"))
        let model = CostModel(account: account, directory: directory)
        XCTAssertNotEqual(model.range, .allTime)
    }

    /// A reading that has not moved is not a new row: the endpoint is polled
    /// far faster than its whole percents change, and the table grew by one row
    /// per poll before this.
    func testUnchangedSamplesAreNotRecorded() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cost-samples-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try XCTUnwrap(CostStore(url: directory.appendingPathComponent("store.sqlite")))
        store.recordSample(window: .session, pct: 10, at: Date(timeIntervalSince1970: 1_000_000))
        store.recordSample(window: .session, pct: 10, at: Date(timeIntervalSince1970: 1_000_060))
        XCTAssertEqual(store.sampleCount(window: .session), 1)
        store.recordSample(window: .session, pct: 11, at: Date(timeIntervalSince1970: 1_000_120))
        XCTAssertEqual(store.sampleCount(window: .session), 2)
    }

    /// Anything older than the retention window is dropped; what is inside it
    /// stays, so the Activity timeline keeps the resets it can still draw.
    func testPruneDropsSamplesOutsideTheRetentionWindow() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cost-prune-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try XCTUnwrap(CostStore(url: directory.appendingPathComponent("store.sqlite")))
        let now = Date()
        store.recordSample(window: .session, pct: 5, at: now.addingTimeInterval(-20 * 86_400))
        store.recordSample(window: .session, pct: 6, at: now)
        XCTAssertEqual(store.sampleCount(window: .session), 2)
        store.prune(olderThanDays: 14)
        XCTAssertEqual(store.sampleCount(window: .session), 1)
    }
}
