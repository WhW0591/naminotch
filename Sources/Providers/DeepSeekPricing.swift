import Foundation

/// When DeepSeek's API is at its peak rate, and when it is half price.
///
/// The windows are the platform's, not this Mac's: **Beijing time, always** —
/// the published rule is `09:00–12:00` and `14:00–18:00` on Monday to Friday,
/// excluding Chinese statutory holidays, and everything else is the discount.
/// Reading them off the local clock would put a reader in Sydney two hours out
/// and a reader in London eight, so the arithmetic happens in a fixed zone and
/// the answer is the same wherever the Mac is.
///
/// The discount is half: an ordinary rate of ¥2 per million tokens is ¥1 in the
/// window, ¥4 is ¥2, and so on. So one boolean is enough to price anything —
/// there is no third state to carry.
enum DeepSeekPricing {
    /// Beijing, whatever the Mac is set to.
    static let timeZone = TimeZone(secondsFromGMT: 8 * 3600)!

    /// The two windows, as minutes from midnight in Beijing.
    static let windows = [(start: 9 * 60, end: 12 * 60), (start: 14 * 60, end: 18 * 60)]

    /// **Not yet read from anywhere.**
    ///
    /// A statutory holiday is not derivable — it is an annual government
    /// announcement — so until codenotch fetches one, a weekday inside a holiday
    /// reads as peak and shows the higher rate. That direction was chosen on
    /// purpose: it is the honest side of an unknown, since the alternative
    /// claims a discount that may not be there.
    ///
    /// The days that matter most this year are already known and left out of the
    /// list on purpose — hard-coding them would be a second source of truth that
    /// goes stale in silence. See `holiday-cn`, which republishes the State
    /// Council's announcement as JSON.
    static var holidays: Set<Date> { [] }

    /// Whether the platform is charging its peak rate at `date`.
    ///
    /// Asks about an instant, not about "now", so a test can name one.
    static func isPeak(at date: Date = Date(), holidays: Set<Date>? = nil) -> Bool {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.weekday, .hour, .minute], from: date)
        guard let weekday = parts.weekday, let hour = parts.hour else { return false }
        // `weekday` is 1 for Sunday, so Monday to Friday is 2 through 6.
        guard (2...6).contains(weekday) else { return false }

        let startOfDay = calendar.startOfDay(for: date)
        guard !(holidays ?? Self.holidays).contains(startOfDay) else { return false }

        let minutes = hour * 60 + (parts.minute ?? 0)
        return windows.contains { minutes >= $0.start && minutes < $0.end }
    }
}
