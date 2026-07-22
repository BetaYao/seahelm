import AppKit

/// Helm command line (`/ command · @ repo · # agent` placeholder).
/// Pure input surface — it emits text changes and submit; the cockpit owns the
/// autocomplete dropdown (so it can float over the Orders/Watch list unclipped).
/// Keyboard navigation of the menu is deferred to WP-6; completion is mouse-driven.
final class CommandInputView: NSView {

    // Appearance-aware text; accents stay fixed.
    private static let ink: NSColor = SemanticColors.text
    private static let inkDim: NSColor = SemanticColors.muted

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

    private let field = FocusReportingTextField()
    private let box = FrostedPanelView()
    private let spinner = NSProgressIndicator()
    private let thumbnailStrip = NSStackView()
    private var savedPlaceholder: String?
    private var placeholder: String = "" {
        didSet { refreshPlaceholder() }
    }

    /// Temp file URLs of pasted images, in paste order. Cleared on submit/cancel.
    private(set) var pendingImageURLs: [URL] = [] {
        didSet { rebuildThumbnails() }
    }

    private var fieldLeadingConstraint: NSLayoutConstraint!
    private var thumbnailStackLeadingConstraint: NSLayoutConstraint!

    /// Anchors of the bordered input box, so the host can align the autocomplete
    /// dropdown to the box's bottom edge.
    var boxBottomAnchor: NSLayoutYAxisAnchor { box.bottomAnchor }
    var boxLeadingAnchor: NSLayoutXAxisAnchor { box.leadingAnchor }
    var boxTrailingAnchor: NSLayoutXAxisAnchor { box.trailingAnchor }

    var text: String {
        get { field.stringValue }
        set { field.stringValue = newValue }
    }

    /// Corner radius of the input box. Defaults to 8 (system menu glass).
    var boxCornerRadius: CGFloat = 8 {
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

        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = AppFont.mono(size: 12.5, weight: .regular)
        field.textColor = Self.ink
        placeholder = "Give an order — / command · @ repo · # agent"
        refreshChromeColors()
        field.delegate = self
        field.target = self
        field.action = #selector(submit)
        field.translatesAutoresizingMaskIntoConstraints = false
        field.setAccessibilityIdentifier("helm.commandInput")
        field.onFocusChange = { [weak self] focused in
            if focused {
                self?.onFocused?()
            } else {
                self?.onUnfocused?()
            }
        }
        field.onPasteImage = { [weak self] url in
            self?.attachImage(url: url)
        }
        box.addSubview(field)

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

        fieldLeadingConstraint = field.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 14)

        NSLayoutConstraint.activate([
            box.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            box.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            box.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            box.heightAnchor.constraint(equalToConstant: 40),

            fieldLeadingConstraint,
            field.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -14),
            field.centerYAnchor.constraint(equalTo: box.centerYAnchor),

            spinner.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -12),
            spinner.centerYAnchor.constraint(equalTo: box.centerYAnchor),

            thumbnailStackLeadingConstraint,
            thumbnailStrip.centerYAnchor.constraint(equalTo: box.centerYAnchor),
            thumbnailStrip.heightAnchor.constraint(equalToConstant: 28),

            box.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
        ])
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshChromeColors()
    }

    private func refreshPlaceholder() {
        field.placeholderAttributedString = NSAttributedString(
            string: placeholder,
            attributes: [
                .foregroundColor: Self.inkDim,
                .font: field.font ?? AppFont.mono(size: 12.5, weight: .regular),
            ]
        )
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
        refreshPlaceholder()
    }

    func focusInput() { window?.makeFirstResponder(field) }

    /// Whether the command field (or its field editor) currently owns focus.
    var isFieldFocused: Bool {
        guard let window else { return false }
        if window.firstResponder === field { return true }
        if let editor = field.currentEditor(), window.firstResponder === editor { return true }
        return false
    }

    /// Show a busy state while an async command runs: disable editing, swap the
    /// placeholder to `message`, and spin.
    func setLoading(_ loading: Bool, message: String = "Working…") {
        if loading {
            savedPlaceholder = placeholder
            field.stringValue = ""
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
    }

    /// Set the text, focus the field, and place the caret at the END (not a
    /// select-all, which would wipe the value on the next keystroke).
    func setTextAndFocusEnd(_ s: String) {
        field.stringValue = s
        window?.makeFirstResponder(field)
        // makeFirstResponder selects all; override to a collapsed caret at end.
        if let editor = field.currentEditor() {
            editor.selectedRange = NSRange(location: (s as NSString).length, length: 0)
        }
        onTextChanged?(s)
    }

    /// Clear any pending image attachments.
    func clearPendingImage() {
        pendingImageURLs = []
    }

    @objc private func submit() {
        let value = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        onSubmit?(value)
        field.stringValue = ""
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
        fieldLeadingConstraint.constant = hasImages ? 14 + stripWidth + 6 : 14
    }
}

extension CommandInputView: NSTextFieldDelegate {
    func controlTextDidChange(_ obj: Notification) {
        onTextChanged?(field.stringValue)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.cancelOperation(_:)):
            onCancel?()
            return true
        case #selector(NSResponder.moveUp(_:)):
            if onMenuKey?(.up) == true { return true }
            if field.stringValue.isEmpty { return onArrowUpAtEmpty?() ?? false }
            return false
        case #selector(NSResponder.moveDown(_:)):
            return onMenuKey?(.down) ?? false
        case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertTab(_:)):
            // Accept the highlighted menu item if the menu is open; otherwise let
            // the field submit (Enter) / change focus (Tab) as usual.
            return onMenuKey?(.accept) ?? false
        default:
            return false
        }
    }
}

/// NSTextField that reports focus changes (becomeFirstResponder fires on focus,
/// unlike controlTextDidBeginEditing which only fires on the first edit).
///
/// Unfocus is deferred one turn so we don't treat the handoff to the field
/// editor as a blur — AppKit resigns the text field itself when the editor
/// becomes first responder.
final class FocusReportingTextField: NSTextField {
    var onFocusChange: ((Bool) -> Void)?
    var onPasteImage: ((URL) -> Void)?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags == .command, event.charactersIgnoringModifiers == "v" {
            if let url = Self.extractImageFromPasteboard() {
                onPasteImage?(url)
                return true
            }
        }
        return super.performKeyEquivalent(with: event)
    }

    private static func extractImageFromPasteboard() -> URL? {
        let pb = NSPasteboard.general
        guard pb.types?.contains(where: {
            $0 == .png || $0 == .tiff || $0 == NSPasteboard.PasteboardType("public.file-url")
        }) == true else { return nil }

        if let url = pb.readObjects(forClasses: [NSURL.self], options: nil)?.first as? URL,
           let _ = NSImage(contentsOf: url) {
            return url
        }

        guard let image = NSImage(pasteboard: pb) else { return nil }
        let tiffData = image.tiffRepresentation
        guard let rep = tiffData.flatMap({ NSBitmapImageRep(data: $0) }),
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
                guard let window = self.window else {
                    self.onFocusChange?(false)
                    return
                }
                if window.firstResponder === self { return }
                if let editor = self.currentEditor(), window.firstResponder === editor { return }
                self.onFocusChange?(false)
            }
        }
        return ok
    }
}
