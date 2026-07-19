import AppKit

// MARK: - CenterOverlayView

/// Full-cover overlay on the center terminal panel. Title lives in the chrome
/// `TerminalHeaderView` above; this view only hosts an action toolbar + content.
/// The terminal keeps running underneath; dismiss via Esc or Close.
final class CenterOverlayView: NSView {

    // MARK: Private

    private let closeButton = NSButton()
    private let saveButton = NSButton()
    private let previewButton = NSButton()
    private let toolbar = NSView()
    private let contentContainer = NSView()
    private let onClose: () -> Void
    private let onSave: (() -> Void)?
    private let onPreview: (() -> Void)?
    private var colorSchemeObserver: NSObjectProtocol?

    // MARK: Init

    init(
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

        setupToolbar()
        setupContent(content)
        // Toolbar must sit above the content (e.g. the editor gutter) in z-order.
        addSubview(toolbar, positioned: .above, relativeTo: contentContainer)
        applyImmersion()

        colorSchemeObserver = NotificationCenter.default.addObserver(
            forName: .ghosttyColorSchemeDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.applyImmersion()
        }
    }

    deinit {
        if let colorSchemeObserver {
            NotificationCenter.default.removeObserver(colorSchemeObserver)
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyImmersion()
    }

    /// Toolbar matches `TerminalHeaderView` (Ghostty chrome). Content stays opaque
    /// so the Metal terminal underneath does not bleed through.
    private func applyImmersion() {
        let bridge = GhosttyBridge.shared
        let chromeBG = bridge.terminalChromeBackground
        let chromeFG = bridge.terminalChromeForeground

        toolbar.layer?.backgroundColor = chromeBG.cgColor
        // Root fill under the toolbar seam — same chrome so title + toolbar read as one strip.
        layer?.backgroundColor = chromeBG.cgColor

        var contentBG = NSColor.windowBackgroundColor
        effectiveAppearance.performAsCurrentDrawingAppearance {
            contentBG = SemanticColors.panel.usingColorSpace(.sRGB)?.withAlphaComponent(1.0)
                ?? NSColor.windowBackgroundColor
        }
        contentContainer.wantsLayer = true
        contentContainer.layer?.backgroundColor = contentBG.cgColor

        let tint = chromeFG.withAlphaComponent(0.85)
        closeButton.contentTintColor = tint
        saveButton.contentTintColor = tint
        previewButton.contentTintColor = tint
    }

    /// Reflect the editor's dirty state on the Save button.
    func setDirty(_ dirty: Bool) {
        saveButton.title = dirty ? "Save•" : "✓ Saved"
        saveButton.isEnabled = dirty
    }

    /// Reflect the editor/preview mode on the Preview button.
    func setPreviewing(_ previewing: Bool) {
        previewButton.title = previewing ? "Edit" : "Preview"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // MARK: Setup

    private func setupToolbar() {
        toolbar.translatesAutoresizingMaskIntoConstraints = false
        toolbar.wantsLayer = true
        toolbar.setAccessibilityIdentifier("centerOverlay.toolbar")
        addSubview(toolbar)

        closeButton.translatesAutoresizingMaskIntoConstraints = false
        closeButton.bezelStyle = .recessed
        closeButton.isBordered = false
        closeButton.title = "✕ Close"
        closeButton.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        closeButton.target = self
        closeButton.action = #selector(closeButtonTapped)
        closeButton.setAccessibilityIdentifier("centerOverlay.closeButton")
        toolbar.addSubview(closeButton)

        NSLayoutConstraint.activate([
            toolbar.topAnchor.constraint(equalTo: topAnchor),
            toolbar.leadingAnchor.constraint(equalTo: leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: trailingAnchor),
            toolbar.heightAnchor.constraint(equalToConstant: 32),

            closeButton.trailingAnchor.constraint(equalTo: toolbar.trailingAnchor, constant: -12),
            closeButton.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),
        ])

        // Right cluster, laid out right→left: Close, Save, Preview.
        var leftmost: NSView = closeButton

        func configureTextButton(_ button: NSButton, id: String, action: Selector) {
            button.translatesAutoresizingMaskIntoConstraints = false
            button.bezelStyle = .recessed
            button.isBordered = false
            button.font = NSFont.systemFont(ofSize: 12, weight: .medium)
            button.target = self
            button.action = action
            button.setAccessibilityIdentifier(id)
            toolbar.addSubview(button)
            NSLayoutConstraint.activate([
                button.trailingAnchor.constraint(equalTo: leftmost.leadingAnchor, constant: -12),
                button.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),
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
    }

    private func setupContent(_ content: NSView) {
        contentContainer.translatesAutoresizingMaskIntoConstraints = false
        contentContainer.wantsLayer = true
        addSubview(contentContainer)

        content.translatesAutoresizingMaskIntoConstraints = false
        contentContainer.addSubview(content)

        NSLayoutConstraint.activate([
            contentContainer.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
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
