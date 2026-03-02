# Scrolly

A minimal macOS menu-bar utility that synchronizes vertical scroll across two or more windows — from the same or different apps.

## How It Works

1. Click the **Scrolly icon** in the menu bar.
2. Choose **"Watch Next Clicked Window"** — the cursor changes to a crosshair.
3. Click on any window you want to watch. Repeat to add more windows.
4. Watched windows appear as menu items. Scroll in any watched window and all others scroll by the same delta.
5. Click a watched-window menu item to **stop watching** it.
6. **Hold Option/Alt** while scrolling to scroll only the current window — useful for fine-tuning mis-synchronisation.

## Architecture

```
Sources/Scrolly/
  main.swift                 App entry point (NSApplication.run)
  AppDelegate.swift          Requests Accessibility permission on launch
  StatusBarController.swift  NSStatusItem, menu management, picker mode UI
  WatchedWindow.swift        AXUIElement wrapper; provides frame in Quartz coords
  WindowPicker.swift         One-shot mouse-click CGEventTap; identifies clicked window
  ScrollSyncManager.swift    Core: listen-only scroll CGEventTap; forwards delta to peers

Resources/
  Info.plist                 LSUIElement=YES (no Dock icon), bundle metadata
  Scrolly.entitlements       Disables sandbox (required for CGEventTap)

Makefile                     Build → package → codesign as Scrolly.app
```

### Key Design Decisions

| Decision | Rationale |
|---|---|
| **CGEventTap (listen-only)** for scroll | Intercepts all scroll events system-wide without blocking them; no risk of wedging the event stream |
| **CGEvent copy + re-post** for forwarding | Preserves every field (delta, phase, momentum) perfectly; no need to reconstruct the event |
| **AXUIElement** for window identity | Works across all apps without injecting code; only needs Accessibility permission |
| **Coordinate conversion** AX→Quartz | AX uses top-left origin; CGEvent uses bottom-left origin — conversion: `cgY = screenH - axY` |
| **Synthetic-event counter** | When forwarding to N windows, increment a counter by N before posting; decrement in the tap callback to skip our own events and avoid infinite loops |
| **Option/Alt flag** to suppress sync | Lets the user nudge one window independently without affecting others |
| **Non-sandbox entitlement** | CGEventTap and Accessibility API require elevated access not available inside the sandbox |

### Coordinate Systems

macOS has two coordinate systems used by the relevant APIs:

- **AX (Accessibility) coordinates**: origin at top-left of primary screen, Y increases downward.
- **Quartz / CGEvent coordinates**: origin at bottom-left of primary screen, Y increases upward.

Conversion (primary screen height = `H`):

```
quartz.x = ax.x
quartz.y = H - ax.y          (for a point)
quartz.y = H - ax.y - h      (for the bottom-left corner of a rect of height h)
```

`WatchedWindow.quartzFrame` performs this conversion so `ScrollSyncManager` can do a simple `CGRect.contains(event.location)` check.

### Event Loop & Infinite-Loop Prevention

```
User scrolls in Window A
  └─ Tap callback fires
       ├─ Option held? → return (no-op)
       ├─ Identify source window by mouse position
       ├─ pendingSynthetic += (N-1)   // N = number of other watched windows
       ├─ for each other window:
       │    copy event, set location = quartzCenter, CGEventPost
       └─ return

Synthetic event arrives at tap callback
  └─ pendingSynthetic > 0?
       ├─ Yes → pendingSynthetic -= 1, return (skip)
       └─ No  → process normally (shouldn't happen in normal flow)
```

## Requirements

- macOS 13 Ventura or later
- **Accessibility permission** must be granted in
  *System Settings → Privacy & Security → Accessibility*

## Build

```sh
# One-time: install Xcode Command Line Tools if needed
xcode-select --install

# Build and package as Scrolly.app
make app

# Install to /Applications (optional)
make install
```

## Permissions

On first launch, Scrolly will prompt for Accessibility permission. Without it:

- The scroll event tap cannot be installed.
- Window picking via `AXUIElementCopyElementAtPosition` will fail.

Grant permission in *System Settings → Privacy & Security → Accessibility*, then relaunch.

## Known Limitations

- If the target window is occluded by another window at the forwarding position, the synthetic scroll event will be delivered to the top-most window at that point instead.
- Scroll forwarding uses the window's geometric centre as the injection point; scroll areas that don't start there might not receive the event. This is usually fine for full-window scroll views but may not work for small embedded scroll areas.
