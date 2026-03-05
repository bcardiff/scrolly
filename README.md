# Scrolly

A minimal macOS menu-bar utility that synchronizes vertical scroll across two or more windows — from the same or different apps.

## How It Works

1. Click the **Scrolly icon** in the menu bar.
2. Choose **"Watch Next Clicked Window"** — the cursor changes to a crosshair.
3. Click on any window you want to watch. Repeat to add more windows.
4. Watched windows appear as menu items. Scroll in any watched window and all others scroll by the same delta.
5. Click a watched-window menu item to **stop watching** it.
6. **Hold Option/Alt** while scrolling to scroll only the current window, creating a persistent offset that is maintained during subsequent synced scrolling.

## Architecture

```
Sources/Scrolly/
  main.swift                 App entry point (NSApplication.run)
  AppDelegate.swift          Requests Accessibility permission on launch
  StatusBarController.swift  NSStatusItem, menu management, picker mode UI
  WatchedWindow.swift        AXUIElement wrapper; provides frame in Quartz coords + AX scroll bar lookup
  WindowPicker.swift         One-shot mouse-click CGEventTap; identifies clicked window via AX
  ScrollSyncManager.swift    Core: listen-only scroll CGEventTap; mirrors position to peers via AX

Resources/
  Info.plist                 LSUIElement=YES (no Dock icon), bundle metadata
  Scrolly.entitlements       Disables sandbox (required for CGEventTap + Accessibility API)
  Scrolly.icns               App icon (blue squircle, paired ↑↓ arrows)
  Scrolly.iconset/           Source PNGs for the icon (all @1x/@2x sizes)

scripts/
  make_icon.swift            Regenerates Scrolly.icns from scratch (run with `swift scripts/make_icon.swift`)

Makefile                     Build → package → codesign as Scrolly.app
```

### Key Design Decisions

| Decision | Rationale |
|---|---|
| **CGEventTap (listen-only)** for scroll detection | Intercepts all scroll events system-wide without blocking them; no risk of wedging the event stream |
| **AX scroll-bar writes** for forwarding | Read `kAXValueAttribute` (0.0–1.0) from source's vertical scroll bar, apply the same delta to each target via `AXUIElementSetAttributeValue`. No synthetic CGEvents → no cursor movement, no forwarding loops. |
| **Delta-based position tracking** | Each window's last known scroll position is stored in `lastPositions`. Forwarding applies the delta (new − old) to targets, so per-window offsets are preserved indefinitely. |
| **AXUIElement** for window identity | Works across all apps without injecting code; only needs Accessibility permission |
| **Scroll-bar element cache** | The AX tree walk to find each window's vertical scroll bar is cached after the first lookup and invalidated lazily on failure |
| **Option/Alt flag** to suppress sync | Lets the user nudge one window independently. The source's tracked position is still updated during Alt-scroll so the offset is preserved when normal sync resumes. |
| **Z-order source detection** | When watched windows overlap, `CGWindowListCopyWindowInfo` (front-to-back order) identifies the topmost watched window under the cursor as the true scroll source |
| **Non-sandbox entitlement** | CGEventTap and Accessibility API require elevated access not available inside the App Sandbox |

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

`WatchedWindow.quartzFrame` performs this conversion so `ScrollSyncManager` can do a simple `CGRect.contains(cursorPosition)` check.

### Scroll Sync Flow

```
User scrolls in Window A
  └─ CGEventTap callback fires (listen-only, head-insert)
       ├─ Option held?
       │    ├─ Yes → updateTrackedPosition(A)  [update baseline, don't sync]
       │    └─ No  → schedule applyScrollDelta(from: A) on main queue
       └─ return (event passes through unmodified)

applyScrollDelta(from: A)  [runs after A has processed the real event]
  ├─ Read A's scroll bar value via AX → newPos
  ├─ delta = newPos − lastPositions[A]
  ├─ lastPositions[A] = newPos
  └─ for each other watched window B:
       ├─ newB = clamp(lastPositions[B] + delta, 0…1)
       ├─ lastPositions[B] = newB
       └─ AXUIElementSetAttributeValue(B's scroll bar, kAXValueAttribute, newB)
```

No synthetic events are generated. No cursor movement. No loop risk.

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

# Build, package, and open
make run

# Install to /Applications (optional)
make install

# Regenerate app icon
swift scripts/make_icon.swift
```

> **Note:** macOS revokes the Accessibility permission each time the app binary is rebuilt.
> Use the **"Restart Scrolly"** menu item (shown when permission is missing) or manually
> toggle Scrolly off and on in *System Settings → Privacy & Security → Accessibility*,
> then relaunch.

## Permissions

On first launch Scrolly will prompt for Accessibility permission. Without it:

- The scroll event tap cannot be installed.
- Window picking via `AXUIElementCopyElementAtPosition` will fail.

Grant permission in *System Settings → Privacy & Security → Accessibility*, then relaunch.

## Known Limitations

- Scroll sync relies on the target app exposing a standard AX vertical scroll bar (`kAXVerticalScrollBarAttribute` on its `AXScrollArea`). This works for all standard AppKit and PDFKit views. Custom scroll implementations that bypass the AX scroll bar may not respond.
- The 0.0–1.0 scroll position is proportional to document length. For documents of different lengths, the same fraction maps to different content positions — the sync preserves relative scroll speed, not absolute content alignment.
