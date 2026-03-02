import AppKit

/// Owns the NSStatusItem (menu-bar icon + menu) and coordinates between
/// WindowPicker and ScrollSyncManager.
final class StatusBarController {

    private let statusItem: NSStatusItem
    private let syncManager = ScrollSyncManager()
    private let picker = WindowPicker()
    private var isPickerActive = false

    // Stable icon images
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
            // addWindow calls onWindowsChanged → rebuildMenu
        }
        picker.onCancelled = { [weak self] in
            guard let self else { return }
            self.isPickerActive = false
            self.statusItem.button?.image = self.idleImage
            self.rebuildMenu()
        }
    }

    // MARK: - Menu construction

    private func rebuildMenu() {
        let menu = NSMenu()

        // -- Watch / Cancel item --
        let watchItem = NSMenuItem()
        if isPickerActive {
            watchItem.title = "Cancel Watching"
            watchItem.action = #selector(togglePickerMode)
            watchItem.target = self
        } else {
            watchItem.title = "Watch Next Clicked Window"
            watchItem.action = #selector(togglePickerMode)
            watchItem.target = self
        }
        menu.addItem(watchItem)

        // -- Watched windows --
        let windows = syncManager.watchedWindows
        if !windows.isEmpty {
            menu.addItem(.separator())
            for win in windows {
                let item = NSMenuItem(title: win.menuLabel, action: #selector(removeWatchedWindow(_:)), keyEquivalent: "")
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
            // Close the menu before starting the picker so clicks aren't eaten by it.
            statusItem.menu = nil
            picker.start()
            // Restore the menu after a short delay (picker will reset it via callbacks).
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                self?.statusItem.menu = self?.buildCurrentMenu()
            }
        }
    }

    @objc private func removeWatchedWindow(_ sender: NSMenuItem) {
        guard let win = sender.representedObject as? WatchedWindow else { return }
        syncManager.removeWindow(win)
        // onWindowsChanged → rebuildMenu
    }

    // Returns the current menu without rebuilding cached state.
    private func buildCurrentMenu() -> NSMenu {
        rebuildMenu()
        return statusItem.menu ?? NSMenu()
    }
}
