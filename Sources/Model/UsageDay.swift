import Foundation

/// The day this app counts in.
///
/// **Not midnight.** Work that runs past it belongs to the day it was started
/// in: a reading taken at two in the morning is about the evening that produced
/// it, and a total that turns over while somebody is still working answers a
/// question nobody asked. Six is late enough to cover a night's work and early
/// enough that a morning reading is the new day's.
///
/// One definition, deliberately, and one place to change it. The local ledger
/// and the cost log are read side by side and are asked the same question —
/// *what has today cost me* — so a boundary that differed between them would
/// put two different numbers under one word.
///
/// Not every `startOfDay` in the app belongs here. "How many days until this
/// resets", "how long ago was that session" and the provider endpoints that
/// publish their own daily buckets are all about *calendar* days, which this is
/// not; they keep `Calendar.startOfDay`.
enum UsageDay {
    /// Six, which is late enough to cover a night's work and early enough that
    /// a morning reading is the new day's. What a fresh install gets, and what
    /// every install had before the hour became a setting.
    static let defaultStartHour = 6

    /// The hour in force. One app-wide value rather than an argument threaded
    /// through every caller: it is a property *of the app*, like its locale —
    /// not of the ledger, or the cost log, or the platform client — and the
    /// three of them must never disagree. `Preferences` owns it and is the only
    /// thing that writes it, through `configure(startHour:)`.
    private(set) static var startHour = defaultStartHour

    /// Sets the boundary. Called from `Preferences` on load and on every change.
    static func configure(startHour hour: Int) {
        startHour = min(23, max(0, hour))
    }

    /// The instant the day containing `date` began, on the hour in force.
    static func start(of date: Date, calendar: Calendar = .current) -> Date {
        start(of: date, calendar: calendar, hour: startHour)
    }

    /// The same, at a stated hour — for a series whose boundary the *provider*
    /// fixed, where the lookup has to agree with the cut that was actually made
    /// rather than with the app's current setting.
    static func start(of date: Date, calendar: Calendar, hour: Int) -> Date {
        let midnight = calendar.startOfDay(for: date)
        guard hour != 0 else { return midnight }
        let today = calendar.date(bySettingHour: hour, minute: 0, second: 0, of: midnight)
            ?? midnight
        if date >= today { return today }
        guard let yesterday = calendar.date(byAdding: .day, value: -1, to: midnight) else {
            return midnight
        }
        return calendar.date(bySettingHour: hour, minute: 0, second: 0, of: yesterday)
            ?? yesterday
    }

    /// The day after the one containing `date`, which is where its range ends.
    ///
    /// Through the calendar rather than by adding 86,400 seconds: a day is not
    /// always that long.
    static func end(of date: Date, calendar: Calendar = .current) -> Date {
        let from = start(of: date, calendar: calendar)
        return calendar.date(byAdding: .day, value: 1, to: from) ?? from.addingTimeInterval(86_400)
    }
}
