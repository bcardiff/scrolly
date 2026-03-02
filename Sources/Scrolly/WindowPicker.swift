import AppKit
import ApplicationServices

/// Installs a one-shot CGEventTap that intercepts the next left-mouse-down,
/// identifies the window under the cursor via the Accessibility API,
/// and calls `onWindowPicked` (or `onCancelled` on right-click / Escape).
final class WindowPicker {
    var onWindowPicked: ((WatchedWindow) -> Void)?
    var onCancelled: (() -> Void)?

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
            options: .defaultTap,          // not listen-only: we can eat the event
            eventsOfInterest: mask,
            callback: WindowPicker.tapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        )

        guard let tap = eventTap else {
            // Accessibility permission is likely missing.
            onCancelled?()
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
            let pos = event.location
            stop()
            identifyWindow(at: pos)
            return nil  // eat the click

        case .rightMouseDown:
            stop()
            onCancelled?()
            return nil  // eat right-click too

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

        // AX uses top-left origin; Quartz uses bottom-left.
        // NSScreen.screens[0].frame.height gives the primary screen height in points.
        let screenH = NSScreen.screens.first?.frame.height ?? 0
        let axY = Float(screenH - quartzPoint.y)

        guard AXUIElementCopyElementAtPosition(system, Float(quartzPoint.x), axY, &element) == .success,
              let el = element else {
            onCancelled?()
            return
        }

        guard let axWindow = axWindowElement(from: el) else {
            onCancelled?()
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

    /// Walks up the AX element hierarchy until an element with role AXWindow is found.
    private func axWindowElement(from element: AXUIElement) -> AXUIElement? {
        var current: AXUIElement = element

        for _ in 0..<20 {  // bounded walk to avoid infinite loops
            var roleVal: AnyObject?
            guard AXUIElementCopyAttributeValue(current, kAXRoleAttribute as CFString, &roleVal) == .success,
                  let role = roleVal as? String else { return nil }

            if role == kAXWindowRole as String { return current }
            if role == kAXSheetRole as String  { return current }

            var parentVal: AnyObject?
            guard AXUIElementCopyAttributeValue(current, kAXParentAttribute as CFString, &parentVal) == .success,
                  let parent = parentVal else { return nil }
            // swiftlint:disable force_cast
            current = parent as! AXUIElement
        }
        return nil
    }
}
