import XCTest
@testable import Codenotch

/// The one place this app's day is defined.
///
/// Everything that files work by a day reads it — the local ledger, the cost
/// log, the cost streak — so a mistake here moves all of them at once, and
/// moves them together, which is the point of it being one definition.
final class UsageDayTests: XCTestCase {
    /// The hour is app-wide state, so a test that moves it puts it back — or the
    /// next class to file a day inherits the boundary this one was checking.
    override func tearDown() {
        UsageDay.configure(startHour: UsageDay.defaultStartHour)
        super.tearDown()
    }

    /// The boundary follows the setting, which is the whole point of it being
    /// one value rather than an argument each caller passes its own version of.
    func testTheBoundaryFollowsTheConfiguredHour() {
        let warsaw = calendar("Europe/Warsaw")
        UsageDay.configure(startHour: 4)
        XCTAssertEqual(UsageDay.start(of: at(warsaw, 2026, 9, 10, 5), calendar: warsaw),
                       at(warsaw, 2026, 9, 10, 4))
        XCTAssertEqual(UsageDay.start(of: at(warsaw, 2026, 9, 10, 3), calendar: warsaw),
                       at(warsaw, 2026, 9, 9, 4))

        UsageDay.configure(startHour: 0)
        XCTAssertEqual(UsageDay.start(of: at(warsaw, 2026, 9, 10, 5), calendar: warsaw),
                       at(warsaw, 2026, 9, 10, 0))

        // Out of range is clamped rather than taken.
        UsageDay.configure(startHour: 99)
        XCTAssertEqual(UsageDay.startHour, 23)
        UsageDay.configure(startHour: -4)
        XCTAssertEqual(UsageDay.startHour, 0)
    }

    private func calendar(_ identifier: String) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: identifier)!
        return calendar
    }

    private func at(_ calendar: Calendar, _ year: Int, _ month: Int, _ day: Int,
                    _ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day,
                                           hour: hour, minute: minute))!
    }

    /// Six on the reader's clock, not midnight — and before six it is still the
    /// day that is ending, which is the whole reason for the shift.
    func testTheDayStartsAtSixOnTheReadersClock() {
        let warsaw = calendar("Europe/Warsaw")
        for hour in [6, 9, 18, 23] {
            XCTAssertEqual(UsageDay.start(of: at(warsaw, 2026, 9, 10, hour), calendar: warsaw),
                           at(warsaw, 2026, 9, 10, 6), "at \(hour):00")
        }
        for (hour, minute) in [(0, 1), (2, 30), (5, 59)] {
            XCTAssertEqual(UsageDay.start(of: at(warsaw, 2026, 9, 10, hour, minute),
                                          calendar: warsaw),
                           at(warsaw, 2026, 9, 9, 6), "at \(hour):\(minute)")
        }
    }

    /// The boundary belongs to the zone it is read in, not to the machine's.
    func testTheBoundaryFollowsTheCalendarItIsGiven() {
        let tokyo = calendar("Asia/Tokyo")
        let newYork = calendar("America/New_York")
        let instant = Date(timeIntervalSince1970: 1_800_000_000)

        XCTAssertNotEqual(UsageDay.start(of: instant, calendar: tokyo),
                          UsageDay.start(of: instant, calendar: newYork))
        for zone in [tokyo, newYork] {
            XCTAssertEqual(zone.component(.hour, from: UsageDay.start(of: instant, calendar: zone)), 6)
        }
    }

    /// **Six on the clock, not six hours after midnight.**
    ///
    /// Warsaw moves its clocks at 02:00 on 29 March 2026, so midnight plus six
    /// hours is 07:00 that morning. The reader means six, and the day that
    /// starts then is twenty-three hours long.
    func testAClockChangeDoesNotMoveTheBoundary() {
        let warsaw = calendar("Europe/Warsaw")
        let beforeTheChange = at(warsaw, 2026, 3, 29, 4)

        XCTAssertEqual(UsageDay.start(of: beforeTheChange, calendar: warsaw),
                       at(warsaw, 2026, 3, 28, 6))
        XCTAssertEqual(UsageDay.start(of: at(warsaw, 2026, 3, 29, 8), calendar: warsaw),
                       at(warsaw, 2026, 3, 29, 6))

        let start = UsageDay.start(of: beforeTheChange, calendar: warsaw)
        XCTAssertEqual(UsageDay.end(of: beforeTheChange, calendar: warsaw)
                        .timeIntervalSince(start), 23 * 3_600)
    }

    /// The end is the next day, not 86,400 seconds later.
    func testTheEndIsTheNextDayRatherThanAFixedDayLong() {
        let warsaw = calendar("Europe/Warsaw")
        let afternoon = at(warsaw, 2026, 9, 10, 15)
        XCTAssertEqual(UsageDay.end(of: afternoon, calendar: warsaw),
                       UsageDay.start(of: at(warsaw, 2026, 9, 11, 9), calendar: warsaw))
        XCTAssertEqual(UsageDay.end(of: afternoon, calendar: warsaw)
                        .timeIntervalSince(UsageDay.start(of: afternoon, calendar: warsaw)),
                       24 * 3_600)
    }
}
