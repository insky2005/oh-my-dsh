import Foundation

// MARK: - Image zoom math (pure, headless-testable)
//
// The decisions behind the Files panel image preview: how much the image is
// scaled to fit the viewport, what the manual zoom range is, and how much one
// ⌘+ / ⌘− press changes it. No AppKit, so tests/file-panel can pin the behaviour
// (see ImagePreviewView for the view that uses it).

enum ImageZoom {

    /// The manual zoom range (5 % … 1600 %).
    static let minMagnification: CGFloat = 0.05
    static let maxMagnification: CGFloat = 16

    /// One ⌘+ / ⌘− press multiplies the zoom by this.
    static let stepRatio: CGFloat = 1.25

    /// Margin the preview keeps around the image (points). The fit is computed
    /// against the viewport minus this margin, and the image sits in a document
    /// view that is that much larger, which is what produces the visible gap.
    static let padding: CGFloat = 16

    /// The magnification that shows the whole image inside `viewport`, keeping its
    /// aspect ratio. A small image is NOT blown up past 100 % (fit is about making
    /// large screenshots readable, not about blurring icons).
    ///
    /// `padding` is the margin the preview keeps around the image on every side,
    /// so the fit is computed against the viewport MINUS the margin.
    static func fitMagnification(imageSize: NSSize, viewport: NSSize,
                                 padding: CGFloat = 0) -> CGFloat {
        // A degenerate viewport (mid-resize, before the first layout) carries no
        // information: report 100 % and let the caller decide whether to apply it.
        guard imageSize.width > 0, imageSize.height > 0,
              viewport.width > 0, viewport.height > 0 else { return 1 }
        let availableWidth = max(1, viewport.width - 2 * padding)
        let availableHeight = max(1, viewport.height - 2 * padding)
        let scale = min(availableWidth / imageSize.width, availableHeight / imageSize.height)
        return min(clamped(scale), 1)
    }

    /// Clamp a magnification into the supported range.
    static func clamped(_ magnification: CGFloat) -> CGFloat {
        guard magnification.isFinite, magnification > 0 else { return minMagnification }
        return min(max(magnification, minMagnification), maxMagnification)
    }

    /// The magnification after one zoom step (+1 in, -1 out, 0 = unchanged).
    /// Stepping past the limits is a no-op at the limit, not a jump.
    static func stepped(_ magnification: CGFloat, direction: Int) -> CGFloat {
        guard direction != 0 else { return clamped(magnification) }
        let factor = direction > 0 ? stepRatio : 1 / stepRatio
        return clamped(magnification * factor)
    }
}
