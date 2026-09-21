import AppKit

// MARK: - Zoomable image preview for the Files panel
//
// The panel used to hand an NSImage to an NSImageView whose frame was the image's
// ORIGINAL pixel size, inside a scroll view: a 4000 px screenshot opened cropped
// and a small icon opened microscopic, with no way to scale (QA request).
//
// This view fits the image to the viewport proportionally when it appears and
// whenever the panel is resized, and lets the user zoom:
//
//   - trackpad pinch         (NSScrollView magnification)
//   - ⌘ + / ⌘ − / ⌘ 0        (keyboard, while the preview has focus)
//   - ⌘ + scroll wheel       (mouse wheel)
//   - double click           (toggle fit ↔ 100 %)
//
// Zooming by hand stops the automatic re-fit (the user's zoom wins) until ⌘0,
// a double click, or the next file open. Zooming out never goes below the range
// in `ImageZoom`, and panning is the scroll view's own (drag + scrollers).

final class ImagePreviewView: NSView {

    /// The image being previewed (its size in points).
    let imageSize: NSSize
    /// The document view that owns the mouse/keyboard interactions — the scroll
    /// view covers this container, so the gestures have to live there.
    let focusView: ImageZoomingView

    private let scroll = NSScrollView()
    private let badge = ZoomBadgeView()
    private var followsViewport = true
    private var magnificationObservation: NSKeyValueObservation?

    init(image: NSImage) {
        imageSize = image.size.width > 0 && image.size.height > 0
            ? image.size
            : NSSize(width: 1, height: 1)
        focusView = ImageZoomingView(image: image, size: imageSize)
        super.init(frame: .zero)

        scroll.documentView = focusView
        scroll.drawsBackground = true
        scroll.backgroundColor = PanelSurface.dynamic
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.allowsMagnification = true
        scroll.minMagnification = ImageZoom.minMagnification
        scroll.maxMagnification = ImageZoom.maxMagnification
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)

        badge.translatesAutoresizingMaskIntoConstraints = false
        addSubview(badge)   // after the scroll view: the badge floats above it
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            badge.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            badge.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
        ])

        focusView.onToggleZoom = { [weak self] in self?.toggleFitAndActualSize() }
        focusView.onZoomStep = { [weak self] direction in self?.zoom(by: direction) }
        focusView.onFitRequested = { [weak self] in self?.fitToViewport() }

        // Trackpad pinch and ⌘-scroll change the magnification behind our back.
        magnificationObservation = scroll.observe(\.magnification, options: [.new]) { [weak self] _, _ in
            self?.refreshBadge()
        }
        toolTip = L10n.tr("preview.imageZoomHint")
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        if followsViewport { applyFit() }
        refreshBadge()
    }

    // MARK: - Zoom

    /// Fit the whole image inside the viewport (proportionally, never enlarging a
    /// small image past 100 %). Called on open, on resize while following, and by
    /// ⌘0 / double click.
    func fitToViewport() {
        followsViewport = true
        applyFit()
    }

    /// 100 %: one image point per view point.
    func zoomToActualSize() {
        followsViewport = false
        scroll.magnification = ImageZoom.clamped(1)
        refreshBadge()
    }

    /// One zoom step (+1 in, -1 out). Manual zoom stops the auto re-fit.
    func zoom(by direction: Int) {
        followsViewport = false
        scroll.magnification = ImageZoom.stepped(scroll.magnification, direction: direction)
        refreshBadge()
    }

    /// Double click: fit when zoomed in/out by hand, 100 % when already fitted.
    func toggleFitAndActualSize() {
        let fitted = ImageZoom.fitMagnification(imageSize: imageSize, viewport: viewportSize)
        if followsViewport && abs(scroll.magnification - fitted) < 0.001 {
            zoomToActualSize()
        } else {
            fitToViewport()
        }
    }

    /// The area the image is fitted into.
    private var viewportSize: NSSize { scroll.contentView.bounds.size }

    private func applyFit() {
        let fitted = ImageZoom.fitMagnification(imageSize: imageSize, viewport: viewportSize)
        guard fitted > 0 else { return }
        scroll.magnification = fitted
        refreshBadge()
    }

    private func refreshBadge() {
        badge.text = "\(Int((scroll.magnification * 100).rounded()))%"
    }

    /// Test surface (tests/file-panel): the current zoom factor.
    var magnification: CGFloat { scroll.magnification }
}

// MARK: - The document view (gestures)

/// The image inside the scroll view. It owns the interactions because it — not the
/// container — is what the mouse reaches.
final class ImageZoomingView: NSImageView {

    var onToggleZoom: (() -> Void)?
    var onZoomStep: ((Int) -> Void)?
    var onFitRequested: (() -> Void)?

    init(image: NSImage, size: NSSize) {
        super.init(frame: NSRect(origin: .zero, size: size))
        self.image = image
        imageScaling = .scaleProportionallyDown
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// The preview takes focus so ⌘+ / ⌘− / ⌘0 reach it.
    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            onToggleZoom?()
            return
        }
        super.mouseDown(with: event)
    }

    override func scrollWheel(with event: NSEvent) {
        if event.modifierFlags.contains(.command) {
            onZoomStep?(event.scrollingDeltaY > 0 ? 1 : -1)
            return
        }
        super.scrollWheel(with: event)
    }

    override func keyDown(with event: NSEvent) {
        guard event.modifierFlags.contains(.command) else {
            super.keyDown(with: event)
            return
        }
        switch event.charactersIgnoringModifiers {
        case "+", "=": onZoomStep?(1)
        case "-", "_": onZoomStep?(-1)
        case "0": onFitRequested?()
        default: super.keyDown(with: event)
        }
    }
}

// MARK: - Zoom badge

/// The floating "42 %" badge in the corner of the preview.
final class ZoomBadgeView: NSView {

    var text: String = "" {
        didSet {
            guard text != oldValue else { return }
            invalidateIntrinsicContentSize()
            needsDisplay = true
        }
    }

    override var intrinsicContentSize: NSSize {
        let size = (text as NSString).size(withAttributes: attributes)
        return NSSize(width: ceil(size.width) + 12, height: ceil(size.height) + 4)
    }

    private var attributes: [NSAttributedString.Key: Any] {
        [.font: NSFont.systemFont(ofSize: 10, weight: .medium), .foregroundColor: NSColor.secondaryLabelColor]
    }

    override func draw(_ dirtyRect: NSRect) {
        guard !text.isEmpty else { return }
        let path = NSBezierPath(roundedRect: bounds, xRadius: 4, yRadius: 4)
        PanelSurface.dynamic.withAlphaComponent(0.82).setFill()
        path.fill()
        let size = (text as NSString).size(withAttributes: attributes)
        (text as NSString).draw(at: NSPoint(x: (bounds.width - size.width) / 2,
                                            y: (bounds.height - size.height) / 2),
                                withAttributes: attributes)
    }
}
