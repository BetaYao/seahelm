import AppKit
import AVKit
import QuickLookUI
import UniformTypeIdentifiers

/// Native previews for non-text files: images via `NSImageView`, audio/video via
/// `AVPlayerView`, everything else the system understands via QuickLook.
///
/// All three backends are system frameworks, so supporting these formats costs
/// no bundle size — we deliberately ship no third-party decoders. Formats macOS
/// can't decode fall through to `FileContentView`'s placeholder.
enum MediaPreviewView {

    /// Builds a preview view for `path`, or nil when the file should not be
    /// handled here (unknown type, or a text type that belongs in the editor).
    static func make(path: String) -> NSView? {
        let url = URL(fileURLWithPath: path)
        guard let type = UTType(filenameExtension: url.pathExtension) else { return nil }

        // Text-ish types stay in the editor even when they render as media
        // (.svg, .html) — editing them is more useful than viewing them.
        guard !type.conforms(to: .text) else { return nil }

        if type.conforms(to: .image) {
            return ImagePreview(url: url)
        }
        if type.conforms(to: .audiovisualContent) {
            return MediaPlayerPreview(url: url)
        }
        // PDF, iWork/Office documents, fonts, archives — whatever QuickLook has
        // a generator for. It renders its own "no preview" state if it doesn't.
        return QuickLookPreview(url: url)
    }
}

// MARK: - Image

/// Clip view that centres the document while it is smaller than the viewport.
/// The default behaviour pins it to the bottom-left corner. Doing this in
/// `constrainBoundsRect` (rather than by nudging frames) keeps it correct at
/// every magnification, because AppKit re-asks on both zoom and resize.
private final class CenteringClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var rect = super.constrainBoundsRect(proposedBounds)
        guard let document = documentView else { return rect }
        let frame = document.frame
        if rect.width > frame.width {
            rect.origin.x = (frame.width - rect.width) / 2
        }
        if rect.height > frame.height {
            rect.origin.y = (frame.height - rect.height) / 2
        }
        return rect
    }
}

/// Zoomable image viewer. Opens fit-to-window (never upscaled past 100%), and
/// offers zoom in/out, a 100% actual-size toggle, and re-fit. Pinch and
/// scroll-wheel magnification come free from `NSScrollView`.
private final class ImagePreview: NSView {

    private static let zoomSteps: [CGFloat] = [
        0.05, 0.1, 0.25, 0.33, 0.5, 0.67, 1, 1.5, 2, 3, 4, 6, 8, 16, 32,
    ]
    private static let padding: CGFloat = 12

    private let scrollView = NSScrollView()
    private let imageView = NSImageView()
    private let percentLabel = NSTextField(labelWithString: "—")
    private let controlBar = NSVisualEffectView()

    /// Natural size in points at 100%, from the largest pixel representation so
    /// "100%" means one image pixel per point regardless of the file's DPI tag.
    private var naturalSize: CGSize = .zero
    /// True while the zoom is the auto-computed fit, so a window resize refits.
    /// Cleared as soon as the user picks a zoom themselves.
    private var isFitMode = true

    init(url: URL) {
        super.init(frame: .zero)

        setupScrollView()
        setupControlBar()

        // Decoding a large image blocks; the click that opened this already
        // happened, so keep it off main like FileContentView does.
        DispatchQueue.global(qos: .userInitiated).async {
            let image = NSImage(contentsOf: url)
            let pixelSize = image.map(ImagePreview.pixelSize(of:)) ?? .zero
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                guard let image, pixelSize.width > 0, pixelSize.height > 0 else {
                    self.scrollView.removeFromSuperview()
                    self.controlBar.removeFromSuperview()
                    self.showPlaceholder("Cannot decode this image")
                    return
                }
                self.naturalSize = pixelSize
                self.imageView.image = image
                // The image view *is* the document, sized at 100%; magnification
                // does all the scaling from there.
                self.imageView.frame = CGRect(origin: .zero, size: pixelSize)
                self.fitToWindow()
            }
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    /// `NSImage.size` is DPI-adjusted; the bitmap rep's pixel dimensions are not.
    private static func pixelSize(of image: NSImage) -> CGSize {
        let pixels = image.representations.reduce(into: CGSize.zero) { best, rep in
            best.width = max(best.width, CGFloat(rep.pixelsWide))
            best.height = max(best.height, CGFloat(rep.pixelsHigh))
        }
        // Vector reps (PDF/SVG-backed) report 0 pixels — fall back to point size.
        return pixels.width > 0 && pixels.height > 0 ? pixels : image.size
    }

    // MARK: Setup

    private func setupScrollView() {
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.allowsMagnification = true
        scrollView.minMagnification = ImagePreview.zoomSteps.first ?? 0.05
        scrollView.maxMagnification = ImagePreview.zoomSteps.last ?? 32
        scrollView.backgroundColor = SemanticColors.panel
        // Must be installed before the document view so centring applies from
        // the first layout pass.
        scrollView.contentView = CenteringClipView()

        imageView.imageScaling = .scaleAxesIndependently
        imageView.animates = true
        scrollView.documentView = imageView

        addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        NotificationCenter.default.addObserver(
            self, selector: #selector(liveMagnifyEnded),
            name: NSScrollView.didEndLiveMagnifyNotification, object: scrollView
        )
    }

    private func setupControlBar() {
        controlBar.translatesAutoresizingMaskIntoConstraints = false
        controlBar.material = .hudWindow
        controlBar.blendingMode = .withinWindow
        controlBar.state = .active
        controlBar.wantsLayer = true
        controlBar.layer?.cornerRadius = 8

        percentLabel.font = AppFont.mono(size: NSFont.smallSystemFontSize, weight: .regular)
        percentLabel.textColor = SemanticColors.text
        percentLabel.alignment = .center

        let stack = NSStackView(views: [
            button("minus", action: #selector(zoomOut), tip: "Zoom out"),
            percentLabel,
            button("plus", action: #selector(zoomIn), tip: "Zoom in"),
            textButton("100%", action: #selector(actualSize), tip: "Actual size"),
            button("arrow.up.left.and.arrow.down.right", action: #selector(fitToWindow), tip: "Fit to window"),
        ])
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .horizontal
        stack.spacing = 8
        stack.alignment = .centerY

        controlBar.addSubview(stack)
        addSubview(controlBar)

        NSLayoutConstraint.activate([
            percentLabel.widthAnchor.constraint(equalToConstant: 52),
            stack.leadingAnchor.constraint(equalTo: controlBar.leadingAnchor, constant: 10),
            stack.trailingAnchor.constraint(equalTo: controlBar.trailingAnchor, constant: -10),
            stack.topAnchor.constraint(equalTo: controlBar.topAnchor, constant: 6),
            stack.bottomAnchor.constraint(equalTo: controlBar.bottomAnchor, constant: -6),
            controlBar.centerXAnchor.constraint(equalTo: centerXAnchor),
            controlBar.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -16),
        ])
    }

    /// Glyphs like `minus` are only a few points tall, so the drawn symbol is a
    /// poor hit target. Every control gets the same square regardless of glyph.
    private static let hitSize: CGFloat = 26

    private func button(_ symbol: String, action: Selector, tip: String) -> NSButton {
        let config = NSImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)?
            .withSymbolConfiguration(config)
        let button = NSButton(image: image ?? NSImage(), target: self, action: action)
        return style(button, tip: tip)
    }

    private func textButton(_ title: String, action: Selector, tip: String) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.font = AppFont.mono(size: NSFont.smallSystemFontSize, weight: .medium)
        button.attributedTitle = NSAttributedString(
            string: title,
            attributes: [
                .foregroundColor: SemanticColors.text,
                .font: AppFont.mono(size: NSFont.smallSystemFontSize, weight: .medium),
            ]
        )
        return style(button, tip: tip, width: 44)
    }

    private func style(_ button: NSButton, tip: String, width: CGFloat? = nil) -> NSButton {
        button.translatesAutoresizingMaskIntoConstraints = false
        button.isBordered = false
        button.bezelStyle = .smallSquare
        button.contentTintColor = SemanticColors.text
        button.toolTip = tip
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: width ?? ImagePreview.hitSize),
            button.heightAnchor.constraint(equalToConstant: ImagePreview.hitSize),
        ])
        return button
    }

    // MARK: Zoom

    /// Scale that fits the image inside the viewport, capped at 100% so small
    /// images open crisp at actual size rather than blown up.
    private var fitMagnification: CGFloat {
        guard naturalSize.width > 0, naturalSize.height > 0 else { return 1 }
        // `contentView.frame` is the unscaled viewport. `.bounds` is in document
        // coordinates — already divided by the magnification — so using it here
        // would feed the current zoom back into the fit and never settle.
        let viewport = scrollView.contentView.frame.size
        guard viewport.width > 0, viewport.height > 0 else { return 1 }
        let available = CGSize(
            width: max(viewport.width - ImagePreview.padding * 2, 1),
            height: max(viewport.height - ImagePreview.padding * 2, 1)
        )
        let scale = min(available.width / naturalSize.width,
                        available.height / naturalSize.height)
        return min(scale, 1)
    }

    @objc private func fitToWindow() {
        setMagnification(fitMagnification, fit: true)
    }

    @objc private func actualSize() {
        setMagnification(1, fit: false)
    }

    @objc private func zoomIn() {
        let current = scrollView.magnification
        setMagnification(ImagePreview.zoomSteps.first { $0 > current + 0.001 }
            ?? scrollView.maxMagnification, fit: false)
    }

    @objc private func zoomOut() {
        let current = scrollView.magnification
        setMagnification(ImagePreview.zoomSteps.last { $0 < current - 0.001 }
            ?? scrollView.minMagnification, fit: false)
    }

    @objc private func liveMagnifyEnded() {
        // Pinch/scroll zoom is a user choice — stop refitting on resize.
        isFitMode = false
        updatePercentLabel()
    }

    private func setMagnification(_ value: CGFloat, fit: Bool) {
        guard naturalSize.width > 0 else { return }
        isFitMode = fit
        let clamped = min(max(value, scrollView.minMagnification), scrollView.maxMagnification)
        // Anchor on the viewport centre (in document coordinates, which is what
        // this API expects) so zooming doesn't drift the image off-screen.
        let center = CGPoint(x: scrollView.contentView.bounds.midX,
                             y: scrollView.contentView.bounds.midY)
        scrollView.setMagnification(clamped, centeredAt: center)
        updatePercentLabel()
    }

    private func updatePercentLabel() {
        percentLabel.stringValue = "\(Int((scrollView.magnification * 100).rounded()))%"
    }

    // MARK: Layout

    override func layout() {
        super.layout()
        // Centring is the clip view's job now; only the fit needs re-deriving
        // when the overlay resizes.
        guard naturalSize.width > 0, isFitMode else { return }
        let target = fitMagnification
        // Guard against re-entering layout for a no-op change.
        guard abs(scrollView.magnification - target) > 0.0001 else { return }
        setMagnification(target, fit: true)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }
}

// MARK: - Audio / Video

private final class MediaPlayerPreview: NSView {

    private let playerView = AVPlayerView()

    init(url: URL) {
        super.init(frame: .zero)

        playerView.translatesAutoresizingMaskIntoConstraints = false
        playerView.player = AVPlayer(url: url)
        playerView.controlsStyle = .inline
        playerView.showsFullScreenToggleButton = true
        playerView.videoGravity = .resizeAspect

        addSubview(playerView)
        NSLayoutConstraint.activate([
            playerView.leadingAnchor.constraint(equalTo: leadingAnchor),
            playerView.trailingAnchor.constraint(equalTo: trailingAnchor),
            playerView.topAnchor.constraint(equalTo: topAnchor),
            playerView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    /// The overlay is dismissed by `removeFromSuperview`, which leaves the
    /// player running and audible. Stop it when we leave the window.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            playerView.player?.pause()
            playerView.player = nil
        }
    }
}

// MARK: - QuickLook

private final class QuickLookPreview: NSView {

    init(url: URL) {
        super.init(frame: .zero)

        let preview = QLPreviewView(frame: .zero, style: .normal) ?? QLPreviewView()
        preview.translatesAutoresizingMaskIntoConstraints = false
        preview.autostarts = false
        preview.previewItem = url as NSURL

        addSubview(preview)
        NSLayoutConstraint.activate([
            preview.leadingAnchor.constraint(equalTo: leadingAnchor),
            preview.trailingAnchor.constraint(equalTo: trailingAnchor),
            preview.topAnchor.constraint(equalTo: topAnchor),
            preview.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }
}

// MARK: - Shared placeholder

private extension NSView {
    func showPlaceholder(_ text: String) {
        let label = NSTextField(labelWithString: text)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.textColor = SemanticColors.muted
        label.alignment = .center
        label.font = NSFont.systemFont(ofSize: NSFont.systemFontSize)

        addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }
}
