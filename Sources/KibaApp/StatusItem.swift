import AppKit
import ServiceManagement
import SwiftUI

/// The menu bar item: left click toggles the panel popover, right click (or
/// control-click) shows the app menu.
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
        let host = NSHostingController(rootView: PanelView(model: model))
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

        model.closePanel = { [weak self] in self?.popover.performClose(nil) }
        track()
    }

    // MARK: Icon

    /// Redraws the icon and its tooltip whenever what they show changes.
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
    }

    // MARK: Clicks

    @objc private func click(_ sender: NSStatusBarButton) {
        guard let e = NSApp.currentEvent else { return toggle(sender) }
        if e.type == .rightMouseUp || e.modifierFlags.contains(.control) {
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

    func menuWillOpen(_ menu: NSMenu) {
        usageItem.isEnabled = model.availability == .ready && !model.busy
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
    }

    // MARK: Menu actions

    @objc private func probe() {
        model.probeUsage()
    }

    @objc private func toggleLogin() {
        let app = SMAppService.mainApp
        do {
            switch app.status {
            case .enabled: try app.unregister()
            case .requiresApproval: break
            default: try app.register()
            }
        } catch {
            model.report("Start at login: \(error.localizedDescription)")
            return
        }
        if app.status == .requiresApproval {
            model.say(Copy.approve)
            SMAppService.openSystemSettingsLoginItems()
        }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    private enum Copy {
        static let usage = "Refresh usage"
        static let login = "Start at login"
        static let quit = "Quit"
        static let approve = "Allow Kiba under Login Items in System Settings to start it at login"
    }
}
