import SwiftUI

/// Every number in this app's UI is measured off the Figma frame in
/// `docs/design/frame-124-hover-tooltip.png` (2000 x 2000 px), so the layout is
/// *proportionally* exact rather than eyeballed.
///
/// The frame fixes only ratios, never an absolute size, so one anchor picks the
/// scale: the design spec calls the provider ring 44pt across, and it measures
/// 117px in the frame. Change `scale` and the notch and the rings resize with it
/// — still in the design's proportions.
enum Design {
    /// Points per pixel of the design frame.
    static let scale: CGFloat = 44.0 / 117.0

    /// A distance measured in design-frame pixels, in points.
    static func px(_ pixels: CGFloat) -> CGFloat { pixels * scale }

    /// **The hover card's own anchor**, on top of `scale`.
    ///
    /// The frame fixes ratios, and `scale` picks them up from a *graphic*
    /// anchor: the ring, 44pt across. Followed through, the card's body text
    /// landed at 9.5pt — under the 11pt this system calls its own default text
    /// size, and well under the 13pt it calls body text. A ring is glanced at;
    /// the card is read at arm's length, and it had been sized as though it were
    /// part of the ring.
    ///
    /// So the card is measured from a size chosen for reading instead: every
    /// constant it is built from goes through `cardPx`, and its two faces
    /// through `cardFontSize`. The proportions are still the frame's — only the
    /// anchor moved.
    ///
    /// **The value is bounded, not chosen.** 1.34 was the first attempt and it
    /// put the body at 12.7pt, which is where a card wants to be — but a card
    /// this size stops fitting screens. `NotchViewModel.cardBudget` reserves the
    /// stack's length along a side edge, and on a 13-inch Air with four
    /// providers the stack is 501pt of 956, leaving 405pt: the 12.7pt card is
    /// 506pt and does not fit, and neither does 506 less one session row, so the
    /// session list came back empty. `SessionCapTests` caught it, and loosening
    /// the budget instead was tried and refused by the suite — see the note on
    /// `cardBudget`.
    ///
    /// Solving for the largest value that keeps every guarantee gives 1.097,
    /// and 1.09 is taken for the margin. That is a body of 10.3pt: better than
    /// the 9.5pt the card shipped with, short of the 12.7pt this was for, and
    /// **the ceiling on this design, not a preference** — there is no larger
    /// value that keeps a legible card and the session list on the smallest
    /// display. Going further means the card's scale following the screen it is
    /// drawn on, which means card geometry per model rather than `NotchLayout`'s
    /// shared constants. That is written up in `TASKS.md` and not done.
    ///
    /// `NotchSize` does not reach here either: that scale is applied to the
    /// notch and the cells it carries, and to nothing else.
    static let tooltipScale: CGFloat = 1.09

    /// Points per design-frame pixel for the card and everything that measures
    /// it — including its tail, and the panel room reserved at each end of the
    /// stack so a card anchored to the first or last cell has somewhere to sit.
    static let cardScale: CGFloat = scale * tooltipScale

    /// A card distance measured in design-frame pixels, in points.
    static func cardPx(_ pixels: CGFloat) -> CGFloat { pixels * cardScale }

    /// Cap-height fraction of an em for SF Pro. Text in the frame can only be
    /// measured by its cap height, so this converts back to a point size.
    private static let capRatio: CGFloat = 0.714

    /// The point size whose capital letters are `pixels` tall in the frame.
    static func fontSize(capPixels pixels: CGFloat) -> CGFloat {
        px(pixels) / capRatio
    }

    /// The same, for text drawn on a card.
    static func cardFontSize(capPixels pixels: CGFloat) -> CGFloat {
        cardPx(pixels) / capRatio
    }
}
