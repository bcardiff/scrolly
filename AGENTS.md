# AGENTS.md — Developer & Agent Notes for Scrolly

This file captures architectural decisions, hard-won debugging knowledge, and
gotchas for anyone (human or AI agent) working on this codebase.

---

## Scroll Forwarding: Why AX, Not CGEvent

The scroll sync mechanism went through several approaches before landing on the
current Accessibility API solution. **Do not revert to CGEvent forwarding** without
understanding why each approach failed.

### CGEvent approaches that were tried and abandoned

| Approach | What happened |
|---|---|
| `CGEvent.postToPid(_:)` | Does **not** scroll PDFView (Apple's PDF viewer). The event is delivered to the process's queue but PDFKit ignores it — possibly due to trust level or window-focus checks. |
| Session-level posting (`CGEvent.post(tap: .cgSessionEventTap)`) with copied event | **Does** scroll PDFView, but moves the hardware cursor to `event.location`. This causes cursor bounce between windows and breaks source detection on subsequent events. |
| `CGEventSource(stateID: .privateState)` synthetic events | Private-state events do NOT move the cursor ✓, but the loop-prevention marker (`kCGEventSourceUserData`, field 39) is stripped by the WindowServer in transit. The tap sees the synthetic events with userData = 0, forwards them again → infinite loop. |
| Timestamp-based loop counter (`[UInt64: Int]`) | Timestamp of a freshly created CGEvent appears to be modified by the WindowServer before the tap sees it, so the stored pre-post timestamp no longer matches. |
| `eventSourceStateID == -1` check | Not conclusively verified to survive the pipeline; combined with userData check still produced loops. |

**Root cause of all CGEvent approaches**: the listen-only tap at
`.cgSessionEventTap` / `.headInsertEventTap` sees every event — including the
synthetic ones we post. Reliable identification of our own synthetic events in
the tap proved impossible with documented APIs.

### Why the AX approach works

`AXUIElementSetAttributeValue(scrollBar, kAXValueAttribute, value)` directly
sets the scroll position in the target application's accessibility tree. This:
- Generates **no HID scroll events** → our tap never fires for it
- Does **not move the hardware cursor**
- Works for PDFView (Preview) and all standard AppKit scroll views
- Is completely loop-free by construction

---

## Swift 6 / CoreGraphics API Notes

- `CGEventTapCreate` → `CGEvent.tapCreate(tap:place:options:eventsOfInterest:callback:userInfo:)`
- `CGEventTapEnable` → `CGEvent.tapEnable(tap:enable:)`
- C tap callbacks must be `static let` closures or global functions (no captures).
- Callback signature: `(CGEventTapProxy, CGEventType, CGEvent, UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>?`
- `CGEventField(rawValue:)` returns `CGEventField?` (optional) — force-unwrap or use named static properties like `.eventSourceStateID`.
- `AXUIElement` is `CFTypeRef`; use `CFEqual(_:_:)` for identity comparison, not `==`.
- `NSNumber` bridging: casting a `CFNumber` (e.g. from `AXWindowID` attribute) to `Int` via `as? Int` **fails** in Swift due to strict bridging. Always cast to `NSNumber` first, then read `.uint32Value` or `.int32Value`.

---

## Coordinate Systems

Three systems appear in this codebase:

| System | Origin | Y direction | Used by |
|---|---|---|---|
| AX (Accessibility) | Top-left of primary screen | Downward | `AXUIElementCopyAttributeValue(kAXPositionAttribute)` |
| AppKit / NSEvent | Bottom-left of primary screen | Upward | `NSEvent.mouseLocation`, `NSScreen.frame` |
| Quartz / CGEvent | Bottom-left of primary screen | Upward | `CGEvent.location`, `CGWindowListCopyWindowInfo` bounds |

AppKit and Quartz share the same coordinate space for scroll purposes.
`WatchedWindow.quartzFrame` converts AX → Quartz/AppKit.

Conversion formula (H = primary screen height):
```
quartzY = H - axY - rectHeight   // for a rect's bottom-left corner
quartzY = H - axY                 // for a point
```

---

## WatchedWindow Notes

- `cgWindowID` is a `lazy var` because the CGWindowList lookup is expensive.
  It's only used for z-order source detection when windows overlap.
- `AXWindowID` AX attribute is undocumented but works on most AppKit apps.
  The CGWindowList fallback (match by PID + bounds within 8px tolerance) covers
  the rest.
- `isValid` does a cheap AX title read; returns `false` when the window is closed.

---

## Source Detection for Overlapping Windows

When two watched windows overlap on screen, `NSEvent.mouseLocation` falls inside
both frames. `ScrollSyncManager.frontmostWatchedWindow(at:)` calls
`CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID)` which returns
windows in front-to-back z-order; it picks the candidate with the lowest index
(frontmost) as the true scroll source.

---

## AX Scroll Bar Discovery

`findVerticalScrollBar(in:depth:maxDepth:)` does a depth-first walk of the AX
tree looking for:
1. An `AXScrollArea` element → grab `kAXVerticalScrollBarAttribute` directly (fast path).
2. An `AXScrollBar` element with `kAXOrientationAttribute == kAXVerticalOrientationValue`.

Results are cached in `scrollBarCache` (keyed by `AXUIElement` identity via
`CFEqual`). The cache entry is validated cheaply on each access with a single
`kAXValueAttribute` read; stale entries are evicted and re-searched.

---

## Timing: Why `DispatchQueue.main.async`

The CGEventTap fires at `.headInsertEventTap` — **before** the event is delivered
to the target application. If we read the source window's scroll position inside
the tap callback, we get the position *before* the scroll happened.

Scheduling `applyScrollDelta` on `DispatchQueue.main.async` defers execution to
the next main run-loop iteration, by which point the source application has
processed the event and updated its scroll bar value.

---

## Alt/Option Scroll — Offset Preservation

When Option is held:
- `updateTrackedPosition(for:)` reads the source window's current AX scroll
  position and stores it in `lastPositions` **without** syncing to other windows.
- This keeps the baseline current so the next normal scroll correctly computes
  `delta = newPos - lastKnownPos` relative to where the Alt-scroll left off.
- Targets' `lastPositions` are not updated during the source's Alt-scroll, so
  their offsets (relative to the source) are preserved going forward.

---

## Building & Permissions

```sh
make app      # swift build -c release + bundle + codesign
make run      # make app + open
make install  # make app + cp -r to /Applications
```

**macOS revokes Accessibility permission** every time the binary is rebuilt
(the code signature changes). After each `make app`:
1. Open *System Settings → Privacy & Security → Accessibility*
2. Toggle Scrolly **off** then **on**, or use the "Restart Scrolly" menu item.

---

## App Icon

`Resources/Scrolly.icns` is generated by `scripts/make_icon.swift` using AppKit
(NSBitmapImageRep + NSBezierPath). Run `swift scripts/make_icon.swift` from the
repo root to regenerate all icon sizes and recompile the `.icns`. The script also
calls `iconutil` automatically.

Icon design: blue squircle (corner radius = 22.5% of size) with two white
arrows — one pointing up, one pointing down — representing synchronized scrolling.
