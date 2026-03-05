import AppKit
import ApplicationServices

/// Installs a one-shot CGEventTap that intercepts the next left-mouse-down,
/// identifies the window under the cursor via the Accessibility API,
/// and calls `onWindowPicked`, `onCancelled` (user cancelled), or
/// `onFailed` (something went wrong — includes a human-readable reason).
final class WindowPicker {
    var onWindowPicked: ((WatchedWindow) -> Void)?
    var onCancelled: (() -> Void)?
    var onFailed: ((String) -> Void)?

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    // MARK: - Start / Stop

    func start() {
        guard eventTap == nil else { return }

        let mask: CGEventMask =
            (1 << CGEventType.leftMouseDown.rawValue)  |
            (1 << CGEventType.rightMouseDown.rawValue) |
            (1 << CGEventType.keyDown.rawValue)

        // We BLOCK the click so it isn't forwarded to the target app.
        eventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: WindowPicker.tapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        )

        guard let tap = eventTap else {
            // tapCreate returns nil when the process is not a trusted accessibility
            // client — i.e. Accessibility permission is not granted (or was revoked
            // by a binary change after a rebuild).
            fail("""
                Could not install the event tap. Accessibility permission is required.

                In System Settings → Privacy & Security → Accessibility:
                • If Scrolly is not listed: click + and add it.
                • If Scrolly is already listed and enabled: toggle it OFF, then back ON, then relaunch Scrolly.

                (macOS revokes permission when the app binary is rebuilt.)
                """)
            return
        }

        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        NSCursor.crosshair.push()
    }

    func stop() {
        NSCursor.pop()
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            if let src = runLoopSource {
                CFRunLoopRemoveSource(CFRunLoopGetMain(), src, .commonModes)
            }
        }
        eventTap = nil
        runLoopSource = nil
    }

    // MARK: - C-compatible tap callback

    private static let tapCallback: CGEventTapCallBack = { proxy, type, event, refcon in
        guard let refcon else { return Unmanaged.passRetained(event) }
        let picker = Unmanaged<WindowPicker>.fromOpaque(refcon).takeUnretainedValue()
        return picker.handle(type: type, event: event)
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        switch type {
        case .leftMouseDown:
            let pos = NSEvent.mouseLocation
            stop()
            identifyWindow(at: pos)
            return nil  // eat the click

        case .rightMouseDown:
            stop()
            onCancelled?()
            return nil

        case .keyDown:
            let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
            if keyCode == 53 { // Escape
                stop()
                onCancelled?()
                return nil
            }
            return Unmanaged.passRetained(event)

        default:
            return Unmanaged.passRetained(event)
        }
    }

    // MARK: - Window identification

    private func identifyWindow(at quartzPoint: CGPoint) {
        let system = AXUIElementCreateSystemWide()
        var element: AXUIElement?

        // AX coords: top-left origin, Y downward.
        // Quartz coords (CGEvent.location): bottom-left origin, Y upward.
        let screenH = NSScreen.screens.first?.frame.height ?? 0
        let axY = Float(screenH - quartzPoint.y)

        let axResult = AXUIElementCopyElementAtPosition(system, Float(quartzPoint.x), axY, &element)

        guard axResult == .success, let el = element else {
            switch axResult {
            case .apiDisabled:
                fail("""
                    Accessibility API is disabled system-wide.
                    Enable it in System Settings → Privacy & Security → Accessibility.
                    """)
            case .notImplemented:
                fail("No accessible element found at that location. The app under the cursor may not support accessibility.")
            default:
                fail("Could not identify a window at that location (AX error \(axResult.rawValue)). Try clicking directly on the window content.")
            }
            return
        }

        guard let axWindow = axWindowElement(from: el) else {
            fail("Clicked element is not inside an accessible window. Try clicking on the window's content area.")
            return
        }

        var pid: pid_t = 0
        AXUIElementGetPid(axWindow, &pid)

        let runningApp = NSRunningApplication(processIdentifier: pid)
        let appName = runningApp?.localizedName ?? "Unknown"

        var titleVal: AnyObject?
        AXUIElementCopyAttributeValue(axWindow, kAXTitleAttribute as CFString, &titleVal)
        let windowTitle = (titleVal as? String) ?? "Untitled"

        let watched = WatchedWindow(pid: pid, appName: appName, windowTitle: windowTitle, axWindow: axWindow)
        onWindowPicked?(watched)
    }

    /// Returns the AXWindow element that contains `element`.
    /// First tries the direct kAXWindowAttribute (fast path, works reliably on secondary monitors),
    /// then falls back to walking up the parent chain.
    private func axWindowElement(from element: AXUIElement) -> AXUIElement? {
        // Fast path: most AX elements have a kAXWindowAttribute pointing directly to their window.
        var windowVal: AnyObject?
        if AXUIElementCopyAttributeValue(element, kAXWindowAttribute as CFString, &windowVal) == .success,
           let win = windowVal {
            return (win as! AXUIElement)
        }

        // Fallback: walk up the parent chain.
        var current: AXUIElement = element
        for _ in 0..<20 {
            var roleVal: AnyObject?
            guard AXUIElementCopyAttributeValue(current, kAXRoleAttribute as CFString, &roleVal) == .success,
                  let role = roleVal as? String else { return nil }

            if role == kAXWindowRole as String { return current }
            if role == kAXSheetRole as String  { return current }

            var parentVal: AnyObject?
            guard AXUIElementCopyAttributeValue(current, kAXParentAttribute as CFString, &parentVal) == .success,
                  let parent = parentVal else { return nil }
            current = parent as! AXUIElement
        }
        return nil
    }

    // MARK: - Helpers

    private func fail(_ reason: String) {
        onFailed?(reason)
    }
}
