import AppKit
import ApplicationServices

/// Manages the list of watched windows and the system-wide scroll event tap.
///
/// ## Scroll strategy
/// For each hardware scroll event on a watched window, we:
///   1. Read the source window's vertical scroll-bar position (0.0 – 1.0) via AX.
///   2. Compute the delta from its last known position.
///   3. Add that delta to every other watched window's scroll position.
///
/// Because we use AX attribute writes rather than synthetic CGEvents, the
/// hardware cursor never moves and there is no risk of forwarding loops.
///
/// ## Alt / Option key — independent nudge
/// When Option is held the event is NOT forwarded, so the active window scrolls
/// independently.  We still update the source window's tracked position so that
/// when the user releases Option the delta baseline is correct and the offset
/// created during the Alt-scroll is preserved going forward.
///
/// ## Timing
/// Our tap fires at `.headInsertEventTap` — before the event is delivered to the
/// source application.  We enqueue the position read on the main queue so the
/// source window has processed the event and updated its scroll position first.
///
/// ## Source detection for overlapping windows
/// When watched windows overlap we query CGWindowListCopyWindowInfo (front-to-
/// back) to identify the topmost watched window under the cursor as the source.
final class ScrollSyncManager {

    private(set) var watchedWindows: [WatchedWindow] = []
    var onWindowsChanged: (() -> Void)?

    /// When enabled, scroll deltas are scaled by page-count ratio so that
    /// documents with different page counts scroll at the same page speed.
    var pageBasedScroll: Bool {
        get { UserDefaults.standard.bool(forKey: "pageBasedScroll") }
        set { UserDefaults.standard.set(newValue, forKey: "pageBasedScroll") }
    }

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    /// Last known vertical scroll position (0.0–1.0) per watched window.
    /// Keyed by ObjectIdentifier of the WatchedWindow instance (stable for
    /// the lifetime of the object).
    private var lastPositions: [ObjectIdentifier: Double] = [:]

    /// Cached AX scroll-bar element per window AXUIElement (avoids re-walking
    /// the AX tree on every scroll event).  Invalidated when lookup fails.
    private var scrollBarCache: [(windowAX: AXUIElement, bar: AXUIElement)] = []


    // MARK: - Window management

    func addWindow(_ window: WatchedWindow) {
        guard !watchedWindows.contains(where: { CFEqual($0.axWindow, window.axWindow) }) else { return }
        watchedWindows.append(window)
        // Seed the position tracker so the first delta is computed from the
        // window's actual current position rather than an unknown baseline.
        if let bar = cachedScrollBar(for: window.axWindow),
           let pos = axScrollValue(bar) {
            lastPositions[ObjectIdentifier(window)] = pos
        }
        updateTap()
        onWindowsChanged?()
    }

    func removeWindow(_ window: WatchedWindow) {
        let id = ObjectIdentifier(window)
        lastPositions.removeValue(forKey: id)
        scrollBarCache.removeAll { CFEqual($0.windowAX, window.axWindow) }
        watchedWindows.removeAll { CFEqual($0.axWindow, window.axWindow) }
        if watchedWindows.isEmpty { stopTap() }
        onWindowsChanged?()
    }

    /// Remove windows whose AX element is no longer valid (window closed / app quit).
    func pruneInvalidWindows() {
        let before = watchedWindows.count
        for w in watchedWindows where !w.isValid {
            lastPositions.removeValue(forKey: ObjectIdentifier(w))
            scrollBarCache.removeAll { CFEqual($0.windowAX, w.axWindow) }
        }
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
        let cursorPosAK = NSEvent.mouseLocation
        guard let source = frontmostWatchedWindow(at: cursorPosAK) else { return }
        let isAlt = event.flags.contains(.maskAlternate)

        // Defer to the next main-queue iteration so the source window has
        // already scrolled by the time we read its new position.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if isAlt {
                // Alt-scroll: move this window freely without syncing.
                // Still update the tracker so the offset is preserved when
                // the user releases Alt and normal sync resumes.
                self.updateTrackedPosition(for: source)
            } else {
                self.applyScrollDelta(from: source)
            }
        }
    }

    /// Record the source window's current scroll position without syncing to others.
    private func updateTrackedPosition(for source: WatchedWindow) {
        guard let bar = cachedScrollBar(for: source.axWindow),
              let pos = axScrollValue(bar) else { return }
        lastPositions[ObjectIdentifier(source)] = pos
    }

    /// Compute how far the source window moved and apply the same delta to every
    /// other watched window, preserving their individual offsets.
    private func applyScrollDelta(from source: WatchedWindow) {
        guard let srcBar = cachedScrollBar(for: source.axWindow),
              let newPos = axScrollValue(srcBar) else { return }

        let srcKey = ObjectIdentifier(source)
        let oldPos = lastPositions[srcKey] ?? newPos   // first event: delta = 0
        let delta  = newPos - oldPos
        lastPositions[srcKey] = newPos

        guard abs(delta) > 1e-9 else { return }

        for target in watchedWindows {
            guard !CFEqual(target.axWindow, source.axWindow) else { continue }
            guard let tgtBar = cachedScrollBar(for: target.axWindow) else { continue }

            let tgtKey = ObjectIdentifier(target)
            // Use tracked position; fall back to a live AX read if unknown.
            let tgtOld: Double
            if let known = lastPositions[tgtKey] {
                tgtOld = known
            } else if let pos = axScrollValue(tgtBar) {
                tgtOld = pos
            } else {
                continue
            }

            // Scale delta by page-count ratio when page-based scroll is active.
            let effectiveDelta: Double
            if pageBasedScroll,
               let srcPages = source.pageCount,
               let tgtPages = target.pageCount {
                effectiveDelta = delta * Double(srcPages) / Double(tgtPages)
            } else {
                effectiveDelta = delta
            }

            let newTgtPos = (tgtOld + effectiveDelta).clamped(to: 0.0...1.0)
            lastPositions[tgtKey] = newTgtPos
            AXUIElementSetAttributeValue(tgtBar, kAXValueAttribute as CFString,
                                         NSNumber(value: newTgtPos) as CFTypeRef)
        }
    }

    // MARK: - AX helpers

    /// Read `kAXValueAttribute` (0.0–1.0) from a scroll-bar element.
    private func axScrollValue(_ bar: AXUIElement) -> Double? {
        var valRef: AnyObject?
        guard AXUIElementCopyAttributeValue(bar, kAXValueAttribute as CFString, &valRef) == .success
        else { return nil }
        return (valRef as? NSNumber)?.doubleValue
    }

    /// Return the cached vertical scroll bar for `windowAX`, or find it by
    /// walking the AX tree and cache it for subsequent calls.
    private func cachedScrollBar(for windowAX: AXUIElement) -> AXUIElement? {
        if let entry = scrollBarCache.first(where: { CFEqual($0.windowAX, windowAX) }) {
            // Validate: a quick value read is cheaper than a full tree walk.
            var probe: AnyObject?
            if AXUIElementCopyAttributeValue(entry.bar, kAXValueAttribute as CFString, &probe) == .success {
                return entry.bar
            }
            // Stale — evict and re-search.
            scrollBarCache.removeAll { CFEqual($0.windowAX, windowAX) }
        }
        guard let bar = findVerticalScrollBar(in: windowAX, depth: 0, maxDepth: 8) else { return nil }
        scrollBarCache.append((windowAX: windowAX, bar: bar))
        return bar
    }

    /// Depth-first search for the first vertical scroll bar under `element`.
    private func findVerticalScrollBar(in element: AXUIElement,
                                       depth: Int,
                                       maxDepth: Int) -> AXUIElement? {
        var roleRef: AnyObject?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef)
        let role = roleRef as? String

        // Scroll area: grab its dedicated vertical-bar attribute (fast path).
        if role == (kAXScrollAreaRole as String) {
            var barRef: AnyObject?
            if AXUIElementCopyAttributeValue(element,
                                             kAXVerticalScrollBarAttribute as CFString,
                                             &barRef) == .success,
               let bar = barRef {
                return (bar as! AXUIElement)
            }
        }

        // This element IS a vertical scroll bar.
        if role == (kAXScrollBarRole as String) {
            var orientRef: AnyObject?
            if AXUIElementCopyAttributeValue(element,
                                             kAXOrientationAttribute as CFString,
                                             &orientRef) == .success,
               (orientRef as? String) == (kAXVerticalOrientationValue as String) {
                return element
            }
        }

        guard depth < maxDepth else { return nil }

        var childrenRef: AnyObject?
        guard AXUIElementCopyAttributeValue(element,
                                             kAXChildrenAttribute as CFString,
                                             &childrenRef) == .success,
              let children = childrenRef as? [AXUIElement] else { return nil }

        for child in children {
            if let found = findVerticalScrollBar(in: child, depth: depth + 1, maxDepth: maxDepth) {
                return found
            }
        }
        return nil
    }

    // MARK: - Source detection

    /// Returns the frontmost watched window whose frame contains `cursorAK`.
    /// Uses CGWindowList z-order when multiple windows overlap at the cursor.
    private func frontmostWatchedWindow(at cursorAK: CGPoint) -> WatchedWindow? {
        let candidates = watchedWindows.filter { $0.quartzFrame?.contains(cursorAK) == true }
        guard !candidates.isEmpty else { return nil }
        guard candidates.count > 1 else { return candidates.first }

        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID)
                as? [[String: Any]] else { return candidates.first }
        var zOrder: [CGWindowID: Int] = [:]
        for (i, info) in list.enumerated() {
            if let n = (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value {
                zOrder[CGWindowID(n)] = i
            }
        }
        return candidates.min(by: { a, b in
            let za = a.cgWindowID.flatMap { zOrder[$0] } ?? Int.max
            let zb = b.cgWindowID.flatMap { zOrder[$0] } ?? Int.max
            return za < zb
        })
    }
}

// MARK: - Comparable clamping

private extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        max(range.lowerBound, min(range.upperBound, self))
    }
}
