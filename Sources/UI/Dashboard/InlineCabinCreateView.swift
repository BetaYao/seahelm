import AppKit
import QuartzCore

/// ChatGPT-style sticky worktree creator at the bottom of the sidebar: a tall
/// rounded prompt box with the name field on top and a bottom row showing the
/// target repo (tap to switch or add) plus the reuse-environment toggle.
final class InlineCabinCreateView: NSView, NSTextViewDelegate {
    /// (taskDescription, repoPath, agentType, reuseEnvironment)
    var onCreate: ((String, String, SailorType, Bool) -> Void)?
    /// Requests an outer height constraint update. The dashboard owns the
    /// constraint so the sidebar can animate around the sticky creator.
    var onPreferredHeightChange: ((CGFloat, Bool) -> Void)?
    /// Invoked when the user picks "Add repo…" — should open a picker and add a workspace.
    var onAddRepo: (() -> Void)?
    /// Live source of the current repo paths, read fresh whenever the menu opens
    /// so newly-added repos appear without re-configuring.
    var repoPathsProvider: (() -> [String])?
    /// Called when the create form is dismissed — on successful submit OR cancel —
    /// so the keyboard-mode controller can exit `.createForm` and return the
    /// dashboard nav ring to `.normal`.
    var onFormEnd: (() -> Void)?
    /// Fired when the user presses Return and the text starts with `/`.
    /// The full trimmed text (including the `/` prefix) is passed to the handler.
    var onSubmitCommand: ((String) -> Void)?

    static let agentChoices = SailorType.allCases.filter { $0.isAIAgent }
    var selectedSailorType: SailorType = {
        SailorType(rawValue: Config.load().defaultAgent) ?? .claudeCode
    }()

    private let promptTextView = PromptTextView()
    private let repoChip = DropdownChip()
    private let agentChip = DropdownChip()
    private let reuseEnvCheckbox: KeyCheckbox = {
        let b = KeyCheckbox()
        b.setButtonType(.switch)
        b.title = "Reuse env"
        return b
    }()
    private let errorLabel = NSTextField(labelWithString: "")
    private var errorHeight: NSLayoutConstraint!
    private var promptHeight: NSLayoutConstraint!

    private var repoPaths: [String] = []
    var selectedRepoPath: String?

    private static let collapsedHeight: CGFloat = 84
    private static let expandedHeight: CGFloat = 120
    private static let collapsedFieldHeight: CGFloat = 24
    private static let expandedFieldHeight: CGFloat = 58
    private static let controlRowHeight: CGFloat = 24
    private static let controlRowBottomPadding: CGFloat = 10
    private static let expansionDuration: TimeInterval = 0.22

    var isExpandedForTesting = false
    var preferredHeightForTesting: CGFloat { preferredHeight }
    var agentChipTitleForTesting: String { agentChip.titleForTesting }
    var agentChipShowsIconForTesting: Bool { agentChip.showsIconForTesting }
    var agentChipBorderWidthForTesting: CGFloat { agentChip.borderWidthForTesting }
    var repoChipPreferredHeightForTesting: CGFloat { Self.controlRowHeight }
    var controlRowBottomPaddingForTesting: CGFloat { Self.controlRowBottomPadding }

    var preferredHeight: CGFloat {
        let base = isExpandedForTesting ? Self.expandedHeight : Self.collapsedHeight
        return base + (errorLabel.isHidden ? 0 : errorHeight.constant + 6)
    }

    /// A clearly-elevated fill so the input reads as a distinct box, not the
    /// same surface as the cards above it.
    private static let inputBg = NSColor(name: nil) { a in
        a.isDark ? NSColor(hex: 0x2b2e35) : NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.99)
    }
    private static let inputBorder = NSColor(name: nil) { a in
        a.isDark ? NSColor(hex: 0x4a4e57) : NSColor(hex: 0xb9c3d1)
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    func configure(repoPaths: [String]) {
        self.repoPaths = repoPaths
        if selectedRepoPath == nil || !(repoPaths.contains(selectedRepoPath ?? "")) {
            selectedRepoPath = repoPaths.first
        }
        applySelectedRepo()
    }

    func focusNameField() { window?.makeFirstResponder(promptTextView) }

    // MARK: Test hooks
    func setNameForTesting(_ s: String) { promptTextView.setPlainText(s) }
    func setReuseEnvForTesting(_ on: Bool) { reuseEnvCheckbox.state = on ? .on : .off }
    func setExpandedForTesting(_ on: Bool) { setExpanded(on, animated: false) }
    func submitForTesting() { submit() }

    private func setup() {
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.borderWidth = 1.5
        layer?.masksToBounds = false
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.35
        layer?.shadowRadius = 10
        layer?.shadowOffset = NSSize(width: 0, height: -3)
        applyColors()

        promptTextView.placeholderString = "Describe the task…"
        promptTextView.font = AppFont.mono(size: 13, weight: .regular)
        promptTextView.delegate = self
        promptTextView.translatesAutoresizingMaskIntoConstraints = false
        promptTextView.onFocusChange = { [weak self] focused in
            self?.setExpanded(focused, animated: true)
        }
        promptTextView.onCancel = { [weak self] in self?.cancelForm() }
        promptTextView.onSubmit = { [weak self] in self?.submit() }
        addSubview(promptTextView)

        errorLabel.maximumNumberOfLines = 2
        errorLabel.font = NSFont.systemFont(ofSize: 10)
        errorLabel.textColor = .systemRed
        errorLabel.isHidden = true
        errorLabel.lineBreakMode = .byWordWrapping
        errorLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(errorLabel)

        // Repo chip: shows the repo name, opens a fresh menu (switch + add).
        repoChip.translatesAutoresizingMaskIntoConstraints = false
        repoChip.onClick = { [weak self] in self?.repoButtonClicked() }
        repoChip.onKeyDown = { [weak self] event in self?.handleRepoChipKey(event) ?? false }
        addSubview(repoChip)

        // Agent chip: pick which AI agent to launch in the new worktree.
        agentChip.translatesAutoresizingMaskIntoConstraints = false
        agentChip.onClick = { [weak self] in self?.agentButtonClicked() }
        agentChip.onKeyDown = { [weak self] event in self?.handleSailorChipKey(event) ?? false }
        agentChip.setIcon(svgString: selectedSailorType.inlinePickerLogoSVG,
                          symbolName: selectedSailorType.inlinePickerSymbolName,
                          accessibilityLabel: selectedSailorType.displayName)
        addSubview(agentChip)

        reuseEnvCheckbox.font = NSFont.systemFont(ofSize: 11)
        reuseEnvCheckbox.translatesAutoresizingMaskIntoConstraints = false
        reuseEnvCheckbox.setContentHuggingPriority(.required, for: .horizontal)
        reuseEnvCheckbox.onKeyDown = { [weak self] event in self?.handleReuseCheckboxKey(event) ?? false }
        addSubview(reuseEnvCheckbox)

        errorHeight = errorLabel.heightAnchor.constraint(equalToConstant: 0)
        promptHeight = promptTextView.heightAnchor.constraint(equalToConstant: Self.collapsedFieldHeight)
        promptHeight.priority = .init(999)

        NSLayoutConstraint.activate([
            promptTextView.topAnchor.constraint(equalTo: topAnchor, constant: 14),
            promptTextView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18),
            promptTextView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -18),
            promptHeight,

            errorLabel.topAnchor.constraint(equalTo: promptTextView.bottomAnchor, constant: 4),
            errorLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            errorLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            errorHeight,
            errorLabel.bottomAnchor.constraint(lessThanOrEqualTo: repoChip.topAnchor),

            repoChip.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            repoChip.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Self.controlRowBottomPadding),
            repoChip.heightAnchor.constraint(equalToConstant: Self.controlRowHeight),

            agentChip.centerYAnchor.constraint(equalTo: repoChip.centerYAnchor),
            agentChip.leadingAnchor.constraint(equalTo: repoChip.trailingAnchor, constant: 10),
            agentChip.heightAnchor.constraint(equalToConstant: Self.controlRowHeight),
            agentChip.widthAnchor.constraint(equalToConstant: 40),

            reuseEnvCheckbox.centerYAnchor.constraint(equalTo: repoChip.centerYAnchor),
            reuseEnvCheckbox.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            reuseEnvCheckbox.leadingAnchor.constraint(greaterThanOrEqualTo: agentChip.trailingAnchor, constant: 8),
        ])
    }

    private func agentButtonClicked() {
        let menu = NSMenu()
        for type in Self.agentChoices {
            let item = NSMenuItem(title: type.displayName, action: #selector(selectSailor(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = type.rawValue
            item.state = (type == selectedSailorType) ? .on : .off
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: agentChip.bounds.height + 4), in: agentChip)
    }

    @objc private func selectSailor(_ sender: NSMenuItem) {
        if let raw = sender.representedObject as? String, let type = SailorType(rawValue: raw) {
            selectedSailorType = type
            refreshSailorChip()
        }
    }

    /// Updates the agent chip icon/label from `selectedSailorType`. Shared by the
    /// menu action and the arrow-key cycling path.
    private func refreshSailorChip() {
        agentChip.setIcon(svgString: selectedSailorType.inlinePickerLogoSVG,
                          symbolName: selectedSailorType.inlinePickerSymbolName,
                          accessibilityLabel: selectedSailorType.displayName)
    }

    /// Updates the repo chip title from `selectedRepoPath`. Shared by the menu
    /// action and the arrow-key cycling path.
    private func applySelectedRepo() {
        let name = selectedRepoPath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "Select repo"
        repoChip.setTitle(name)
    }

    private func repoButtonClicked() {
        let menu = NSMenu()
        let paths = repoPathsProvider?() ?? repoPaths
        repoPaths = paths
        for path in paths {
            let item = NSMenuItem(title: URL(fileURLWithPath: path).lastPathComponent,
                                  action: #selector(selectRepo(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = path
            item.state = (path == selectedRepoPath) ? .on : .off
            menu.addItem(item)
        }
        if !paths.isEmpty { menu.addItem(.separator()) }
        let add = NSMenuItem(title: "Add deck…", action: #selector(addRepoClicked), keyEquivalent: "")
        add.target = self
        menu.addItem(add)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: repoChip.bounds.height + 4), in: repoChip)
    }

    @objc private func selectRepo(_ sender: NSMenuItem) {
        selectedRepoPath = sender.representedObject as? String
        applySelectedRepo()
    }

    @objc private func addRepoClicked() { onAddRepo?() }

    func reportCreateSuccess() {
        promptTextView.setPlainText("")
        errorLabel.isHidden = true
        errorLabel.stringValue = ""
        errorHeight.constant = 0
        onPreferredHeightChange?(preferredHeight, true)
    }

    func reportCreateFailure(_ message: String) {
        errorLabel.stringValue = message
        errorLabel.isHidden = false
        errorHeight.constant = errorLabel.intrinsicContentSize.height
        onPreferredHeightChange?(preferredHeight, true)
    }

    @objc private func submit() {
        let text = promptTextView.plainText.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        if text.hasPrefix("/") {
            onSubmitCommand?(text)
            clearAfterSubmit()
            onFormEnd?()
        } else {
            guard let repo = selectedRepoPath else { return }
            onCreate?(text, repo, selectedSailorType, reuseEnvCheckbox.state == .on)
            onFormEnd?()
        }
    }

    private func clearAfterSubmit() {
        promptTextView.setPlainText("")
        hideCommandCompletions()
        errorLabel.isHidden = true
        errorLabel.stringValue = ""
        errorHeight.constant = 0
        onPreferredHeightChange?(preferredHeight, true)
    }

    // MARK: - Command completion

    fileprivate struct CommandItem {
        let name: String
        let args: String
        let desc: String
    }

    private static let commandCompletions: [CommandItem] = [
        CommandItem(name: "new",       args: "<task>",            desc: "Create a cabin and assign a task"),
        CommandItem(name: "order",     args: "<branch> <task>",   desc: "Assign a task to an existing cabin"),
        CommandItem(name: "commit",    args: "<branch>",          desc: "Commit changes"),
        CommandItem(name: "return",    args: "<branch>",          desc: "Return to port · delete cabin"),
        CommandItem(name: "broadcast", args: "<task>",            desc: "Broadcast to all agents"),
    ]

    func textDidChange(_ notification: Notification) {
        let text = promptTextView.plainText
        // Show completions when text is exactly "/" or "/\w*"
        let isCommandPrefix = text.hasPrefix("/") && text.dropFirst().allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
        if isCommandPrefix {
            showCommandCompletions(prefix: String(text.dropFirst()))
        } else {
            hideCommandCompletions()
        }
    }

    private var completionPanel: NSPanel?

    private static let completionRowHeight: CGFloat = 30
    private static let completionPanelWidth: CGFloat = 300
    private static let completionVerticalPadding: CGFloat = 5

    private func showCommandCompletions(prefix: String) {
        let needle = prefix.lowercased()
        let filtered = Self.commandCompletions.filter { needle.isEmpty || $0.name.hasPrefix(needle) }
        guard !filtered.isEmpty else { hideCommandCompletions(); return }

        // Build or reuse a borderless panel positioned above the input field
        let panel: NSPanel
        if let existing = completionPanel {
            panel = existing
        } else {
            panel = NSPanel(contentRect: .zero,
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered,
                            defer: false)
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = true
            completionPanel = panel
        }

        // Build a stack of item views
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.spacing = 1
        stack.edgeInsets = NSEdgeInsets(top: Self.completionVerticalPadding, left: 5,
                                        bottom: Self.completionVerticalPadding, right: 5)
        stack.translatesAutoresizingMaskIntoConstraints = false

        for item in filtered {
            let row = CompletionRowView(item: item, height: Self.completionRowHeight) { [weak self] in
                self?.applyCompletion(item.name)
            }
            row.translatesAutoresizingMaskIntoConstraints = false
            stack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: stack.widthAnchor,
                                       constant: -2 * 5).isActive = true
        }

        let container = NSVisualEffectView()
        container.material = .menu
        container.blendingMode = .behindWindow
        container.state = .active
        container.wantsLayer = true
        container.layer?.cornerRadius = 10
        container.layer?.borderWidth = 0.5
        container.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.6).cgColor
        container.layer?.masksToBounds = true
        container.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        let panelHeight = CGFloat(filtered.count) * Self.completionRowHeight
            + CGFloat(max(0, filtered.count - 1)) * 1
            + 2 * Self.completionVerticalPadding

        panel.contentView = container

        // Position above the input view
        guard let window else { hideCommandCompletions(); return }
        let viewOriginInScreen = window.convertToScreen(convert(bounds, to: nil))
        let panelFrame = NSRect(
            x: viewOriginInScreen.minX + 12,
            y: viewOriginInScreen.maxY + 6,
            width: Self.completionPanelWidth,
            height: panelHeight
        )
        panel.setFrame(panelFrame, display: true)
        if panel.parent == nil { window.addChildWindow(panel, ordered: .above) }
        panel.orderFront(nil)
    }

    private func hideCommandCompletions() {
        if let panel = completionPanel {
            panel.parent?.removeChildWindow(panel)
            panel.orderOut(nil)
        }
    }

    deinit {
        hideCommandCompletions()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { hideCommandCompletions() }
    }

    private func applyCompletion(_ name: String) {
        promptTextView.setPlainText("/\(name) ")
        // Move cursor to end
        let len = promptTextView.string.count
        promptTextView.setSelectedRange(NSRange(location: len, length: 0))
        hideCommandCompletions()
    }

    /// Cancels/collapses the form and notifies the keyboard-mode controller.
    private func cancelForm() {
        hideCommandCompletions()
        window?.makeFirstResponder(nil)
        onFormEnd?()
    }

    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        // Return-to-submit is handled in PromptTextView.keyDown; here we only let
        // Shift+Return fall through as a newline.
        if commandSelector == #selector(NSResponder.insertTab(_:)) {
            window?.makeFirstResponder(repoChip)
            return true
        }
        if commandSelector == #selector(NSResponder.insertBacktab(_:)) {
            window?.makeFirstResponder(reuseEnvCheckbox)
            return true
        }
        return false
    }

    // MARK: - Keyboard ring & in-place cycling

    /// Focus ring order: name → repo → agent → reuse → name.
    private func focusRingNext(after responder: NSView) {
        switch responder {
        case repoChip:          window?.makeFirstResponder(agentChip)
        case agentChip:         window?.makeFirstResponder(reuseEnvCheckbox)
        case reuseEnvCheckbox:  window?.makeFirstResponder(promptTextView)
        default:                window?.makeFirstResponder(repoChip)
        }
    }

    private func focusRingPrev(before responder: NSView) {
        switch responder {
        case repoChip:          window?.makeFirstResponder(promptTextView)
        case agentChip:         window?.makeFirstResponder(repoChip)
        case reuseEnvCheckbox:  window?.makeFirstResponder(agentChip)
        default:                window?.makeFirstResponder(reuseEnvCheckbox)
        }
    }

    /// Tab(48)/Shift+Tab and Esc handling shared by the chip & checkbox controls.
    /// Returns true if the key was consumed.
    private func handleRingKey(_ event: NSEvent, on view: NSView) -> Bool {
        switch event.keyCode {
        case 48: // Tab
            if event.modifierFlags.contains(.shift) { focusRingPrev(before: view) }
            else { focusRingNext(after: view) }
            return true
        case 53: // Esc
            cancelForm()
            return true
        default:
            return false
        }
    }

    private func handleRepoChipKey(_ event: NSEvent) -> Bool {
        switch event.keyCode {
        case 123: cycleRepo(-1); return true   // Left
        case 124: cycleRepo(+1); return true   // Right
        case 49, 36: repoButtonClicked(); return true  // Space/Return → menu
        default: return handleRingKey(event, on: repoChip)
        }
    }

    private func handleSailorChipKey(_ event: NSEvent) -> Bool {
        switch event.keyCode {
        case 123: cycleSailor(-1); return true  // Left
        case 124: cycleSailor(+1); return true  // Right
        case 49, 36: agentButtonClicked(); return true  // Space/Return → menu
        default: return handleRingKey(event, on: agentChip)
        }
    }

    private func handleReuseCheckboxKey(_ event: NSEvent) -> Bool {
        switch event.keyCode {
        case 49: // Space → toggle
            reuseEnvCheckbox.state = (reuseEnvCheckbox.state == .on) ? .off : .on
            return true
        default:
            return handleRingKey(event, on: reuseEnvCheckbox)
        }
    }

    /// Cycle the selected repo by `delta` with modular wraparound over the live
    /// repo paths, then refresh the chip via the shared update path.
    func cycleRepo(_ delta: Int) {
        let paths = repoPathsProvider?() ?? repoPaths
        repoPaths = paths
        guard !paths.isEmpty else { return }
        let current = selectedRepoPath.flatMap { paths.firstIndex(of: $0) } ?? 0
        let next = (current + delta + paths.count) % paths.count
        selectedRepoPath = paths[next]
        applySelectedRepo()
    }

    /// Cycle the selected agent by `delta` with modular wraparound over the AI
    /// agent choices, then refresh the chip via the shared update path.
    func cycleSailor(_ delta: Int) {
        let all = Self.agentChoices
        guard !all.isEmpty else { return }
        let current = all.firstIndex(of: selectedSailorType) ?? 0
        let next = (current + delta + all.count) % all.count
        selectedSailorType = all[next]
        refreshSailorChip()
    }

    func controlTextDidBeginEditing(_ obj: Notification) {
        setExpanded(true, animated: true)
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        setExpanded(false, animated: true)
    }

    private func setExpanded(_ expanded: Bool, animated: Bool) {
        guard isExpandedForTesting != expanded else { return }
        isExpandedForTesting = expanded
        applyColors(animated: animated)
        onPreferredHeightChange?(preferredHeight, animated)
        updateFieldHeight(animated: animated)
    }

    private func updateFieldHeight(animated: Bool) {
        let nextHeight = isExpandedForTesting ? Self.expandedFieldHeight : Self.collapsedFieldHeight
        guard abs(promptHeight.constant - nextHeight) > 0.5 else { return }

        let update = {
            self.promptHeight.constant = nextHeight
            self.layoutSubtreeIfNeeded()
        }

        guard animated, window != nil else {
            update()
            return
        }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.expansionDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            context.allowsImplicitAnimation = true
            update()
        }
    }

    // MARK: - Appearance
    private func applyColors(animated: Bool = false) {
        let borderColor = isExpandedForTesting
            ? NSColor.controlAccentColor.withAlphaComponent(0.72)
            : Self.inputBorder
        let backgroundColor = Self.inputBg
        let shadowOpacity: Float = isExpandedForTesting ? 0.48 : 0.35
        let shadowRadius: CGFloat = isExpandedForTesting ? 16 : 10
        let borderWidth: CGFloat = isExpandedForTesting ? 1.8 : 1.5

        let update = {
            self.layer?.backgroundColor = self.resolvedCGColor(backgroundColor)
            self.layer?.borderColor = self.resolvedCGColor(borderColor)
            self.layer?.shadowOpacity = shadowOpacity
            self.layer?.shadowRadius = shadowRadius
            self.layer?.borderWidth = borderWidth
        }

        guard animated else {
            update()
            return
        }

        CATransaction.begin()
        CATransaction.setAnimationDuration(Self.expansionDuration)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeInEaseOut))
        update()
        CATransaction.commit()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }
}

/// A clickable row in the command completion popover: `/name <args>` on the
/// left, a short description right-aligned, with a full-row hover highlight.
private final class CompletionRowView: NSView {
    private let action: () -> Void
    private let nameLabel: NSTextField
    private let argsLabel: NSTextField
    private let descLabel: NSTextField
    private var isHovered = false {
        didSet { updateBackground() }
    }

    init(item: InlineCabinCreateView.CommandItem, height: CGFloat, action: @escaping () -> Void) {
        self.action = action

        nameLabel = NSTextField(labelWithString: "/\(item.name)")
        argsLabel = NSTextField(labelWithString: item.args)
        descLabel = NSTextField(labelWithString: item.desc)

        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 6

        nameLabel.font = .monospacedSystemFont(ofSize: 12.5, weight: .medium)
        nameLabel.textColor = SemanticColors.text
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        nameLabel.setContentHuggingPriority(.required, for: .horizontal)

        argsLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        argsLabel.textColor = .tertiaryLabelColor
        argsLabel.translatesAutoresizingMaskIntoConstraints = false
        argsLabel.lineBreakMode = .byTruncatingTail
        argsLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        descLabel.font = .systemFont(ofSize: 11)
        descLabel.textColor = .secondaryLabelColor
        descLabel.alignment = .right
        descLabel.translatesAutoresizingMaskIntoConstraints = false
        descLabel.lineBreakMode = .byTruncatingTail
        descLabel.setContentHuggingPriority(.required, for: .horizontal)
        descLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        addSubview(nameLabel)
        addSubview(argsLabel)
        addSubview(descLabel)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: height),

            nameLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            nameLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

            argsLabel.leadingAnchor.constraint(equalTo: nameLabel.trailingAnchor, constant: 6),
            argsLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

            descLabel.leadingAnchor.constraint(greaterThanOrEqualTo: argsLabel.trailingAnchor, constant: 8),
            descLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            descLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])

        let click = NSClickGestureRecognizer(target: self, action: #selector(clicked))
        addGestureRecognizer(click)
        let area = NSTrackingArea(rect: .zero,
                                  options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    @objc private func clicked() { action() }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }

    private func updateBackground() {
        layer?.backgroundColor = isHovered
            ? NSColor.controlAccentColor.withAlphaComponent(0.85).cgColor
            : .clear
        nameLabel.textColor = isHovered ? .white : SemanticColors.text
        argsLabel.textColor = isHovered ? NSColor.white.withAlphaComponent(0.75) : .tertiaryLabelColor
        descLabel.textColor = isHovered ? NSColor.white.withAlphaComponent(0.85) : .secondaryLabelColor
    }
}

private extension SailorType {
    var inlinePickerLogoSVG: String? {
        switch self {
        case .claudeCode:
            return """
            <svg fill="#f3f4f6" viewBox="0 0 24 24" xmlns="http://www.w3.org/2000/svg"><path d="m4.7144 15.9555 4.7174-2.6471.079-.2307-.079-.1275h-.2307l-.7893-.0486-2.6956-.0729-2.3375-.0971-2.2646-.1214-.5707-.1215-.5343-.7042.0546-.3522.4797-.3218.686.0608 1.5179.1032 2.2767.1578 1.6514.0972 2.4468.255h.3886l.0546-.1579-.1336-.0971-.1032-.0972L6.973 9.8356l-2.55-1.6879-1.3356-.9714-.7225-.4918-.3643-.4614-.1578-1.0078.6557-.7225.8803.0607.2246.0607.8925.686 1.9064 1.4754 2.4893 1.8336.3643.3035.1457-.1032.0182-.0728-.164-.2733-1.3539-2.4467-1.445-2.4893-.6435-1.032-.17-.6194c-.0607-.255-.1032-.4674-.1032-.7285L6.287.1335 6.6997 0l.9957.1336.419.3642.6192 1.4147 1.0018 2.2282 1.5543 3.0296.4553.8985.2429.8318.091.255h.1579v-.1457l.1275-1.706.2368-2.0947.2307-2.6957.0789-.7589.3764-.9107.7468-.4918.5828.2793.4797.686-.0668.4433-.2853 1.8517-.5586 2.9021-.3643 1.9429h.2125l.2429-.2429.9835-1.3053 1.6514-2.0643.7286-.8196.85-.9046.5464-.4311h1.0321l.759 1.1293-.34 1.1657-1.0625 1.3478-.8804 1.1414-1.2628 1.7-.7893 1.36.0729.1093.1882-.0183 2.8535-.607 1.5421-.2794 1.8396-.3157.8318.3886.091.3946-.3278.8075-1.967.4857-2.3072.4614-3.4364.8136-.0425.0304.0486.0607 1.5482.1457.6618.0364h1.621l3.0175.2247.7892.522.4736.6376-.079.4857-1.2142.6193-1.6393-.3886-3.825-.9107-1.3113-.3279h-.1822v.1093l1.0929 1.0686 2.0035 1.8092 2.5075 2.3314.1275.5768-.3218.4554-.34-.0486-2.2039-1.6575-.85-.7468-1.9246-1.621h-.1275v.17l.4432.6496 2.3436 3.5214.1214 1.0807-.17.3521-.6071.2125-.6679-.1214-1.3721-1.9246L14.38 17.959l-1.1414-1.9428-.1397.079-.674 7.2552-.3156.3703-.7286.2793-.6071-.4614-.3218-.7468.3218-1.4753.3886-1.9246.3157-1.53.2853-1.9004.17-.6314-.0121-.0425-.1397.0182-1.4328 1.9672-2.1796 2.9446-1.7243 1.8456-.4128.164-.7164-.3704.0667-.6618.4008-.5889 2.386-3.0357 1.4389-1.882.929-1.0868-.0062-.1579h-.0546l-6.3385 4.1164-1.1293.1457-.4857-.4554.0608-.7467.2307-.2429 1.9064-1.3114Z"/></svg>
            """
        case .codex:
            return """
            <svg viewBox="0 0 24 24" xmlns="http://www.w3.org/2000/svg"><path fill="#f3f4f6" d="M22.282 9.821a6 6 0 0 0-.516-4.91a6.05 6.05 0 0 0-6.51-2.9A6.065 6.065 0 0 0 4.981 4.18a6 6 0 0 0-3.998 2.9a6.05 6.05 0 0 0 .743 7.097a5.98 5.98 0 0 0 .51 4.911a6.05 6.05 0 0 0 6.515 2.9A6 6 0 0 0 13.26 24a6.06 6.06 0 0 0 5.772-4.206a6 6 0 0 0 3.997-2.9a6.06 6.06 0 0 0-.747-7.073M13.26 22.43a4.48 4.48 0 0 1-2.876-1.04l.141-.081l4.779-2.758a.8.8 0 0 0 .392-.681v-6.737l2.02 1.168a.07.07 0 0 1 .038.052v5.583a4.504 4.504 0 0 1-4.494 4.494M3.6 18.304a4.47 4.47 0 0 1-.535-3.014l.142.085l4.783 2.759a.77.77 0 0 0 .78 0l5.843-3.369v2.332a.08.08 0 0 1-.033.062L9.74 19.95a4.5 4.5 0 0 1-6.14-1.646M2.34 7.896a4.5 4.5 0 0 1 2.366-1.973V11.6a.77.77 0 0 0 .388.677l5.815 3.354l-2.02 1.168a.08.08 0 0 1-.071 0l-4.83-2.786A4.504 4.504 0 0 1 2.34 7.872zm16.597 3.855l-5.833-3.387L15.119 7.2a.08.08 0 0 1 .071 0l4.83 2.791a4.494 4.494 0 0 1-.676 8.105v-5.678a.79.79 0 0 0-.407-.667m2.01-3.023l-.141-.085l-4.774-2.782a.78.78 0 0 0-.785 0L9.409 9.23V6.897a.07.07 0 0 1 .028-.061l4.83-2.787a4.5 4.5 0 0 1 6.68 4.66zm-12.64 4.135l-2.02-1.164a.08.08 0 0 1-.038-.057V6.075a4.5 4.5 0 0 1 7.375-3.453l-.142.08L8.704 5.46a.8.8 0 0 0-.393.681zm1.097-2.365l2.602-1.5l2.607 1.5v2.999l-2.597 1.5l-2.607-1.5Z"/></svg>
            """
        case .openCode:
            return """
            <svg viewBox="0 0 24 24" xmlns="http://www.w3.org/2000/svg"><path fill="#f3f4f6" d="M22 24H2V0h20zM17 4.8H7v14.4h10z"/></svg>
            """
        case .gemini:
            return """
            <svg fill="#f3f4f6" viewBox="0 0 24 24" xmlns="http://www.w3.org/2000/svg"><path d="M11.04 19.32Q12 21.51 12 24q0-2.49.93-4.68.96-2.19 2.58-3.81t3.81-2.55Q21.51 12 24 12q-2.49 0-4.68-.93a12.3 12.3 0 0 1-3.81-2.58a12.3 12.3 0 0 1-2.58-3.81Q12 2.49 12 0q0 2.49-.96 4.68-.93 2.19-2.55 3.81a12.3 12.3 0 0 1-3.81 2.58Q2.49 12 0 12q2.49 0 4.68.96 2.19.93 3.81 2.55t2.55 3.81"/></svg>
            """
        case .cline:
            return """
            <svg viewBox="0 0 24 24" xmlns="http://www.w3.org/2000/svg"><path fill="#f3f4f6" d="m23.365 13.556l-1.442-2.895V8.994c0-2.764-2.218-5.002-4.954-5.002h-2.464c.178-.367.276-.779.276-1.213A2.77 2.77 0 0 0 12.018 0a2.77 2.77 0 0 0-2.763 2.779c0 .434.098.846.276 1.213H7.067c-2.736 0-4.954 2.238-4.954 5.002v1.667L.64 13.549c-.149.29-.149.636 0 .927l1.472 2.855v1.667C2.113 21.762 4.33 24 7.067 24h9.902c2.736 0 4.954-2.238 4.954-5.002V17.33l1.44-2.865c.143-.286.143-.622.002-.91m-12.854 2.36a2.27 2.27 0 0 1-2.261 2.273a2.27 2.27 0 0 1-2.261-2.273v-4.042A2.27 2.27 0 0 1 8.249 9.6a2.267 2.267 0 0 1 2.262 2.274zm7.285 0a2.27 2.27 0 0 1-2.26 2.273a2.27 2.27 0 0 1-2.262-2.273v-4.042A2.267 2.267 0 0 1 15.535 9.6a2.267 2.267 0 0 1 2.261 2.274z"/></svg>
            """
        case .amp:
            return """
            <svg viewBox="0 0 24 24" xmlns="http://www.w3.org/2000/svg"><path fill="#f3f4f6" d="M12 0c6.628 0 12 5.373 12 12s-5.372 12-12 12C5.373 24 0 18.627 0 12S5.373 0 12 0m-.92 19.278l5.034-8.377a.44.44 0 0 0 .097-.268a.455.455 0 0 0-.455-.455l-2.851.004l.924-5.468l-.927-.003l-5.018 8.367s-.1.183-.1.291c0 .251.204.455.455.455l2.831-.004l-.901 5.458z"/></svg>
            """
        case .cursor:
            return """
            <svg fill="#f3f4f6" viewBox="0 0 24 24" xmlns="http://www.w3.org/2000/svg"><path d="M11.503.131 1.891 5.678a.84.84 0 0 0-.42.726v11.188c0 .3.162.575.42.724l9.609 5.55a1 1 0 0 0 .998 0l9.61-5.55a.84.84 0 0 0 .42-.724V6.404a.84.84 0 0 0-.42-.726L12.497.131a1.01 1.01 0 0 0-.996 0M2.657 6.338h18.55c.263 0 .43.287.297.515L12.23 22.918c-.062.107-.229.064-.229-.06V12.335a.59.59 0 0 0-.295-.51l-9.11-5.257c-.109-.063-.064-.23.061-.23"/></svg>
            """
        default:
            return nil
        }
    }

    var inlinePickerSymbolName: String {
        switch self {
        case .claudeCode: return "sparkle"
        case .codex:      return "terminal"
        case .openCode:   return "chevron.left.forwardslash.chevron.right"
        case .gemini:     return "sparkles"
        case .cline:      return "hammer"
        case .goose:      return "paperplane"
        case .amp:        return "bolt"
        case .aider:      return "wrench.and.screwdriver"
        case .cursor:     return "cursorarrow"
        case .kiro:       return "k.circle"
        case .pi:         return "pi"
        default:          return "cpu"
        }
    }
}

private final class PromptTextView: NSTextView {
    var placeholderString = "" {
        didSet { needsDisplay = true }
    }
    var onFocusChange: ((Bool) -> Void)?
    /// Invoked when the user presses Esc in the name field (cancel the form).
    var onCancel: (() -> Void)?
    /// Invoked when the user presses Return (without Shift) to submit the form.
    var onSubmit: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        // Return (36) / numeric-keypad Enter (76): submit. Shift+Return: newline.
        // Read the event's own modifiers — reliable, unlike NSEvent.modifierFlags
        // in a doCommandBy callback.
        if event.keyCode == 36 || event.keyCode == 76 {
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if !flags.contains(.shift) {
                onSubmit?()
                return
            }
        }
        super.keyDown(with: event)
    }

    convenience init() {
        let storage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        let container = NSTextContainer(containerSize: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        container.heightTracksTextView = false
        storage.addLayoutManager(layoutManager)
        layoutManager.addTextContainer(container)
        self.init(frame: .zero, textContainer: container)
    }

    override init(frame frameRect: NSRect, textContainer container: NSTextContainer?) {
        super.init(frame: frameRect, textContainer: container)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        drawsBackground = false
        isRichText = false
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticDashSubstitutionEnabled = false
        isAutomaticTextReplacementEnabled = false
        allowsUndo = true
        textContainerInset = NSSize(width: 0, height: 0)
        textContainer?.lineFragmentPadding = 0
        insertionPointColor = NSColor.controlAccentColor
        textColor = SemanticColors.text
    }

    var plainText: String {
        textStorage?.string ?? string
    }

    func setPlainText(_ value: String) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font ?? AppFont.mono(size: 13, weight: .regular),
            .foregroundColor: textColor ?? SemanticColors.text
        ]
        textStorage?.setAttributedString(NSAttributedString(string: value, attributes: attributes))
        needsDisplay = true
    }

    override func didChangeText() {
        super.didChangeText()
        needsDisplay = true
    }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }

    override func becomeFirstResponder() -> Bool {
        let didBecome = super.becomeFirstResponder()
        if didBecome { onFocusChange?(true) }
        return didBecome
    }

    override func resignFirstResponder() -> Bool {
        let didResign = super.resignFirstResponder()
        if didResign { onFocusChange?(false) }
        return didResign
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard plainText.isEmpty, !placeholderString.isEmpty else { return }

        let attributes: [NSAttributedString.Key: Any] = [
            .font: font ?? AppFont.mono(size: 13, weight: .regular),
            .foregroundColor: SemanticColors.muted
        ]
        placeholderString.draw(
            at: NSPoint(x: 0, y: 1),
            withAttributes: attributes
        )
    }
}

/// A bordered, rounded dropdown chip: title + down-chevron, opens a menu on click.
final class DropdownChip: NSView {
    var onClick: (() -> Void)?
    /// Keyboard handler invoked from `keyDown(with:)`. Return true if consumed.
    var onKeyDown: ((NSEvent) -> Bool)?
    var titleForTesting: String { titleLabel.stringValue }
    var showsIconForTesting: Bool { !iconView.isHidden }
    var borderWidthForTesting: CGFloat { layer?.borderWidth ?? 0 }

    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let chevron = NSImageView()
    private var iconWidth: NSLayoutConstraint!
    private var iconLeadingFromEdge: NSLayoutConstraint!
    private var iconCenterX: NSLayoutConstraint!
    private var titleLeadingFromIcon: NSLayoutConstraint!
    private var titleLeadingFromEdge: NSLayoutConstraint!
    private var chevronLeadingFromTitle: NSLayoutConstraint!
    private var chevronLeadingFromIcon: NSLayoutConstraint!
    private var trackingAreaRef: NSTrackingArea?
    private var isHovering = false {
        didSet { applyColors() }
    }

    private static let chipBg = NSColor(name: nil) { a in
        a.isDark ? NSColor(hex: 0x34373e).withAlphaComponent(0.7) : NSColor(hex: 0xeef1f6).withAlphaComponent(0.9)
    }
    private static let chipBgIdle = NSColor(name: nil) { _ in
        .clear
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 5
        layer?.borderWidth = 0
        applyColors()

        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.contentTintColor = SemanticColors.text
        iconView.symbolConfiguration = .init(pointSize: 13, weight: .semibold)
        addSubview(iconView)

        titleLabel.font = .systemFont(ofSize: 11, weight: .medium)
        titleLabel.textColor = SemanticColors.text
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.setContentHuggingPriority(.required, for: .horizontal)
        addSubview(titleLabel)

        chevron.image = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 8, weight: .semibold))
        chevron.contentTintColor = SemanticColors.muted
        chevron.translatesAutoresizingMaskIntoConstraints = false
        chevron.setContentHuggingPriority(.required, for: .horizontal)
        addSubview(chevron)

        iconWidth = iconView.widthAnchor.constraint(equalToConstant: 0)
        iconLeadingFromEdge = iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 11)
        iconCenterX = iconView.centerXAnchor.constraint(equalTo: centerXAnchor, constant: -5)
        titleLeadingFromIcon = titleLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 6)
        titleLeadingFromEdge = titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10)
        chevronLeadingFromTitle = chevron.leadingAnchor.constraint(equalTo: titleLabel.trailingAnchor, constant: 6)
        chevronLeadingFromIcon = chevron.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 5)
        titleLeadingFromEdge.isActive = true
        chevronLeadingFromTitle.isActive = true

        NSLayoutConstraint.activate([
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconWidth,
            iconView.heightAnchor.constraint(equalToConstant: 16),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            chevron.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            chevron.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])

        addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(clicked)))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    @objc private func clicked() { onClick?() }

    // MARK: Keyboard focus
    override var acceptsFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
        needsDisplay = true
        return super.becomeFirstResponder()
    }

    override func resignFirstResponder() -> Bool {
        needsDisplay = true
        return super.resignFirstResponder()
    }

    override func keyDown(with event: NSEvent) {
        if onKeyDown?(event) == true { return }
        super.keyDown(with: event)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard window?.firstResponder === self else { return }
        let ringRect = bounds.insetBy(dx: 1, dy: 1)
        let path = NSBezierPath(roundedRect: ringRect, xRadius: 5, yRadius: 5)
        SemanticColors.accent.setStroke()
        path.lineWidth = 1.5
        path.stroke()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingAreaRef {
            removeTrackingArea(trackingAreaRef)
        }
        let area = NSTrackingArea(rect: bounds,
                                  options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                                  owner: self,
                                  userInfo: nil)
        addTrackingArea(area)
        trackingAreaRef = area
    }

    override func mouseEntered(with event: NSEvent) {
        isHovering = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovering = false
    }

    func setTitle(_ s: String) {
        iconView.isHidden = true
        iconView.image = nil
        iconWidth.constant = 0
        titleLabel.isHidden = false
        titleLabel.stringValue = s
        iconLeadingFromEdge.isActive = false
        iconCenterX.isActive = false
        titleLeadingFromIcon.isActive = false
        titleLeadingFromEdge.isActive = true
        chevronLeadingFromIcon.isActive = false
        chevronLeadingFromTitle.isActive = true
    }

    func setIcon(svgString: String?, symbolName: String, accessibilityLabel: String) {
        iconView.isHidden = false
        if let svgString, let data = svgString.data(using: .utf8), let image = NSImage(data: data) {
            iconView.image = image
        } else {
            iconView.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: accessibilityLabel)?
                .withSymbolConfiguration(.init(pointSize: 13, weight: .semibold))
        }
        iconWidth.constant = 16
        titleLabel.isHidden = true
        titleLabel.stringValue = ""
        titleLeadingFromEdge.isActive = false
        titleLeadingFromIcon.isActive = false
        iconCenterX.isActive = false
        iconLeadingFromEdge.isActive = true
        chevronLeadingFromTitle.isActive = false
        chevronLeadingFromIcon.isActive = true
        setAccessibilityLabel(accessibilityLabel)
    }

    private func applyColors() {
        layer?.backgroundColor = resolvedCGColor(isHovering ? Self.chipBg : Self.chipBgIdle)
        layer?.borderColor = nil
        iconView.contentTintColor = SemanticColors.text
        titleLabel.textColor = SemanticColors.text
        chevron.contentTintColor = SemanticColors.muted
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }
}

/// A checkbox button that participates in the form's keyboard ring: it accepts
/// first responder, draws a focus ring, and forwards keyDown to a handler.
final class KeyCheckbox: NSButton {
    /// Keyboard handler invoked from `keyDown(with:)`. Return true if consumed.
    var onKeyDown: ((NSEvent) -> Bool)?

    override var acceptsFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
        needsDisplay = true
        return super.becomeFirstResponder()
    }

    override func resignFirstResponder() -> Bool {
        needsDisplay = true
        return super.resignFirstResponder()
    }

    override func keyDown(with event: NSEvent) {
        if onKeyDown?(event) == true { return }
        super.keyDown(with: event)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard window?.firstResponder === self else { return }
        let ringRect = bounds.insetBy(dx: 1, dy: 1)
        let path = NSBezierPath(roundedRect: ringRect, xRadius: 5, yRadius: 5)
        SemanticColors.accent.setStroke()
        path.lineWidth = 1.5
        path.stroke()
    }
}
