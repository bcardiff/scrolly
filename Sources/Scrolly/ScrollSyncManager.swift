import AppKit
import ApplicationServices

/// Manages the list of watched windows and the system-wide scroll event tap.
///
/// When a scroll event arrives in a watched window (and Option is not held)
/// the same delta is forwarded to every other watched window by re-posting
/// a copy of the event positioned at the centre of each target window.
final class ScrollSyncManager {

    private(set) var watchedWindows: [WatchedWindow] = []

    /// Called whenever the watched-window list changes (add / remove / prune).
    var onWindowsChanged: (() -> Void)?

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    /// Number of synthetic scroll events we have posted that have not yet
    /// passed through our own tap callback. Used to break the forwarding loop.
    private var pendingSynthetic = 0

    // MARK: - Window management

    func addWindow(_ window: WatchedWindow) {
        // Don't add duplicates (same AX element).
        guard !watchedWindows.contains(where: { CFEqual($0.axWindow, window.axWindow) }) else { return }
        watchedWindows.append(window)
        updateTap()
        onWindowsChanged?()
    }

    func removeWindow(_ window: WatchedWindow) {
        watchedWindows.removeAll { CFEqual($0.axWindow, window.axWindow) }
        if watchedWindows.isEmpty { stopTap() }
        onWindowsChanged?()
    }

    /// Remove windows whose AX element is no longer valid (closed/quit).
    func pruneInvalidWindows() {
        let before = watchedWindows.count
        watchedWindows = watchedWindows.filter { $0.isValid }
        if watchedWindows.count != before {
            if watchedWindows.isEmpty { stopTap() }
            onWindowsChanged?()
        }
    }

    // MARK: - Tap lifecycle

    private func updateTap() {
        if eventTap == nil, !watchedWindows.isEmpty {
            startTap()
        }
    }

    private func startTap() {
        let mask = CGEventMask(1 << CGEventType.scrollWheel.rawValue)
        eventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,          // passive — never block scroll events
            eventsOfInterest: mask,
            callback: ScrollSyncManager.tapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        )

        guard let tap = eventTap else { return }
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private func stopTap() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            if let src = runLoopSource {
                CFRunLoopRemoveSource(CFRunLoopGetMain(), src, .commonModes)
            }
        }
        eventTap = nil
        runLoopSource = nil
        pendingSynthetic = 0
    }

    // MARK: - C-compatible tap callback

    private static let tapCallback: CGEventTapCallBack = { proxy, type, event, refcon in
        guard let refcon else { return Unmanaged.passRetained(event) }
        let mgr = Unmanaged<ScrollSyncManager>.fromOpaque(refcon).takeUnretainedValue()
        mgr.handleScrollEvent(event)
        return Unmanaged.passRetained(event)
    }

    // MARK: - Scroll handling

    private func handleScrollEvent(_ event: CGEvent) {
        // Skip events we posted ourselves.
        if pendingSynthetic > 0 {
            pendingSynthetic -= 1
            return
        }

        // Skip when Option/Alt is held — lets the user nudge a window independently.
        guard !event.flags.contains(.maskAlternate) else { return }

        // Remove stale windows before doing any work.
        pruneInvalidWindows()
        guard watchedWindows.count >= 2 else { return }

        // Identify which watched window the scroll is in.
        let mousePos = event.location
        guard let sourceWindow = watchedWindows.first(where: { $0.quartzFrame?.contains(mousePos) == true }) else {
            return
        }

        let targets = watchedWindows.filter { !CFEqual($0.axWindow, sourceWindow.axWindow) }
        guard !targets.isEmpty else { return }

        // Forward to every other watched window.
        pendingSynthetic += targets.count
        for target in targets {
            guard let center = target.quartzCenter,
                  let copy = event.copy() else {
                pendingSynthetic -= 1
                continue
            }
            copy.location = center
            copy.post(tap: .cgSessionEventTap)
        }
    }
}
