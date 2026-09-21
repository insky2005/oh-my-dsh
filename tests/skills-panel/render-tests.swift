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
    header.kind = .panel
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

// 4. The panel surface token. Every panel's top region (header / toolbar /
//    status bar) and its content area paint this one surface — #1B1B1C in dark,
//    #F9FAFB in light — so the whole right-hand column reads as a single
//    surface. Pinned here so a stray shade can't creep back in.
func hex(_ color: NSColor) -> String {
    guard let c = color.usingColorSpace(.sRGB) else { return "?" }
    return String(format: "#%02x%02x%02x",
                  Int((c.redComponent * 255).rounded()),
                  Int((c.greenComponent * 255).rounded()),
                  Int((c.blueComponent * 255).rounded()))
}
check("panel surface dark token is #1b1b1c", hex(PanelSurface.dark) == "#1b1b1c")
check("panel surface light token is #f9fafb", hex(PanelSurface.light) == "#f9fafb")
check("panel surface picks the dark token for a dark appearance",
      hex(PanelSurface.color(for: NSAppearance(named: .darkAqua)!)) == "#1b1b1c")
check("panel surface picks the light token for a light appearance",
      hex(PanelSurface.color(for: NSAppearance(named: .aqua)!)) == "#f9fafb")
var dynamicDark = ""
var dynamicLight = ""
NSAppearance(named: .darkAqua)!.performAsCurrentDrawingAppearance { dynamicDark = hex(PanelSurface.dynamic) }
NSAppearance(named: .aqua)!.performAsCurrentDrawingAppearance { dynamicLight = hex(PanelSurface.dynamic) }
check("panel surface dynamic color follows the appearance",
      dynamicDark == "#1b1b1c" && dynamicLight == "#f9fafb")

for (name, expected) in [(NSAppearance.Name.aqua, "#f9fafb"), (NSAppearance.Name.darkAqua, "#1b1b1c")] {
    // Two views through the SAME render pipeline: `kind = .panel` must paint
    // exactly what the token resolves to. (Comparing a rendered colour against a
    // hex constant instead would also fold in the display colour space, which
    // shifts a dark value by ~6/255 — the light one happens to survive it, which
    // would make such a check pass for the wrong reason.)
    func dominant(configure: (DynamicFillView) -> Void) -> String {
        let host4 = NSView(frame: NSRect(x: 0, y: 0, width: 64, height: 32))
        host4.appearance = NSAppearance(named: name)
        let surface = DynamicFillView()
        configure(surface)
        surface.frame = host4.bounds
        host4.addSubview(surface)
        host4.layoutSubtreeIfNeeded()
        return band(host4, rows: 0..<32).colors.max { $0.value < $1.value }?.key ?? ""
    }
    let token = PanelSurface.color(for: NSAppearance(named: name)!)
    check("panel surface kind paints the \(expected) token for \(name.rawValue)",
          dominant { $0.kind = .panel } == dominant { $0.kind = .custom(token) })
}

// 5. Cards / buttons / tabs paint the panel-control scale (PanelControl): a
//    normal fill, and the highlight fill when hovered / selected / toggled on.
check("panel control dark fill is #43454a", hex(PanelControl.darkNormal) == "#43454a")
check("panel control dark highlight is #353638", hex(PanelControl.darkHighlight) == "#353638")
check("panel control light fill is #ffffff", hex(PanelControl.lightNormal) == "#ffffff")
check("panel control light highlight is #f1f3f5", hex(PanelControl.lightHighlight) == "#f1f3f5")
check("panel control picks fill + highlight by appearance",
      hex(PanelControl.fill(for: NSAppearance(named: .darkAqua)!, highlighted: false)) == "#43454a"
      && hex(PanelControl.fill(for: NSAppearance(named: .darkAqua)!, highlighted: true)) == "#353638"
      && hex(PanelControl.fill(for: NSAppearance(named: .aqua)!, highlighted: false)) == "#ffffff"
      && hex(PanelControl.fill(for: NSAppearance(named: .aqua)!, highlighted: true)) == "#f1f3f5")

/// Render an arbitrary view on its own and return its dominant pixel colour.
func renderDominant(_ appearance: NSAppearance.Name, _ view: NSView) -> String {
    let host = NSView(frame: NSRect(x: 0, y: 0, width: 64, height: 32))
    host.appearance = NSAppearance(named: appearance)
    view.frame = host.bounds
    host.addSubview(view)
    host.layoutSubtreeIfNeeded()
    return band(host, rows: 0..<32).colors.max { $0.value < $1.value }?.key ?? ""
}

// Compared render-to-render for the same reason as above (the display colour
// space shifts dark values, so the reference view goes through the pipeline too).
for (name, dark) in [(NSAppearance.Name.aqua, false), (NSAppearance.Name.darkAqua, true)] {
    func reference(highlighted: Bool) -> String {
        let view = DynamicFillView()
        view.kind = .custom(PanelControl.fill(dark: dark, highlighted: highlighted))
        return renderDominant(name, view)
    }
    func button(state: NSControl.StateValue) -> String {
        let b = HoverButton(frame: NSRect(x: 0, y: 0, width: 64, height: 32))
        b.isBordered = false
        b.state = state
        return renderDominant(name, b)
    }
    check("button paints the normal control fill in \(name.rawValue)",
          button(state: .off) == reference(highlighted: false))
    check("selected button paints the highlight control fill in \(name.rawValue)",
          button(state: .on) == reference(highlighted: true))
}

print("done")
