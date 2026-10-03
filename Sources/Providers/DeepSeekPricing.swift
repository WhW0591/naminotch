import Foundation

/// When DeepSeek's API is at its peak rate, and when it is half price.
///
/// The windows are the platform's, not this Mac's: **Beijing time, always**.
/// As adjusted on 2026-08-23, peak is 09:00-12:00 and 14:00-18:00 on Monday to
/// Friday, excluding Chinese statutory holidays; everything else is the
/// discount, including all of Saturday and Sunday and any make-up workday that
/// falls on one. Off-peak is half the peak price.
///
/// Reading the windows off the local clock would put a reader in Sydney two
/// hours out and a reader in London eight, so the arithmetic happens in a fixed
/// zone and the answer is the same wherever the Mac is.
///
/// The ranges are half-open: 12:00 sharp is already off-peak, as is 18:00, and
/// 09:00 sharp is already peak.
enum DeepSeekPricing {
    /// Beijing, whatever the Mac is set to.
    static let timeZone = TimeZone(secondsFromGMT: 8 * 3600)!

    /// The two windows, as minutes from midnight in Beijing.
    static let windows = [(start: 9 * 60, end: 12 * 60), (start: 14 * 60, end: 18 * 60)]

    /// The days the platform treats as off-peak whatever the weekday says.
    ///
    /// Empty here on purpose: the statutory list is an annual State Council
    /// announcement, so it is loaded at runtime by `DeepSeekHolidays` and passed
    /// into `isPeak`. This property is only the fallback for a caller that has
    /// none, and an empty list is deliberately the *peak* answer rather than the
    /// discount — it is the honest side of an unknown.
    static var holidays: Set<Date> { [] }

    /// Whether the platform is charging its peak rate at `date`.
    ///
    /// Asks about an instant, not about "now", so a test can name one.
    static func isPeak(at date: Date = Date(), holidays: Set<Date>? = nil) -> Bool {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.weekday, .hour, .minute], from: date)
        guard let weekday = parts.weekday, let hour = parts.hour else { return false }
        // `weekday` is 1 for Sunday, so Monday to Friday is 2 through 6. A
        // Saturday or Sunday is off-peak all day, make-up workday or not.
        guard (2...6).contains(weekday) else { return false }

        let startOfDay = calendar.startOfDay(for: date)
        guard !(holidays ?? Self.holidays).contains(startOfDay) else { return false }

        let minutes = hour * 60 + (parts.minute ?? 0)
        return windows.contains { minutes >= $0.start && minutes < $0.end }
    }
}
