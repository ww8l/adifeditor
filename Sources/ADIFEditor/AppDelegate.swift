import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.activate(ignoringOtherApps: true)
    }

    /// No blank-document story: this is an editor for files loggers produced, not a
    /// logger (§3), so an empty grid would be a window with nothing to do. Launching
    /// with no file offers the Open panel instead.
    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationOpenUntitledFile(_ sender: NSApplication) -> Bool {
        NSDocumentController.shared.openDocument(nil)
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// Settings lives on the delegate rather than on a window: the QRZ credentials and
    /// the POTA program-field switch are the app's, not any one log's, and they have to be
    /// reachable with no document open.
    @MainActor @objc func showPreferences(_ sender: Any?) {
        PreferencesWindowController.shared.showWindow(sender)
    }
}
