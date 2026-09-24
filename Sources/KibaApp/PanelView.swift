import AppKit
import KibaCore
import SwiftUI

/// The popover: which account has room, and how much.
struct PanelView: View {
    let model: AppModel

    var body: some View {
        CapHeight(limit: model.heightLimit) {
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    content
                }
                .scrollIndicators(.hidden)
                .scrollBounceBehavior(.basedOnSize)
                .onChange(of: model.scrollSerial) {
                    guard let k = model.scrollKey else { return }
                    proxy.scrollTo(k)
                }
            }
        }
        .frame(width: Theme.width)
        .background(Backdrop())
        .background(KeyCatcher(move: model.move, activate: model.activate, escape: model.escape))
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            notice
            if case .failed = model.availability, !model.refreshing {
                ActionRow(model: model, key: nil, label: Copy.retry) { model.refresh(force: true) }
            }
            if !model.sections.isEmpty {
                rule
                ForEach(model.sections) { sec in
                    block(sec)
                }
                rule
                ActionRow(model: model, key: .usage, label: Copy.usage, detail: model.usageAge) {
                    model.trigger(.usage)
                }
                .id(ActionKey.usage)
            }
        }
        .padding(.vertical, Theme.pad)
        .padding(.horizontal, Theme.gutter)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.gap) {
            Text(Copy.title)
                .font(Theme.title)
                .foregroundStyle(Theme.ink)
            Spacer(minLength: Theme.gap)
            Text(model.meta)
                .font(Theme.meta)
                .foregroundStyle(Theme.idle)
                .lineLimit(1)
        }
        .padding(.horizontal, Theme.inset)
        .padding(.bottom, Theme.blockGap)
    }

    /// The action error in `out` and the passing message in `idle`, each
    /// shown while it is set.
    @ViewBuilder private var notice: some View {
        noticeLine(model.error, color: Theme.out)
        noticeLine(model.message, color: Theme.idle)
    }

    @ViewBuilder private func noticeLine(_ text: String, color: Color) -> some View {
        if !text.isEmpty {
            Text(text)
                .font(Theme.meta)
                .foregroundStyle(color)
                .lineLimit(Theme.noticeLines)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, Theme.inset)
                .padding(.bottom, Theme.blockGap)
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
                Text(p.title.uppercased())
                    .font(Theme.eyebrow)
                    .tracking(Theme.eyebrowTracking)
                    .foregroundStyle(Theme.idle)
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
                ActionRow(model: model, key: .save(p), label: Copy.save) { model.trigger(.save(p)) }
                    .id(ActionKey.save(p))
            }
        }
    }

    private func line(_ text: String, color: Color) -> some View {
        Text(text)
            .font(Theme.meta)
            .foregroundStyle(color)
            .lineLimit(Theme.noticeLines)
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

/// Takes its content's height up to `limit`, then hands the content exactly
/// that height; the scroll view inside scrolls whatever is taller.
/// "+ ADD ACCOUNT" at the right of a provider's eyebrow line: the add action,
/// lit in `accent` under the pointer or the keyboard cursor.
private struct AddButton: View {
    let model: AppModel
    let provider: Provider

    private var key: ActionKey { .add(provider) }

    var body: some View {
        HStack(spacing: Theme.plusGap) {
            Image(systemName: Symbol.plus)
                .font(Theme.plus)
            Text(Copy.add)
                .font(Theme.eyebrow)
                .tracking(Theme.eyebrowTracking)
        }
        .foregroundStyle(model.cursor == key ? Theme.accent : Theme.idle)
        .contentShape(Rectangle())
        .onHover { inside in
            if inside { model.point(key) }
        }
        .onTapGesture { model.trigger(key) }
        .help(Copy.addHelp)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }

    private enum Symbol {
        static let plus = "plus"
    }

    private enum Copy {
        static let add = "ADD ACCOUNT"
        static let addHelp = "Log in to another account in Terminal and save it"
    }
}

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

/// The popover material behind the panel.
private struct Backdrop: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .popover
        v.blendingMode = .behindWindow
        v.state = .followsWindowActiveState
        return v
    }

    func updateNSView(_ v: NSVisualEffectView, context: Context) {}
}
