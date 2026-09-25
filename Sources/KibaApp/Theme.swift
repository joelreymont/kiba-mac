import AppKit
import KibaCore
import SwiftUI

/// Design tokens (DESIGN.md "Visual design"): colors that follow the
/// appearance, type, and the panel's measurements.
enum Theme {
    // MARK: Color

    /// Light values hold 3:1 against the track on the popover material; the
    /// red holds 4.5:1 as text on both appearances (Apple's contrast criteria).
    /// Under Increase Contrast each holds 7:1 against the window background
    /// and 3:1 against the raised track.
    static let roomNS = dynamic(
        light: rgb(0x1F7F52), dark: rgb(0x4FC08A), lightContrast: rgb(0x0F5132), darkContrast: rgb(0x6FD9A4))
    static let lowNS = dynamic(
        light: rgb(0x9E6A0E), dark: rgb(0xE2A93B), lightContrast: rgb(0x6B4700), darkContrast: rgb(0xF2C263))
    static let outNS = dynamic(
        light: rgb(0xB52F2F), dark: rgb(0xF07070), lightContrast: rgb(0x8F1F1F), darkContrast: rgb(0xFFAAAA))

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
    /// Empty reservoir, raised a step under Increase Contrast.
    static let track = Color(nsColor: dynamic(
        light: .quaternaryLabelColor, dark: .quaternaryLabelColor,
        lightContrast: .tertiaryLabelColor, darkContrast: .tertiaryLabelColor))
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

    /// System text styles, the HIG's type for Mac text: each size and weight
    /// is the style's macOS default, never a fixed point size.
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
    /// `screenInset` replaces it. Taller content scrolls.
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
    /// The name is laid out before the spacer, so it gets every point plan
    /// and figures leave, and gives way alone when that is not enough.
    static let nameFirst: Double = 1
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
    /// A provider's status line, its error or "Not logged in", wraps to
    /// at most this many lines.
    static let statusLines = 3

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

    /// The appearances a color resolves for: light, dark, and each under
    /// Increase Contrast.
    private static let looks: [NSAppearance.Name] = [
        .aqua, .darkAqua, .accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua,
    ]

    private static func dynamic(
        light: NSColor, dark: NSColor, lightContrast: NSColor, darkContrast: NSColor
    ) -> NSColor {
        NSColor(name: nil) { look in
            switch look.bestMatch(from: looks) {
            case .darkAqua?: dark
            case .accessibilityHighContrastAqua?: lightContrast
            case .accessibilityHighContrastDarkAqua?: darkContrast
            default: light
            }
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
