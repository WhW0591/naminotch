import AppKit
import Combine
import SwiftUI

/// Where the cost layer plugs into the app: the cost models watch the usage
/// store's snapshots, a Claude card borrows the token chart the Codex card
/// has, and the Activity window opens from the menu.
@MainActor
enum Costs {
    private static var subscription: AnyCancellable?
    private static var activityWindow: NSWindow?
    /// Removed again the moment the window closes; see `showActivity`.
    private static var activityCloseObserver: NSObjectProtocol?

    /// What a Claude login's card gains before the notch draws it: the daily
    /// token chart and summary the Codex server publishes for Codex, built
    /// here from the transcripts Claude Code writes.
    static func decorate(_ snapshot: ProviderSnapshot) -> ProviderSnapshot {
        // The suite compares cells to what it fed in; the machine's own
        // accounts and transcripts must not leak into that.
        guard !Runtime.isUnderTest, snapshot.tokenUsage == nil,
              let usage = CostModels.model(for: snapshot.id)?.tokenUsage else { return snapshot }
        var snapshot = snapshot
        snapshot.tokenUsage = usage
        return snapshot
    }

    static func attach(to store: UsageStore) {
        _ = PlanCatalog.shared
        _ = PriceTable.shared
        _ = CostAccountStore.shared
        subscription = store.$snapshots
            .receive(on: RunLoop.main)
            .sink { snapshots in
                CostAccountStore.shared.rediscover()
                CostModels.all.forEach { $0.observe(snapshots) }
            }
    }

    static func showActivity() {
        if activityWindow == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 720),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable],
                             backing: .buffered, defer: false)
            w.title = L10n.t("Activity")
            w.minSize = NSSize(width: 900, height: 560)
            w.contentViewController = NSHostingController(rootView: TimelinePane().frame(minWidth: 900, minHeight: 560))
            // Held by ARC rather than released by AppKit, and dropped again
            // when the window closes: the timeline is a large SwiftUI tree, and
            // keeping it alive for the rest of the session bought only restored
            // scroll position.
            w.isReleasedWhenClosed = false
            w.center()
            activityWindow = w
            activityCloseObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification, object: w, queue: .main
            ) { _ in
                MainActor.assumeIsolated {
                    if let token = activityCloseObserver {
                        NotificationCenter.default.removeObserver(token)
                    }
                    activityCloseObserver = nil
                    activityWindow = nil
                }
            }
        }
        NSApp.activate(ignoringOtherApps: true)
        activityWindow?.makeKeyAndOrderFront(nil)
    }
}
