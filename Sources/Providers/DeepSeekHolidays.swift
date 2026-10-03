import Foundation

/// The Chinese statutory holidays, so a weekday inside one is not billed as peak.
///
/// The list is an annual announcement by the State Council and cannot be
/// derived, so it is read from `holiday-cn`, which republishes that announcement
/// as JSON and updates it daily by CI. Two things the source's own notes warn
/// about are handled here: a year is named by the *document* rather than by the
/// dates in it, so December reads next year's file as well; and weekends joined
/// onto a holiday are not in the data at all, which is fine — weekends are
/// already off-peak, and a make-up workday is a weekend day, so it stays
/// off-peak exactly as the platform says it should.
///
/// The cached copy is what gets used. A fetch that fails leaves the last good
/// list in place rather than emptying it, because an empty list is not neutral:
/// it claims every holiday is a working day and prices them all at the peak
/// rate.
@MainActor
final class DeepSeekHolidays: ObservableObject {
    static let shared = DeepSeekHolidays()

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
    private static let cacheKey = "deepSeekHolidayDays"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        days = Self.load(from: defaults)
        recompute()
    }

    /// Loads the cache and refreshes it. Safe to call more than once.
    func start() {
        refresh()
        guard timer == nil else { return }
        // A minute is finer than any boundary it has to notice — the windows
        // close on the hour — and coarse enough to cost nothing.
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.recompute() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func recompute() {
        isPeak = DeepSeekPricing.isPeak(holidays: days)
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
            guard let self, !found.isEmpty else { return }
            self.days = found
            self.defaults.set(found.map(\.timeIntervalSince1970), forKey: Self.cacheKey)
            self.recompute()
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
