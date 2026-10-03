import Foundation
import SQLite3

extension CostStore {
    /// The per-day token chart and summary for a Claude login, from the
    /// indexed turns: the same shape the Codex server publishes, so the card
    /// draws both alike. Nil until anything has been indexed.
    func tokenUsage(now: Date = Date(), calendar: Calendar = .current) -> AccountTokenUsage? {
        var days: [(key: String, tokens: Int)] = []
        var lifetime = 0
        queue.sync {
            let sql = "SELECT date(ts, 'unixepoch', 'localtime') AS d, SUM(input + output + cache_read + cache_write)"
                    + " FROM usage_event GROUP BY d ORDER BY d"
            guard let st = prepare(sql) else { return }
            defer { sqlite3_finalize(st) }
            while sqlite3_step(st) == SQLITE_ROW {
                let key = text(st, 0) ?? ""
                let tokens = Int(sqlite3_column_int64(st, 1))
                days.append((key, tokens))
                lifetime += tokens
            }
        }
        guard !days.isEmpty else { return nil }

        // Streaks over calendar days with any usage.
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        // `startOfDay` here on purpose, unlike the two uses below it: these are
        // the stored days' own key dates being turned back into instants so
        // consecutive ones can be compared, not a decision about which day an
        // instant belongs to. The keys are the app's days already — see
        // `UsageDay` — and what matters is that they keep their order.
        let dates = days.compactMap { formatter.date(from: $0.key) }.map { calendar.startOfDay(for: $0) }
        var longest = 0, run = 0
        var previous: Date?
        for d in dates {
            if let p = previous, let next = calendar.date(byAdding: .day, value: 1, to: p), calendar.isDate(next, inSameDayAs: d) {
                run += 1
            } else {
                run = 1
            }
            longest = max(longest, run)
            previous = d
        }
        var current = 0
        if let last = dates.last {
            // The app's day, so a streak survives the small hours the way the
            // figures it is counted from do. Both sides are compared by calendar
            // day, and the boundary instant still falls on the date it is the
            // boundary *of*.
            let today = UsageDay.start(of: now, calendar: calendar)
            let yesterday = calendar.date(byAdding: .day, value: -1, to: today)!
            if calendar.isDate(last, inSameDayAs: today) || calendar.isDate(last, inSameDayAs: yesterday) { current = run }
        }

        let summary = AccountTokenUsage.Summary(lifetimeTokens: lifetime,
                                              peakDailyTokens: days.map(\.tokens).max(),
                                              longestRunningTurnSeconds: nil,
                                              currentStreakDays: current,
                                              longestStreakDays: longest)
        let buckets = days.map { AccountTokenUsage.DailyBucket(startDate: $0.key, tokens: $0.tokens) }
        return AccountTokenUsage(summary: summary, dailyUsageBuckets: buckets)
    }
}
