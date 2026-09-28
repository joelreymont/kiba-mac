import AppKit
import SwiftUI

/// Where the app menu drops from in the panel: an invisible AppKit view
/// behind the header's More control, which installs `AppModel.showMenu` to
/// pop `menu` up below the control, left edges aligned. The status item
/// keeps the menu and its delegate, so it enables its items as it does on a
/// right click.
struct MenuAnchor: NSViewRepresentable {
    let model: AppModel
    let menu: NSMenu

    func makeNSView(context: Context) -> AnchorView {
        let v = AnchorView()
        update(v)
        return v
    }

    func updateNSView(_ v: AnchorView, context: Context) {
        update(v)
    }

    private func update(_ v: AnchorView) {
        model.showMenu = { [weak v, menu] in v?.drop(menu) }
    }
}

final class AnchorView: NSView {
    /// Clicks reach the button above it.
    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    /// Opens on the next turn of the main loop, so the click, key or
    /// VoiceOver press that asked returns before the menu tracks. The menu's
    /// top left meets this view's bottom left, y 0 in its unflipped bounds.
    func drop(_ menu: NSMenu) {
        Task { @MainActor [weak self] in
            guard let self, window != nil else { return }
            menu.popUp(positioning: nil, at: NSPoint(x: bounds.minX, y: bounds.minY), in: self)
        }
    }
}
