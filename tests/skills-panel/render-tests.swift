import AppKit
import Foundation

// Regression test for an AppKit painting trap that made the Skills panel's
// header (title + buttons) and tab selector invisible:
//
//   DynamicFillView is opaque and fills its dirty rect. AppKit can hand an
//   opaque view a dirty rect LARGER than its bounds, so the fill painted over
//   sibling views that were added earlier (lower in z-order) — the header was
//   covered by the content container and showed as a plain colour band.
//
// The fill is now clamped to the view's own bounds. These checks fail if that
// clamp is ever removed.
// Usage: tests/skills-panel/run.sh

func check(_ name: String, _ cond: Bool) {
    print((cond ? "ok" : "FAIL") + " - " + name)
    if !cond { exit(1) }
}

_ = NSApplication.shared

/// Distinct colours (and bright ink) in a horizontal band of the rendered view.
func band(_ view: NSView, rows: Range<Int>) -> (colors: [String: Int], bright: Int) {
    guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds), let data = rep.bitmapData else {
        return ([:], -1)
    }
    view.cacheDisplay(in: view.bounds, to: rep)
    let bpr = rep.bytesPerRow
    let spp = rep.samplesPerPixel
    var colors: [String: Int] = [:]
    var bright = 0
    for y in rows {
        for x in 0..<rep.pixelsWide {
            let o = y * bpr + x * spp
            colors[String(format: "#%02x%02x%02x", data[o], data[o + 1], data[o + 2]), default: 0] += 1
            if Int(data[o + 1]) > 0x80 { bright += 1 }
        }
    }
    return (colors, bright)
}

func makeHeader(in host: NSView, topInset: CGFloat, width: CGFloat) -> DynamicFillView {
    let header = DynamicFillView()
    header.kind = .window
    header.frame = NSRect(x: 0, y: host.bounds.height - topInset - 28, width: width, height: 28)
    let title = HeaderLabel()
    title.translatesAutoresizingMaskIntoConstraints = false
    title.text = "render-test-title"
    header.addSubview(title)
    NSLayoutConstraint.activate([
        title.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 10),
        title.centerYAnchor.constraint(equalTo: header.centerYAnchor),
    ])
    return header
}

// 1. Baseline: a header with a title draws ink in its band (top 28pt at 2x).
let host1 = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 200))
let header1 = makeHeader(in: host1, topInset: 0, width: 900)
host1.addSubview(header1)
host1.layoutSubtreeIfNeeded()
let baseline = band(host1, rows: 0..<56)
check("header band draws the title", baseline.bright > 100)

// 2. The trap: an opaque full-width sibling added AFTER the header (i.e. above
//    it in z-order) must not paint over it, even though its own frame does not
//    overlap the header band.
let host2 = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 200))
let header2 = makeHeader(in: host2, topInset: 0, width: 900)
host2.addSubview(header2)
let container = DynamicFillView()
container.kind = .custom(NSColor.red)
container.frame = NSRect(x: 0, y: 0, width: 900, height: 120)   // strictly below
host2.addSubview(container)
host2.layoutSubtreeIfNeeded()
let covered = band(host2, rows: 0..<56)
let redPixels = covered.colors["#ff0000", default: 0]
check("opaque sibling does not paint outside its bounds (no red in the header band)", redPixels == 0)
check("opaque sibling does not erase the header ink", covered.bright > 100)

// 3. Z-order safety: the same sibling inserted BELOW the header also renders fine.
let host3 = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 200))
let header3 = makeHeader(in: host3, topInset: 0, width: 900)
host3.addSubview(header3)
let container3 = DynamicFillView()
container3.kind = .custom(NSColor.red)
container3.frame = NSRect(x: 0, y: 0, width: 900, height: 120)
host3.addSubview(container3, positioned: .below, relativeTo: header3)
host3.layoutSubtreeIfNeeded()
check("header below-sibling ordering keeps the ink", band(host3, rows: 0..<56).bright > 100)

print("done")
