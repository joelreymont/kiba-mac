import AppKit
import KibaCore
import SwiftUI

/// The popover: which account has room, and how much. `menu` is the status
/// item's app menu, which the header's More control opens.
struct PanelView: View {
    let model: AppModel
    let menu: NSMenu

    var body: some View {
        CapHeight(limit: model.heightLimit) {
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    content
                }
                .scrollIndicators(.automatic)
                .scrollBounceBehavior(.basedOnSize)
                .onChange(of: model.scrollSerial) {
                    guard let k = model.scrollKey else { return }
                    proxy.scrollTo(k)
                }
            }
        }
        .frame(width: Theme.width)
        .background(Backdrop())
        .background(KeyCatcher(
            move: model.move, activate: model.activate, escape: model.escape, forget: model.forgetCursor))
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            notice
            if model.canRetry {
                ActionRow(model: model, key: .retry, label: Copy.retry)
                    .id(ActionKey.retry)
            }
            if !model.sections.isEmpty {
                rule
                ForEach(model.sections) { sec in
                    block(sec)
                }
                rule
                ActionRow(model: model, key: .usage, label: Copy.usage, detail: model.probeAge)
                    .id(ActionKey.usage)
            }
        }
        .padding(.vertical, Theme.pad)
        .padding(.horizontal, Theme.gutter)
    }

    /// The title with More at its right, as a section header carries its
    /// add, and the meta line under the title: beside the title and More it
    /// would lose its age to truncation.
    private var header: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Theme.gap) {
                Text(Copy.title)
                    .font(Theme.title)
                    .foregroundStyle(Theme.ink)
                Spacer(minLength: Theme.gap)
                MoreButton(model: model, menu: menu)
                    .id(ActionKey.menu)
            }
            Text(model.meta)
                .font(Theme.meta)
                .foregroundStyle(Theme.idle)
                .lineLimit(1)
        }
        .padding(.horizontal, Theme.inset)
        .padding(.bottom, Theme.blockGap)
    }

    /// The error in `out`, the held result in `ink` and the passing message
    /// in `idle`, each shown while it is set; Dismiss at the right while a
    /// result or an action error is held.
    @ViewBuilder private var notice: some View {
        if !(model.error.isEmpty && model.note.isEmpty && model.message.isEmpty) {
            HStack(alignment: .top, spacing: Theme.gap) {
                VStack(alignment: .leading, spacing: Theme.blockGap) {
                    noticeLine(model.error, color: Theme.out)
                    noticeLine(model.note, color: Theme.ink)
                    noticeLine(model.message, color: Theme.idle)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if model.canDismiss {
                    DismissButton(model: model)
                        .id(ActionKey.dismiss)
                }
            }
            .padding(.horizontal, Theme.inset)
            .padding(.bottom, Theme.blockGap)
        }
    }

    /// Shown whole, however many lines it holds: the panel scrolls.
    @ViewBuilder private func noticeLine(_ text: String, color: Color) -> some View {
        if !text.isEmpty {
            Text(text)
                .font(Theme.meta)
                .foregroundStyle(color)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var rule: some View {
        Divider()
            .padding(.horizontal, Theme.inset)
            .padding(.vertical, Theme.blockGap)
    }

    private func block(_ sec: Section) -> some View {
        let p = sec.id
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Theme.gap) {
                Text(p.title)
                    .font(Theme.section)
                    .foregroundStyle(Theme.ink)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: Theme.gap)
                AddButton(model: model, provider: p)
            }
            .padding(.horizontal, Theme.inset)
            .padding(.top, Theme.eyebrowTop)
            .padding(.bottom, Theme.eyebrowBottom)
            .id(ActionKey.add(p))
            if let e = sec.status.error {
                line(e, color: Theme.out)
            } else if sec.status.live == nil {
                line(Copy.loggedOut, color: Theme.idle)
            }
            ForEach(sec.accounts) { a in
                AccountRow(model: model, provider: p, account: a)
                    .id(ActionKey.use(p, a.name))
            }
            if sec.canSave {
                ActionRow(model: model, key: .save(p), label: Copy.save)
                    .id(ActionKey.save(p))
            }
        }
    }

    private func line(_ text: String, color: Color) -> some View {
        Text(text)
            .font(Theme.meta)
            .foregroundStyle(color)
            .lineLimit(Theme.statusLines)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, Theme.inset)
            .padding(.bottom, Theme.eyebrowBottom)
    }

    private enum Copy {
        static let title = "Room to work"
        static let retry = "Retry"
        static let usage = "Refresh usage"
        static let save = "Save the current login"
        static let loggedOut = "Not logged in"
    }
}

/// The plus at the right of a provider's header: the add action as a
/// standard accessory-bar button, tinted `accent` under the keyboard cursor,
/// named for its provider ("Add Codex account") wherever VoiceOver meets it.
private struct AddButton: View {
    let model: AppModel
    let provider: Provider

    private var key: ActionKey { .add(provider) }
    private var label: String { "\(Copy.add) \(provider.title) \(Copy.account)" }

    var body: some View {
        Button(label, systemImage: Symbol.plus) { model.trigger(key) }
            .labelStyle(.iconOnly)
            .buttonStyle(.accessoryBar)
            .foregroundStyle(model.cursor == key ? Theme.accent : Theme.idle)
            .disabled(model.busy)
            .help(label)
            .cursorTarget(model, key)
    }

    private enum Symbol {
        static let plus = "plus"
    }

    private enum Copy {
        static let add = "Add"
        static let account = "account"
    }
}

/// The cross beside a held notice: acknowledges it. It stays enabled while
/// an action runs, since it only clears what is shown.
private struct DismissButton: View {
    let model: AppModel

    var body: some View {
        Button(Copy.dismiss, systemImage: Symbol.cross) { model.trigger(.dismiss) }
            .labelStyle(.iconOnly)
            .buttonStyle(.accessoryBar)
            .foregroundStyle(model.cursor == .dismiss ? Theme.accent : Theme.idle)
            .help(Copy.dismiss)
            .cursorTarget(model, .dismiss)
    }

    private enum Symbol {
        static let cross = "xmark"
    }

    private enum Copy {
        static let dismiss = "Dismiss notice"
    }
}

/// The ellipsis ending the title line: pops the app menu (Refresh usage,
/// Start at login, Quit) up below itself, from a click or from ⏎ or Space on
/// the cursor. It stays enabled while an action runs: the menu enables its
/// own items.
private struct MoreButton: View {
    let model: AppModel
    let menu: NSMenu

    var body: some View {
        Button(Copy.more, systemImage: Symbol.more) { model.trigger(.menu) }
            .labelStyle(.iconOnly)
            .buttonStyle(.accessoryBar)
            .font(Theme.meta)
            .foregroundStyle(model.cursor == .menu ? Theme.accent : Theme.idle)
            .help(Copy.more)
            .accessibilityHint(Copy.hint)
            .background(MenuAnchor(model: model, menu: menu))
            .cursorTarget(model, .menu)
    }

    private enum Symbol {
        static let more = "ellipsis.circle"
    }

    private enum Copy {
        static let more = "More"
        static let hint = "Opens the app menu"
    }
}

/// Takes its content's height up to `limit`, then hands the content exactly
/// that height; the scroll view inside scrolls whatever is taller.
private struct CapHeight: Layout {
    let limit: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let v = subviews.first else { return .zero }
        let ideal = v.sizeThatFits(ProposedViewSize(width: proposal.width, height: nil))
        return CGSize(width: proposal.width ?? ideal.width, height: min(ideal.height, limit))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(bounds.size))
    }
}

/// The popover material behind the panel; a solid window background under
/// Reduce Transparency.
private struct Backdrop: View {
    @Environment(\.accessibilityReduceTransparency) private var solid

    var body: some View {
        if solid {
            Color(nsColor: .windowBackgroundColor)
        } else {
            Material()
        }
    }
}

private struct Material: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .popover
        v.blendingMode = .behindWindow
        v.state = .followsWindowActiveState
        return v
    }

    func updateNSView(_ v: NSVisualEffectView, context: Context) {}
}
