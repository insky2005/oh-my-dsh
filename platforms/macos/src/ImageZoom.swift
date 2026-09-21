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

    /// The magnification that shows the whole image inside `viewport`, keeping its
    /// aspect ratio. A small image is NOT blown up past 100 % (fit is about making
    /// large screenshots readable, not about blurring icons).
    static func fitMagnification(imageSize: NSSize, viewport: NSSize) -> CGFloat {
        guard imageSize.width > 0, imageSize.height > 0,
              viewport.width > 0, viewport.height > 0 else { return 1 }
        let scale = min(viewport.width / imageSize.width, viewport.height / imageSize.height)
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
