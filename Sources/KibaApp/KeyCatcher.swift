import AppKit
import SwiftUI

/// Panel keyboard: ↑/↓ and ⇥/⇧⇥ move the cursor, ⏎ and Space activate,
/// ⌫ and ⌦ ask to forget the cursor's account, ⌘L logs it in again, ⎋
/// backs out or closes; any other key keeps AppKit's default. An invisible
/// AppKit view that takes first responder whenever the panel's window
/// becomes key and reads keys through the standard key bindings; ⌘L comes
/// as a key equivalent. Holding first responder is safe because the panel
/// has no text field or other control that reads keys, and the cursor
/// reaches every control a click can, so it replaces the key-view loop
/// rather than hiding a control from it.
struct KeyCatcher: NSViewRepresentable {
    let move: (Int) -> Void
    let activate: () -> Void
    let escape: () -> Void
    let forget: () -> Void
    let relogin: () -> Void

    func makeNSView(context: Context) -> KeyView {
        let v = KeyView()
        update(v)
        return v
    }

    func updateNSView(_ v: KeyView, context: Context) {
        update(v)
    }

    private func update(_ v: KeyView) {
        v.move = move
        v.activate = activate
        v.escape = escape
        v.forget = forget
        v.relogin = relogin
    }
}

final class KeyView: NSView {
    var move: (Int) -> Void = { _ in }
    var activate: () -> Void = {}
    var escape: () -> Void = {}
    var forget: () -> Void = {}
    var relogin: () -> Void = {}

    override var acceptsFirstResponder: Bool { true }

    /// Keys only: clicks always reach the rows above it.
    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func viewWillMove(toWindow next: NSWindow?) {
        NotificationCenter.default.removeObserver(self, name: NSWindow.didBecomeKeyNotification, object: window)
        super.viewWillMove(toWindow: next)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        NotificationCenter.default.addObserver(
            self, selector: #selector(windowBecameKey), name: NSWindow.didBecomeKeyNotification, object: window)
        if window.isKeyWindow { window.makeFirstResponder(self) }
    }

    @objc private func windowBecameKey(_ note: Notification) {
        window?.makeFirstResponder(self)
    }

    override func keyDown(with event: NSEvent) {
        interpretKeyEvents([event])
    }

    override func moveUp(_ sender: Any?) {
        move(-1)
    }

    override func moveDown(_ sender: Any?) {
        move(1)
    }

    override func insertTab(_ sender: Any?) {
        move(1)
    }

    override func insertBacktab(_ sender: Any?) {
        move(-1)
    }

    override func insertNewline(_ sender: Any?) {
        activate()
    }

    /// Space presses the cursor's control, as it presses a focused button;
    /// any other typed text keeps the default handling.
    override func insertText(_ text: Any) {
        guard text as? String == Key.space else {
            super.insertText(text)
            return
        }
        activate()
    }

    override func cancelOperation(_ sender: Any?) {
        escape()
    }

    override func deleteBackward(_ sender: Any?) {
        forget()
    }

    override func deleteForward(_ sender: Any?) {
        forget()
    }

    /// ⌘L arrives as a key equivalent, not through `keyDown`.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.modifierFlags.intersection(Key.modifiers) == .command,
              event.charactersIgnoringModifiers?.lowercased() == Key.relogin else {
            return super.performKeyEquivalent(with: event)
        }
        relogin()
        return true
    }

    private enum Key {
        static let space = " "
        static let relogin = "l"
        /// Caps Lock and the function key do not count against ⌘L.
        static let modifiers: NSEvent.ModifierFlags = [.command, .shift, .option, .control]
    }
}
