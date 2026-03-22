# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Is

Scrolly is a macOS menu-bar utility (Swift, SPM) that synchronizes vertical scroll across two or more windows using the Accessibility API. Targets macOS 13+. Swift tools version 6.0 with Swift 5 language mode.

## Build Commands

```sh
make app      # swift build -c release → bundle → ad-hoc codesign
make run      # build + open
make install  # build + copy to /Applications
make clean    # rm .build/ and .app bundle
swift scripts/make_icon.swift  # regenerate app icon
```

After every rebuild, macOS revokes Accessibility permission (signature changes). Toggle Scrolly off/on in System Settings → Privacy & Security → Accessibility, or use the "Restart Scrolly" menu item.

There are no tests or linter configured.

## Architecture

Entry: `main.swift` → `AppDelegate` → `StatusBarController` (owns the menu-bar UI).

Two core subsystems hang off StatusBarController:

- **WindowPicker** — one-shot blocking CGEventTap that captures a mouse click, resolves the clicked window via `AXUIElementCopyElementAtPosition`, and returns a `WatchedWindow`.
- **ScrollSyncManager** — persistent listen-only CGEventTap for scroll events. On scroll: identifies the frontmost watched window (z-order via `CGWindowListCopyWindowInfo`), defers to next main-queue iteration (so source app processes event first), reads source scroll-bar value (0.0–1.0) via AX, computes delta, writes delta to all other watched windows via `AXUIElementSetAttributeValue`.

**WatchedWindow** wraps an `AXUIElement` with coordinate conversion (AX ↔ Quartz), lazy `cgWindowID` resolution, and scroll-bar element caching.

## Critical Constraints

- **Do not use CGEvent forwarding for scroll sync.** Multiple approaches were tried and failed (see AGENTS.md for details). The AX scroll-bar write approach is loop-free by construction.
- **No App Sandbox** — required for CGEventTap + Accessibility API access.
- `LSUIElement=YES` in Info.plist — status-bar-only app, no Dock icon.
- AX coordinates (top-left origin, Y down) vs Quartz/AppKit (bottom-left origin, Y up). `WatchedWindow.quartzFrame` handles conversion. Primary screen height `H` is the conversion factor.
- `AXUIElement` is `CFTypeRef` — use `CFEqual` for identity, not `==`.
- `CFNumber` → `Int` bridging fails in Swift. Cast to `NSNumber` first, then `.uint32Value`.
