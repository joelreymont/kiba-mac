import AppKit
import SwiftUI

/// Panel keyboard: ↑/↓ move the cursor, ⏎ activates, ⎋ backs out or closes.
/// An invisible AppKit view that takes first responder whenever the panel's
/// window becomes key, and reads keys through the standard key bindings.
struct KeyCatcher: NSViewRepresentable {
    let move: (Int) -> Void
    let activate: () -> Void
    let escape: () -> Void

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
    }
}

final class KeyView: NSView {
    var move: (Int) -> Void = { _ in }
    var activate: () -> Void = {}
    var escape: () -> Void = {}

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

    override func insertNewline(_ sender: Any?) {
        activate()
    }

    override func cancelOperation(_ sender: Any?) {
        escape()
    }
}
