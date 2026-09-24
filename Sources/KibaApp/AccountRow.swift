import KibaCore
import SwiftUI

/// A saved account: name, plan, figures, and its reservoir below.
/// No box: the row lights under the pointer or the keyboard cursor, and
/// faintly while it is the live login.
struct AccountRow: View {
    let model: AppModel
    let provider: Provider
    let account: Account

    private var key: ActionKey { .use(provider, account.name) }

    var body: some View {
        Group {
            if model.forgetting == key {
                confirm
            } else {
                row
            }
        }
        .padding(.horizontal, Theme.inset)
        .padding(.vertical, Theme.rowPad)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Theme.corner)
                .fill(Theme.ink.opacity(fill)))
        .contentShape(Rectangle())
        .onHover { inside in
            if inside { model.point(key) }
        }
    }

    private var fill: Double {
        if model.cursor == key { return Theme.hover }
        return account.active ? Theme.current : 0
    }

    private var row: some View {
        let state = Rows.state(account.usage, active: account.active)
        let red = state == .blocked || state == .dead
        let plan = Rows.planText(account, now: model.now)
        return VStack(alignment: .leading, spacing: Theme.lineGap) {
            HStack(spacing: Theme.gap) {
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
                    .foregroundStyle(Theme.color(state))
                    .lineLimit(1)
                    .fixedSize()
            }
            ReservoirView(figures: Rows.figures(account.usage), drained: state == .dead)
        }
        .onTapGesture { model.trigger(key) }
        .help(Rows.tooltip(provider, account, now: model.now).joined(separator: "\n"))
        .contextMenu {
            Button("Forget…") { model.askForget(provider, account.name) }
                .disabled(model.busy)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(account.active ? [] : .isButton)
    }

    private var confirm: some View {
        HStack(spacing: Theme.gap) {
            Text("Forget \(account.name.raw)?")
                .font(Theme.name)
                .foregroundStyle(Theme.ink)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: Theme.gap)
            Button("Forget", role: .destructive) { model.forget(provider, account.name) }
                .fontWeight(.semibold)
                .foregroundStyle(Theme.out)
                .disabled(model.busy)
            Button("Keep") { model.keep() }
                .foregroundStyle(Theme.accent)
        }
        .font(Theme.name)
        .buttonStyle(.borderless)
    }
}
