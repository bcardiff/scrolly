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

    /// The CoreGraphics window ID (= NSWindow.windowNumber) for this window.
    ///
    /// Tried in order:
    ///   1. Undocumented AX attribute "AXWindowID" (fast, works on most AppKit apps).
    ///   2. CGWindowListCopyWindowInfo match by PID + bounds (reliable fallback).
    lazy var cgWindowID: CGWindowID? = {
        // 1. Try "AXWindowID" — returns CFNumber bridged to NSNumber.
        //    Do NOT cast to Swift Int directly; use NSNumber.uint32Value to
        //    avoid Swift's strict NSNumber bridging rules dropping the value.
        var val: AnyObject?
        if AXUIElementCopyAttributeValue(self.axWindow, "AXWindowID" as CFString, &val) == .success,
           let num = val as? NSNumber {
            let wid = num.uint32Value
            if wid != 0 {
                NSLog("Scrolly: wid=%u via AXWindowID for '%@'", wid, self.menuLabel)
                return CGWindowID(wid)
            }
        }
        // 2. Fallback: scan the on-screen window list and match by owner PID + frame.
        //    CGWindowListCopyWindowInfo bounds use top-left origin (same as AX coords).
        NSLog("Scrolly: AXWindowID unavailable for '%@', trying CGWindowList fallback", self.menuLabel)
        return Self.findCGWindowID(pid: self.pid, axFrame: self.axFrame)
    }()

    private static func findCGWindowID(pid: pid_t, axFrame: CGRect?) -> CGWindowID? {
        guard let frame = axFrame else { return nil }
        // Deprecated in macOS 14 but still functional; ScreenCaptureKit (replacement)
        // requires Screen Recording permission which is not appropriate here.
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID)
                as? [[String: Any]] else { return nil }
        for info in list {
            guard let ownerPID = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                  ownerPID == pid else { continue }
            guard let boundsNS = info[kCGWindowBounds as String] as? NSDictionary,
                  let b = CGRect(dictionaryRepresentation: boundsNS as CFDictionary)
            else { continue }
            if abs(b.minX - frame.minX) < 8 && abs(b.minY - frame.minY) < 8 &&
               abs(b.width  - frame.width)  < 8 && abs(b.height - frame.height) < 8 {
                if let widNum = info[kCGWindowNumber as String] as? NSNumber {
                    let wid = CGWindowID(widNum.uint32Value)
                    NSLog("Scrolly: wid=%u via CGWindowList for pid=%d", wid, pid)
                    return wid
                }
            }
        }
        NSLog("Scrolly: no wid found for pid=%d frame=(%.0f,%.0f,%.0fx%.0f)",
              pid, frame.minX, frame.minY, frame.width, frame.height)
        return nil
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
