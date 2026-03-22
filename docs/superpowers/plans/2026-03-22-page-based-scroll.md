# Page Based Scroll Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a toggleable "Page Based Scroll" mode that scales scroll sync deltas by page-count ratio so PDFs with different page counts scroll at the same page speed.

**Architecture:** `WatchedWindow` gets a `pageCount` property that reads `kAXDocumentAttribute` → file URL → `PDFDocument.pageCount`, with caching and mod-date invalidation. `ScrollSyncManager.applyScrollDelta` scales the delta by `srcPages/tgtPages` when the mode is enabled. A checkmark menu item in `StatusBarController` toggles the mode, persisted via `UserDefaults`.

**Tech Stack:** Swift, PDFKit (system framework), Accessibility API, UserDefaults

**Spec:** `docs/superpowers/specs/2026-03-22-page-based-scroll-design.md`

---

### Task 1: Add `pageCount` property to WatchedWindow

**Files:**
- Modify: `Sources/Scrolly/WatchedWindow.swift`

This task adds page-count discovery with caching and mod-date invalidation.

- [ ] **Step 1: Add `import PDFKit` at the top of `WatchedWindow.swift`**

Add after the existing imports (line 2):

```swift
import PDFKit
```

- [ ] **Step 2: Add the page-count cache struct and property to `WatchedWindow`**

Add after the `axWindow` property (after line 9), before `init`:

```swift
    /// Cached PDF page count, invalidated when the file's modification date changes.
    private var pageCountCache: (url: String, modDate: Date, count: Int)?
    /// Last time we checked the file's modification date (throttle to 1/sec).
    private var lastStatTime: Date = .distantPast
```

- [ ] **Step 3: Add the `pageCount` computed property**

Add after the `menuLabel` computed property (after line 21):

```swift
    /// Number of pages in the document, if it is a local PDF.
    /// Returns `nil` for non-PDFs, inaccessible documents, or page count of 0.
    /// Cached with mod-date invalidation, stat throttled to once per second.
    var pageCount: Int? {
        // 1. Read document URL from AX
        var docRef: AnyObject?
        guard AXUIElementCopyAttributeValue(axWindow, kAXDocumentAttribute as CFString, &docRef) == .success,
              let urlString = docRef as? String,
              let url = URL(string: urlString),
              url.scheme == "file",
              url.path.lowercased().hasSuffix(".pdf") else {
            return nil
        }

        let path = url.path
        let now = Date()

        // 2. Check cache — throttle stat() to once per second
        if let cached = pageCountCache, cached.url == urlString {
            if now.timeIntervalSince(lastStatTime) < 1.0 {
                return cached.count > 0 ? cached.count : nil
            }
            // Re-stat to check for modification
            lastStatTime = now
            if let modDate = fileModificationDate(path: path), modDate == cached.modDate {
                return cached.count > 0 ? cached.count : nil
            }
            // File changed — fall through to re-read
        }

        // 3. Read page count via PDFKit
        lastStatTime = now
        guard let modDate = fileModificationDate(path: path),
              let doc = PDFDocument(url: URL(fileURLWithPath: path)) else {
            pageCountCache = nil
            return nil
        }
        let count = doc.pageCount
        pageCountCache = (url: urlString, modDate: modDate, count: count)
        return count > 0 ? count : nil
    }

    private func fileModificationDate(path: String) -> Date? {
        try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date
    }
```

- [ ] **Step 4: Build to verify no compilation errors**

Run: `swift build -c release`
Expected: BUILD SUCCEEDED

- [ ] **Step 5: Commit**

```bash
git add Sources/Scrolly/WatchedWindow.swift
git commit -m "feat: add pageCount property to WatchedWindow

Reads kAXDocumentAttribute → PDF page count via PDFKit.
Cached with mod-date invalidation, stat throttled to 1/sec."
```

---

### Task 2: Add `pageBasedScroll` property and delta scaling to ScrollSyncManager

**Files:**
- Modify: `Sources/Scrolly/ScrollSyncManager.swift`

- [ ] **Step 1: Add the `pageBasedScroll` property**

Add after line 31 (`var onWindowsChanged: ...`):

```swift
    /// When enabled, scroll deltas are scaled by page-count ratio so that
    /// documents with different page counts scroll at the same page speed.
    var pageBasedScroll: Bool {
        get { UserDefaults.standard.bool(forKey: "pageBasedScroll") }
        set { UserDefaults.standard.set(newValue, forKey: "pageBasedScroll") }
    }
```

- [ ] **Step 2: Modify `applyScrollDelta(from:)` to scale the delta**

In `applyScrollDelta(from:)`, replace the block inside the for-loop that computes and applies the new target position. The current code (lines 174–193):

```swift
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

            let newTgtPos = (tgtOld + delta).clamped(to: 0.0...1.0)
            lastPositions[tgtKey] = newTgtPos
            AXUIElementSetAttributeValue(tgtBar, kAXValueAttribute as CFString,
                                         NSNumber(value: newTgtPos) as CFTypeRef)
        }
```

Replace with:

```swift
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
```

- [ ] **Step 3: Build to verify no compilation errors**

Run: `swift build -c release`
Expected: BUILD SUCCEEDED

- [ ] **Step 4: Commit**

```bash
git add Sources/Scrolly/ScrollSyncManager.swift
git commit -m "feat: scale scroll delta by page-count ratio in page-based mode

When pageBasedScroll is enabled, multiplies delta by srcPages/tgtPages
so PDFs with different page counts scroll at the same page speed.
Falls back to raw delta when page count is unavailable."
```

---

### Task 3: Add "Page Based Scroll" menu toggle to StatusBarController

**Files:**
- Modify: `Sources/Scrolly/StatusBarController.swift`

- [ ] **Step 1: Add the menu item in `rebuildMenu()`**

In `rebuildMenu()`, add the toggle item between the "About Scrolly" item (line 124) and the "Quit/Restart" section (line 127). Insert after `menu.addItem(about)` (line 124):

```swift
        // -- Page Based Scroll toggle --
        let pageBasedItem = NSMenuItem(
            title: "Page Based Scroll",
            action: #selector(togglePageBasedScroll),
            keyEquivalent: ""
        )
        pageBasedItem.target = self
        pageBasedItem.state = syncManager.pageBasedScroll ? .on : .off
        menu.addItem(pageBasedItem)
```

- [ ] **Step 2: Add the toggle action method**

Add after the `showAbout()` method (after line 192):

```swift
    @objc private func togglePageBasedScroll() {
        syncManager.pageBasedScroll.toggle()
        rebuildMenu()
    }
```

- [ ] **Step 3: Build to verify no compilation errors**

Run: `swift build -c release`
Expected: BUILD SUCCEEDED

- [ ] **Step 4: Commit**

```bash
git add Sources/Scrolly/StatusBarController.swift
git commit -m "feat: add Page Based Scroll menu toggle

Checkmark-style toggle in the menu bar dropdown.
State persisted via UserDefaults."
```

---

### Task 4: Build, manual test, and final commit

**Files:**
- None (verification only)

- [ ] **Step 1: Full release build**

Run: `make app`
Expected: "Built Scrolly.app" message with no errors.

- [ ] **Step 2: Manual test checklist**

After granting Accessibility permission:

1. Open two PDFs with different page counts in Preview (continuous mode)
2. Watch both windows in Scrolly
3. With "Page Based Scroll" OFF: scroll and confirm both windows scroll by the same proportional amount (current behavior — longer doc scrolls faster in pages)
4. Toggle "Page Based Scroll" ON (checkmark appears)
5. Scroll and confirm both windows now scroll at the same page speed
6. Hold Option and scroll — confirm only the active window moves (offset preserved)
7. Release Option and scroll normally — confirm sync resumes with the offset
8. Quit and relaunch — confirm the toggle state is preserved
9. Watch a non-PDF window alongside a PDF — confirm it falls back to raw delta

- [ ] **Step 3: Commit if any adjustments were needed**

Only if manual testing revealed issues that required code changes.
