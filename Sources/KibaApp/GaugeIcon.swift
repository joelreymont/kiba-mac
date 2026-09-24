import AppKit

/// The menu bar icon: one thin vertical cell per provider, filled from the
/// bottom to the active account's headline room, outline only when unknown.
/// A template image in the menu bar's label color; `out` when an error is
/// showing; half opacity while the status is unavailable.
enum GaugeIcon {
    static let size = NSSize(width: 18, height: 18)
    private static let cellWidth: CGFloat = 6
    private static let cellHeight: CGFloat = 14
    private static let cellGap: CGFloat = 3
    private static let stroke: CGFloat = 1
    /// Clearance between the outline and the fill.
    private static let clearance: CGFloat = 0.75
    private static let radius: CGFloat = 1.5
    private static let fillRadius: CGFloat = 0.5
    private static let dimAlpha: CGFloat = 0.5
    private static let label = "AI accounts"

    static func image(_ g: Gauge) -> NSImage {
        let img = NSImage(size: size, flipped: false) { rect in
            draw(g, in: rect)
            return true
        }
        img.isTemplate = !g.alert
        img.accessibilityDescription = label
        return img
    }

    private static func draw(_ g: Gauge, in r: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.setAlpha(g.dim ? dimAlpha : 1)
        let ink: NSColor = g.alert ? Theme.outNS : .black
        ink.setStroke()
        ink.setFill()
        let n = CGFloat(g.cells.count)
        let total = n * cellWidth + max(n - 1, 0) * cellGap
        var x = r.midX - total / 2
        let y = r.midY - cellHeight / 2
        for cell in g.cells {
            let box = NSRect(x: x, y: y, width: cellWidth, height: cellHeight)
            let outline = NSBezierPath(
                roundedRect: box.insetBy(dx: stroke / 2, dy: stroke / 2), xRadius: radius, yRadius: radius)
            outline.lineWidth = stroke
            outline.stroke()
            if case .level(let f) = cell, f > 0 {
                let well = box.insetBy(dx: stroke + clearance, dy: stroke + clearance)
                let fill = NSRect(x: well.minX, y: well.minY, width: well.width, height: well.height * min(f, 1))
                NSBezierPath(roundedRect: fill, xRadius: fillRadius, yRadius: fillRadius).fill()
            }
            x += cellWidth + cellGap
        }
    }
}
