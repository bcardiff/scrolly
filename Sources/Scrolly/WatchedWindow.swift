import AppKit
import ApplicationServices

/// Represents a window being monitored for scroll synchronisation.
final class WatchedWindow {
    let pid: pid_t
    let appName: String
    let windowTitle: String
    /// The accessibility element for the window. Valid as long as the window is open.
    let axWindow: AXUIElement

    init(pid: pid_t, appName: String, windowTitle: String, axWindow: AXUIElement) {
        self.pid = pid
        self.appName = appName
        self.windowTitle = windowTitle
        self.axWindow = axWindow
    }

    /// Human-readable label for menu items.
    var menuLabel: String { "\(appName) — \(windowTitle)" }

    /// Window frame in Accessibility (AX) coordinates:
    ///   origin = top-left of primary screen, Y increases downward.
    var axFrame: CGRect? {
        var posVal: AnyObject?
        var sizeVal: AnyObject?
        guard AXUIElementCopyAttributeValue(axWindow, kAXPositionAttribute as CFString, &posVal) == .success,
              AXUIElementCopyAttributeValue(axWindow, kAXSizeAttribute as CFString, &sizeVal) == .success,
              let posAX = posVal, let sizeAX = sizeVal else { return nil }

        var pos = CGPoint.zero
        var size = CGSize.zero
        AXValueGetValue(posAX as! AXValue, .cgPoint, &pos)
        AXValueGetValue(sizeAX as! AXValue, .cgSize, &size)
        return CGRect(origin: pos, size: size)
    }

    /// Window frame in Quartz / CGEvent coordinates:
    ///   origin = bottom-left of primary screen, Y increases upward.
    ///
    /// Use this to check `CGEvent.location` membership.
    var quartzFrame: CGRect? {
        guard let ax = axFrame else { return nil }
        let h = primaryScreenHeight
        return CGRect(
            x: ax.origin.x,
            y: h - ax.origin.y - ax.size.height,
            width: ax.size.width,
            height: ax.size.height
        )
    }

    /// Geometric centre of the window in Quartz coordinates.
    /// Used as the injection point for synthetic scroll events.
    var quartzCenter: CGPoint? {
        guard let f = quartzFrame else { return nil }
        return CGPoint(x: f.midX, y: f.midY)
    }

    /// Returns false when the AX element is no longer valid (window closed / app quit).
    var isValid: Bool {
        var val: AnyObject?
        return AXUIElementCopyAttributeValue(axWindow, kAXTitleAttribute as CFString, &val) == .success
    }
}

// MARK: - Helpers

/// Height of the primary screen in points (used for AX ↔ Quartz coordinate conversion).
private var primaryScreenHeight: CGFloat {
    // NSScreen.screens[0] is the primary (menu-bar) screen.
    // Its frame is in Quartz coordinates; the height is what we need.
    return NSScreen.screens.first?.frame.height ?? CGFloat(CGDisplayBounds(CGMainDisplayID()).height)
}
