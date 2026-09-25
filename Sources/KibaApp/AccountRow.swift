import KibaCore
import SwiftUI

/// A saved account: name, plan, figures, and its reservoir below.
/// No box: the row lights under the pointer or the keyboard cursor, and
/// faintly while it is the live login.
struct AccountRow: View {
    let model: AppModel
    let provider: Provider
    let account: Account

    @Environment(\.accessibilityDifferentiateWithoutColor) private var shapes

    private var key: ActionKey { .use(provider, account.name) }

    var body: some View {
        if model.forgetting == key {
            confirm.modifier(Slab(fill: fill))
        } else {
            row
        }
    }

    private var fill: Double {
        if model.cursor == key { return Theme.hover }
        return account.active ? Theme.current : 0
    }

    private var row: some View {
        let state = Rows.state(account.usage, active: account.active)
        let usable = Rows.usable(state)
        let red = usable == false
        let plan = Rows.planText(account, now: model.now)
        return Button {
            model.trigger(key)
        } label: {
            VStack(alignment: .leading, spacing: Theme.lineGap) {
                HStack(spacing: Theme.gap) {
                    dot(usable)
                    Text(account.name.raw)
                        .font(account.active ? Theme.nameActive : Theme.name)
                        .foregroundStyle(account.active ? Theme.accent : red ? Theme.idle : Theme.ink)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if !plan.isEmpty {
                        Text(plan)
                            .font(Theme.meta)
                            .foregroundStyle(red ? Theme.out : Theme.idle)
                            .lineLimit(1)
                            .fixedSize()
                    }
                    Spacer(minLength: Theme.gap)
                    Text(Rows.figuresText(account.usage))
                        .font(Theme.figures)
                        .foregroundStyle(red ? Theme.out : Theme.ink)
                        .lineLimit(1)
                        .fixedSize()
                }
                ReservoirView(figures: Rows.figures(account.usage), drained: red)
            }
            .modifier(Slab(fill: fill))
        }
        .buttonStyle(.plain)
        .disabled(model.busy)
        .help(Rows.tooltip(provider, account, now: model.now).joined(separator: "\n"))
        .contextMenu {
            Button("Forget…") { model.askForget(provider, account.name) }
                .disabled(model.busy)
        }
        .accessibilityElement(children: .combine)
        .cursorTarget(model, key)
    }

    /// Green: the account can take work; red: limited or logged out; grey:
    /// not probed yet. Under Differentiate Without Color the dot becomes a
    /// check, a cross, or a question mark.
    private func dot(_ usable: Bool?) -> some View {
        Group {
            if shapes {
                Image(systemName: Symbol.dot(usable))
                    .font(Theme.meta.bold())
            } else {
                Circle()
            }
        }
        .foregroundStyle(Theme.dot(usable))
        .frame(width: Theme.dot, height: Theme.dot)
        .accessibilityLabel(Copy.dot(usable))
    }

    private enum Symbol {
        static func dot(_ usable: Bool?) -> String {
            switch usable {
            case true?: return "checkmark.circle.fill"
            case false?: return "xmark.circle.fill"
            case nil: return "questionmark.circle.fill"
            }
        }
    }

    private enum Copy {
        static let forget = "Forget"
        static let keep = "Keep"

        static func dot(_ usable: Bool?) -> String {
            switch usable {
            case true?: return "has room"
            case false?: return "limited"
            case nil: return "not probed"
            }
        }
    }

    /// The row's padding, full width, highlight and hit shape, applied inside
    /// the button so every lit point activates it.
    private struct Slab: ViewModifier {
        let fill: Double

        func body(content: Content) -> some View {
            content
                .padding(.horizontal, Theme.inset)
                .padding(.vertical, Theme.rowPad)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: Theme.corner)
                        .fill(Theme.ink.opacity(fill)))
                .contentShape(Rectangle())
        }
    }

    /// "Forget …? Forget / Keep": each button is a cursor stop and carries
    /// the cursor fill while the cursor is on it.
    private var confirm: some View {
        HStack(spacing: Theme.gap) {
            Text("Forget \(account.name.raw)?")
                .font(Theme.name)
                .foregroundStyle(Theme.ink)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: Theme.gap)
            choice(.forget(provider, account.name), Copy.forget, role: .destructive)
                .fontWeight(.semibold)
                .foregroundStyle(Theme.out)
                .disabled(model.busy)
            choice(.keep(provider, account.name), Copy.keep, role: nil)
                .foregroundStyle(Theme.accent)
        }
        .font(Theme.name)
        .buttonStyle(.borderless)
    }

    private func choice(_ k: ActionKey, _ label: String, role: ButtonRole?) -> some View {
        Button(role: role) {
            model.trigger(k)
        } label: {
            Text(label)
                .padding(.horizontal, Theme.choicePad)
                .background(
                    RoundedRectangle(cornerRadius: Theme.corner)
                        .fill(Theme.ink.opacity(model.cursor == k ? Theme.hover : 0)))
        }
        .cursorTarget(model, k)
        .id(k)
    }
}
