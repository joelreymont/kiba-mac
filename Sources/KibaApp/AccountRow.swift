import KibaCore
import SwiftUI

/// A saved account: name, plan, figures, its limit-reset badge while it
/// offers resets, and its reservoir below. No box: the row lights under the
/// pointer or the keyboard cursor, and faintly while it is the live login.
struct AccountRow: View {
    let model: AppModel
    let provider: Provider
    let account: Account

    @Environment(\.accessibilityDifferentiateWithoutColor) private var shapes

    private var key: ActionKey { .use(provider, account.name) }
    private var badgeKey: ActionKey { .redeem(provider, account.name) }
    /// Limit resets the row offers; the badge shows while there are any.
    private var offer: Int { Rows.resets(account.usage) }

    var body: some View {
        if let c = model.confirming, c.row == key {
            confirm(c).modifier(Slab(fill: fill))
        } else {
            row
        }
    }

    private var fill: Double {
        if model.cursor == key { return Theme.hover }
        return account.active ? Theme.current : 0
    }

    /// Dot, name, plan, figures and badge on one line; the name at its whole
    /// width, or asking `nameMin` and truncating past it.
    private func oneLine(_ usable: Bool?, _ red: Bool, wholeName: Bool) -> some View {
        HStack(spacing: Theme.gap) {
            dot(usable)
            if wholeName {
                name(red).fixedSize()
            } else {
                name(red).frame(idealWidth: Theme.nameMin, alignment: .leading)
            }
            plan(red)
            Spacer(minLength: Theme.gap)
            figures(Rows.figuresText(account.usage), red, wrap: false)
            badgeSpot
        }
    }

    private var row: some View {
        let state = Rows.state(account.usage, active: account.active)
        let usable = Rows.usable(state)
        let red = usable == false
        return Button {
            model.trigger(key)
        } label: {
            VStack(alignment: .leading, spacing: Theme.lineGap) {
                // One line while the name keeps its whole width, else while
                // it keeps `nameMin`, beside plan and figures; else plan and
                // labelled figures move to a line of their own under it.
                ViewThatFits(in: .horizontal) {
                    oneLine(usable, red, wholeName: true)
                    oneLine(usable, red, wholeName: false)
                    VStack(alignment: .leading, spacing: Theme.lineGap) {
                        HStack(spacing: Theme.gap) {
                            dot(usable)
                            name(red)
                        }
                        HStack(alignment: .firstTextBaseline, spacing: Theme.gap) {
                            plan(red)
                            Spacer(minLength: Theme.gap)
                            figures(labelled(state), red, wrap: true)
                            badgeSpot
                        }
                        .padding(.leading, Theme.dot + Theme.gap)
                    }
                }
                ReservoirView(figures: Rows.figures(account.usage), drained: red)
            }
            .modifier(Slab(fill: fill))
        }
        .buttonStyle(.plain)
        .disabled(model.busy)
        .help(Rows.tooltip(provider, account, now: model.now).joined(separator: "\n"))
        .contextMenu {
            Button("Forget…") { model.ask(.forget, provider, account.name) }
                .disabled(model.busy)
        }
        // The dot and the reservoir are drawn only; the label and value
        // carry what they show, window by window.
        .accessibilityElement(children: .combine)
        .accessibilityLabel(speechLabel)
        .accessibilityValue(speechValue(state))
        .accessibilityHint(speechHint(state))
        .cursorTarget(model, key)
        .overlayPreferenceValue(BadgeSpot.self) { spot in
            if let spot {
                GeometryReader { g in
                    let r = g[spot]
                    badge.position(x: r.midX, y: r.midY)
                }
            }
        }
    }

    private func name(_ red: Bool) -> some View {
        Text(account.name.raw)
            .font(account.active ? Theme.nameActive : Theme.name)
            .foregroundStyle(account.active ? Theme.accent : red ? Theme.idle : Theme.ink)
            .lineLimit(1)
            .truncationMode(.middle)
    }

    @ViewBuilder private func plan(_ red: Bool) -> some View {
        let text = Rows.planText(account, now: model.now)
        if !text.isEmpty {
            Text(text)
                .font(Theme.meta)
                .foregroundStyle(red ? Theme.out : Theme.idle)
                .lineLimit(1)
                .fixedSize()
        }
    }

    /// On the name line at their full width; under the name, as wide as the
    /// row allows, wrapping when they must.
    @ViewBuilder private func figures(_ text: String, _ red: Bool, wrap: Bool) -> some View {
        let t = Text(text)
            .font(Theme.figures)
            .foregroundStyle(red ? Theme.out : Theme.ink)
        if wrap {
            t.multilineTextAlignment(.trailing)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            t.lineLimit(1)
                .fixedSize()
        }
    }

    /// Keeps the badge's place without raising the line; the badge sits over
    /// the row, not in its button, so it stays a control of its own.
    @ViewBuilder private var badgeSpot: some View {
        if offer > 0 {
            Badge(count: offer)
                .hidden()
                .frame(height: 0)
                .anchorPreference(key: BadgeSpot.self, value: .bounds) { $0 }
        }
    }

    /// The figures with their windows' labels, for the line under the name;
    /// "limit" while blocked, as on one line.
    private func labelled(_ state: RowState) -> String {
        guard state != .blocked else { return Rows.figuresText(account.usage) }
        return Rows.figures(account.usage).map { "\($0.label) \($0.left)%" }.joined(separator: Copy.figureSep)
    }

    /// VoiceOver: provider, full name, and whether it is the current account.
    private var speechLabel: String {
        let who = "\(provider.title): \(account.name.raw)"
        return account.active ? who + Copy.sep + Copy.current : who
    }

    /// VoiceOver: plan, verdict, each window's allowance left, and the age
    /// of the numbers.
    private func speechValue(_ state: RowState) -> String {
        let u = account.usage
        var parts: [String] = []
        if !account.plan.isEmpty { parts.append(account.plan + Copy.planWord) }
        parts.append(verdict(state))
        parts += Rows.figures(u).map { "\($0.label): \(max($0.left, 0))\(Copy.left)" }
        if let at = u?.fetchedAt, at > 0 { parts.append(Copy.probed + Rows.age(at, now: model.now)) }
        return parts.joined(separator: Copy.sep)
    }

    /// What the status dot shows, in words: room, a limit and when it
    /// lifts, a login to repeat, or why the usage is unknown.
    private func verdict(_ state: RowState) -> String {
        let u = account.usage
        switch state {
        case .ok, .tight:
            return Copy.room
        case .blocked:
            let when = Rows.blocking(u).map { Rows.resetLong($0.resetsAt, now: model.now) } ?? ""
            return when.isEmpty ? Copy.limited : Copy.limited + Copy.sep + Copy.resetsIn + when
        case .dead:
            return Copy.relogin
        case .unknown:
            guard let u else { return Copy.unprobed }
            return u.note.isEmpty ? Copy.noLimits : u.note
        }
    }

    private func speechHint(_ state: RowState) -> String {
        if state == .dead { return Copy.loginHint }
        return account.active ? "" : "Switches \(provider.title) to this account"
    }

    /// The count of limit resets on offer; a click asks before spending one.
    /// Under the cursor it wears the keyboard focus ring, drawn inside the
    /// button's margin, which also widens its hit area to the ring.
    private var badge: some View {
        Button {
            model.trigger(badgeKey)
        } label: {
            Badge(count: offer)
                .padding(Theme.ringGap + Theme.ringWidth)
                .overlay {
                    if model.cursor == badgeKey {
                        Capsule().strokeBorder(Theme.focus, lineWidth: Theme.ringWidth)
                    }
                }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .disabled(model.busy)
        .help(Copy.badgeHelp(offer))
        .accessibilityLabel(Rows.resetsText(offer))
        .accessibilityHint(Copy.badgeHint)
        .cursorTarget(model, badgeKey, within: key)
        .id(badgeKey)
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
        static let reset = "Reset"
        static let keep = "Keep"
        static let badgeHint = "Uses one reset"
        static let figureSep = " · "
        static let sep = ", "
        static let current = "current account"
        static let planWord = " plan"
        static let room = "has room"
        static let limited = "limit reached"
        static let resetsIn = "resets in "
        static let relogin = "login required, log in again"
        static let unprobed = "usage not probed yet"
        static let noLimits = "no limits reported"
        static let left = "% left"
        static let probed = "probed "
        static let loginHint = "Logs in to this account again"

        static func forgetAsk(_ name: String) -> String {
            "Forget \(name)?"
        }

        static func resetAsk(_ name: String, _ n: Int) -> String {
            "Use a limit reset on \(name)? (\(n) left)"
        }

        static func badgeHelp(_ n: Int) -> String {
            "\(Rows.resetsText(n)) available. Click to use one."
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

    /// "Forget …? Forget / Keep" or "Use a limit reset on …? (2 left)
    /// Reset / Keep": each button is a cursor stop and carries the cursor
    /// fill while the cursor is on it.
    private func confirm(_ c: Choice) -> some View {
        let w = words(c.kind)
        return HStack(spacing: Theme.gap) {
            Text(w.ask)
                .font(Theme.name)
                .foregroundStyle(Theme.ink)
                .lineLimit(Theme.askLines)
                .truncationMode(.middle)
            Spacer(minLength: Theme.gap)
            choice(.confirm(provider, account.name), w.go, role: w.role)
                .fontWeight(.semibold)
                .foregroundStyle(w.tint)
                .disabled(model.busy)
            choice(.keep(provider, account.name), Copy.keep, role: nil)
                .foregroundStyle(Theme.accent)
        }
        .font(Theme.name)
        .buttonStyle(.borderless)
    }

    /// The question and the go button's label, role, and color: Forget is
    /// destructive, Reset spends a reset and is not.
    private func words(_ kind: Choice.Kind) -> (ask: String, go: String, role: ButtonRole?, tint: Color) {
        switch kind {
        case .forget: (Copy.forgetAsk(account.name.raw), Copy.forget, .destructive, Theme.out)
        case .reset: (Copy.resetAsk(account.name.raw, offer), Copy.reset, nil, Theme.accent)
        }
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

/// White digits on an accent capsule, a circle for one digit: the macOS
/// badge idiom. The digits carry it under Differentiate Without Color.
private struct Badge: View {
    let count: Int

    var body: some View {
        Text(count, format: .number)
            .font(Theme.badge)
            .foregroundStyle(Theme.onAccent)
            .padding(.horizontal, Theme.badgePad)
            .frame(minWidth: Theme.badgeSize, minHeight: Theme.badgeSize)
            .background(Capsule().fill(Theme.accent))
    }
}

/// Where the name line keeps the badge's place.
private struct BadgeSpot: PreferenceKey {
    static var defaultValue: Anchor<CGRect>? { nil }

    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        value = value ?? nextValue()
    }
}
