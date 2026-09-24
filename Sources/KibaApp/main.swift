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

/// `KIBA_FIXTURE=<snapshot.json>` runs the app on a fixture instead of the store.
private let fixtureVar = "KIBA_FIXTURE"

private let connect: Connect = {
    guard let path = ProcessInfo.processInfo.environment[fixtureVar], !path.isEmpty else {
        return { EmptyBackend() }
    }
    let file = URL(fileURLWithPath: path)
    return { () throws(KibaError) -> any Backend in try FixtureBackend(file: file) }
}()

let app = NSApplication.shared
let delegate = AppDelegate(connect: connect)
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
