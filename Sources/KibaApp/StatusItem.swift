import AppKit
import ServiceManagement
import SwiftUI

/// The menu bar item: left click toggles the panel popover, right click (or
/// control-click) shows the app menu. The panel's More control opens the
/// same menu for the pointer, the keyboard and VoiceOver; VoiceOver also
/// reaches it through the item's Show Menu action.
@MainActor
final class StatusItem: NSObject, NSPopoverDelegate, NSMenuDelegate {
    private let model: AppModel
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let popover = NSPopover()
    private let menu = NSMenu()
    private let usageItem = NSMenuItem(title: Copy.usage, action: #selector(probe), keyEquivalent: "")
    private let loginItem = NSMenuItem(title: Copy.login, action: #selector(toggleLogin), keyEquivalent: "")
    private var drawn: Gauge?

    init(model: AppModel) {
        self.model = model
        super.init()
        let host = NSHostingController(rootView: PanelView(model: model, menu: menu))
        host.sizingOptions = .preferredContentSize
        popover.contentViewController = host
        popover.behavior = .transient
        popover.delegate = self

        let quit = NSMenuItem(title: Copy.quit, action: #selector(quit), keyEquivalent: "q")
        for m in [usageItem, loginItem, quit] { m.target = self }
        menu.items = [usageItem, loginItem, .separator(), quit]
        menu.autoenablesItems = false
        menu.delegate = self

        guard let button = item.button else {
            preconditionFailure("NSStatusBar made a status item without a button")
        }
        button.imagePosition = .imageOnly
        button.target = self
        button.action = #selector(click(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        // The action returns before the menu tracks, so the assistive app
        // that asked is not held while the menu stays open.
        button.setAccessibilityCustomActions([
            NSAccessibilityCustomAction(name: Copy.showMenu) { [weak self] in
                Task { @MainActor in self?.showMenu() }
                return true
            },
        ])

        model.closePanel = { [weak self] in self?.popover.performClose(nil) }
        model.announce = { text in
            NSAccessibility.post(
                element: NSApp as Any, notification: .announcementRequested,
                userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.high.rawValue])
        }
        track()
    }

    // MARK: Icon

    /// Redraws the icon, its tooltip and its accessibility value whenever
    /// what they show changes.
    private func track() {
        withObservationTracking {
            render()
        } onChange: { [weak self] in
            Task { @MainActor in self?.track() }
        }
    }

    private func render() {
        let g = model.gauge
        if g != drawn {
            item.button?.image = GaugeIcon.image(g)
            drawn = g
        }
        item.button?.toolTip = model.iconTip
        item.button?.setAccessibilityValue(model.iconValue)
    }

    // MARK: Clicks

    /// Only a mouse click can be a right or control-click: a press from the
    /// keyboard or VoiceOver (whose keys hold Control) toggles the panel.
    @objc private func click(_ sender: NSStatusBarButton) {
        guard let e = NSApp.currentEvent else { return toggle(sender) }
        let control = e.type == .leftMouseUp && e.modifierFlags.contains(.control)
        if e.type == .rightMouseUp || control {
            showMenu()
        } else {
            toggle(sender)
        }
    }

    private func toggle(_ button: NSStatusBarButton) {
        if popover.isShown {
            popover.performClose(nil)
            return
        }
        NSApp.activate()
        if let screen = button.window?.screen ?? NSScreen.main {
            model.fit(height: screen.visibleFrame.height - Theme.screenInset)
        }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    /// Attaching the menu only for this click keeps left click free for the
    /// popover; `performClick` tracks the menu until it closes.
    private func showMenu() {
        if popover.isShown { popover.performClose(nil) }
        item.menu = menu
        item.button?.performClick(nil)
        item.menu = nil
    }

    // MARK: NSPopoverDelegate

    func popoverWillShow(_ note: Notification) {
        item.button?.highlight(true)
        model.opened()
    }

    func popoverWillClose(_ note: Notification) {
        item.button?.highlight(false)
        model.closed()
    }

    /// A press on the status item itself is left to `toggle`, so it closes
    /// the popover instead of closing and reopening it.
    func popoverShouldClose(_ popover: NSPopover) -> Bool {
        guard let e = NSApp.currentEvent, e.type == .leftMouseDown,
              let w = item.button?.window else { return true }
        return e.window !== w
    }

    // MARK: NSMenuDelegate

    /// Start at login shows on when registered, mixed and titled as
    /// waiting while macOS needs the user's approval, else off.
    func menuWillOpen(_ menu: NSMenu) {
        usageItem.isEnabled = model.availability == .ready && !model.busy
        let status = SMAppService.mainApp.status
        loginItem.title = status == .requiresApproval ? Copy.loginApproval : Copy.login
        switch status {
        case .enabled: loginItem.state = .on
        case .requiresApproval: loginItem.state = .mixed
        case .notRegistered, .notFound: loginItem.state = .off
        @unknown default: loginItem.state = .off
        }
    }

    // MARK: Menu actions

    @objc private func probe() {
        model.probeUsage()
    }

    /// Registered: unregister. Not registered, or not found (macOS has no
    /// record of the bundle before its first registration): register, then
    /// open Login Items when macOS asks the user to approve it. Waiting for
    /// approval: open Login Items.
    @objc private func toggleLogin() {
        let app = SMAppService.mainApp
        switch app.status {
        case .enabled:
            do {
                try app.unregister()
            } catch {
                model.report(.loginItem(error.localizedDescription))
            }
        case .notRegistered, .notFound:
            do {
                try app.register()
            } catch {
                model.report(.loginItem(error.localizedDescription))
            }
            if app.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
        case .requiresApproval:
            SMAppService.openSystemSettingsLoginItems()
        @unknown default:
            model.report(.loginItem(Copy.unknownStatus))
        }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    private enum Copy {
        static let usage = "Refresh usage"
        static let login = "Start at login"
        static let loginApproval = "Start at login (needs approval in Login Items)"
        static let quit = "Quit"
        static let showMenu = "Show Menu"
        static let unknownStatus = "macOS reports a login item status Kiba does not know"
    }
}
