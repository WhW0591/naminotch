import Foundation
import os

/// Reads the DeepSeek Platform account through the grant DeepSeek Harness
/// already holds.
///
/// This is the borrowed-credential pattern again — the same bargain as Grok's
/// `~/.grok/auth.json` or Kilo's `~/.local/share/kilo/auth.json` — with one
/// wrinkle: Harness's grant is not a website token, so it rides in
/// `x-dsh-auth-token` and is only good on the origin that issued it. That is
/// why `DSHCredentials` keeps the `issuer` at all, and why the request is built
/// against it rather than against a constant.
///
/// The money is Platform's own, and the percentage derived from it is ours, so
/// this is `.derived` — exactly the fidelity the signed-in DeepSeek provider
/// declares for the same account. The ring wears DeepSeek's mark rather than a
/// Harness-specific one because the account behind it is DeepSeek's; what
/// differs is where the credential came from, and Settings says that plainly
/// (`via DeepSeek Harness`).
///
/// A machine with no Harness install gets no ring rather than a row asking for
/// a sign-in NamiNotch cannot perform: the grant is the only way in, and
/// NamiNotch does not own it.
actor DSHProvider: UsageProvider {
    /// The id this provider registers under, named once so the places that have
    /// to know it without building one — the default-on rule in `Preferences` —
    /// cannot drift from the one it answers to.
    nonisolated static let providerID = "dsh"
    nonisolated let id = DSHProvider.providerID
    nonisolated let displayName = "DeepSeek Harness"
    nonisolated let glyph = ProviderGlyph.deepseek

    private let session: URLSession
    private let credentialsURL: URL

    init(session: URLSession = .shared,
         credentialsURL: URL = DSHCredentials.credentialsURL) {
        self.session = session
        self.credentialsURL = credentialsURL
    }

    nonisolated var signInRoute: SignInRoute {
        // Nothing to run from here and no modal of our own: the grant is minted
        // by Harness's browser sign-in, so the honest action is to open it.
        .openApp(bundleID: "com.deepseek.dsh", name: "DeepSeek Harness")
    }

    nonisolated func account() -> ProviderAccount? {
        DSHCredentials.account(from: credentialsURL)
    }

    nonisolated var isVisibleWhenAbsent: Bool { false }

    func fetchSnapshot() async throws -> ProviderSnapshot {
        let credentials = try DSHCredentials.load(from: credentialsURL)
        let body = try await fetchSummary(credentials)
        Log.usage.debug("dsh get_user_summary -> \(body.prefix(400), privacy: .public)")
        let windows = try DSHUsage.windows(fromJSON: body)

        // Today's tokens are a second request on the same grant, and a failure
        // there must not cost the ring its reading: the balance *is* the ring,
        // and the day's figure is one extra row under it.
        let usage = try? await fetchDailyUsage(credentials)

        return ProviderSnapshot(
            id: id,
            displayName: displayName,
            glyph: glyph,
            fidelity: .derived,
            status: .ok,
            windows: windows,
            headlineID: "spend",
            tokenUsage: usage
        )
    }

    private func fetchSummary(_ credentials: DSHCredentials) async throws -> String {
        try await get(DSHUsage.summaryPath, credentials)
    }

    /// The account's daily totals, which the card draws as "Today".
    ///
    /// Two requests on the same grant, and the money is the optional half: if
    /// the second fails the day's tokens still show, because a row carrying one
    /// number beats no row at all.
    private func fetchDailyUsage(_ credentials: DSHCredentials) async throws -> AccountTokenUsage {
        // Read once, so the window and the label on the figures cannot disagree
        // if the setting moves while the two requests are in flight.
        let hour = UsageDay.startHour
        let query = DSHUsage.amountQuery(dayStartHour: hour)
        let amount = try await get(DSHUsage.amountPath + "?" + query, credentials)
        let cost = try? await get(DSHUsage.costPath + "?" + query, credentials)
        return try DSHUsage.dailyUsage(amountJSON: amount, costJSON: cost, dayStartHour: hour)
    }

    /// One read on the grant, with the five client headers the owning package
    /// builds for every Platform request.
    private func get(_ path: String, _ credentials: DSHCredentials) async throws -> String {
        guard let url = URL(string: path, relativeTo: credentials.issuer) else {
            throw UsageProviderError.badResponse(status: 0)
        }

        var request = URLRequest(url: url)
        request.setValue(credentials.token, forHTTPHeaderField: "x-dsh-auth-token")
        for (name, value) in DSHUsage.clientHeaders() {
            request.setValue(value, forHTTPHeaderField: name)
        }
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15

        Log.usage.debug("GET \(credentials.issuer.absoluteString, privacy: .public)\(path, privacy: .public)")
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        Log.usage.debug("dsh \(path, privacy: .public) answered \(status)")

        // The grant was rejected. Harness's own account provider answers this
        // by clearing the stored grant; here it is a sign-in the *user* has to
        // do in Harness, so the ring says `needsAuth` and keeps nothing.
        if status == 401 || status == 403 { throw UsageProviderError.needsAuth }
        if status == 429 { throw UsageProviderError.rateLimited(retryAfter: 60) }
        guard (200..<300).contains(status),
              let text = String(data: data, encoding: .utf8)
        else { throw UsageProviderError.badResponse(status: status) }

        // A rejected grant can also ride under HTTP 200, named in the envelope
        // rather than in the status line — the case `DeepSeekUsage` would
        // otherwise report as "no wallet".
        if DSHUsage.rejection(inJSON: text) { throw UsageProviderError.needsAuth }

        return text
    }
}
