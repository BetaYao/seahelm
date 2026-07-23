import AppKit

/// Helm command line (`/ command · @ repo · # agent` placeholder).
/// Pure input surface — it emits text changes and submit; the cockpit owns the
/// autocomplete dropdown (so it can float over the Orders/Watch list unclipped).
///
/// The field is a multi-line text view that auto-grows with its content (up to
/// `maxLineCount`, then scrolls). Return submits; Shift+Return inserts a newline.
final class CommandInputView: NSView {

    // Appearance-aware text; accents stay fixed.
    private static let ink: NSColor = SemanticColors.text

    enum MenuKey { case up, down, accept }

    var onTextChanged: ((String) -> Void)?
    var onSubmit: ((String) -> Void)?
    /// Esc pressed while the field is focused (used to close the cockpit).
    var onCancel: (() -> Void)?
    /// Arrow/Enter while the autocomplete menu is open. Return true if the host
    /// consumed it (menu visible) so the keystroke doesn't also edit/submit.
    var onMenuKey: ((MenuKey) -> Bool)?
    /// ↑ pressed while the field is focused, the menu is closed, and the text is
    /// empty — the nav ring reclaims focus. Return true when consumed.
    var onArrowUpAtEmpty: (() -> Bool)?
    /// The field became first responder (keyboard OR mouse click) — lets the
    /// host's focus model track that the command row is active.
    var onFocused: (() -> Void)?
    /// The field resigned first responder (click elsewhere, Tab, etc.).
    var onUnfocused: (() -> Void)?
    /// An image was pasted (or drag-dropped) into the field. The URL points to
    /// a temp PNG file the host can pass downstream.
    var onImagePasted: ((URL) -> Void)?

    private let field = GrowingTextView()
    private let scroll = NSScrollView()
    private let box = FrostedPanelView()
    /// Solid color wash over the glass that gives the flush band a distinct
    /// input-surface color — this is what separates it from the panel behind.
    private let tint = NSView()
    private let spinner = NSProgressIndicator()

    /// Deep input-surface fill. Darker than the panel in dark mode, so the band
    /// reads as a recessed field rather than a decorative strip.
    private static let bandFill: NSColor = NSColor(name: nil) { a in
        a.isDark
            ? NSColor(hex: 0x061a21).withAlphaComponent(0.90)
            : NSColor(srgbRed: 0xff / 255.0, green: 0xff / 255.0, blue: 0xff / 255.0, alpha: 0.92)
    }
    private static let bandFillFocused: NSColor = NSColor(name: nil) { a in
        a.isDark
            ? NSColor(hex: 0x0a2530).withAlphaComponent(0.94)
            : NSColor.white.withAlphaComponent(0.98)
    }

    /// Field (or its editor) currently owns focus — drives the lit state.
    private var isFocused = false {
        didSet { if oldValue != isFocused { updateFocusAppearance() } }
    }
    private let thumbnailStrip = NSStackView()
    private var savedPlaceholder: String?
    private var placeholder: String = "" {
        didSet { field.placeholder = placeholder; refreshPlaceholder() }
    }

    /// Vertical padding above/below the text inside the band.
    private static let verticalInset: CGFloat = 11
    /// One text row's height (min band content). Recomputed from the font.
    private var lineHeight: CGFloat = 18
    /// How many rows the field grows to before it starts scrolling.
    private static let maxLineCount: CGFloat = 6

    /// Temp file URLs of pasted images, in paste order. Cleared on submit/cancel.
    private(set) var pendingImageURLs: [URL] = [] {
        didSet { rebuildThumbnails() }
    }

    private var scrollLeadingConstraint: NSLayoutConstraint!
    private var scrollHeightConstraint: NSLayoutConstraint!
    private var thumbnailStackLeadingConstraint: NSLayoutConstraint!

    /// Anchors of the input band, so the host can align the autocomplete
    /// dropdown to the band's bottom edge.
    var boxBottomAnchor: NSLayoutYAxisAnchor { box.bottomAnchor }
    var boxLeadingAnchor: NSLayoutXAxisAnchor { box.leadingAnchor }
    var boxTrailingAnchor: NSLayoutXAxisAnchor { box.trailingAnchor }

    var text: String {
        get { field.string }
        set {
            field.string = newValue
            field.needsDisplay = true
            recomputeHeight()
        }
    }

    /// Corner radius of the input band. Defaults to 0 (flush / immersive band).
    var boxCornerRadius: CGFloat = 0 {
        didSet { box.layer?.cornerRadius = boxCornerRadius }
    }

    /// When false, no hairline border — glass fill only.
    var showsChrome: Bool = true {
        didSet { refreshChromeColors() }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    private func setup() {
        translatesAutoresizingMaskIntoConstraints = false

        box.kind = .input
        box.translatesAutoresizingMaskIntoConstraints = false

        let font = AppFont.mono(size: 12.5, weight: .regular)
        lineHeight = ceil(font.ascender - font.descender + font.leading)

        field.font = font
        field.textColor = Self.ink
        field.placeholderColor = SemanticColors.muted
        field.placeholderAccentColor = SemanticColors.accent
        field.isRichText = false
        field.drawsBackground = false
        field.isVerticallyResizable = true
        field.isHorizontallyResizable = false
        field.autoresizingMask = [.width]
        field.textContainerInset = NSSize(width: 0, height: 0)
        field.textContainer?.lineFragmentPadding = 0
        field.textContainer?.widthTracksTextView = true
        field.delegate = self
        field.allowsUndo = true
        field.setAccessibilityIdentifier("helm.commandInput")
        placeholder = "Give an order — / command · @ repo · # agent"
        field.onFocusChange = { [weak self] focused in
            self?.isFocused = focused
            if focused { self?.onFocused?() } else { self?.onUnfocused?() }
        }
        field.onPasteImage = { [weak self] url in self?.attachImage(url: url) }

        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = false
        scroll.hasHorizontalScroller = false
        scroll.verticalScrollElasticity = .none
        scroll.autohidesScrollers = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = field

        tint.wantsLayer = true
        tint.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(tint)
        box.addSubview(scroll)

        refreshChromeColors()

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        spinner.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(spinner)

        thumbnailStrip.orientation = .horizontal
        thumbnailStrip.alignment = .centerY
        thumbnailStrip.spacing = 4
        thumbnailStrip.translatesAutoresizingMaskIntoConstraints = false
        thumbnailStackLeadingConstraint = thumbnailStrip.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 6)
        box.addSubview(thumbnailStrip)

        addSubview(box)

        scrollLeadingConstraint = scroll.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 16)
        scrollHeightConstraint = scroll.heightAnchor.constraint(equalToConstant: lineHeight)

        NSLayoutConstraint.activate([
            // Flush band: fills the composer bar edge-to-edge, no floating inset box.
            box.topAnchor.constraint(equalTo: topAnchor),
            box.leadingAnchor.constraint(equalTo: leadingAnchor),
            box.trailingAnchor.constraint(equalTo: trailingAnchor),
            box.bottomAnchor.constraint(equalTo: bottomAnchor),

            tint.leadingAnchor.constraint(equalTo: box.leadingAnchor),
            tint.trailingAnchor.constraint(equalTo: box.trailingAnchor),
            tint.topAnchor.constraint(equalTo: box.topAnchor),
            tint.bottomAnchor.constraint(equalTo: box.bottomAnchor),

            scrollLeadingConstraint,
            scroll.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -14),
            scroll.topAnchor.constraint(equalTo: box.topAnchor, constant: Self.verticalInset),
            scroll.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -Self.verticalInset),
            scrollHeightConstraint,

            spinner.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -12),
            spinner.topAnchor.constraint(equalTo: box.topAnchor, constant: Self.verticalInset),

            thumbnailStackLeadingConstraint,
            thumbnailStrip.topAnchor.constraint(equalTo: box.topAnchor, constant: Self.verticalInset),
            thumbnailStrip.heightAnchor.constraint(equalToConstant: 28),
        ])
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshChromeColors()
    }

    override func layout() {
        super.layout()
        recomputeHeight()
    }

    /// Resize the band to fit the text, clamped to [1, maxLineCount] rows, then
    /// scroll. Idempotent — only mutates the constraint when the value changes.
    private func recomputeHeight() {
        guard let lm = field.layoutManager, let tc = field.textContainer else { return }
        lm.ensureLayout(for: tc)
        let content = field.string.isEmpty ? lineHeight : ceil(lm.usedRect(for: tc).height)
        let minH = lineHeight
        let maxH = lineHeight * Self.maxLineCount
        let target = min(max(content, minH), maxH)
        if abs(scrollHeightConstraint.constant - target) > 0.5 {
            scrollHeightConstraint.constant = target
        }
        // Only scroll once the content overflows the cap.
        scroll.hasVerticalScroller = content > maxH
    }

    private func refreshPlaceholder() {
        field.placeholderFont = field.font ?? AppFont.mono(size: 12.5, weight: .regular)
        field.needsDisplay = true
    }

    private func refreshChromeColors() {
        box.kind = .input
        box.layer?.cornerRadius = boxCornerRadius
        if showsChrome {
            box.layer?.borderWidth = 0.5
            box.layer?.borderColor = resolvedCGColor(NSColor.separatorColor.withAlphaComponent(0.55))
        } else {
            box.layer?.borderWidth = 0
            box.layer?.borderColor = nil
        }
        field.textColor = Self.ink
        field.placeholderColor = SemanticColors.muted
        field.placeholderAccentColor = SemanticColors.accent
        refreshPlaceholder()
        updateFocusAppearance()
    }

    /// The band's prominence is carried by color: a deep fill that deepens a
    /// touch more when focused. No borders, bars, or rules.
    private func updateFocusAppearance() {
        tint.layer?.backgroundColor = resolvedCGColor(isFocused ? Self.bandFillFocused : Self.bandFill)
    }

    func focusInput() { window?.makeFirstResponder(field) }

    /// Whether the command field (or its field editor) currently owns focus.
    var isFieldFocused: Bool {
        guard let window else { return false }
        return window.firstResponder === field
    }

    /// Show a busy state while an async command runs: disable editing, swap the
    /// placeholder to `message`, and spin.
    func setLoading(_ loading: Bool, message: String = "Working…") {
        if loading {
            savedPlaceholder = placeholder
            field.string = ""
            placeholder = message
            field.isEditable = false
            field.isSelectable = false
            spinner.startAnimation(nil)
        } else {
            placeholder = savedPlaceholder ?? placeholder
            field.isEditable = true
            field.isSelectable = true
            spinner.stopAnimation(nil)
        }
        recomputeHeight()
    }

    /// Set the text, focus the field, and place the caret at the END (not a
    /// select-all, which would wipe the value on the next keystroke).
    func setTextAndFocusEnd(_ s: String) {
        field.string = s
        window?.makeFirstResponder(field)
        field.setSelectedRange(NSRange(location: (s as NSString).length, length: 0))
        field.needsDisplay = true
        recomputeHeight()
        onTextChanged?(s)
    }

    /// Clear any pending image attachments.
    func clearPendingImage() {
        pendingImageURLs = []
    }

    fileprivate func submit() {
        let value = field.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        onSubmit?(value)
        field.string = ""
        field.needsDisplay = true
        recomputeHeight()
        onTextChanged?("")
        clearPendingImage()
    }

    /// Save a pasted image to a temp PNG and show a thumbnail preview.
    private func attachImage(url: URL) {
        pendingImageURLs.append(url)
        onImagePasted?(url)
    }

    @objc private func removeThumbnail(_ sender: NSButton) {
        let index = sender.tag
        guard index >= 0, index < pendingImageURLs.count else { return }
        pendingImageURLs.remove(at: index)
    }

    private func rebuildThumbnails() {
        thumbnailStrip.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for (index, url) in pendingImageURLs.enumerated() {
            let container = NSView()
            container.translatesAutoresizingMaskIntoConstraints = false
            container.wantsLayer = true
            container.layer?.cornerRadius = 4
            container.layer?.masksToBounds = true

            let imageView = NSImageView()
            imageView.imageScaling = .scaleProportionallyDown
            imageView.translatesAutoresizingMaskIntoConstraints = false
            imageView.image = NSImage(contentsOf: url)
            container.addSubview(imageView)

            let remove = NSButton()
            remove.bezelStyle = .inline
            remove.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Remove image")
            remove.contentTintColor = NSColor.secondaryLabelColor
            remove.isBordered = false
            remove.translatesAutoresizingMaskIntoConstraints = false
            remove.tag = index
            remove.target = self
            remove.action = #selector(removeThumbnail(_:))
            container.addSubview(remove)

            container.widthAnchor.constraint(equalToConstant: 28).isActive = true
            container.heightAnchor.constraint(equalToConstant: 28).isActive = true
            NSLayoutConstraint.activate([
                imageView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                imageView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                imageView.topAnchor.constraint(equalTo: container.topAnchor),
                imageView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
                remove.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: 4),
                remove.topAnchor.constraint(equalTo: container.topAnchor, constant: -4),
                remove.widthAnchor.constraint(equalToConstant: 16),
                remove.heightAnchor.constraint(equalToConstant: 16),
            ])

            thumbnailStrip.addArrangedSubview(container)
        }
        updateThumbnailLayout()
    }

    private func updateThumbnailLayout() {
        let count = pendingImageURLs.count
        let hasImages = count > 0
        thumbnailStrip.isHidden = !hasImages
        // Each thumbnail is 28pt + 4pt spacing, plus 6pt leading margin.
        let stripWidth = hasImages ? CGFloat(count) * 28 + CGFloat(max(0, count - 1)) * 4 : 0
        thumbnailStackLeadingConstraint.constant = hasImages ? 6 : 0
        scrollLeadingConstraint.constant = hasImages ? 16 + stripWidth + 6 : 16
    }
}

extension CommandInputView: NSTextViewDelegate {
    func textDidChange(_ notification: Notification) {
        field.needsDisplay = true
        recomputeHeight()
        onTextChanged?(field.string)
    }

    func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.cancelOperation(_:)):
            onCancel?()
            return true
        case #selector(NSResponder.moveUp(_:)):
            if onMenuKey?(.up) == true { return true }
            if field.string.isEmpty { return onArrowUpAtEmpty?() ?? false }
            return false
        case #selector(NSResponder.moveDown(_:)):
            return onMenuKey?(.down) ?? false
        case #selector(NSResponder.insertNewline(_:)):
            // Menu open → accept the highlighted item. Shift+Return → literal
            // newline (let the text view handle it). Plain Return → submit.
            if onMenuKey?(.accept) == true { return true }
            let shift = NSApp.currentEvent?.modifierFlags.contains(.shift) ?? false
            if shift { return false }
            submit()
            return true
        case #selector(NSResponder.insertTab(_:)):
            return onMenuKey?(.accept) ?? false
        default:
            return false
        }
    }
}

/// Multi-line text view that reports focus changes, draws a placeholder while
/// empty, and intercepts image pastes.
///
/// Unfocus is deferred one turn so a handoff (e.g. to a menu row's mouseDown
/// that re-focuses us) isn't mistaken for a blur.
final class GrowingTextView: NSTextView {
    var onFocusChange: ((Bool) -> Void)?
    var onPasteImage: ((URL) -> Void)?

    var placeholder: String = ""
    var placeholderColor: NSColor = .secondaryLabelColor
    var placeholderAccentColor: NSColor = .controlAccentColor
    var placeholderFont: NSFont = .systemFont(ofSize: 12.5)

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !placeholder.isEmpty else { return }
        let pad = textContainer?.lineFragmentPadding ?? 0
        let origin = NSPoint(x: textContainerInset.width + pad, y: textContainerInset.height)
        attributedPlaceholder().draw(at: origin)
    }

    /// Plain placeholder in a calm color, with just the `/ @ #` sigils lifted
    /// into the accent color so the command grammar reads at a glance.
    private func attributedPlaceholder() -> NSAttributedString {
        let str = NSMutableAttributedString(string: placeholder, attributes: [
            .foregroundColor: placeholderColor,
            .font: placeholderFont,
        ])
        let full = str.string as NSString
        for sigil in ["/", "@", "#"] {
            let r = full.range(of: sigil)
            if r.location != NSNotFound {
                str.addAttribute(.foregroundColor, value: placeholderAccentColor, range: r)
            }
        }
        return str
    }

    override func paste(_ sender: Any?) {
        if let url = Self.extractImageFromPasteboard() {
            onPasteImage?(url)
            return
        }
        super.pasteAsPlainText(sender)
    }

    private static func extractImageFromPasteboard() -> URL? {
        let pb = NSPasteboard.general
        guard pb.types?.contains(where: {
            $0 == .png || $0 == .tiff || $0 == NSPasteboard.PasteboardType("public.file-url")
        }) == true else { return nil }

        if let url = pb.readObjects(forClasses: [NSURL.self], options: nil)?.first as? URL,
           NSImage(contentsOf: url) != nil {
            return url
        }

        guard let image = NSImage(pasteboard: pb) else { return nil }
        guard let rep = image.tiffRepresentation.flatMap({ NSBitmapImageRep(data: $0) }),
              let pngData = rep.representation(using: .png, properties: [:]) else { return nil }

        let tmpDir = FileManager.default.temporaryDirectory
        let fileName = "seahelm-paste-\(Int(Date().timeIntervalSince1970)).png"
        let fileURL = tmpDir.appendingPathComponent(fileName)
        do {
            try pngData.write(to: fileURL)
            return fileURL
        } catch {
            return nil
        }
    }

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok { onFocusChange?(true) }
        return ok
    }

    override func resignFirstResponder() -> Bool {
        let ok = super.resignFirstResponder()
        if ok {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                guard let window = self.window else { self.onFocusChange?(false); return }
                if window.firstResponder === self { return }
                self.onFocusChange?(false)
            }
        }
        return ok
    }
}
