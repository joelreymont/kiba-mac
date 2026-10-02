import KibaCore
import SwiftUI

/// The signature: a 4 pt bar under an account row showing the usable limit
/// left, one segment per window, each filled from the left to the share of
/// its window left and colored by its own level, on a grey track; a used-up
/// window is an empty track. A drained bar (`Rows.drained`: the login is
/// dead or has no plan) shows every window as an empty track, and a row
/// with no figures yet shows the two windows
/// every provider reports, session and week, as empty tracks.
struct ReservoirView: View {
    let figures: [Figure]
    let drained: Bool

    @Environment(\.accessibilityReduceMotion) private var still

    var body: some View {
        HStack(spacing: Theme.barGap) {
            if figures.isEmpty {
                ForEach(0 ..< Self.unknownSegments, id: \.self) { _ in track }
            }
            ForEach(Array(figures.enumerated()), id: \.offset) { _, f in
                Level(fraction: drained ? 0 : Self.fraction(f))
                    .fill(Rows.isLow(f) ? Theme.low : Theme.room)
                    .background(track)
            }
        }
        .frame(height: Theme.barHeight)
        .animation(still ? nil : .easeOut(duration: Theme.fillTime), value: figures)
        .accessibilityHidden(true)
    }

    private var track: some View {
        RoundedRectangle(cornerRadius: Theme.barRadius).fill(Theme.track)
    }

    /// Session and week: the windows every provider reports.
    private static let unknownSegments = 2
    private static let whole = 100.0

    private static func fraction(_ f: Figure) -> Double {
        min(max(Double(f.left) / whole, 0), 1)
    }
}

/// The filled part of one segment; animatable so a fill glides to its new level.
private struct Level: Shape {
    var fraction: Double

    var animatableData: Double {
        get { fraction }
        set { fraction = newValue }
    }

    /// A remainder too thin to see still shows a sliver as wide as the bar
    /// is tall: what is left is never drawn as nothing.
    func path(in r: CGRect) -> Path {
        guard fraction > 0 else { return Path() }
        let w = max(r.width * fraction, r.height)
        let bar = CGRect(x: r.minX, y: r.minY, width: w, height: r.height)
        return Path(roundedRect: bar, cornerRadius: min(Theme.barRadius, w / 2))
    }
}
