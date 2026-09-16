import AppKit

/// The "+" on a project group header opens this: a small anchored form that
/// creates one worktree in that project. The repo is already decided by the header
/// that was clicked, so the form only asks for what a create actually needs —
/// the task, who staffs it, and what to branch from.
///
/// Equivalent to the helm's `/worktree <task> @<repo>`, and it lands the same
/// way: create, staff, then enter the new worktree.
final class AddWorktreePopoverController: NSViewController {
    /// (task, agentType). Worktrees always branch off the repo's main line, so
    /// the base is not a choice this form offers. The owner performs the create
    /// and then calls `reportFailure(_:)` if it fails.
    var onCreate: ((String, AgentType) -> Void)?

    private let project: String

    private let taskView = GrowingTextView()
    private let taskScroll = NSScrollView()
    private let composer = ComposerBoxView()
    private let attachmentStrip = NSStackView()
    private let formStack = NSStackView()
    private let agentChip = RoundedFillView(fill: Palette.chipFill, radius: 7)
    private let agentPopup = NSPopUpButton()
    private let createButton = CreateButton()
    private let errorLabel = NSTextField(wrappingLabelWithString: "")
    private let spinner = NSProgressIndicator()

    private var isCreating = false
    /// Temp-file URLs of images pasted into the task field, in paste order. They
    /// ride along to the agent as absolute paths appended to the task.
    private(set) var pendingImageURLs: [URL] = [] {
        didSet { rebuildThumbnails() }
    }

    private static let contentWidth: CGFloat = 360
    private static let horizontalInset: CGFloat = 14
    private static let topInset: CGFloat = 12
    private static let bottomInset: CGFloat = 14
    /// Three lines of the 12pt task font — room for a real brief without the
    /// popover turning into an editor.
    private static let taskHeight: CGFloat = 48
    private static let thumbnailSide: CGFloat = 44

    init(project: String) {
        self.project = project
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: Self.contentWidth, height: 160))

        let header = makeHeader()
        configureComposer()
        configureAgentPicker()

        errorLabel.font = AppFont.mono(size: 10)
        errorLabel.textColor = .systemRed
        errorLabel.maximumNumberOfLines = 3
        errorLabel.preferredMaxLayoutWidth = Self.contentWidth - Self.horizontalInset * 2
        errorLabel.isHidden = true

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false

        createButton.keyEquivalent = "\r"
        createButton.setAccessibilityIdentifier("dashboard.addWorktree.createButton")
        createButton.target = self
        createButton.action = #selector(submit)

        // Who staffs it on the left, Create on the right. A flexible spacer pins
        // Create to the trailing edge.
        let footerSpacer = NSView()
        footerSpacer.setContentHuggingPriority(.defaultLow - 1, for: .horizontal)
        let footer = NSStackView(views: [agentChip, footerSpacer, spinner, createButton])
        footer.orientation = .horizontal
        footer.alignment = .centerY
        footer.spacing = 8

        // The error sits in its own row under the brief rather than squeezed
        // between the controls, so a git message has room to wrap. Hidden, it
        // takes no space.
        [header, composer, errorLabel, footer].forEach(formStack.addArrangedSubview)
        formStack.orientation = .vertical
        formStack.alignment = .leading
        formStack.spacing = 10
        formStack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(formStack)

        NSLayoutConstraint.activate([
            root.widthAnchor.constraint(equalToConstant: Self.contentWidth),
            formStack.topAnchor.constraint(equalTo: root.topAnchor, constant: Self.topInset),
            formStack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -Self.bottomInset),
            formStack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: Self.horizontalInset),
            formStack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -Self.horizontalInset),
            header.widthAnchor.constraint(equalTo: formStack.widthAnchor),
            composer.widthAnchor.constraint(equalTo: formStack.widthAnchor),
            errorLabel.widthAnchor.constraint(equalTo: formStack.widthAnchor),
            footer.widthAnchor.constraint(equalTo: formStack.widthAnchor),
            footer.heightAnchor.constraint(equalToConstant: 28),
        ])

        view = root
        updateContentSize()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(taskView)
    }

    /// Branch glyph + title, with the project the "+" belonged to as a chip on
    /// the right so it's clear where the worktree lands.
    private func makeHeader() -> NSView {
        let branchIcon = symbolView("arrow.triangle.branch", pointSize: 11, weight: .semibold,
                                    tint: SemanticColors.accent)

        let titleLabel = NSTextField(labelWithString: "New worktree")
        titleLabel.font = AppFont.mono(size: 12, weight: .semibold)
        titleLabel.textColor = .labelColor

        let folderIcon = symbolView("folder", pointSize: 9, weight: .medium, tint: .secondaryLabelColor)
        let projectLabel = NSTextField(labelWithString: project)
        projectLabel.font = AppFont.mono(size: 10, weight: .medium)
        projectLabel.textColor = .secondaryLabelColor
        projectLabel.lineBreakMode = .byTruncatingMiddle
        projectLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let projectRow = NSStackView(views: [folderIcon, projectLabel])
        projectRow.orientation = .horizontal
        projectRow.alignment = .centerY
        projectRow.spacing = 4
        projectRow.translatesAutoresizingMaskIntoConstraints = false
        let projectChip = RoundedFillView(fill: Palette.chipFill, radius: 5)
        projectChip.toolTip = project
        projectChip.addSubview(projectRow)
        projectChip.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow - 1, for: .horizontal)
        let row = NSStackView(views: [branchIcon, titleLabel, spacer, projectChip])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 6
        row.setCustomSpacing(5, after: branchIcon)

        NSLayoutConstraint.activate([
            row.heightAnchor.constraint(equalToConstant: 20),
            projectChip.heightAnchor.constraint(equalToConstant: 18),
            projectRow.leadingAnchor.constraint(equalTo: projectChip.leadingAnchor, constant: 7),
            projectRow.trailingAnchor.constraint(equalTo: projectChip.trailingAnchor, constant: -7),
            projectRow.centerYAnchor.constraint(equalTo: projectChip.centerYAnchor),
        ])
        return row
    }

    /// The brief and its attachments share one rounded box, chat-composer style:
    /// a three-line text area (same `GrowingTextView` the helm used, so paste
    /// behaviour matches) with pasted screenshots lined up underneath. Return
    /// submits, Shift+Return inserts a newline.
    private func configureComposer() {
        taskView.font = AppFont.mono(size: 12)
        taskView.textColor = .labelColor
        taskView.insertionPointColor = SemanticColors.accent
        taskView.placeholder = "Describe the task, or paste a screenshot…"
        taskView.placeholderFont = AppFont.mono(size: 12)
        taskView.placeholderColor = .placeholderTextColor
        taskView.placeholderAccentColor = .placeholderTextColor
        taskView.isRichText = false
        taskView.drawsBackground = false
        taskView.isVerticallyResizable = true
        taskView.isHorizontallyResizable = false
        taskView.autoresizingMask = [.width]
        taskView.textContainerInset = NSSize(width: 0, height: 0)
        taskView.textContainer?.lineFragmentPadding = 0
        taskView.textContainer?.widthTracksTextView = true
        taskView.allowsUndo = true
        taskView.delegate = self
        taskView.setAccessibilityIdentifier("dashboard.addWorktree.taskField")
        taskView.onPasteImage = { [weak self] url in self?.pendingImageURLs.append(url) }
        taskView.onFocusChange = { [weak self] focused in self?.composer.isFocused = focused }

        taskScroll.drawsBackground = false
        taskScroll.borderType = .noBorder
        taskScroll.hasHorizontalScroller = false
        taskScroll.hasVerticalScroller = true
        taskScroll.autohidesScrollers = true
        taskScroll.scrollerStyle = .overlay
        taskScroll.translatesAutoresizingMaskIntoConstraints = false
        taskScroll.documentView = taskView

        attachmentStrip.orientation = .horizontal
        attachmentStrip.spacing = 6
        attachmentStrip.isHidden = true

        let content = NSStackView(views: [taskScroll, attachmentStrip])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 10
        content.translatesAutoresizingMaskIntoConstraints = false

        // A click in the box's padding (or beside the thumbnails) still means
        // "type here".
        composer.onMouseDown = { [weak self] in
            guard let self, !self.isCreating else { return }
            self.view.window?.makeFirstResponder(self.taskView)
        }
        composer.addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: composer.topAnchor, constant: 10),
            content.bottomAnchor.constraint(equalTo: composer.bottomAnchor, constant: -10),
            content.leadingAnchor.constraint(equalTo: composer.leadingAnchor, constant: 12),
            content.trailingAnchor.constraint(equalTo: composer.trailingAnchor, constant: -12),
            taskScroll.widthAnchor.constraint(equalTo: content.widthAnchor),
            taskScroll.heightAnchor.constraint(equalToConstant: Self.taskHeight),
            attachmentStrip.heightAnchor.constraint(equalToConstant: Self.thumbnailSide),
        ])
    }

    private func rebuildThumbnails() {
        attachmentStrip.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for (index, url) in pendingImageURLs.enumerated() {
            let thumbnail = AttachmentThumbnailView(url: url, side: Self.thumbnailSide)
            thumbnail.onRemove = { [weak self] in
                guard let self, !self.isCreating, index < self.pendingImageURLs.count else { return }
                self.pendingImageURLs.remove(at: index)
            }
            attachmentStrip.addArrangedSubview(thumbnail)
        }
        attachmentStrip.isHidden = pendingImageURLs.isEmpty
        updateContentSize()
    }

    /// Size the popover to whatever the form needs. Only `preferredContentSize`
    /// is set: NSPopover follows that, but assigning the view's frame by hand as
    /// well stops it following, and grown content then clips off the top.
    ///
    /// The form stack is measured, not `view`: NSViewController pins its view's
    /// height to `preferredContentSize` (priority 501), so the view's own fitting
    /// size only reports the last value back and the popover never shrinks.
    private func updateContentSize() {
        guard isViewLoaded else { return }
        let height = formStack.fittingSize.height + Self.topInset + Self.bottomInset
        preferredContentSize = NSSize(width: Self.contentWidth, height: ceil(height))
    }

    /// The agents a new worktree can be staffed with.
    static let agentChoices = AgentType.allCases.filter { $0.isAIAgent }

    /// A borderless pop-up in a soft chip, so the one choice in the footer reads
    /// as a setting on the brief rather than a second big button.
    private func configureAgentPicker() {
        agentPopup.removeAllItems()
        let defaultAgent = AgentType(rawValue: Config.load().defaultAgent) ?? .claudeCode
        for choice in Self.agentChoices {
            let item = NSMenuItem(title: choice.displayName, action: nil, keyEquivalent: "")
            item.representedObject = choice.rawValue
            agentPopup.menu?.addItem(item)
        }
        agentPopup.selectItem(withTitle: defaultAgent.displayName)
        agentPopup.isBordered = false
        agentPopup.font = AppFont.mono(size: 11, weight: .medium)
        agentPopup.controlSize = .small
        agentPopup.setAccessibilityIdentifier("dashboard.addWorktree.agentPopup")
        agentPopup.translatesAutoresizingMaskIntoConstraints = false

        let agentIcon = symbolView("sparkles", pointSize: 10, weight: .medium, tint: .secondaryLabelColor)
        let row = NSStackView(views: [agentIcon, agentPopup])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 2
        row.translatesAutoresizingMaskIntoConstraints = false
        agentChip.addSubview(row)
        agentChip.toolTip = "Agent to start in the new worktree"

        NSLayoutConstraint.activate([
            agentChip.heightAnchor.constraint(equalToConstant: 26),
            row.leadingAnchor.constraint(equalTo: agentChip.leadingAnchor, constant: 8),
            row.trailingAnchor.constraint(equalTo: agentChip.trailingAnchor, constant: -4),
            row.centerYAnchor.constraint(equalTo: agentChip.centerYAnchor),
        ])
    }

    private var selectedAgentType: AgentType {
        guard let raw = agentPopup.selectedItem?.representedObject as? String,
              let type = AgentType(rawValue: raw) else { return .claudeCode }
        return type
    }

    private func symbolView(_ name: String, pointSize: CGFloat, weight: NSFont.Weight,
                            tint: NSColor) -> NSImageView {
        let imageView = NSImageView(image: NSImage(systemSymbolName: name, accessibilityDescription: nil) ?? NSImage())
        imageView.symbolConfiguration = .init(pointSize: pointSize, weight: weight)
        imageView.contentTintColor = tint
        imageView.setContentHuggingPriority(.required, for: .horizontal)
        imageView.setContentCompressionResistancePriority(.required, for: .horizontal)
        return imageView
    }

    /// The brief handed to the agent: caption, then peelable image paths on
    /// their own line — same shape Telegram inbound media uses so
    /// `sendCommand` can paste attachments for Claude/Codex/Cursor/OpenCode.
    private var composedTask: String {
        let typed = taskView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        return TelegramInboundMedia.composeOrderText(
            paths: pendingImageURLs,
            caption: typed.isEmpty ? nil : typed)
    }

    @objc private func submit() {
        guard !isCreating else { return }
        let task = composedTask
        guard !task.isEmpty else {
            reportFailure("Describe the task first.")
            NSSound.beep()
            return
        }
        setCreating(true)
        onCreate?(task, selectedAgentType)
    }

    // MARK: - Owner callbacks

    func reportFailure(_ message: String) {
        setCreating(false)
        errorLabel.stringValue = message
        errorLabel.isHidden = false
        updateContentSize()
    }

    private func setCreating(_ creating: Bool) {
        isCreating = creating
        createButton.isEnabled = !creating
        createButton.isBusy = creating
        taskView.isEditable = !creating
        taskView.isSelectable = !creating
        agentPopup.isEnabled = !creating
        composer.alphaValue = creating ? 0.6 : 1
        if creating {
            errorLabel.isHidden = true
            spinner.startAnimation(nil)
        } else {
            spinner.stopAnimation(nil)
        }
        updateContentSize()
    }

    // MARK: Test hooks

    var isCreatingForTesting: Bool { isCreating }
    var errorTextForTesting: String? { errorLabel.isHidden ? nil : errorLabel.stringValue }
    var agentChoiceTitlesForTesting: [String] { agentPopup.itemTitles }
    var thumbnailCountForTesting: Int { attachmentStrip.arrangedSubviews.count }
    var contentSizeForTesting: NSSize { preferredContentSize }
    func setTaskForTesting(_ text: String) { taskView.string = text }
    func attachImageForTesting(_ url: URL) { pendingImageURLs.append(url) }
    func removeImageForTesting(at index: Int) {
        guard index >= 0, index < pendingImageURLs.count else { return }
        pendingImageURLs.remove(at: index)
    }
    func submitForTesting() { submit() }
}

extension AddWorktreePopoverController: NSTextViewDelegate {
    func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            // Shift+Return keeps the brief multi-line; plain Return creates.
            if NSApp.currentEvent?.modifierFlags.contains(.shift) == true { return false }
            submit()
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            view.window?.performClose(nil)
            return true
        default:
            return false
        }
    }
}

// MARK: - Styling

/// Fills tuned to sit on the popover's own translucent material in both
/// appearances, rather than the opaque navy panels of the main window.
private enum Palette {
    static let chipFill = NSColor(name: nil) { appearance in
        appearance.isDark ? .white.withAlphaComponent(0.07) : .black.withAlphaComponent(0.05)
    }
    static let composerFill = NSColor(name: nil) { appearance in
        appearance.isDark ? .black.withAlphaComponent(0.18) : .white.withAlphaComponent(0.75)
    }
    static let composerStroke = NSColor(name: nil) { appearance in
        appearance.isDark ? .white.withAlphaComponent(0.09) : .black.withAlphaComponent(0.10)
    }
    static let composerStrokeFocused = SemanticColors.accent.withAlphaComponent(0.6)
    /// Readable ink on a solid accent fill: dark mode's accent is a bright cyan
    /// (white on it fails contrast), light mode's a deep teal.
    static let inkOnAccent = NSColor(name: nil) { appearance in
        appearance.isDark ? NSColor(hex: 0x03181e) : .white
    }
}

/// A rounded fill whose colors resolve at draw time, so the popover re-themes on
/// a light/dark flip instead of keeping a `cgColor` captured in `loadView`.
private class RoundedFillView: NSView {
    var fill: NSColor { didSet { needsDisplay = true } }
    var stroke: NSColor? { didSet { needsDisplay = true } }
    private let radius: CGFloat

    init(fill: NSColor, stroke: NSColor? = nil, radius: CGFloat) {
        self.fill = fill
        self.stroke = stroke
        self.radius = radius
        super.init(frame: .zero)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.cornerRadius = radius
        layer?.cornerCurve = .continuous
        layer?.backgroundColor = fill.cgColor
        layer?.borderWidth = stroke == nil ? 0 : 1
        layer?.borderColor = stroke?.cgColor
    }
}

/// The brief's box: takes an accent outline while the text inside has focus.
private final class ComposerBoxView: RoundedFillView {
    var onMouseDown: (() -> Void)?
    var isFocused = false {
        didSet { stroke = isFocused ? Palette.composerStrokeFocused : Palette.composerStroke }
    }

    init() {
        super.init(fill: Palette.composerFill, stroke: Palette.composerStroke, radius: 9)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    override func mouseDown(with event: NSEvent) {
        onMouseDown?()
    }
}

/// One pasted image: an aspect-filled square with a remove badge kept inside its
/// corner (a badge hanging off the edge gets clipped by the rounded mask).
private final class AttachmentThumbnailView: NSView {
    var onRemove: (() -> Void)?
    private let image: NSImage

    init(url: URL, side: CGFloat) {
        image = NSImage(contentsOf: url) ?? NSWorkspace.shared.icon(forFile: url.path)
        super.init(frame: NSRect(x: 0, y: 0, width: side, height: side))
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        toolTip = url.lastPathComponent

        let remove = NSButton()
        remove.isBordered = false
        remove.bezelStyle = .inline
        remove.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Remove image")
        remove.symbolConfiguration = .init(pointSize: 7, weight: .bold)
        remove.contentTintColor = .white
        remove.imagePosition = .imageOnly
        remove.wantsLayer = true
        remove.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.6).cgColor
        remove.layer?.cornerRadius = 8
        remove.toolTip = "Remove"
        remove.translatesAutoresizingMaskIntoConstraints = false
        remove.target = self
        remove.action = #selector(removeTapped)
        addSubview(remove)

        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: side),
            heightAnchor.constraint(equalToConstant: side),
            remove.widthAnchor.constraint(equalToConstant: 16),
            remove.heightAnchor.constraint(equalToConstant: 16),
            remove.topAnchor.constraint(equalTo: topAnchor, constant: 3),
            remove.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -3),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        guard let layer else { return }
        layer.cornerRadius = 7
        layer.cornerCurve = .continuous
        layer.masksToBounds = true
        layer.contentsGravity = .resizeAspectFill
        layer.contents = image.layerContents(forContentsScale: layer.contentsScale)
        layer.borderWidth = 1
        layer.borderColor = Palette.composerStroke.cgColor
    }

    @objc private func removeTapped() { onRemove?() }
}

/// Accent-filled Create button with a faint ↩ hint. Custom because the stock
/// default button paints the system blue, which clashes with the app's teal
/// accent.
private final class CreateButton: NSButton {
    /// Swaps the label to "Creating…" while the worktree is being made.
    var isBusy = false { didSet { refreshTitle() } }
    private var hovering = false
    private var hoverArea: NSTrackingArea?

    /// Draws no bezel: a Return `keyEquivalent` otherwise makes AppKit paint the
    /// default-button chrome under our fill.
    private final class PillCell: NSButtonCell {
        override func drawBezel(withFrame frame: NSRect, in controlView: NSView) {}
    }

    init() {
        super.init(frame: .zero)
        let pill = PillCell()
        pill.isBordered = false
        pill.backgroundColor = .clear
        pill.highlightsBy = []
        pill.showsStateBy = []
        cell = pill
        isBordered = false
        focusRingType = .none
        alignment = .center
        wantsLayer = true
        layer?.cornerRadius = 7
        layer?.cornerCurve = .continuous
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 96),
            heightAnchor.constraint(equalToConstant: 28),
        ])
        refreshTitle()
        refreshFill()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    override var isEnabled: Bool { didSet { refreshFill() } }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshFill()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(
            rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self, userInfo: nil
        )
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseEntered(with event: NSEvent) { hovering = true; refreshFill() }
    override func mouseExited(with event: NSEvent) { hovering = false; refreshFill() }

    /// A layer fill rather than drawing in `draw(_:)`, which the popover's
    /// material swallows.
    private func refreshFill() {
        let alpha: CGFloat = !isEnabled ? 0.45 : (hovering ? 0.85 : 1)
        layer?.backgroundColor = resolvedCGColor(SemanticColors.accent.withAlphaComponent(alpha))
    }

    private func refreshTitle() {
        let title = NSMutableAttributedString(string: isBusy ? "Creating…" : "Create", attributes: [
            .font: AppFont.mono(size: 11, weight: .semibold),
            .foregroundColor: Palette.inkOnAccent,
        ])
        if !isBusy {
            title.append(NSAttributedString(string: "  ↩", attributes: [
                .font: AppFont.mono(size: 11, weight: .medium),
                .foregroundColor: Palette.inkOnAccent.withAlphaComponent(0.5),
            ]))
        }
        attributedTitle = title
    }
}
