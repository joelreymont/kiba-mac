import KibaCore
import SwiftUI

/// The signature: a 4 pt bar under an account row, one segment per figure,
/// each filled from the left to the share of its window left and colored
/// by its own level; a spent window is a red track. A drained bar shows
/// every window as an empty grey track, and a row with no figures yet shows
/// the two windows every provider reports, session and week, as empty tracks.
struct ReservoirView: View {
    let figures: [Figure]
    let drained: Bool

    @Environment(\.accessibilityReduceMotion) private var still

    var body: some View {
        HStack(spacing: Theme.barGap) {
            if figures.isEmpty {
                ForEach(0 ..< Self.unknownSegments, id: \.self) { _ in track(Theme.track) }
            }
            ForEach(Array(figures.enumerated()), id: \.offset) { _, f in
                Level(fraction: drained ? 0 : Self.fraction(f))
                    .fill(Rows.isLow(f) ? Theme.low : Theme.room)
                    .background(track(!drained && Rows.isSpent(f) ? Theme.out : Theme.track))
            }
        }
        .frame(height: Theme.barHeight)
        .animation(still ? nil : .easeOut(duration: Theme.fillTime), value: figures)
        .accessibilityHidden(true)
    }

    private func track(_ color: Color) -> some View {
        RoundedRectangle(cornerRadius: Theme.barRadius).fill(color)
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

    func path(in r: CGRect) -> Path {
        let w = r.width * fraction
        guard w > 0 else { return Path() }
        let bar = CGRect(x: r.minX, y: r.minY, width: w, height: r.height)
        return Path(roundedRect: bar, cornerRadius: min(Theme.barRadius, w / 2))
    }
}
