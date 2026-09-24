import SwiftUI

/// A flat command line ("Add account…") with the account rows' hover and
/// cursor fill. `key` nil marks a row outside the cursor's reach (Retry).
struct ActionRow: View {
    let model: AppModel
    let key: ActionKey?
    let label: String
    var detail = ""
    let perform: () -> Void

    @State private var hovered = false

    var body: some View {
        HStack(spacing: Theme.gap) {
            Text(label)
                .font(Theme.action)
                .foregroundStyle(model.busy ? Theme.idle : Theme.ink)
                .lineLimit(1)
            Spacer(minLength: Theme.gap)
            if !detail.isEmpty {
                Text(detail)
                    .font(Theme.meta)
                    .foregroundStyle(Theme.idle)
                    .lineLimit(1)
                    .fixedSize()
            }
        }
        .padding(.horizontal, Theme.inset)
        .padding(.vertical, Theme.actionPad)
        .background(
            RoundedRectangle(cornerRadius: Theme.corner)
                .fill(Theme.ink.opacity(lit ? Theme.hover : 0)))
        .contentShape(Rectangle())
        .onHover { inside in
            hovered = inside
            if inside, let key { model.point(key) }
        }
        .onTapGesture {
            if !model.busy { perform() }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }

    private var lit: Bool {
        guard let key else { return hovered }
        return model.cursor == key
    }
}
