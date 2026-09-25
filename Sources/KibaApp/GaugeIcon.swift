import AppKit

/// The menu bar icon: one thin vertical cell per provider, each with its own
/// geometry so no state rests on color: filled from the bottom to the current
/// account's headline room; outline only when unknown; a slash when nothing
/// usable is left; an exclamation mark on an error. A template image in the
/// menu bar's label color; `out` while an error is showing; half opacity
/// while the status is unavailable.
enum GaugeIcon {
    static let size = NSSize(width: 18, height: 18)
    private static let cellWidth: CGFloat = 6
    private static let cellHeight: CGFloat = 14
    private static let cellGap: CGFloat = 3
    private static let stroke: CGFloat = 1
    /// Clearance between the outline and what is drawn inside it.
    private static let clearance: CGFloat = 0.75
    private static let radius: CGFloat = 1.5
    private static let fillRadius: CGFloat = 0.5
    /// The share of the well the exclamation mark's bar takes; its dot is
    /// as tall as the well is wide.
    private static let barShare: CGFloat = 0.6
    private static let full: CGFloat = 100
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
            mark(cell, in: box)
            x += cellWidth + cellGap
        }
    }

    /// What a cell shows within its outline `box`: a strike across the whole
    /// cell, or a fill or mark inside the well the outline leaves.
    private static func mark(_ cell: Gauge.Cell, in box: NSRect) {
        let well = box.insetBy(dx: stroke + clearance, dy: stroke + clearance)
        switch cell {
        case .unknown:
            return
        case .level(let left):
            // At least a stroke, so a nearly spent account is not outline-only.
            let height = max(stroke, well.height * CGFloat(left) / full)
            let fill = NSRect(x: well.minX, y: well.minY, width: well.width, height: height)
            NSBezierPath(roundedRect: fill, xRadius: fillRadius, yRadius: fillRadius).fill()
        case .spent:
            let slash = NSBezierPath()
            slash.move(to: NSPoint(x: box.minX, y: box.minY))
            slash.line(to: NSPoint(x: box.maxX, y: box.maxY))
            slash.lineWidth = stroke
            slash.stroke()
        case .fault:
            let barHeight = well.height * barShare
            let bar = NSRect(x: well.minX, y: well.maxY - barHeight, width: well.width, height: barHeight)
            let dot = NSRect(x: well.minX, y: well.minY, width: well.width, height: well.width)
            NSBezierPath(roundedRect: bar, xRadius: fillRadius, yRadius: fillRadius).fill()
            NSBezierPath(ovalIn: dot).fill()
        }
    }
}
