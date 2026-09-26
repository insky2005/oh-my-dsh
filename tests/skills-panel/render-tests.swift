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

// 6. Header labels that must stay inside their own frame. HeaderLabel draws with
//    NSString.draw(at:) — it neither clips nor ellipsizes — so a long text in a
//    narrow header (the tasks panel's workspace line: "kylee-dsh-blog · 非 GitHub
//    仓库" in a 300pt panel) would be painted UNDER the buttons beside it.
//    FittingHeaderLabel truncates its own text to its frame instead.
do {
    let long = "kylee-dsh-blog · 非 GitHub 仓库"

    // 6a. A text that FITS is drawn untouched, and the tooltip carries the whole
    //     thing either way.
    let wide = FittingHeaderLabel()
    wide.fullText = "owner/repo"
    wide.frame = NSRect(x: 0, y: 0, width: 150, height: 16)
    wide.layoutSubtreeIfNeeded()
    check("a fitting header text is left alone", wide.text == "owner/repo")
    check("and its tooltip is the full text", wide.toolTip == "owner/repo")

    // 6b. A text that does NOT fit is truncated with an ellipsis, and — the point
    //     of the whole thing — no ink is painted past the label's right edge.
    let host = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 16))
    let narrow = FittingHeaderLabel()
    narrow.fullText = long
    narrow.frame = NSRect(x: 0, y: 0, width: 90, height: 16)
    host.addSubview(narrow)
    host.layoutSubtreeIfNeeded()
    check("an over-long header text is truncated with an ellipsis",
          narrow.text.hasSuffix("…") && narrow.text.count < long.count)
    check("the fitted text really fits its frame",
          (narrow.text as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 11)]).width
          <= narrow.frame.width)
    check("the tooltip still carries the full text", narrow.toolTip == long)
    // Ink pixels inside the label's frame vs. past its right edge. (The render runs
    // at 2x; "ink" = any pixel darker/lighter than an empty view — counting only
    // BRIGHT pixels would miss the light appearance's grey ink.)
    func ink(_ view: NSView, host: NSView, edge: CGFloat) -> (inside: Int, past: Int) {
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds), let data = rep.bitmapData else {
            return (-1, -1)
        }
        host.cacheDisplay(in: host.bounds, to: rep)
        let scale = rep.pixelsWide / Int(host.bounds.width)
        let edgePx = Int(edge) * scale
        var inside = 0
        var past = 0
        for x in 0..<rep.pixelsWide {
            for y in 0..<rep.pixelsHigh {
                let o = y * rep.bytesPerRow + x * rep.samplesPerPixel
                guard Int(data[o + 1]) > 0x20 || Int(data[o + 3]) > 0x40 else { continue }
                if x < edgePx { inside += 1 } else { past += 1 }
            }
        }
        return (inside, past)
    }
    let fitted = ink(narrow, host: host, edge: narrow.frame.maxX)
    check("the fitted text really draws inside its frame (got \(fitted.inside) ink pixels)", fitted.inside > 20)
    check("no ink is painted past the label's frame (got \(fitted.past) ink pixels)", fitted.past == 0)

    // The premise, pinned: a PLAIN HeaderLabel with the same text and frame does
    // paint past its own edge (it draws with NSString.draw(at:) and AppKit does not
    // clip it), which is exactly what FittingHeaderLabel exists to prevent. If this
    // ever stops being true the fitting label is harmless — but the reason for it
    // would have changed, and this test should be re-read rather than deleted.
    let plainHost = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 16))
    let plain = HeaderLabel()
    plain.text = long
    plain.frame = NSRect(x: 0, y: 0, width: 90, height: 16)
    plainHost.addSubview(plain)
    plainHost.layoutSubtreeIfNeeded()
    check("a plain HeaderLabel really does overdraw its own frame (that is the trap)",
          ink(plain, host: plainHost, edge: plain.frame.maxX).past > 100)

    // 6c. Before the first layout pass (width 0) the label draws NOTHING rather
    //     than a flash of over-long text …
    let fresh = FittingHeaderLabel()
    fresh.fullText = long
    check("a label with no width yet draws nothing",
          FittingHeaderLabel.fitted(long, width: 0).isEmpty)
    // … and once it has a width it settles on ONE text: re-fitting must not grow
    // or shrink it again (an oscillating label would relayout forever).
    fresh.frame = NSRect(x: 0, y: 0, width: 90, height: 16)
    fresh.layoutSubtreeIfNeeded()
    let settled = fresh.text
    fresh.needsLayout = true
    fresh.layoutSubtreeIfNeeded()
    check("re-fitting settles on the same text", fresh.text == settled && !settled.isEmpty)
}

print("done")
