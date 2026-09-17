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
