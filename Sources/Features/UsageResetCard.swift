import SwiftUI

/// The notification modal card displayed beside the notch when a provider's limit resets.
struct UsageResetCard: View {
    let event: UsageResetEvent
    let direction: NotchEdge.TooltipDirection
    var tailOffset: CGFloat = 0
    var onDismiss: (() -> Void)? = nil

    @Environment(\.codenotchAccentColor) private var accentColor
    @Environment(\.codenotchReduceTransparency) private var reduceTransparency
    @Environment(\.notchSurfaceStyle) private var surfaceStyle
    @Environment(\.colorScheme) private var colorScheme

    static let cardHeight: CGFloat = Design.px(210)
    /// **The card is content, and content is not glass.**
    ///
    /// Liquid Glass belongs to the layer floating above content — the bar and its
    /// handles — and Apple's guidance is blunt about the other side: "Don't use
    /// Liquid Glass in the content layer", no glass lists, cards or table cells.
    /// This is a card of limits and resets, so it is painted as one, and the
    /// notch beside it stays glass.
    private var surfaceFill: Color { Palette.card }

    /// The same ink the tooltip's rows use. The card is no longer glass, so
    /// this resolves to the ordinary secondary colour — see `TooltipGlassContrast`.
    @Environment(\.tooltipSecondaryInk) private var secondaryInk

    private var clampedTailOffset: CGFloat {
        let size = TooltipTail.size(for: direction)
        switch direction {
        case .leading, .trailing:
            let maxOffset = max(0, (Self.cardHeight / 2) - NotchLayout.cardCorner - (size.height / 2))
            return min(max(tailOffset, -maxOffset), maxOffset)
        case .up, .down:
            let maxOffset = max(0, (NotchLayout.cardWidth / 2) - NotchLayout.cardCorner - (size.width / 2))
            return min(max(tailOffset, -maxOffset), maxOffset)
        }
    }

    var body: some View {
        stack
    }

    private var titleText: String {
        if let notice = event.noticeTitle { return notice }
        switch event.kind {
        case .reset:
            return L10n.t("\(event.providerName) Reset")
        case .sessionLimitReached:
            return L10n.t("\(event.providerName) Limit Reached")
        case .weeklyLimitReached:
            return L10n.t("\(event.providerName) Weekly Limit")
        }
    }

    private var subtitleText: String {
        if let notice = event.noticeSubtitle { return notice }
        switch event.kind {
        case .reset:
            return L10n.t("\(event.windowLabel) limit refreshed")
        case .sessionLimitReached, .weeklyLimitReached:
            return L10n.t("\(event.windowLabel) limit is spent")
        }
    }

    private var statusColor: Color {
        switch event.kind {
        case .reset:
            return Palette.ample
        case .sessionLimitReached, .weeklyLimitReached:
            return Palette.critical
        }
    }

    private var statusText: String {
        if let notice = event.noticeStatus { return notice }
        switch event.kind {
        case .reset:
            return L10n.t("Quota is available (0% used)")
        case .sessionLimitReached:
            return L10n.t("Session limit reached (100% used)")
        case .weeklyLimitReached:
            return L10n.t("Weekly limit reached (100% used)")
        }
    }

    private var resetTimePrefix: String {
        switch event.kind {
        case .reset:
            return L10n.t("Next reset")
        case .sessionLimitReached, .weeklyLimitReached:
            return L10n.t("Resets at")
        }
    }

    private var card: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: NotchLayout.cardCorner, style: .circular)
                .fill(surfaceFill)
                .frame(width: NotchLayout.cardWidth, height: Self.cardHeight)

            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .center, spacing: NotchLayout.headerGap) {
                    ProviderGlyphView(glyph: event.glyph)
                        .foregroundStyle(Palette.textPrimary)

                    VStack(alignment: .leading, spacing: 0) {
                        HStack(spacing: 0) {
                            Text(titleText)
                                .font(Typography.cardTitle)
                                .foregroundStyle(Palette.textPrimary)
                                .layoutPriority(1)

                            Spacer(minLength: Design.px(12))

                            if let onDismiss {
                                Button(action: onDismiss) {
                                    Image(systemName: "xmark")
                                        .font(.system(size: 11, weight: .bold))
                                        .foregroundStyle(secondaryInk)
                                        .frame(width: 16, height: 16)
                                }
                                .buttonStyle(.plain)
                            }
                        }

                        Text(subtitleText)
                            .font(Typography.cardBody)
                            .foregroundStyle(secondaryInk)
                            .lineLimit(1)
                    }
                }

                HStack(spacing: Design.px(12)) {
                    Circle()
                        .fill(statusColor)
                        .frame(width: Design.px(16), height: Design.px(16))

                    Text(statusText)
                        .font(Typography.cardBody)
                        .foregroundStyle(statusColor)
                        .lineLimit(1)

                    Spacer(minLength: 0)
                }
                .padding(.top, NotchLayout.headerToBlock)

                if let resetsAt = event.resetsAt {
                    Text("\(resetTimePrefix) \(resetsAt.formatted(date: .omitted, time: .shortened))")
                        .font(Typography.cardBody)
                        .foregroundStyle(secondaryInk)
                        .lineLimit(1)
                        .padding(.top, Design.px(8))
                }
            }
            .padding(NotchLayout.cardPadding)
            .frame(width: NotchLayout.cardWidth, height: Self.cardHeight, alignment: .topLeading)
        }
        .frame(width: NotchLayout.cardWidth, height: Self.cardHeight, alignment: .top)
        .clipShape(RoundedRectangle(cornerRadius: NotchLayout.cardCorner, style: .circular))
        .overlay {
            if reduceTransparency {
                RoundedRectangle(cornerRadius: NotchLayout.cardCorner, style: .circular)
                    .strokeBorder(Palette.ringTrack, lineWidth: 1)
            }
        }
    }

    private var tail: some View {
        let size = TooltipTail.size(for: direction)
        return TooltipTail(direction: direction)
            .fill(surfaceFill)
            .frame(width: size.width, height: size.height)
            .offset(x: direction == .up || direction == .down ? clampedTailOffset : 0,
                    y: direction == .leading || direction == .trailing ? clampedTailOffset : 0)
    }

    @ViewBuilder private var stack: some View {
        switch direction {
        case .leading:
            HStack(spacing: 0) { card; tail }
        case .trailing:
            HStack(spacing: 0) { tail; card }
        case .down:
            VStack(spacing: 0) { tail; card }
        case .up:
            VStack(spacing: 0) { card; tail }
        }
    }
}
