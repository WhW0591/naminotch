import Foundation

/// Decodes the signed-in DeepSeek Platform response the account ring reads.
///
/// One endpoint, one window: the account's own funded/spent money. The
/// per-API-key, per-model, per-day breakdown that used to hang off this
/// response is gone — it was never the balance, and the balance is what a ring
/// can honestly draw.
enum DeepSeekUsage {
    struct Reading: Equatable {
        let currency: String
        let spent: Double
        let balance: Double
        let availableTokens: Int?

        var usedFraction: Double {
            let funded = spent + balance
            guard funded > 0 else { return 0 }
            return min(max(spent / funded, 0), 1)
        }
    }

    enum ParseError: Error { case malformed, noWallet }

    static func reading(fromJSON json: String) throws -> Reading {
        guard let data = json.data(using: .utf8) else { throw ParseError.malformed }
        let envelope = try JSONDecoder().decode(Envelope.self, from: data)
        guard let summary = envelope.data?.bizData else { throw ParseError.noWallet }

        // **The wallet the figures are actually about.**
        //
        // `normal_wallets` lists every currency the account has ever been
        // issued, and an empty one can sit above the funded one. Taken as
        // `.first`, an account holding CNY with a dormant USD wallet listed
        // above it read as "USD, 0.00 balance, 0.00 spent" — `funded` was zero,
        // so `usedFraction` returned zero, and the ring drew an empty circle
        // for an account with money in it. Measured on a real account before
        // this was fixed: USD balance 0 above CNY balance, and the ring said 0%.
        //
        // The first wallet with a balance is the one the numbers belong to. An
        // account with nothing in any of them falls back to the first, which is
        // a true zero either way — and still `noWallet` when the list is empty.
        let wallet = summary.normalWallets.first { (Double($0.balance) ?? 0) > 0 }
            ?? summary.normalWallets.first
        guard let wallet else { throw ParseError.noWallet }

        let spent = summary.totalCosts.first(where: { $0.currency == wallet.currency })
            .flatMap { Double($0.amount) } ?? 0
        guard let balance = Double(wallet.balance), spent >= 0, balance >= 0 else {
            throw ParseError.malformed
        }
        return Reading(currency: wallet.currency, spent: spent, balance: balance,
                       availableTokens: summary.totalAvailableTokenEstimation.flatMap(Int.init))
    }

    /// The account window, in the shape every provider's parser returns.
    static func windows(fromJSON json: String) throws -> [LimitWindow] {
        let reading = try reading(fromJSON: json)
        var windows = [LimitWindow(
            id: "spend",
            label: L10n.t("Account usage (\(reading.currency))"),
            usedFraction: reading.usedFraction,
            money: UsageMoneyBreakdown(currency: reading.currency,
                                       spent: reading.spent,
                                       remaining: reading.balance)
        )]
        // The website's summary carries this estimate for some accounts and not
        // others; absent is a missing window rather than a zero one.
        if let availableTokens = reading.availableTokens {
            windows.append(LimitWindow(id: "available-tokens",
                                       label: "Available tokens (estimate)",
                                       detail: "\(LimitWindow.compact(availableTokens)) available"))
        }
        return windows
    }

    // MARK: - Wire

    private struct Envelope: Decodable { let data: DataContainer? }
    private struct DataContainer: Decodable {
        let bizData: Summary
        enum CodingKeys: String, CodingKey { case bizData = "biz_data" }
    }
    private struct Summary: Decodable {
        let normalWallets: [Wallet]
        let totalCosts: [Cost]
        let totalAvailableTokenEstimation: String?
        enum CodingKeys: String, CodingKey {
            case normalWallets = "normal_wallets"
            case totalCosts = "total_costs"
            case totalAvailableTokenEstimation = "total_available_token_estimation"
        }
    }
    private struct Wallet: Decodable { let currency: String; let balance: String }
    private struct Cost: Decodable { let currency: String; let amount: String }
}
