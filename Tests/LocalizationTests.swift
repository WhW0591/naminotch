import XCTest
@testable import Codenotch

/// Catalog lookups with an explicit locale. English is the source; the
/// Simplified Chinese assertions here only prove a translation that exists
/// is served, not that every key has one.
final class LocalizationTests: XCTestCase {
    private let zhHans = Locale(identifier: "zh-Hans")
    private let english = Locale(identifier: "en")
    private let now = Date(timeIntervalSince1970: 1_787_900_000)
    private let resetNow = Date(timeIntervalSince1970: 1_700_000_000)

    // MARK: - ElapsedCopy

    func testElapsedCopyInSimplifiedChinese() {
        XCTAssertEqual(
            ElapsedCopy.text(since: now.addingTimeInterval(-5), now: now, locale: zhHans),
            "刚刚"
        )
        XCTAssertEqual(
            ElapsedCopy.text(since: now.addingTimeInterval(-6 * 60), now: now, locale: zhHans),
            "6 分钟"
        )
        XCTAssertEqual(
            ElapsedCopy.text(since: now.addingTimeInterval(-60 * 60), now: now, locale: zhHans),
            "1 小时"
        )
        XCTAssertEqual(
            ElapsedCopy.text(since: now.addingTimeInterval(-65 * 60), now: now, locale: zhHans),
            "1 小时 5 分钟"
        )
        XCTAssertEqual(
            ElapsedCopy.ago(since: now.addingTimeInterval(-6 * 60), now: now, locale: zhHans),
            "6 分钟前"
        )
    }

    func testElapsedCopyInEnglishWhenAsked() {
        XCTAssertEqual(
            ElapsedCopy.text(since: now.addingTimeInterval(-5), now: now, locale: english),
            "just now"
        )
        XCTAssertEqual(
            ElapsedCopy.text(since: now.addingTimeInterval(-6 * 60), now: now, locale: english),
            "6 min"
        )
        XCTAssertEqual(
            ElapsedCopy.text(since: now.addingTimeInterval(-60 * 60), now: now, locale: english),
            "1 hr"
        )
        XCTAssertEqual(
            ElapsedCopy.text(since: now.addingTimeInterval(-65 * 60), now: now, locale: english),
            "1 hr 5 min"
        )
        XCTAssertEqual(
            ElapsedCopy.ago(since: now.addingTimeInterval(-6 * 60), now: now, locale: english),
            "6 min ago"
        )
    }

    // MARK: - ResetCopy

    func testResetCopyUnderAnHourInSimplifiedChinese() {
        XCTAssertEqual(
            ResetCopy.text(for: resetNow.addingTimeInterval(51 * 60), now: resetNow, locale: zhHans),
            "51 分钟后重置"
        )
        XCTAssertEqual(
            ResetCopy.text(for: resetNow.addingTimeInterval(-5), now: resetNow, locale: zhHans),
            "正在重置…"
        )
    }

    /// The last minute counts in seconds, and a locale that translates the
    /// minutes translates the seconds too — mixing English into one minute out
    /// of five hours is the kind of thing nobody notices until they see it.
    func testTheLastMinuteIsTranslatedWhereTheMinutesAre() {
        let lastMinute = resetNow.addingTimeInterval(42)
        XCTAssertEqual(ResetCopy.text(for: lastMinute, now: resetNow, locale: english),
                       "Resets in 42 sec")
        XCTAssertEqual(ResetCopy.text(for: lastMinute, now: resetNow, locale: zhHans),
                       "42 秒后重置")
        XCTAssertEqual(ResetCopy.countdown(to: lastMinute, now: resetNow, locale: english), "42s")
    }

    func testResetCopyUnderAnHourInEnglishWhenAsked() {
        XCTAssertEqual(
            ResetCopy.text(for: resetNow.addingTimeInterval(51 * 60), now: resetNow, locale: english),
            "Resets in 51 min"
        )
        XCTAssertEqual(
            ResetCopy.text(for: resetNow.addingTimeInterval(-5), now: resetNow, locale: english),
            "Resetting…"
        )
    }

    // MARK: - LimitWindow.summary

    func testWindowSummaryInSimplifiedChinese() {
        XCTAssertEqual(
            percentWindow(0.12).summary(locale: zhHans),
            "12% 已用 · 88% 剩余"
        )
        XCTAssertEqual(
            LimitWindow(id: "w", label: "Requests", used: 8).summary(locale: zhHans),
            "已用 8"
        )
        XCTAssertEqual(
            LimitWindow(id: "w", label: "Requests", remaining: 3).summary(locale: zhHans),
            "剩余 3"
        )
        XCTAssertEqual(
            LimitWindow(id: "w", label: "Requests").summary(locale: zhHans),
            "暂无读数"
        )
    }

    func testWindowSummaryInEnglishWhenAsked() {
        XCTAssertEqual(
            percentWindow(0.12).summary(locale: english),
            "12% Used · 88% left"
        )
        XCTAssertEqual(
            LimitWindow(id: "w", label: "Requests", used: 8).summary(locale: english),
            "8 used"
        )
        XCTAssertEqual(
            LimitWindow(id: "w", label: "Requests", remaining: 3).summary(locale: english),
            "3 left"
        )
        XCTAssertEqual(
            LimitWindow(id: "w", label: "Requests").summary(locale: english),
            "No reading"
        )
    }

    // MARK: - Menu and settings keys

    func testMenuCopyInSimplifiedChinese() {
        XCTAssertEqual(L10n.t("Always show", locale: zhHans), "始终显示")
        XCTAssertEqual(L10n.t("Settings…", locale: zhHans), "设置…")
    }

    func testMenuCopyInEnglishWhenAsked() {
        XCTAssertEqual(L10n.t("Always show", locale: english), "Always show")
        XCTAssertEqual(L10n.t("Settings…", locale: english), "Settings…")
    }

    // MARK: - Sign-in

    func testSignInActionTitleStaysEnglishUnderTheTestPin() {
        XCTAssertEqual(
            SignInRoute.modal(name: "Perplexity").actionTitle,
            "Sign in to Perplexity"
        )
    }

    func testSignInCopyInSimplifiedChinese() {
        XCTAssertEqual(
            L10n.t("Sign in to \("Perplexity")", locale: zhHans),
            "登录 Perplexity"
        )
    }

    func testLimitNotificationCopyInSimplifiedChinese() {
        XCTAssertEqual(L10n.t("When a limit is reached", locale: zhHans), "额度用尽时")
        XCTAssertEqual(L10n.t("Show notification for session limit", locale: zhHans), "会话额度用尽时显示通知")
        XCTAssertEqual(L10n.t("Show notification for weekly limit", locale: zhHans), "周额度用尽时显示通知")
        XCTAssertEqual(L10n.t("Alert sound", locale: zhHans), "提示音")
        XCTAssertEqual(L10n.t("Preview session limit alert", locale: zhHans), "预览会话额度提醒")
        XCTAssertEqual(L10n.t("Preview weekly limit alert", locale: zhHans), "预览周额度提醒")
        XCTAssertEqual(
            L10n.t("Displays a notification card from the side of the notch when a provider's session or weekly usage limit is reached.", locale: zhHans),
            "当某家服务的会话或周额度用尽时，刘海侧面滑出一张通知卡片。"
        )
        XCTAssertEqual(L10n.t("When a limit resets", locale: zhHans), "额度重置时")
        XCTAssertEqual(L10n.t("Show notification from notch", locale: zhHans), "从刘海显示通知")
        XCTAssertEqual(L10n.t("Reset sound", locale: zhHans), "重置提示音")
        XCTAssertEqual(L10n.t("Preview notification", locale: zhHans), "预览通知")
        XCTAssertEqual(
            L10n.t("Displays a notification card from the side of the notch when a provider's usage limit resets.", locale: zhHans),
            "当某家服务的额度窗口滚动过后，刘海侧面滑出一张通知卡片。"
        )
    }

    func testSignInCopyInEnglishWhenAsked() {
        XCTAssertEqual(
            L10n.t("Sign in to \("Perplexity")", locale: english),
            "Sign in to Perplexity"
        )
    }

    /// Every language the picker offers must resolve to a locale the catalog
    /// is filed under — a region-qualified or unshipped identifier silently
    /// serves another language instead.
    func testEveryOfferedLanguageResolves() {
        XCTAssertEqual(
            AppLanguage.allCases.map(\.rawValue),
            ["system", "en", "zh-Hans"]
        )
        XCTAssertNil(AppLanguage.system.locale)
        for language in AppLanguage.allCases where language != .system {
            XCTAssertEqual(language.locale?.identifier, language.rawValue)
        }
    }

    private func percentWindow(_ fraction: Double) -> LimitWindow {
        LimitWindow(id: "w", label: "Monthly limit", usedFraction: fraction)
    }
}
