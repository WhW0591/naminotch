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

    /// The calling build's version, which is what the header means. Codenotch
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
}
