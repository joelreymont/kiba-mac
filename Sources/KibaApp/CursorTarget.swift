import SwiftUI

/// A control the keyboard cursor rests on. The pointer moves the cursor to
/// it, and the control under the cursor is the accessibility focus: VoiceOver
/// follows the arrow keys, and the cursor follows VoiceOver.
private struct CursorTarget: ViewModifier {
    let model: AppModel
    let key: ActionKey
    /// The control this one sits on, which takes the cursor back when the
    /// pointer leaves this one, since entering it again is no new hover.
    let within: ActionKey?

    @AccessibilityFocusState private var focused: Bool

    func body(content: Content) -> some View {
        content
            .onHover { inside in
                if inside {
                    model.point(key)
                } else if let within, model.cursor == key {
                    model.point(within)
                }
            }
            .accessibilityFocused($focused)
            .onChange(of: model.cursor == key, initial: true) { _, on in
                if on { focused = true }
            }
            .onChange(of: focused) { _, on in
                if on { model.point(key) }
            }
    }
}

extension View {
    /// Makes this control the one `key` names for the cursor; `within` names
    /// the control it sits on.
    func cursorTarget(_ model: AppModel, _ key: ActionKey, within: ActionKey? = nil) -> some View {
        modifier(CursorTarget(model: model, key: key, within: within))
    }
}
