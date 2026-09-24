import AppKit
import KibaCore
import SwiftUI

/// Design tokens (DESIGN.md "Visual design"): colors that follow the
/// appearance, type, and the panel's measurements.
enum Theme {
    // MARK: Color

    static let roomNS = dynamic(light: 0x2E9E6B, dark: 0x4FC08A)
    static let lowNS = dynamic(light: 0xC98A1E, dark: 0xE2A93B)
    static let outNS = dynamic(light: 0xC93B3B, dark: 0xE25555)

    /// Figures of ok rows; reservoir segments with half or more left.
    static let room = Color(nsColor: roomNS)
    /// Figures of tight rows; reservoir segments under half.
    static let low = Color(nsColor: lowNS)
    /// Figures of blocked and dead rows, errors, the urgent icon.
    static let out = Color(nsColor: outNS)
    /// Figures of unknown rows, meta text.
    static let idle = Color(nsColor: .secondaryLabelColor)
    /// Names.
    static let ink = Color(nsColor: .labelColor)
    /// Empty reservoir.
    static let track = Color(nsColor: .quaternaryLabelColor)
    /// The active account's name.
    static let accent = Color.accentColor

    static func color(_ s: RowState) -> Color {
        switch s {
        case .ok: return room
        case .tight: return low
        case .blocked, .dead: return out
        case .unknown: return idle
        }
    }

    // MARK: Type

    /// New York: an editorial headline over a utility list.
    static let title = Font.system(size: 17, weight: .semibold, design: .serif)
    static let eyebrow = Font.system(size: 11, weight: .semibold)
    static let eyebrowTracking: CGFloat = 0.8
    /// The plus before "ADD ACCOUNT" in the eyebrow line.
    static let plus = Font.system(size: 9, weight: .bold)
    static let plusGap: CGFloat = 3
    static let name = Font.system(size: 13)
    static let nameActive = Font.system(size: 13, weight: .bold)
    static let meta = Font.system(size: 11)
    static let figures = Font.system(size: 11, weight: .semibold).monospacedDigit()
    static let action = Font.system(size: 13)

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
    static let actionPad: CGFloat = 5
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
