import AppKit
import ApplicationServices

/// Manages the list of watched windows and the system-wide scroll event tap.
///
/// When a scroll event arrives in a watched window (and Option is not held)
/// the same delta is forwarded to every other watched window.
///
/// ## Forwarding strategy
/// We copy the event, set its location to the centre of the target window, and
/// post it at the session level (`CGEvent.post(tap: .cgSessionEventTap)`).
/// Session-level posting routes by the event's embedded position, so the target
/// window receives the scroll regardless of where the real cursor sits.
///
/// ## Loop prevention
/// Session-level posting re-enters our own listen-only tap.  We mark synthetic
/// events by writing a fixed value into `kCGEventSourceUserData` (field 28), a
/// field documented as "programmer-defined value" that apps ignore.  The tap
/// skips any event carrying that marker.
final class ScrollSyncManager {

    private static let syntheticMarker: Int64 = 0x5C524C59  // 'SCRLY'
    // kCGEventSourceUserData — "programmer-defined integer value copied into the event"
    private static let markerField = CGEventField(rawValue: 28)!

    private(set) var watchedWindows: [WatchedWindow] = []
    var onWindowsChanged: (() -> Void)?

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    // MARK: - Window management

    func addWindow(_ window: WatchedWindow) {
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

    /// Remove windows whose AX element is no longer valid (window closed / app quit).
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
        if eventTap == nil, !watchedWindows.isEmpty { startTap() }
    }

    private func startTap() {
        let mask = CGEventMask(1 << CGEventType.scrollWheel.rawValue)
        eventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: ScrollSyncManager.tapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        )
        guard let tap = eventTap else {
            NSLog("Scrolly: scroll tap creation failed — accessibility permission missing?")
            return
        }
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        NSLog("Scrolly: scroll tap installed")
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
        NSLog("Scrolly: scroll tap removed")
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
        // Skip synthetic events we posted (loop prevention).
        if event.getIntegerValueField(Self.markerField) == Self.syntheticMarker { return }

        // Option/Alt held → pass through without syncing (manual nudge).
        guard !event.flags.contains(.maskAlternate) else { return }

        pruneInvalidWindows()
        guard watchedWindows.count >= 2 else { return }

        // Identify the source watched window by the mouse position in the event.
        let mousePos = event.location
        guard let sourceWindow = watchedWindows.first(where: { $0.quartzFrame?.contains(mousePos) == true }) else {
            return
        }

        let targets = watchedWindows.filter { !CFEqual($0.axWindow, sourceWindow.axWindow) }
        guard !targets.isEmpty else { return }

        NSLog("Scrolly: forwarding scroll from %@ to %d window(s)", sourceWindow.menuLabel, targets.count)

        for target in targets {
            guard let center = target.quartzCenter,
                  let copy = event.copy() else { continue }
            // Set target position so the OS routes the event to this window.
            copy.location = center
            // Mark as synthetic so our own tap ignores it.
            copy.setIntegerValueField(Self.markerField, value: Self.syntheticMarker)
            // Session-level post: routed by event.location to whatever window is there.
            copy.post(tap: .cgSessionEventTap)
        }
    }
}
