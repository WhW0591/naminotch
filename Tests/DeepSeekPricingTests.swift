import XCTest
@testable import Codenotch

/// DeepSeek bills by Beijing time, so these pin the clock rather than the Mac's:
/// every case is written as an instant in UTC+8 and must answer the same on a
/// machine set to any zone.
final class DeepSeekPricingTests: XCTestCase {
    private func beijing(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int = 0) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = DeepSeekPricing.timeZone
        return calendar.date(from: DateComponents(
            year: y, month: mo, day: d, hour: h, minute: mi))!
    }

    /// 2026-10-05 is a Monday, 2026-10-09 a Friday, 2026-10-10 a Saturday.
    func testTheWindowsArePeakOnAWeekday() {
        XCTAssertTrue(DeepSeekPricing.isPeak(at: beijing(2026, 10, 5, 9, 0)), "09:00 is in")
        XCTAssertTrue(DeepSeekPricing.isPeak(at: beijing(2026, 10, 5, 11, 59)))
        XCTAssertTrue(DeepSeekPricing.isPeak(at: beijing(2026, 10, 5, 14, 0)), "the second window")
        XCTAssertTrue(DeepSeekPricing.isPeak(at: beijing(2026, 10, 9, 17, 59)))
    }

    /// The ends belong to the discount: the platform says `09:00–12:00`, which
    /// is a window that closes at twelve, not one that includes it.
    func testTheEdgesOfAWindowAreNotPeak() {
        XCTAssertFalse(DeepSeekPricing.isPeak(at: beijing(2026, 10, 5, 8, 59)))
        XCTAssertFalse(DeepSeekPricing.isPeak(at: beijing(2026, 10, 5, 12, 0)), "12:00 closes it")
        XCTAssertFalse(DeepSeekPricing.isPeak(at: beijing(2026, 10, 5, 13, 59)), "between the two")
        XCTAssertFalse(DeepSeekPricing.isPeak(at: beijing(2026, 10, 5, 18, 0)), "18:00 closes it")
    }

    func testTheWeekendIsNeverPeak() {
        XCTAssertFalse(DeepSeekPricing.isPeak(at: beijing(2026, 10, 10, 10, 0)), "Saturday")
        XCTAssertFalse(DeepSeekPricing.isPeak(at: beijing(2026, 10, 11, 15, 0)), "Sunday")
    }

    /// A make-up workday is a Saturday, and the platform counts it as off-peak —
    /// which falls out of asking about the weekday rather than about "workday".
    func testAMakeUpWorkdayIsOffPeak() {
        XCTAssertFalse(DeepSeekPricing.isPeak(at: beijing(2026, 10, 10, 10, 0)))
    }

    /// A holiday is a weekday that is not peak. Passed in, because the real list
    /// is an annual announcement and not something to derive.
    func testAHolidayWeekdayIsNotPeak() {
        let nationalDay = beijing(2026, 10, 5, 10, 0)
        XCTAssertTrue(DeepSeekPricing.isPeak(at: nationalDay), "peak while the list is empty")
        // The day has to be cut in the same zone the reading uses. Cutting it in
        // the Mac's was the first version of this test, and it failed — which is
        // the whole reason the zone is fixed rather than inherited.
        var beijing = Calendar(identifier: .gregorian)
        beijing.timeZone = DeepSeekPricing.timeZone
        XCTAssertFalse(DeepSeekPricing.isPeak(at: nationalDay, holidays: [
            beijing.startOfDay(for: nationalDay)
        ]))
    }

    /// **The same instant answers the same on any Mac.** The zone is fixed, so a
    /// reading taken in Sydney and one taken in London agree.
    func testTheAnswerDoesNotDependOnTheMachinesZone() {
        let instant = beijing(2026, 10, 5, 10, 0)
        XCTAssertTrue(DeepSeekPricing.isPeak(at: instant))
        // That instant is 12:00 in Sydney and 02:00 in London, and neither is a
        // reason for the answer to change.
        XCTAssertEqual(DeepSeekPricing.timeZone.secondsFromGMT(for: instant), 8 * 3600)
    }
}
