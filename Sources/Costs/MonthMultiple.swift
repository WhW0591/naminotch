import Foundation

/// What this month's usage has been worth against what the plan costs.
///
/// The one figure in the cost layer that answers *was the subscription worth
/// it*. Everything else there says what was spent; this says whether spending it
/// through a monthly plan rather than per token was the right call.
///
/// The plan itself is not modelled here. `CostAccount` already carries how an
/// account is billed — `billing`, `monthlyPrice`, and the tier `PlanCatalog`
/// detects — and this reads those rather than keeping a second copy of them.
@MainActor
enum MonthMultiple {
    /// The start of the calendar month in progress.
    ///
    /// The calendar's month, deliberately **not** `UsageDay`: the app counts a
    /// *day* from six in the morning so a night's work stays with the evening it
    /// began in, but a subscription is billed on the first, and a month measured
    /// from six a.m. on the 31st is a month nobody is charged for.
    static func monthStart(_ now: Date = Date()) -> Date {
        let calendar = Calendar.current
        return calendar.date(from: calendar.dateComponents([.year, .month], from: now)) ?? now
    }

    /// What this account's turns have cost so far this month, in the Mac's
    /// currency, where the cost index can say.
    ///
    /// Nil rather than zero when the index cannot be read. "0× what you paid"
    /// reads as a subscription that was wasted, and the honest answer to a
    /// figure that could not be worked out is that there is none — the same
    /// rule the ring follows for a reading it does not have.
    static func usageCost(for account: CostAccount, now: Date = Date()) -> Double? {
        guard let store = CostModels.model(for: account.id)?.store_ else { return nil }
        let priced = store.share(since: monthStart(now)).compactMap(\.cost)
        guard !priced.isEmpty else { return nil }
        return priced.reduce(0, +)
    }

    /// How many times over the plan has paid for itself this month.
    ///
    /// Nil for anything that is not a monthly plan, and that is the whole of the
    /// rule: an account billed per token has no period for usage to be a
    /// multiple *of*, so a ratio against nothing is worse than no ratio at all.
    /// Nil as well when either side is unknown — see `usageCost(for:now:)` — and
    /// when the plan costs nothing, which has nothing to divide by.
    static func times(for account: CostAccount, monthly: Double,
                      now: Date = Date()) -> Double? {
        guard account.billing == .subscription, monthly > 0 else { return nil }
        guard let usage = usageCost(for: account, now: now) else { return nil }
        return usage / monthly
    }
}
