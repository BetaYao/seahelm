import AppKit

// MARK: - CenterOverlayView

/// Full-cover overlay rendered on top of the center terminal panel.
/// Contains a header bar (title + close button) and a content area below.
/// The terminal keeps running underneath; dismiss via Esc or the close button.
final class CenterOverlayView: NSView {

    // MARK: Private

    private let titleLabel = NSTextField(labelWithString: "")
    private let closeButton = NSButton()
    private let saveButton = NSButton()
    private let previewButton = NSButton()
    private let headerBar = NSView()
    private let contentContainer = NSView()
    private let onClose: () -> Void
    private let onSave: (() -> Void)?
    private let onPreview: (() -> Void)?

    // MARK: Init

    init(
        title: String,
        content: NSView,
        onSave: (() -> Void)? = nil,
        onPreview: (() -> Void)? = nil,
        onClose: @escaping () -> Void
    ) {
        self.onClose = onClose
        self.onSave = onSave
        self.onPreview = onPreview
        super.init(frame: .zero)

        wantsLayer = true

        setupHeader(title: title)
        setupContent(content)
        // Header must sit above the content (e.g. the editor gutter) in z-order.
        addSubview(headerBar, positioned: .above, relativeTo: contentContainer)
        applyOpaqueBackground()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyOpaqueBackground()
    }

    /// The center terminal renders via a Metal layer that bleeds through any
    /// translucent background, so the overlay (and its header) must be fully
    /// opaque. Re-resolve the color whenever the appearance changes.
    private func applyOpaqueBackground() {
        var resolved = NSColor.windowBackgroundColor
        effectiveAppearance.performAsCurrentDrawingAppearance {
            resolved = SemanticColors.panel.usingColorSpace(.sRGB)?.withAlphaComponent(1.0)
                ?? NSColor.windowBackgroundColor
        }
        layer?.backgroundColor = resolved.cgColor
        headerBar.layer?.backgroundColor = resolved.cgColor
    }

    /// Reflect the editor's dirty state on the Save button.
    func setDirty(_ dirty: Bool) {
        saveButton.title = dirty ? "Save•" : "Saved"
        saveButton.isEnabled = dirty
    }

    /// Reflect the editor/preview mode on the Preview button.
    func setPreviewing(_ previewing: Bool) {
        previewButton.title = previewing ? "Edit" : "Preview"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // MARK: Setup

    private func setupHeader(title: String) {
        headerBar.translatesAutoresizingMaskIntoConstraints = false
        // Opaque background applied in applyOpaqueBackground() — the center
        // terminal's Metal layer bleeds through any translucent fill.
        headerBar.wantsLayer = true
        addSubview(headerBar)

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.stringValue = title
        titleLabel.textColor = SemanticColors.text
        titleLabel.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        titleLabel.lineBreakMode = .byTruncatingTail
        headerBar.addSubview(titleLabel)

        closeButton.translatesAutoresizingMaskIntoConstraints = false
        closeButton.isBordered = false
        closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close")
        closeButton.contentTintColor = SemanticColors.text
        closeButton.target = self
        closeButton.action = #selector(closeButtonTapped)
        headerBar.addSubview(closeButton)

        NSLayoutConstraint.activate([
            headerBar.topAnchor.constraint(equalTo: topAnchor),
            headerBar.leadingAnchor.constraint(equalTo: leadingAnchor),
            headerBar.trailingAnchor.constraint(equalTo: trailingAnchor),
            headerBar.heightAnchor.constraint(equalToConstant: 32),

            titleLabel.leadingAnchor.constraint(equalTo: headerBar.leadingAnchor, constant: 12),
            titleLabel.centerYAnchor.constraint(equalTo: headerBar.centerYAnchor),

            closeButton.trailingAnchor.constraint(equalTo: headerBar.trailingAnchor, constant: -8),
            closeButton.centerYAnchor.constraint(equalTo: headerBar.centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 20),
            closeButton.heightAnchor.constraint(equalToConstant: 20),
        ])

        // Right cluster, laid out right→left: Close, Save, Preview.
        var leftmost: NSView = closeButton

        func configureTextButton(_ button: NSButton, id: String, action: Selector) {
            button.translatesAutoresizingMaskIntoConstraints = false
            button.bezelStyle = .recessed
            button.isBordered = false
            button.font = NSFont.systemFont(ofSize: 12, weight: .medium)
            button.contentTintColor = SemanticColors.text
            button.target = self
            button.action = action
            button.setAccessibilityIdentifier(id)
            headerBar.addSubview(button)
            NSLayoutConstraint.activate([
                button.trailingAnchor.constraint(equalTo: leftmost.leadingAnchor, constant: -12),
                button.centerYAnchor.constraint(equalTo: headerBar.centerYAnchor),
            ])
            leftmost = button
        }

        if onSave != nil {
            configureTextButton(saveButton, id: "centerOverlay.saveButton", action: #selector(saveButtonTapped))
            setDirty(false)
        }
        if onPreview != nil {
            configureTextButton(previewButton, id: "centerOverlay.previewButton", action: #selector(previewButtonTapped))
            setPreviewing(false)
        }

        titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: leftmost.leadingAnchor, constant: -8).isActive = true
    }

    private func setupContent(_ content: NSView) {
        contentContainer.translatesAutoresizingMaskIntoConstraints = false
        addSubview(contentContainer)

        content.translatesAutoresizingMaskIntoConstraints = false
        contentContainer.addSubview(content)

        NSLayoutConstraint.activate([
            contentContainer.topAnchor.constraint(equalTo: headerBar.bottomAnchor),
            contentContainer.leadingAnchor.constraint(equalTo: leadingAnchor),
            contentContainer.trailingAnchor.constraint(equalTo: trailingAnchor),
            contentContainer.bottomAnchor.constraint(equalTo: bottomAnchor),

            content.topAnchor.constraint(equalTo: contentContainer.topAnchor),
            content.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor),
            content.bottomAnchor.constraint(equalTo: contentContainer.bottomAnchor),
        ])
    }

    // MARK: Actions

    @objc private func closeButtonTapped() {
        onClose()
    }

    @objc private func saveButtonTapped() {
        onSave?()
    }

    @objc private func previewButtonTapped() {
        onPreview?()
    }

    // MARK: Key handling

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { // Esc
            onClose()
        } else {
            super.keyDown(with: event)
        }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.keyCode == 53 {
            onClose()
            return true
        }
        // Cmd+S → save (when editable).
        if onSave != nil,
           event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
           event.charactersIgnoringModifiers == "s" {
            onSave?()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}
