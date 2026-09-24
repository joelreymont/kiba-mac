import AppKit
import KibaCore

/// Owns the model and the menu bar item for the life of the app.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let connect: Connect
    private var item: StatusItem?

    init(connect: @escaping Connect) {
        self.connect = connect
    }

    func applicationDidFinishLaunching(_ note: Notification) {
        let model = AppModel(connect: connect)
        item = StatusItem(model: model)
        model.start()
    }
}

private let connect: Connect = {
    try CoreBackend(env: ProcessInfo.processInfo.environment, username: NSUserName())
}

let app = NSApplication.shared
let delegate = AppDelegate(connect: connect)
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
