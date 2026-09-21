//
//  PanelSurface.swift — the one background color shared by every shell panel.
//
//  Both the top region of a panel (header / toolbar / status bar) and its
//  content area paint this surface, so the right-hand column reads as a single
//  surface instead of a stack of differently shaded strips. The values are the
//  dsh web UI's own chrome tokens:
//
//      dark  = #1B1B1C  (--dsw-static-neutral-bluish-900)
//      light = #F9FAFB  (--dsw-static-neutral-bluish-50)
//
//  Two flavours, because call sites differ:
//    - color(dark:) / color(for:) — explicit per-mode shades for draw(_:) code,
//      where resolving a dynamic color at draw time proved unreliable in the
//      layer-backed window (see docs/terminal-header-fix.md);
//    - dynamic — a dynamic color for stock AppKit views (NSTextView /
//      NSScrollView / PDFView / …), which re-resolves on appearance changes
//      exactly like the system color it replaces.
//
//  The panel base widgets themselves (DynamicFillView / HoverButton /
//  HeaderLabel / CustomIconButton) live in PreviewPanel.swift.
//

import AppKit

/// Interactive surfaces — cards, buttons and tabs — one step up from the panel
/// surface: a normal fill, and a highlight fill for hover / press / selection.
///
///      dark  normal #43454A   highlight #353638
///      light normal #FFFFFF   highlight #F1F3F5
///
/// Same two flavours as PanelSurface: `fill(dark:highlighted:)` for draw(_:)
/// code, `dynamic(highlighted:)` for stock AppKit surfaces (layer backgrounds
/// included — resolve those through `fill` since a CGColor is a snapshot).
enum PanelControl {
    /// #43454A — card / button / tab fill.
    static let darkNormal = NSColor(srgbRed: 0x43 / 255.0, green: 0x45 / 255.0,
                                    blue: 0x4A / 255.0, alpha: 1)
    /// #353638 — hover / pressed / selected fill (dark theme).
    static let darkHighlight = NSColor(srgbRed: 0x35 / 255.0, green: 0x36 / 255.0,
                                       blue: 0x38 / 255.0, alpha: 1)
    /// #FFFFFF — card / button / tab fill (light theme).
    static let lightNormal = NSColor(srgbRed: 1.0, green: 1.0, blue: 1.0, alpha: 1)
    /// #F1F3F5 — hover / pressed / selected fill (light theme).
    static let lightHighlight = NSColor(srgbRed: 0xF1 / 255.0, green: 0xF3 / 255.0,
                                        blue: 0xF5 / 255.0, alpha: 1)

    static func fill(dark: Bool, highlighted: Bool) -> NSColor {
        dark ? (highlighted ? darkHighlight : darkNormal)
             : (highlighted ? lightHighlight : lightNormal)
    }

    static func fill(for appearance: NSAppearance, highlighted: Bool) -> NSColor {
        fill(dark: appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua,
             highlighted: highlighted)
    }

    static func dynamic(highlighted: Bool) -> NSColor {
        NSColor(name: nil) { fill(for: $0, highlighted: highlighted) }
    }
}

enum PanelSurface {
    /// #1B1B1C — dark theme panel surface.
    static let dark = NSColor(srgbRed: 0x1B / 255.0, green: 0x1B / 255.0,
                              blue: 0x1C / 255.0, alpha: 1)
    /// #F9FAFB — light theme panel surface.
    static let light = NSColor(srgbRed: 0xF9 / 255.0, green: 0xFA / 255.0,
                               blue: 0xFB / 255.0, alpha: 1)

    static func color(dark: Bool) -> NSColor { dark ? Self.dark : Self.light }

    static func color(for appearance: NSAppearance) -> NSColor {
        color(dark: appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua)
    }

    /// Dynamic color for stock AppKit views that re-resolve on appearance change.
    static var dynamic: NSColor { NSColor(name: nil) { color(for: $0) } }
}
