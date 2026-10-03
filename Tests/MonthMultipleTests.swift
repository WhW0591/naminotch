import XCTest
@testable import Codenotch

/// The rules around "this month's usage was N× what the plan costs".
///
/// The arithmetic is one division; what needs pinning is the three ways it must
/// decline to answer, because each of them is a number a reader would believe.
@MainActor
final class MonthMultipleTests: XCTestCase {
    private func account(_ id: String, billing: CostAccount.Billing,
                         price: Double = 0) -> CostAccount {
        CostAccount(id: id, provider: "claude", name: id,
                    configDirectory: URL(fileURLWithPath: "/nonexistent"),
                    billing: billing, monthlyPrice: price)
    }

    /// **The month is the calendar's, not the app's day.**
    ///
    /// `UsageDay` turns the app's day over at six in the morning so a night's
    /// work stays with the evening it began in. A bill does not: it arrives on
    /// the first. Measuring a plan against a month that began at six on the 31st
    /// would compare it to a month nobody is charged for.
    func testTheMonthIsTheCalendarMonth() throws {
        let calendar = Calendar.current
        let now = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2026, month: 3, day: 17, hour: 4)))

        let start = MonthMultiple.monthStart(now)
        let parts = calendar.dateComponents([.year, .month, .day, .hour], from: start)
        XCTAssertEqual(parts.year, 2026)
        XCTAssertEqual(parts.month, 3)
        XCTAssertEqual(parts.day, 1, "the month begins on the first, not at six a.m.")
        XCTAssertEqual(parts.hour, 0)

        // Four in the morning is the *previous* day by the app's reckoning, and
        // still March by the month's. The two boundaries are meant to differ.
        XCTAssertEqual(UsageDay.start(of: now, calendar: calendar), calendar.date(
            from: DateComponents(year: 2026, month: 3, day: 16, hour: 6)))
    }

    /// **An account billed per token has no multiple**, and that is the rule
    /// this feature exists to respect: an API key is not a period, so there is
    /// nothing for usage to be a multiple *of*.
    func testAnAccountBilledPerTokenHasNoMultiple() {
        XCTAssertNil(MonthMultiple.times(for: account("claude", billing: .api), monthly: 20))
        // Even with no usage figure to read, the answer is the same and no
        // deeper lookup is needed.
        XCTAssertNil(MonthMultiple.usageCost(for: account("claude", billing: .api)))
    }

    /// A plan that costs nothing has nothing to divide by.
    func testAPlanThatCostsNothingHasNoMultiple() {
        XCTAssertNil(MonthMultiple.times(for: account("claude", billing: .subscription), monthly: 0))
    }

    /// **An unreadable cost index is not zero usage.**
    ///
    /// "0× what you paid" reads as a subscription that was wasted, so the
    /// answer when the figure cannot be worked out has to be that there is no
    /// answer. `claude-nothing` names no account in the store, which is the
    /// cheapest honest way to reach that branch.
    func testAnUnknownUsageCostIsNotZero() {
        let unknown = account("claude-nothing", billing: .subscription, price: 20)
        XCTAssertNil(MonthMultiple.usageCost(for: unknown))
        XCTAssertNil(MonthMultiple.times(for: unknown, monthly: 20))
    }
}
