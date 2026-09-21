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
    /// Last value shown in the badge (skips redundant redraws).
    private var badgePercentage = -1
    /// True while the view itself is setting the magnification, so the observation
    /// can tell its own changes from a user pinch.
    private var isApplyingFit = false

    init(image: NSImage) {
        imageSize = image.size.width > 0 && image.size.height > 0
            ? image.size
            : NSSize(width: 1, height: 1)
        // The document view carries the padding around the image, and the image is
        // drawn unscaled and centred inside it: that is what keeps the image away
        // from the panel edges (QC: it hugged the bottom-left corner).
        focusView = ImageZoomingView(image: image, size: imageSize, padding: ImageZoom.padding)
        super.init(frame: .zero)

        // A clip view that centres a document smaller than the viewport: without it
        // NSScrollView pins the document to the bottom-left corner.
        scroll.contentView = CenteringClipView()
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
            // FIXED size: the badge must never resize itself. The zoom is applied
            // from inside layout(), so a magnify notification can arrive DURING a
            // layout pass; resizing a view at that moment crashes AppKit (QC: the
            // app crashed as soon as an image was opened).
            badge.widthAnchor.constraint(equalToConstant: ZoomBadgeView.size.width),
            badge.heightAnchor.constraint(equalToConstant: ZoomBadgeView.size.height),
            badge.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            badge.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
        ])

        focusView.onToggleZoom = { [weak self] in self?.toggleFitAndActualSize() }
        focusView.onZoomStep = { [weak self] direction in self?.zoom(by: direction) }
        focusView.onFitRequested = { [weak self] in self?.fitToViewport() }

        // Trackpad pinch changes the magnification behind our back. Deferred: a
        // magnification change can be delivered during a layout pass (applyFit sets
        // it from layout()), and touching views there is not safe.
        magnificationObservation = scroll.observe(\.magnification, options: [.new]) { [weak self] _, _ in
            guard let self = self else { return }
            // A change we did not make is a USER zoom: stop following the viewport,
            // or the next resize would snap it back to fit.
            if !self.isApplyingFit { self.followsViewport = false }
            DispatchQueue.main.async { self.refreshBadge() }
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
        setMagnification(ImageZoom.clamped(1))
    }

    /// One zoom step (+1 in, -1 out). Manual zoom stops the auto re-fit.
    func zoom(by direction: Int) {
        followsViewport = false
        setMagnification(ImageZoom.stepped(scroll.magnification, direction: direction))
    }

    /// Apply a magnification without implicit layer animation. Animating it made a
    /// window resize look like the image jumping to 100 % and back (QC).
    private func setMagnification(_ value: CGFloat) {
        guard abs(scroll.magnification - value) > 0.0001 else { return }
        isApplyingFit = true
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        scroll.magnification = value
        CATransaction.commit()
        isApplyingFit = false
        refreshBadge()
    }

    /// Double click: fit when zoomed in/out by hand, 100 % when already fitted.
    func toggleFitAndActualSize() {
        let fitted = ImageZoom.fitMagnification(imageSize: imageSize, viewport: viewportSize,
                                               padding: ImageZoom.padding)
        if followsViewport && abs(scroll.magnification - fitted) < 0.001 {
            zoomToActualSize()
        } else {
            fitToViewport()
        }
    }

    /// The area the image is fitted into, in SCREEN points: the clip view's FRAME.
    ///
    /// Its `bounds` must NOT be used: with magnification enabled the bounds are in
    /// document units (frame / magnification), so using them made the fit depend on
    /// the magnification it was about to set — the value oscillated between fit and
    /// 100 % while a panel resize ran (QC: the zoom was not smooth).
    private var viewportSize: NSSize { scroll.contentView.frame.size }

    private func applyFit() {
        let viewport = viewportSize
        // During a live resize the viewport can be degenerate for a frame; a fit
        // computed from that is meaningless and would flash 100 %.
        guard viewport.width > 1, viewport.height > 1 else { return }
        let fitted = ImageZoom.fitMagnification(imageSize: imageSize, viewport: viewport,
                                                padding: ImageZoom.padding)
        setMagnification(fitted)
    }

    private func refreshBadge() {
        let percentage = Int((scroll.magnification * 100).rounded())
        guard percentage != badgePercentage else { return }
        badgePercentage = percentage
        badge.text = "\(percentage)%"
    }

    // MARK: - Test surface (tests/file-panel)

    /// The current zoom factor.
    var magnification: CGFloat { scroll.magnification }
    /// Whether a document smaller than the viewport is centred (see CenteringClipView).
    var centersContent: Bool { scroll.contentView is CenteringClipView }
}

// MARK: - The document view (gestures)

/// The image inside the scroll view. It owns the interactions because it — not the
/// container — is what the mouse reaches.
final class ImageZoomingView: NSImageView {

    var onToggleZoom: (() -> Void)?
    var onZoomStep: ((Int) -> Void)?
    var onFitRequested: (() -> Void)?

    /// The padding kept around the image on every side.
    let padding: CGFloat

    init(image: NSImage, size: NSSize, padding: CGFloat) {
        self.padding = padding
        // The document is the image PLUS the padding; the image is drawn unscaled
        // (alignment centres it in that box), so zooming scales both together.
        super.init(frame: NSRect(x: 0, y: 0,
                                width: size.width + 2 * padding,
                                height: size.height + 2 * padding))
        self.image = image
        imageScaling = .scaleNone
        imageAlignment = .alignCenter
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

// MARK: - Centring clip view

/// An NSClipView that centres a document smaller than the viewport.
///
/// NSScrollView pins such a document to the bottom-left corner; with the padding
/// box around the image that put the picture against the panel edges (QC report).
/// Constraining the bounds origin keeps it centred for every magnification and
/// still lets a LARGER document scroll normally.
final class CenteringClipView: NSClipView {

    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var rect = super.constrainBoundsRect(proposedBounds)
        guard let document = documentView else { return rect }
        let documentSize = document.frame.size
        if documentSize.width < rect.width {
            rect.origin.x = -(rect.width - documentSize.width) / 2
        }
        if documentSize.height < rect.height {
            rect.origin.y = -(rect.height - documentSize.height) / 2
        }
        return rect
    }
}

// MARK: - Zoom badge

/// The floating "42 %" badge in the corner of the preview.
///
/// Its size is CONSTANT: changing the text only schedules a redraw. Measuring the
/// text and invalidating the intrinsic size here crashed AppKit when the badge was
/// updated during a layout pass (the zoom is applied from layout()), and a zoom
/// percentage always fits the fixed box.
final class ZoomBadgeView: NSView {

    /// Fixed box this badge is laid out in (see ImagePreviewView.init).
    static let size = NSSize(width: 54, height: 18)

    var text: String = "" {
        didSet {
            guard text != oldValue else { return }
            needsDisplay = true
        }
    }

    override var intrinsicContentSize: NSSize { Self.size }

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
