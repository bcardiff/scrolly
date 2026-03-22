import AppKit
import ApplicationServices

/// Owns the NSStatusItem (menu-bar icon + menu) and coordinates between
/// WindowPicker and ScrollSyncManager.
final class StatusBarController: NSObject, NSMenuDelegate {

    private static let quitItemTag = 1

    private let statusItem: NSStatusItem
    private let syncManager = ScrollSyncManager()
    private let picker = WindowPicker()
    private var isPickerActive = false
    private var flagsTimer: Timer?

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

    override init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()

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

            let restartItem = NSMenuItem(
                title: "Restart Scrolly",
                action: #selector(restartScrolly),
                keyEquivalent: ""
            )
            restartItem.target = self
            menu.addItem(restartItem)
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

        // -- About --
        let about = NSMenuItem(title: "About Scrolly", action: #selector(showAbout), keyEquivalent: "")
        about.target = self
        menu.addItem(about)

        // -- Page Based Scroll toggle --
        let pageBasedItem = NSMenuItem(
            title: "Page Based Scroll",
            action: #selector(togglePageBasedScroll),
            keyEquivalent: ""
        )
        pageBasedItem.target = self
        pageBasedItem.state = syncManager.pageBasedScroll ? .on : .off
        menu.addItem(pageBasedItem)

        // -- Quit / Restart (toggled live via flagsChanged monitor in menuWillOpen) --
        let quit = NSMenuItem(title: "Quit Scrolly", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
        quit.tag = StatusBarController.quitItemTag
        menu.addItem(quit)

        if AXIsProcessTrusted() {
            let restart = NSMenuItem(title: "Restart Scrolly", action: #selector(restartScrolly), keyEquivalent: "")
            restart.tag = StatusBarController.quitItemTag + 1
            restart.target = self
            restart.isHidden = true
            menu.addItem(restart)
        }

        menu.delegate = self
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

    @objc private func restartScrolly() {
        // Spawn a shell that waits for this process to exit, then reopens the app.
        let path = Bundle.main.bundleURL.path
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "sleep 0.5; open '\(path)'"]
        try? task.run()
        NSApp.terminate(nil)
    }

    @objc private func showAbout() {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let alert = NSAlert()
        alert.messageText = "Scrolly \(version)"
        alert.informativeText = "Synchronises vertical scroll across two or more windows.\n\nhttps://github.com/bcardiff/scrolly"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "GitHub →")
        alert.addButton(withTitle: "OK")
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(URL(string: "https://github.com/bcardiff/scrolly")!)
        }
    }

    @objc private func togglePageBasedScroll() {
        syncManager.pageBasedScroll.toggle()
        rebuildMenu()
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

    // MARK: - NSMenuDelegate

    func menuWillOpen(_ menu: NSMenu) {
        updateQuitRestart(in: menu, optionHeld: NSEvent.modifierFlags.contains(.option))
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self, weak menu] _ in
            guard let self, let menu else { return }
            self.updateQuitRestart(in: menu, optionHeld: NSEvent.modifierFlags.contains(.option))
        }
        RunLoop.main.add(timer, forMode: .common)
        flagsTimer = timer
    }

    func menuDidClose(_ menu: NSMenu) {
        flagsTimer?.invalidate()
        flagsTimer = nil
    }

    private func updateQuitRestart(in menu: NSMenu, optionHeld: Bool) {
        let swap = optionHeld && AXIsProcessTrusted()
        menu.item(withTag: StatusBarController.quitItemTag)?.isHidden = swap
        menu.item(withTag: StatusBarController.quitItemTag + 1)?.isHidden = !swap
    }
}
