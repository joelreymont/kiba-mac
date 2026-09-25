import SwiftUI

/// A flat command line ("Save the current login", "Retry") with the account
/// rows' cursor fill; it runs the action its `key` names.
struct ActionRow: View {
    let model: AppModel
    let key: ActionKey
    let label: String
    var detail = ""

    var body: some View {
        Button {
            model.trigger(key)
        } label: {
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
                    .fill(Theme.ink.opacity(model.cursor == key ? Theme.hover : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(model.busy)
        .accessibilityElement(children: .combine)
        .cursorTarget(model, key)
    }
}
