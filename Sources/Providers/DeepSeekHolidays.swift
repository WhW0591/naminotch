import Foundation

/// The Chinese statutory holidays, so a weekday inside one is not billed as peak.
///
/// The rule it feeds is DeepSeek's, and current as of its 2026-08-23 adjustment:
/// peak is Monday-Friday 09:00-12:00 and 14:00-18:00 Beijing time, excluding
/// Chinese statutory holidays, and off-peak is half of that. Weekends are
/// off-peak all day, make-up workdays included — a make-up Saturday is still a
/// Saturday.
///
/// The list is an annual State Council announcement and cannot be derived, so it
/// is read from `holiday-cn`, which republishes that announcement as JSON. Two
/// things the source's own notes warn about are handled here: a year is named by
/// the *document* rather than by the dates in it, so December reads next year's
/// file as well; and weekends joined onto a holiday are not in the data at all,
/// which is fine — weekends are already off-peak.
///
/// The cached copy is what gets used. A fetch that fails leaves the last good
/// list in place rather than emptying it, because an empty list is not neutral:
/// it claims every holiday is a working day and prices them all at the peak
/// rate.
@MainActor
final class DeepSeekHolidays: ObservableObject {
    static let shared = DeepSeekHolidays()

    /// How old the cached list may get before it is fetched again.
    ///
    /// The list is an annual announcement, so a month is already far more often
    /// than it can change. The refresh is not chasing the source's daily
    /// re-publication; it is there so a Mac that never restarts still picks up
    /// next year's file.
    static let refreshInterval: TimeInterval = 30 * 86_400
    /// How soon a failed fetch may be tried again. Without this, an offline Mac
    /// would ask once a minute for a month.
    static let retryInterval: TimeInterval = 86_400

    /// Whether the platform is at its peak rate right now.
    ///
    /// Published rather than computed in the view, because it changes with the
    /// clock and nothing else would tell the view to look again: without the
    /// tick below, an icon drawn at 08:59 would still say off-peak at noon.
    @Published private(set) var isPeak = DeepSeekPricing.isPeak()

    /// Beijing start-of-day for each statutory holiday.
    @Published private(set) var days: Set<Date> = []

    private var timer: Timer?
    private let defaults: UserDefaults
    private var fetchedAt: Date?
    private var lastAttempt: Date?
    private var refreshing = false

    private static let cacheKey = "deepSeekHolidayDays"
    private static let fetchedAtKey = "deepSeekHolidayFetchedAt"
    private static let lastAttemptKey = "deepSeekHolidayLastAttempt"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        days = Self.load(from: defaults)
        fetchedAt = defaults.object(forKey: Self.fetchedAtKey) as? Date
        lastAttempt = defaults.object(forKey: Self.lastAttemptKey) as? Date
        recompute()
    }

    /// Loads the cache, fetches it when due, and keeps the peak answer in step
    /// with the clock. Safe to call more than once.
    func start() {
        refreshIfDue()
        guard timer == nil else { return }
        // A minute is finer than any boundary it has to notice — the windows
        // close on the hour — and coarse enough to cost nothing.
        let timer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.recompute()
                self?.refreshIfDue()
            }
        }
        timer.tolerance = 5
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func recompute() {
        isPeak = DeepSeekPricing.isPeak(holidays: days)
    }

    /// Whether the cached list is old enough to fetch again.
    ///
    /// Pure, so a test can name both clocks instead of waiting a month.
    nonisolated static func refreshIsDue(fetchedAt: Date?, lastAttempt: Date?, now: Date) -> Bool {
        if let fetchedAt, now.timeIntervalSince(fetchedAt) < refreshInterval { return false }
        if let lastAttempt, now.timeIntervalSince(lastAttempt) < retryInterval { return false }
        return true
    }

    private func refreshIfDue() {
        guard !refreshing,
              Self.refreshIsDue(fetchedAt: fetchedAt, lastAttempt: lastAttempt, now: Date()) else { return }
        refreshing = true
        refresh()
    }

    // MARK: - The list

    /// `https://cdn.jsdelivr.net/gh/NateScarlet/holiday-cn@master/{year}.json`
    nonisolated static func url(for year: Int) -> URL {
        URL(string: "https://cdn.jsdelivr.net/gh/NateScarlet/holiday-cn@master/\(year).json")!
    }

    private func refresh() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = DeepSeekPricing.timeZone
        let year = calendar.component(.year, from: Date())
        // December can already be governed by next year's document — the source
        // says so in as many words — so both are read in the last month.
        let years = calendar.component(.month, from: Date()) == 12 ? [year, year + 1] : [year]

        Task { [weak self] in
            var found: Set<Date> = []
            for year in years {
                guard let data = try? await URLSession.shared.data(
                    from: Self.url(for: year)).0 else { continue }
                found.formUnion(Self.holidays(inJSON: data))
            }
            guard let self else { return }
            let now = Date()
            self.lastAttempt = now
            self.defaults.set(now, forKey: Self.lastAttemptKey)
            if !found.isEmpty {
                self.days = found
                self.fetchedAt = now
                self.defaults.set(found.map { $0.timeIntervalSince1970 }, forKey: Self.cacheKey)
                self.defaults.set(now, forKey: Self.fetchedAtKey)
                self.recompute()
            }
            self.refreshing = false
        }
    }

    /// The off days in one of the source's files. `isOffDay` false is a make-up
    /// workday and is deliberately ignored — it is a weekend, and weekends are
    /// off-peak whatever the announcement says about them.
    /// Pure, and deliberately not on the main actor: it is a parser, and the
    /// fetch that feeds it has no business on the main thread either.
    nonisolated static func holidays(inJSON data: Data) -> Set<Date> {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = root["days"] as? [[String: Any]] else { return [] }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = DeepSeekPricing.timeZone
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate]
        var days: Set<Date> = []
        for row in rows where row["isOffDay"] as? Bool == true {
            guard let text = row["date"] as? String, let date = formatter.date(from: text) else { continue }
            days.insert(calendar.startOfDay(for: date))
        }
        return days
    }

    private static func load(from defaults: UserDefaults) -> Set<Date> {
        let stamps = defaults.array(forKey: cacheKey) as? [Double] ?? []
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = DeepSeekPricing.timeZone
        return Set(stamps.map { calendar.startOfDay(for: Date(timeIntervalSince1970: $0)) })
    }
}
