import AppKit

/// The "+" on a project group header opens this: a small anchored form that
/// creates one worktree in that deck. The repo is already decided by the header
/// that was clicked, so the form only asks for what a create actually needs —
/// the task, who staffs it, and what to branch from.
///
/// Equivalent to the helm's `/worktree <task> @<repo>`, and it lands the same
/// way: create, staff, then enter the new cabin.
final class AddCabinPopoverController: NSViewController {
    /// (task, agentType). Worktrees always branch off the repo's main line, so
    /// the base is not a choice this form offers. The owner performs the create
    /// and then calls `reportFailure(_:)` if it fails.
    var onCreate: ((String, SailorType) -> Void)?

    private let project: String

    private let taskView = GrowingTextView()
    private let taskScroll = NSScrollView()
    private let taskBox = NSView()
    private let thumbnailStrip = NSStackView()
    private let headerRow = NSStackView()
    private let footerRow = NSStackView()
    private let agentPopup = NSPopUpButton()
    private let createButton = NSButton()
    private let errorLabel = NSTextField(labelWithString: "")
    private let spinner = NSProgressIndicator()

    private var isCreating = false
    /// Temp-file URLs of images pasted into the task field, in paste order. They
    /// ride along to the agent as absolute paths appended to the task.
    private(set) var pendingImageURLs: [URL] = [] {
        didSet { rebuildThumbnails() }
    }

    private static let contentWidth: CGFloat = 340
    private static let baseContentHeight: CGFloat = 142
    private static let thumbnailContentHeight: CGFloat = 178
    /// Two lines of the task font — a one-liner felt cramped for a task brief.
    private static let taskLineHeight: CGFloat = 15
    private static let taskVisibleLines: CGFloat = 2

    init(project: String) {
        self.project = project
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    override func loadView() {
        let root = NSView(frame: NSRect(
            x: 0,
            y: 0,
            width: Self.contentWidth,
            height: Self.baseContentHeight
        ))

        let titleLabel = NSTextField(labelWithString: "New worktree")
        titleLabel.font = AppFont.mono(size: 12, weight: .semibold)
        titleLabel.textColor = .labelColor

        let projectIcon = NSImageView(image: NSImage(
            systemSymbolName: "folder",
            accessibilityDescription: "Project"
        ) ?? NSImage())
        projectIcon.symbolConfiguration = .init(pointSize: 10, weight: .medium)
        projectIcon.contentTintColor = .secondaryLabelColor
        projectIcon.translatesAutoresizingMaskIntoConstraints = false

        let projectLabel = NSTextField(labelWithString: project)
        projectLabel.font = AppFont.mono(size: 10, weight: .medium)
        projectLabel.textColor = .secondaryLabelColor
        projectLabel.lineBreakMode = .byTruncatingMiddle

        let headerSpacer = NSView()
        headerSpacer.setContentHuggingPriority(.defaultLow - 1, for: .horizontal)
        headerRow.setViews([titleLabel, headerSpacer, projectIcon, projectLabel], in: .leading)
        headerRow.orientation = .horizontal
        headerRow.alignment = .centerY
        headerRow.spacing = 6

        configureTaskField()
        configureAgentPopup()

        errorLabel.font = AppFont.mono(size: 10)
        errorLabel.textColor = .systemRed
        errorLabel.lineBreakMode = .byTruncatingTail
        errorLabel.isHidden = true

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false

        createButton.title = "Create"
        createButton.bezelStyle = .rounded
        createButton.controlSize = .regular
        createButton.font = AppFont.mono(size: 11)
        createButton.keyEquivalent = "\r"
        createButton.setAccessibilityIdentifier("dashboard.addWorktree.createButton")
        createButton.target = self
        createButton.action = #selector(submit)

        // One control row: who staffs it on the left, Create on the right. A
        // flexible spacer — not the error label — pins Create to the trailing
        // edge, since a hidden arranged view reserves no width.
        let footerSpacer = NSView()
        footerSpacer.setContentHuggingPriority(.defaultLow - 1, for: .horizontal)
        footerSpacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        footerRow.setViews([agentPopup, errorLabel, footerSpacer, spinner, createButton], in: .leading)
        footerRow.orientation = .horizontal
        footerRow.spacing = 8
        footerRow.alignment = .centerY
        agentPopup.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        errorLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        createButton.setContentHuggingPriority(.required, for: .horizontal)

        let stack = NSStackView(views: [headerRow, taskBox, thumbnailStrip, footerRow])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)

        NSLayoutConstraint.activate([
            root.widthAnchor.constraint(equalToConstant: Self.contentWidth),
            headerRow.heightAnchor.constraint(equalToConstant: 20),
            projectIcon.widthAnchor.constraint(equalToConstant: 13),
            projectIcon.heightAnchor.constraint(equalToConstant: 13),
            taskBox.heightAnchor.constraint(equalToConstant: 50),
            thumbnailStrip.heightAnchor.constraint(equalToConstant: 26),
            footerRow.heightAnchor.constraint(equalToConstant: 28),
            agentPopup.widthAnchor.constraint(equalToConstant: 142),
            agentPopup.heightAnchor.constraint(equalToConstant: 28),
            createButton.widthAnchor.constraint(equalToConstant: 78),
            createButton.heightAnchor.constraint(equalToConstant: 28),
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 12),
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            headerRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            taskBox.widthAnchor.constraint(equalTo: stack.widthAnchor),
            footerRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])

        view = root
        updateContentSize()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(taskView)
    }

    /// A two-line task brief that also takes pasted images (same `GrowingTextView`
    /// the helm uses, so paste behaviour matches). Return submits, Shift+Return
    /// inserts a newline.
    private func configureTaskField() {
        taskView.font = AppFont.mono(size: 12)
        taskView.placeholder = "Describe the task…"
        taskView.placeholderFont = AppFont.mono(size: 12)
        taskView.placeholderColor = .secondaryLabelColor
        taskView.placeholderAccentColor = .secondaryLabelColor
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

        taskScroll.drawsBackground = false
        taskScroll.borderType = .noBorder
        taskScroll.hasHorizontalScroller = false
        taskScroll.hasVerticalScroller = true
        taskScroll.autohidesScrollers = true
        taskScroll.translatesAutoresizingMaskIntoConstraints = false
        taskScroll.documentView = taskView

        taskBox.wantsLayer = true
        taskBox.layer?.cornerRadius = 6
        taskBox.layer?.borderWidth = 1
        taskBox.layer?.borderColor = NSColor.separatorColor.cgColor
        taskBox.layer?.backgroundColor = NSColor.textBackgroundColor.withAlphaComponent(0.5).cgColor
        taskBox.addSubview(taskScroll)
        NSLayoutConstraint.activate([
            taskScroll.leadingAnchor.constraint(equalTo: taskBox.leadingAnchor, constant: 10),
            taskScroll.trailingAnchor.constraint(equalTo: taskBox.trailingAnchor, constant: -10),
            taskScroll.topAnchor.constraint(equalTo: taskBox.topAnchor, constant: 8),
            taskScroll.bottomAnchor.constraint(equalTo: taskBox.bottomAnchor, constant: -8),
            taskScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: Self.taskLineHeight * Self.taskVisibleLines),
        ])

        thumbnailStrip.orientation = .horizontal
        thumbnailStrip.spacing = 4
        thumbnailStrip.isHidden = true
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
            imageView.imageScaling = .scaleProportionallyUpOrDown
            imageView.translatesAutoresizingMaskIntoConstraints = false
            imageView.image = NSImage(contentsOf: url)
            imageView.toolTip = url.lastPathComponent
            container.addSubview(imageView)

            let remove = NSButton()
            remove.isBordered = false
            remove.bezelStyle = .inline
            remove.image = NSImage(systemSymbolName: "xmark.circle.fill",
                                   accessibilityDescription: "Remove image")
            remove.contentTintColor = .secondaryLabelColor
            remove.translatesAutoresizingMaskIntoConstraints = false
            remove.tag = index
            remove.target = self
            remove.action = #selector(removeThumbnail(_:))
            container.addSubview(remove)

            NSLayoutConstraint.activate([
                container.widthAnchor.constraint(equalToConstant: 26),
                container.heightAnchor.constraint(equalToConstant: 26),
                imageView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                imageView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                imageView.topAnchor.constraint(equalTo: container.topAnchor),
                imageView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
                remove.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: 3),
                remove.topAnchor.constraint(equalTo: container.topAnchor, constant: -3),
                remove.widthAnchor.constraint(equalToConstant: 14),
                remove.heightAnchor.constraint(equalToConstant: 14),
            ])
            thumbnailStrip.addArrangedSubview(container)
        }
        thumbnailStrip.isHidden = pendingImageURLs.isEmpty
        updateContentSize()
    }

    private func updateContentSize() {
        let height = pendingImageURLs.isEmpty
            ? Self.baseContentHeight
            : Self.thumbnailContentHeight
        preferredContentSize = NSSize(width: Self.contentWidth, height: height)
        guard isViewLoaded else { return }
        view.frame.size = preferredContentSize
    }

    @objc private func removeThumbnail(_ sender: NSButton) {
        guard sender.tag >= 0, sender.tag < pendingImageURLs.count else { return }
        pendingImageURLs.remove(at: sender.tag)
    }

    private func configureAgentPopup() {
        agentPopup.removeAllItems()
        let defaultAgent = SailorType(rawValue: Config.load().defaultAgent) ?? .claudeCode
        for choice in InlineCabinCreateView.agentChoices {
            let item = NSMenuItem(title: choice.displayName, action: nil, keyEquivalent: "")
            item.representedObject = choice.rawValue
            agentPopup.menu?.addItem(item)
        }
        agentPopup.selectItem(withTitle: defaultAgent.displayName)
        agentPopup.font = AppFont.mono(size: 11)
        agentPopup.controlSize = .regular
        agentPopup.setAccessibilityIdentifier("dashboard.addWorktree.agentPopup")
    }

    private var selectedAgentType: SailorType {
        guard let raw = agentPopup.selectedItem?.representedObject as? String,
              let type = SailorType(rawValue: raw) else { return .claudeCode }
        return type
    }

    /// The brief handed to the agent: the typed text plus one absolute path per
    /// pasted image, which is how these CLIs take attachments.
    private var composedTask: String {
        let typed = taskView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !pendingImageURLs.isEmpty else { return typed }
        let paths = pendingImageURLs.map(\.path).joined(separator: " ")
        return typed.isEmpty ? paths : "\(typed) \(paths)"
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
    }

    private func setCreating(_ creating: Bool) {
        isCreating = creating
        createButton.isEnabled = !creating
        taskView.isEditable = !creating
        taskView.isSelectable = !creating
        agentPopup.isEnabled = !creating
        if creating {
            errorLabel.isHidden = true
            spinner.startAnimation(nil)
        } else {
            spinner.stopAnimation(nil)
        }
    }

    // MARK: Test hooks

    var isCreatingForTesting: Bool { isCreating }
    var errorTextForTesting: String? { errorLabel.isHidden ? nil : errorLabel.stringValue }
    var agentChoiceTitlesForTesting: [String] { agentPopup.itemTitles }
    var thumbnailCountForTesting: Int { thumbnailStrip.arrangedSubviews.count }
    var contentSizeForTesting: NSSize { preferredContentSize }
    func setTaskForTesting(_ text: String) { taskView.string = text }
    func attachImageForTesting(_ url: URL) { pendingImageURLs.append(url) }
    func removeImageForTesting(at index: Int) {
        guard index >= 0, index < pendingImageURLs.count else { return }
        pendingImageURLs.remove(at: index)
    }
    func submitForTesting() { submit() }
}

extension AddCabinPopoverController: NSTextViewDelegate {
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
