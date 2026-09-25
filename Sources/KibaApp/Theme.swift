import AppKit
import KibaCore
import SwiftUI

/// Design tokens (DESIGN.md "Visual design"): colors that follow the
/// appearance, type, and the panel's measurements.
enum Theme {
    // MARK: Color

    /// Light values hold 3:1 against the track on the popover material; the
    /// red holds 4.5:1 as text on both appearances (Apple's contrast criteria).
    static let roomNS = dynamic(light: 0x1F7F52, dark: 0x4FC08A)
    static let lowNS = dynamic(light: 0x9E6A0E, dark: 0xE2A93B)
    static let outNS = dynamic(light: 0xB52F2F, dark: 0xF07070)

    /// Reservoir segments with half or more left.
    static let room = Color(nsColor: roomNS)
    /// Reservoir segments under half.
    static let low = Color(nsColor: lowNS)
    /// Spent reservoir segments, "limit" and "log in again", errors, the urgent icon.
    static let out = Color(nsColor: outNS)
    /// Meta text, plan text, idle controls.
    static let idle = Color(nsColor: .secondaryLabelColor)
    /// Names and figures: text is never colored by state, the bars are.
    static let ink = Color(nsColor: .labelColor)
    /// Empty reservoir; `trackContrast` under Increase Contrast.
    static let track = Color(nsColor: .quaternaryLabelColor)
    static let trackContrast = Color(nsColor: .tertiaryLabelColor)
    /// The active account's name; the limit-reset badge's fill.
    static let accent = Color.accentColor
    /// Text on an `accent` fill: the badge's count.
    static let onAccent = Color(nsColor: .alternateSelectedControlTextColor)
    /// The keyboard focus ring around the badge under the cursor.
    static let focus = Color(nsColor: .keyboardFocusIndicatorColor)

    /// The status dot: `room` when the account can take work, `out` when it
    /// is limited or dead, `idle` while unknown.
    static func dot(_ usable: Bool?) -> Color {
        switch usable {
        case true?: return room
        case false?: return out
        case nil: return idle
        }
    }

    // MARK: Type

    /// System text styles only, so Bold Text and the system's weights apply.
    static let title = Font.title3.bold()
    static let section = Font.headline
    static let name = Font.body
    static let nameActive = Font.body.bold()
    static let meta = Font.subheadline
    static let figures = Font.subheadline.monospacedDigit()
    /// The count in the limit-reset badge.
    static let badge = Font.caption.bold().monospacedDigit()
    static let action = Font.body

    // MARK: Layout

    static let width: CGFloat = 340
    /// Height cap until a screen is known; the screen's visible height less
    /// `screenInset` replaces it. Taller content scrolls, without indicators.
    static let maxHeight: CGFloat = 600
    /// Room for the popover arrow and shadow under the menu bar.
    static let screenInset: CGFloat = 24
    /// Panel padding above and below the content.
    static let pad: CGFloat = 10
    /// Space between the panel edge and a row's highlight.
    static let gutter: CGFloat = 6
    /// Row content inset inside its highlight.
    static let inset: CGFloat = 10
    /// Between the name, the plan, and the figures.
    static let gap: CGFloat = 8
    static let rowPad: CGFloat = 6
    /// The status dot before a name.
    static let dot: CGFloat = 8
    /// The least width the name keeps beside plan and figures on one line,
    /// about 20 characters; when they would leave it less, they move under it.
    static let nameMin: CGFloat = 140
    static let actionPad: CGFloat = 5
    /// Between a confirmation's button label and its cursor fill.
    static let choicePad: CGFloat = 6
    /// Lines a confirmation's question takes before it truncates.
    static let askLines = 2
    /// The limit-reset badge's height, and its width for one digit.
    static let badgeSize: CGFloat = 18
    /// Between the badge's digits and its ends once they outgrow the circle.
    static let badgePad: CGFloat = 5
    /// The focus ring's stroke, and its gap outside the badge.
    static let ringWidth: CGFloat = 2
    static let ringGap: CGFloat = 1.5
    /// Between a row's name line and its reservoir.
    static let lineGap: CGFloat = 5
    static let corner: CGFloat = 6
    static let eyebrowTop: CGFloat = 8
    static let eyebrowBottom: CGFloat = 4
    static let blockGap: CGFloat = 6
    static let noticeLines = 3

    // MARK: Reservoir

    static let barHeight: CGFloat = 4
    static let barGap: CGFloat = 3
    static let barRadius: CGFloat = 2
    static let fillTime = 0.35

    // MARK: Emphasis

    /// Row fill under the pointer or the keyboard cursor.
    static let hover = 0.10
    /// Row fill of the active account.
    static let current = 0.05

    private static func dynamic(light: UInt32, dark: UInt32) -> NSColor {
        NSColor(name: nil) { look in
            let isDark = look.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return rgb(isDark ? dark : light)
        }
    }

    private static func rgb(_ hex: UInt32) -> NSColor {
        let byte = CGFloat(UInt8.max)
        return NSColor(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / byte,
            green: CGFloat((hex >> 8) & 0xFF) / byte,
            blue: CGFloat(hex & 0xFF) / byte,
            alpha: 1)
    }
}
