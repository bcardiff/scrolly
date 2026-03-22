# Page Based Scroll — Design Spec

## Problem

When synchronizing scroll across two PDF documents with different page counts in Preview (continuous mode), the current delta-based sync applies the same 0.0–1.0 scroll-bar delta to all windows. A scroll wheel event in a 10-page PDF produces a small delta (~0.01), which when applied to a 5-page PDF moves it proportionally less content. The result: the longer document scrolls faster in terms of pages.

## Goal

Add a toggleable "Page Based Scroll" mode that scales the sync delta by the ratio of page counts, so scrolling one page in the source window scrolls one page in every target window, regardless of document length.

## Constraints

- Alt/Option-scroll offset preservation must continue to work.
- Windows without a discoverable page count fall back to the current raw-delta behavior.
- No new external dependencies (PDFKit is a system framework).

## Design

### 1. Page-count discovery on WatchedWindow

Add a method to `WatchedWindow` that returns an optional page count:

1. Read `kAXDocumentAttribute` from `axWindow` → URL string. Parse with `URL(string:)` and verify the scheme is `file://`.
2. If the path ends in `.pdf`, create `PDFDocument(url:)` and return `.pageCount`.
3. Cache the result as a tuple: `(url: String, modificationDate: Date, pageCount: Int)`.
4. On subsequent access, `stat()` the file — but throttle to at most once per second to avoid unnecessary I/O in the scroll hot path. If the modification date changed (file was re-saved), invalidate cache and re-read.
5. Return `nil` if not a PDF, attribute unavailable, file unreadable, or page count is 0 (e.g. password-protected PDFs).

Requires `import PDFKit` in `WatchedWindow.swift`.

Note: `kAXDocumentAttribute` is known to work on Preview's `AXWindow` element. Third-party PDF viewers may or may not expose it; the `nil` fallback handles this gracefully.

### 2. Delta scaling in ScrollSyncManager.applyScrollDelta

When `pageBasedScroll` is enabled, after computing the raw delta from the source window:

```
if let srcPages = source.pageCount, let tgtPages = target.pageCount,
   srcPages > 0, tgtPages > 0 {
    scaledDelta = delta * Double(srcPages) / Double(tgtPages)
} else {
    scaledDelta = delta  // fallback: no scaling
}
```

This converts the source's proportional movement into equivalent page movement in the target's scroll space. The `scaledDelta` replaces `delta` in the existing clamped addition: `let newTgtPos = (tgtOld + scaledDelta).clamped(to: 0.0...1.0)`.

The scaling applies in `applyScrollDelta(from:)` inside the per-target loop, so mixed page counts across 3+ windows are handled correctly (each target gets its own scaling ratio). No changes to `updateTrackedPosition(for:)` (Alt-scroll path) — it only updates the source baseline and doesn't touch targets.

### 3. Menu toggle

Add a "Page Based Scroll" menu item in `StatusBarController`:

- Checkmark-style toggle (on/off).
- State stored as `var pageBasedScroll: Bool` on `ScrollSyncManager`.
- Persisted via `UserDefaults` (key: `"pageBasedScroll"`), defaults to `false`.
- Positioned in the menu above the separator before Quit/Restart.

### 4. Files changed

| File | Change |
|---|---|
| `WatchedWindow.swift` | Add `pageCount` computed property with cache, `import PDFKit` |
| `ScrollSyncManager.swift` | Add `pageBasedScroll` property, scale delta in `applyScrollDelta` |
| `StatusBarController.swift` | Add menu item and toggle action |

### 5. Edge cases

| Scenario | Behavior |
|---|---|
| One window is PDF, other is not | Raw delta (no scaling) for the non-PDF target |
| Both windows are non-PDF | Raw delta for all (current behavior) |
| PDF file re-saved with different page count | Cache invalidated on next scroll via mod-date check |
| Document changed in watched window (different file opened) | `kAXDocumentAttribute` returns new URL → cache miss → re-query |
| `pageBasedScroll` toggled mid-session | Takes effect on next scroll event; `lastPositions` remain valid |
| Alt-scroll while page-based mode is on | Works unchanged — only source baseline updated, no scaling involved |
| Password-protected PDF | `pageCount` returns 0 → treated as `nil` → raw delta fallback |
| Extreme page-count ratio (e.g. 500:2) | Clamping to 0.0–1.0 prevents overshoot; target may pin at boundary |
