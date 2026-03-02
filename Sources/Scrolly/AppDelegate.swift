import AppKit
import ApplicationServices

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusBarController: StatusBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Permission state is surfaced through the status-bar menu.
        // We do NOT call AXIsProcessTrustedWithOptions(prompt:true) here because:
        //   • Each rebuild produces a new binary signature; macOS treats it as a
        //     new app and invalidates the previous permission entry.
        //   • Prompting unconditionally on every launch confuses users who have
        //     already granted access (it just shows "enable in Settings" again).
        // Instead, the menu shows a clear action item when permission is missing,
        // and the WindowPicker surfaces an actionable error when it actually fails.
        statusBarController = StatusBarController()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ app: NSApplication) -> Bool {
        return false
    }
}
