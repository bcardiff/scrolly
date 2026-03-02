import AppKit
import ApplicationServices

/// Owns the NSStatusItem (menu-bar icon + menu) and coordinates between
/// WindowPicker and ScrollSyncManager.
final class StatusBarController {

    private let statusItem: NSStatusItem
    private let syncManager = ScrollSyncManager()
    private let picker = WindowPicker()
    private var isPickerActive = false

    private let idleImage: NSImage = {
        let img = NSImage(systemSymbolName: "arrow.up.and.down", accessibilityDescription: "Scrolly") ?? NSImage()
        img.isTemplate = true
        return img
    }()
    private let pickingImage: NSImage = {
        let img = NSImage(systemSymbolName: "cursorarrow.click", accessibilityDescription: "Scrolly — pick window") ?? NSImage()
        img.isTemplate = true
        return img
    }()

    // MARK: - Init

    init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = idleImage
        statusItem.button?.toolTip = "Scrolly"

        syncManager.onWindowsChanged = { [weak self] in
            self?.rebuildMenu()
        }

        setupPicker()
        rebuildMenu()
    }

    // MARK: - Picker wiring

    private func setupPicker() {
        picker.onWindowPicked = { [weak self] window in
            guard let self else { return }
            self.isPickerActive = false
            self.statusItem.button?.image = self.idleImage
            self.syncManager.addWindow(window)
            // addWindow → onWindowsChanged → rebuildMenu
        }

        picker.onCancelled = { [weak self] in
            guard let self else { return }
            self.isPickerActive = false
            self.statusItem.button?.image = self.idleImage
            self.rebuildMenu()
        }

        picker.onFailed = { [weak self] reason in
            guard let self else { return }
            self.isPickerActive = false
            self.statusItem.button?.image = self.idleImage
            self.rebuildMenu()
            self.showPickerFailureAlert(reason: reason)
        }
    }

    // MARK: - Menu construction

    private func rebuildMenu() {
        let menu = NSMenu()

        // -- Permission warning (shown when AX access is not granted) --
        if !AXIsProcessTrusted() {
            let permItem = NSMenuItem(
                title: "⚠ Grant Accessibility Access…",
                action: #selector(openAccessibilitySettings),
                keyEquivalent: ""
            )
            permItem.target = self
            menu.addItem(permItem)
            menu.addItem(.separator())
        }

        // -- Watch / Cancel item --
        let watchTitle = isPickerActive ? "Cancel Watching" : "Watch Next Clicked Window"
        let watchItem = NSMenuItem(title: watchTitle, action: #selector(togglePickerMode), keyEquivalent: "")
        watchItem.target = self
        menu.addItem(watchItem)

        // -- Watched windows --
        let windows = syncManager.watchedWindows
        if !windows.isEmpty {
            menu.addItem(.separator())
            for win in windows {
                let item = NSMenuItem(
                    title: win.menuLabel,
                    action: #selector(removeWatchedWindow(_:)),
                    keyEquivalent: ""
                )
                item.target = self
                item.representedObject = win
                item.toolTip = "Click to stop watching this window"
                menu.addItem(item)
            }
        }

        menu.addItem(.separator())

        // -- Quit --
        let quit = NSMenuItem(title: "Quit Scrolly", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)

        statusItem.menu = menu
    }

    // MARK: - Actions

    @objc private func togglePickerMode() {
        if isPickerActive {
            picker.stop()
            isPickerActive = false
            statusItem.button?.image = idleImage
            rebuildMenu()
        } else {
            isPickerActive = true
            statusItem.button?.image = pickingImage
            rebuildMenu()
            // Remove the menu so the picker's click tap doesn't receive the
            // menu-close click.
            statusItem.menu = nil
            picker.start()
            // Restore the menu. If picker.start() failed synchronously (e.g. no
            // permission), onFailed already called rebuildMenu(); doing it again
            // here is harmless.
            rebuildMenu()
        }
    }

    @objc private func removeWatchedWindow(_ sender: NSMenuItem) {
        guard let win = sender.representedObject as? WatchedWindow else { return }
        syncManager.removeWindow(win)
    }

    @objc private func openAccessibilitySettings() {
        showAccessibilityInstructions()
    }

    // MARK: - Alerts

    private func showAccessibilityInstructions() {
        let alert = NSAlert()
        alert.messageText = "Accessibility Permission Required"
        alert.informativeText = """
            Scrolly needs Accessibility access to monitor scroll events and identify windows.

            1. Open System Settings → Privacy & Security → Accessibility
            2. If Scrolly is not listed, click + and add it.
            3. If Scrolly is listed but not working, toggle it OFF then back ON.
            4. Relaunch Scrolly.

            Note: macOS revokes the permission each time the app binary is rebuilt, so step 3 may be needed after every rebuild.
            """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Later")

        if alert.runModal() == .alertFirstButtonReturn {
            openSystemSettings()
        }
    }

    private func showPickerFailureAlert(reason: String) {
        let alert = NSAlert()
        alert.messageText = "Could Not Watch Window"
        alert.informativeText = reason
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "OK")

        if alert.runModal() == .alertFirstButtonReturn {
            openSystemSettings()
        }
    }

    private func openSystemSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }
}
