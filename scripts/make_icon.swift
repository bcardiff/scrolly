#!/usr/bin/swift
/// Generates Resources/Scrolly.iconset/*.png and Resources/Scrolly.icns
/// Run once: swift scripts/make_icon.swift
import AppKit

// MARK: - Drawing

func renderIcon(px: Int) -> Data {
    let s = CGFloat(px)

    let bmp = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    // Keep size == pixels so 1 pt == 1 px inside this context.
    bmp.size = NSSize(width: s, height: s)

    guard let ctx = NSGraphicsContext(bitmapImageRep: bmp) else { fatalError("no ctx") }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = ctx

    // ── Background: blue squircle ──────────────────────────────────────────
    let r = s * 0.225
    let bgColor = NSColor(red: 0.05, green: 0.48, blue: 0.96, alpha: 1.0)
    bgColor.setFill()
    NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: s, height: s),
                 xRadius: r, yRadius: r).fill()

    // ── Two paired arrows (↑ and ↓) side-by-side in white ─────────────────
    // Dimensions are expressed as fractions of `s` for resolution-independence.
    NSColor.white.setFill()
    NSColor.white.setStroke()

    let aw   = s * 0.10   // arrow shaft width
    let ah   = s * 0.50   // total arrow height (shaft + head)
    let hw   = s * 0.22   // arrowhead width
    let hh   = s * 0.18   // arrowhead height
    let gap  = s * 0.10   // gap between the two arrows
    let cx   = s / 2
    let cy   = s / 2

    // Left arrow points UP
    let lx = cx - gap/2 - aw/2
    run(path: upArrow(cx: lx, cy: cy, aw: aw, ah: ah, hw: hw, hh: hh))

    // Right arrow points DOWN (mirror of upArrow)
    let rx = cx + gap/2 + aw/2
    run(path: downArrow(cx: rx, cy: cy, aw: aw, ah: ah, hw: hw, hh: hh))

    NSGraphicsContext.restoreGraphicsState()
    return bmp.representation(using: .png, properties: [:])!
}

func run(path: NSBezierPath) {
    path.fill()
}

/// Upward-pointing arrow centred at (cx, cy).
func upArrow(cx: CGFloat, cy: CGFloat, aw: CGFloat, ah: CGFloat,
             hw: CGFloat, hh: CGFloat) -> NSBezierPath {
    let top    = cy + ah / 2
    let bottom = cy - ah / 2
    let shaftTop = top - hh

    let p = NSBezierPath()
    // Shaft (bottom to where head begins)
    p.move(to: NSPoint(x: cx - aw/2, y: bottom))
    p.line(to: NSPoint(x: cx + aw/2, y: bottom))
    p.line(to: NSPoint(x: cx + aw/2, y: shaftTop))
    // Arrowhead (right shoulder → tip → left shoulder)
    p.line(to: NSPoint(x: cx + hw/2, y: shaftTop))
    p.line(to: NSPoint(x: cx,         y: top))
    p.line(to: NSPoint(x: cx - hw/2, y: shaftTop))
    p.line(to: NSPoint(x: cx - aw/2, y: shaftTop))
    p.close()
    return p
}

/// Downward-pointing arrow centred at (cx, cy).
func downArrow(cx: CGFloat, cy: CGFloat, aw: CGFloat, ah: CGFloat,
               hw: CGFloat, hh: CGFloat) -> NSBezierPath {
    let bottom = cy - ah / 2
    let top    = cy + ah / 2
    let shaftBottom = bottom + hh

    let p = NSBezierPath()
    p.move(to: NSPoint(x: cx - aw/2, y: top))
    p.line(to: NSPoint(x: cx + aw/2, y: top))
    p.line(to: NSPoint(x: cx + aw/2, y: shaftBottom))
    p.line(to: NSPoint(x: cx + hw/2, y: shaftBottom))
    p.line(to: NSPoint(x: cx,         y: bottom))
    p.line(to: NSPoint(x: cx - hw/2, y: shaftBottom))
    p.line(to: NSPoint(x: cx - aw/2, y: shaftBottom))
    p.close()
    return p
}

// MARK: - Generate iconset

let fm = FileManager.default
let iconsetPath = "Resources/Scrolly.iconset"
try! fm.createDirectory(atPath: iconsetPath, withIntermediateDirectories: true, attributes: nil)

let configs: [(pts: Int, scale: Int)] = [
    (16, 1), (16, 2),
    (32, 1), (32, 2),
    (128, 1), (128, 2),
    (256, 1), (256, 2),
    (512, 1), (512, 2),
]

for cfg in configs {
    let px   = cfg.pts * cfg.scale
    let data = renderIcon(px: px)
    let name = cfg.scale > 1
        ? "icon_\(cfg.pts)x\(cfg.pts)@\(cfg.scale)x.png"
        : "icon_\(cfg.pts)x\(cfg.pts).png"
    let url = URL(fileURLWithPath: "\(iconsetPath)/\(name)")
    try! data.write(to: url)
    print("  \(name)  (\(px)×\(px))")
}

// MARK: - Convert to .icns

let result = Process()
result.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
result.arguments = ["-c", "icns", iconsetPath, "-o", "Resources/Scrolly.icns"]
try! result.run()
result.waitUntilExit()

if result.terminationStatus == 0 {
    print("\nResources/Scrolly.icns  ✓")
} else {
    print("iconutil failed with status \(result.terminationStatus)")
    exit(1)
}
