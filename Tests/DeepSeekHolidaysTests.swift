import XCTest
@testable import Codenotch

/// Reading `holiday-cn`'s files. The shapes here are the source's own: `isOffDay`
/// true is a day off and false is a make-up workday, and the announcement's year
/// is not always the year of the dates in it.
final class DeepSeekHolidaysTests: XCTestCase {
    private func beijing(_ y: Int, _ mo: Int, _ d: Int) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = DeepSeekPricing.timeZone
        return calendar.startOfDay(for: calendar.date(from: DateComponents(
            year: y, month: mo, day: d, hour: 12))!)
    }

    private let fixture = Data("""
    { "year": 2026,
      "papers": ["https://www.gov.cn/..."],
      "days": [
        { "name": "国庆节", "date": "2026-10-01", "isOffDay": true  },
        { "name": "国庆节", "date": "2026-10-10", "isOffDay": false },
        { "name": "中秋节", "date": "2026-09-25", "isOffDay": true  }
      ] }
    """.utf8)

    func testOnlyTheDaysOffAreKept() {
        let days = DeepSeekHolidays.holidays(inJSON: fixture)
        XCTAssertEqual(days, [beijing(2026, 10, 1), beijing(2026, 9, 25)])
        XCTAssertFalse(days.contains(beijing(2026, 10, 10)),
                       "a make-up workday is a Saturday, and weekends are off-peak already")
    }

    /// The days are cut in Beijing, as the reading that consumes them is.
    func testTheDaysAreCutInBeijing() {
        for day in DeepSeekHolidays.holidays(inJSON: fixture) {
            var beijing = Calendar(identifier: .gregorian)
            beijing.timeZone = DeepSeekPricing.timeZone
            XCTAssertEqual(beijing.startOfDay(for: day), day)
        }
    }

    func testNonsenseIsNotADayOff() {
        XCTAssertTrue(DeepSeekHolidays.holidays(inJSON: Data("not json".utf8)).isEmpty)
        // The fixture has to actually be missing the field — the first version
        // of this carried `"isOffDay": true` while claiming to test its absence,
        // so the parser was right and the test was wrong.
        XCTAssertTrue(DeepSeekHolidays.holidays(
            inJSON: Data(#"{"days":[{"date":"2026-10-01"}]}"#.utf8)).isEmpty,
            "isOffDay absent is not isOffDay true")
    }

    func testTheAddressIsTheSourcesOwn() {
        XCTAssertEqual(DeepSeekHolidays.url(for: 2026).absoluteString,
                       "https://cdn.jsdelivr.net/gh/NateScarlet/holiday-cn@master/2026.json")
    }

    /// The list is an annual announcement, so it is fetched once a month — and a
    /// failure backs off a day rather than asking once a minute.
    func testTheListIsFetchedMonthlyAndRetriedDaily() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertTrue(DeepSeekHolidays.refreshIsDue(fetchedAt: nil, lastAttempt: nil, now: now))
        XCTAssertFalse(DeepSeekHolidays.refreshIsDue(
            fetchedAt: now.addingTimeInterval(-10 * 86_400), lastAttempt: nil, now: now))
        XCTAssertTrue(DeepSeekHolidays.refreshIsDue(
            fetchedAt: now.addingTimeInterval(-31 * 86_400), lastAttempt: nil, now: now))
        XCTAssertFalse(DeepSeekHolidays.refreshIsDue(
            fetchedAt: nil, lastAttempt: now.addingTimeInterval(-3600), now: now))
        XCTAssertTrue(DeepSeekHolidays.refreshIsDue(
            fetchedAt: nil, lastAttempt: now.addingTimeInterval(-2 * 86_400), now: now))
    }
}
