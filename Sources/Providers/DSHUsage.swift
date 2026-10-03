import Foundation

/// The Platform account endpoint DeepSeek Harness's own account provider reads.
///
/// Harness authenticates with the grant in `x-dsh-auth-token` rather than the
/// website's `Authorization: Bearer`, and describes the calling UI in five
/// client headers that the owning package keeps to itself. The balance envelope
/// that comes back is the same one `Sites.deepSeek` decodes from the website —
/// `data.biz_data` with `normal_wallets` and `total_costs` — so the reading is
/// handed straight to `DeepSeekUsage`. One parser, one set of tests, and no
/// second opinion about what the numbers mean.
enum DSHUsage {
    static let summaryPath = "/api/v0/users/get_user_summary"

    /// The five headers `@deepseek-ai/dsh-deepseek-account-platform` builds for
    /// every Platform request.
    ///
    /// Every one of them is owned by that package and cannot be overridden by
    /// deployment configuration, which is why they are assembled here rather
    /// than read from Settings. `x-client-bundle-id` is empty on purpose — the
    /// provider sets it that way — and the timezone offset is whole seconds
    /// east of UTC, not a name or an abbreviation.
    static func clientHeaders(
        locale: Locale = .current,
        timeZone: TimeZone = .current,
        version: String = DSHUsage.clientVersion
    ) -> [String: String] {
        [
            "x-client-platform": "desktop-mac",
            "x-client-bundle-id": "",
            "x-client-version": version,
            "x-client-locale": wireLocale(locale),
            "x-client-timezone-offset": String(timeZone.secondsFromGMT()),
        ]
    }

    /// Harness reduces the calling UI's language to the two the Platform
    /// serves, so a third language reports as English rather than as itself.
    static func wireLocale(_ locale: Locale) -> String {
        let code = locale.language.languageCode?.identifier
            ?? locale.identifier.split(separator: "_").first.map(String.init)
            ?? "en"
        return code == "zh" ? "zh_CN" : "en_US"
    }

    /// The calling build's version, which is what the header means. NamiNotch
    /// is the client making the request, so it reports its own.
    static var clientVersion: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)
            .flatMap { $0.isEmpty ? nil : $0 } ?? "1.0"
    }

    /// The account windows this endpoint can answer.
    ///
    /// Handed straight to `DeepSeekUsage`: Harness's grant reads the same
    /// endpoint the website does, and returns the same envelope, so a second
    /// parser here would be a second opinion about what the numbers mean — the
    /// thing this adapter exists to avoid.
    static func windows(fromJSON json: String) throws -> [LimitWindow] {
        try DeepSeekUsage.windows(fromJSON: json)
    }

    /// The Platform's own "this grant is no longer good" codes.
    ///
    /// The owning package treats HTTP 401 and a top-level `code: 40003` as the
    /// same event and clears the stored grant for both; anything else keeps it.
    /// Reproduced here so the ring asks for a sign-in in the cases that deserve
    /// one, and keeps its last reading in the cases that do not.
    static func rejection(inJSON json: String) -> Bool {
        guard let data = json.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let code = root["code"] as? NSNumber
        else { return false }
        return code.intValue == 40003
    }

    // MARK: - Today

    static let amountPath = "/api/v0/usage/by_api_key/amount"
    static let costPath = "/api/v0/usage/by_api_key/cost"

    /// The window the platform's own console asks for: thirty days up to
    /// tomorrow. `tz` is whole seconds east of UTC — the same number
    /// `x-client-timezone-offset` carries.
    ///
    /// **The day boundary is `start`, and nothing else.** Measured three ways,
    /// because the obvious reading of the first two is wrong:
    ///
    /// * `tz` is ignored — the same window at `tz=0`, `+39600` and `-39600`
    ///   comes back with byte-identical bucket keys *and* values.
    /// * So is `x-client-timezone-offset` — `+39600`, `0`, `+28800` and
    ///   `-18000` likewise change nothing.
    /// * `start` is *not*. A window beginning at 00:00, 14:00 and 18:00 UTC
    ///   comes back cut at 00:00, 14:00 and 18:00 UTC — and one beginning at
    ///   local 06:00 comes back cut at local 06:00.
    ///
    /// So the platform has no opinion about the reader's day; it cuts wherever
    /// it is asked to. What this app has always sent is local midnight, which
    /// is why the buckets have always looked like local calendar days — and why
    /// moving the boundary is a matter of moving this one line, not of asking
    /// the platform for anything.
    ///
    /// The window must be thirty days; a ten-day one is refused with
    /// `biz_code: 1, "INVALID_PARAM"`. Its alignment is not checked.
    static func amountQuery(now: Date = Date(), timeZone: TimeZone = .current,
                            calendar: Calendar = .current,
                            dayStartHour: Int = UsageDay.startHour) -> String {
        // The app's day, which is what makes the buckets six-to-six rather than
        // midnight-to-midnight. The platform cuts wherever `start` says, so this
        // is the whole of the setting's reach into the wire.
        let today = UsageDay.start(of: now, calendar: calendar, hour: dayStartHour)
        let start = calendar.date(byAdding: .day, value: -29, to: today) ?? today
        let end = calendar.date(byAdding: .day, value: 1, to: today) ?? today
        return "start=\(Int(start.timeIntervalSince1970))"
            + "&end=\(Int(end.timeIntervalSince1970))"
            + "&tz=\(timeZone.secondsFromGMT(for: now))"
    }

    /// The account's daily totals, in the shape the card already draws.
    ///
    /// A token is a token of whatever kind: prompt cache hits, cache misses and
    /// the response together are everything the model was handed or produced,
    /// and counting only some of them would answer a different question than
    /// "how much did I use today". `REQUEST` is a count rather than tokens and
    /// is left out. Both endpoints are summed across their series for the same
    /// reason: the card's row is the account's, not one API key's.
    ///
    /// Money is optional — `costJSON` is nil when that request failed — and a
    /// day the platform never priced keeps a nil cost rather than a zero one, so
    /// the card can tell "nothing spent" from "nothing said".
    ///
    /// `summary` stays nil: `AccountTokenUsage.Summary` is Codex's own lifetime
    /// and streak statistics, and the platform publishes nothing like them.
    static func dailyUsage(amountJSON: String, costJSON: String? = nil,
                           now: Date = Date(),
                           calendar: Calendar = .current,
                           dayStartHour: Int = UsageDay.startHour) throws -> AccountTokenUsage {
        var tokensByDay: [String: Int] = [:]
        for (epoch, tokens) in try dailyTokens(fromJSON: amountJSON) {
            tokensByDay[dayKey(epoch: epoch, calendar: calendar), default: 0] += tokens
        }

        var costByDay: [String: Double] = [:]
        var currency: String?
        if let costJSON, let priced = try? dailyCost(fromJSON: costJSON) {
            currency = priced.currency
            for (epoch, cost) in priced.byDay {
                costByDay[dayKey(epoch: epoch, calendar: calendar), default: 0] += cost
            }
        }

        let buckets = Set(tokensByDay.keys).union(costByDay.keys).sorted().map { day in
            AccountTokenUsage.DailyBucket(startDate: day,
                                          tokens: tokensByDay[day] ?? 0,
                                          cost: costByDay[day])
        }
        // The boundary travels with the buckets: the lookup has to agree with
        // the cut that was actually made, and the setting can move under a
        // reading that is already on screen.
        return AccountTokenUsage(dailyUsageBuckets: buckets, currency: currency,
                                 dayStartHour: dayStartHour)
    }

    /// Tokens by the epoch of the local midnight they belong to.
    private static func dailyTokens(fromJSON json: String) throws -> [Int: Int] {
        guard let data = json.data(using: .utf8) else { throw DeepSeekUsage.ParseError.malformed }
        let envelope = try JSONDecoder().decode(AmountEnvelope.self, from: data)
        guard let series = envelope.data?.bizData?.series else {
            throw DeepSeekUsage.ParseError.malformed
        }
        var byDay: [Int: Int] = [:]
        for series in series {
            for bucket in series.buckets {
                let tokens = tokenFields.reduce(0) { $0 + (bucket.usage[$1]?.value ?? 0) }
                byDay[bucket.time, default: 0] += tokens
            }
        }
        return byDay
    }

    /// Money by the same key. The cost endpoint nests one level deeper than the
    /// amount one — `biz_data.data[]` is per currency, and the series live
    /// inside it — because a currency has to be named for the amounts under it.
    private static func dailyCost(fromJSON json: String) throws -> (currency: String?,
                                                                    byDay: [Int: Double]) {
        guard let data = json.data(using: .utf8) else { throw DeepSeekUsage.ParseError.malformed }
        let envelope = try JSONDecoder().decode(CostEnvelope.self, from: data)
        guard let entries = envelope.data?.bizData?.data else {
            throw DeepSeekUsage.ParseError.malformed
        }
        var byDay: [Int: Double] = [:]
        var currency: String?
        for entry in entries {
            if currency == nil { currency = entry.currency }
            for series in entry.series {
                for bucket in series.buckets {
                    byDay[bucket.time, default: 0] += bucket.cost.value
                }
            }
        }
        return (currency, byDay)
    }

    private static let tokenFields = [
        "PROMPT_CACHE_HIT_TOKEN", "PROMPT_CACHE_MISS_TOKEN", "RESPONSE_TOKEN",
    ]

    /// The day a bucket at `epoch` belongs to, in the `YYYY-MM-DD` form
    /// `AccountTokenUsage` keys its own lookups by — so a bucket written here is
    /// one `usageToday` can find.
    private static func dayKey(epoch: Int, calendar: Calendar) -> String {
        let parts = calendar.dateComponents(
            [.year, .month, .day],
            from: Date(timeIntervalSince1970: TimeInterval(epoch))
        )
        return String(format: "%04d-%02d-%02d",
                      parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    // MARK: - Wire

    private struct AmountEnvelope: Decodable { let data: AmountData? }
    private struct AmountData: Decodable {
        let bizData: AmountSummary?
        enum CodingKeys: String, CodingKey { case bizData = "biz_data" }
    }
    private struct AmountSummary: Decodable { let series: [AmountSeries] }
    private struct AmountSeries: Decodable {
        let buckets: [AmountBucket]
    }
    private struct AmountBucket: Decodable {
        let time: Int
        let usage: [String: WireInt]
    }

    private struct CostEnvelope: Decodable { let data: CostData? }
    private struct CostData: Decodable {
        let bizData: CostSummary?
        enum CodingKeys: String, CodingKey { case bizData = "biz_data" }
    }
    private struct CostSummary: Decodable { let data: [CostCurrency] }
    private struct CostCurrency: Decodable {
        let currency: String
        let series: [CostSeries]
    }
    private struct CostSeries: Decodable {
        let buckets: [CostBucket]
    }
    private struct CostBucket: Decodable {
        let time: Int
        let cost: WireDouble
    }

    /// The platform writes these counts as numbers on some days and as strings
    /// on others, so both are read rather than one being assumed.
    private struct WireInt: Decodable {
        let value: Int

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let number = try? container.decode(Int.self) {
                value = number
            } else if let number = try? container.decode(Double.self) {
                value = Int(number)
            } else if let text = try? container.decode(String.self), let number = Int(text) {
                value = number
            } else {
                value = 0
            }
        }
    }

    /// The same for money, which arrives as a decimal string — `"0.12"` — and
    /// would be read as zero by an `Int` decode.
    private struct WireDouble: Decodable {
        let value: Double

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let number = try? container.decode(Double.self) {
                value = number
            } else if let text = try? container.decode(String.self), let number = Double(text) {
                value = number
            } else {
                value = 0
            }
        }
    }
}
