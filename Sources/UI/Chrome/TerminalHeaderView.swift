import AppKit

/// Right-column chrome header. Expanded: centered title. Collapsed: lights + icons + title + expand.
final class TerminalHeaderView: NSView {
    weak var delegate: ChromeHeaderDelegate? {
        didSet { iconCluster.delegate = delegate }
    }

    /// Empty host for repositioned `standardWindowButton`s (used when collapsed).
    let trafficLightSlot = NSView()

    private let titleLabel = NSTextField(labelWithString: "")
    /// Copies a seahelm-web link for the focused pane. Sits left of the memory
    /// readout, which itself sits left of the centred title.
    private let shareButton = ChromeIconButton()
    /// Mints, changes and revokes the links. Nil, or a nil offer, means there
    /// is no focused pane to share.
    weak var paneSharing: PaneSharing?
    /// Focused pane's session memory. Pinned to the leading edge rather than
    /// trailing the title: the title is centred and truncates from the tail, so
    /// a suffix would both drift as the title changes and be the first thing cut.
    private let memoryLabel = NSTextField(labelWithString: "")
    private let iconCluster = ChromeIconClusterView()
    private let expandButton = ChromeIconButton()
    /// Forks the focused pane's session into the worktree its agent went to.
    /// Shown only while there is such a worktree; collapses to zero width
    /// otherwise so the title keeps the room.
    private let forkButton = ChromeIconButton()
    private var forkButtonWidth: NSLayoutConstraint?
    /// Display name of the worktree a fork would land in; nil hides the button.
    private var forkTargetName: String?
    var onForkPane: (() -> Void)?
    /// On a pane that was forked: `⑂ #n`, the pane its work carries on in.
    /// Clicking it opens that pane. Zero width while there is none.
    private let forkedBadge = ChromeIconButton()
    private var forkedBadgeWidth: NSLayoutConstraint?
    private var forkedBadgeTitle: String?
    var onOpenFork: (() -> Void)?
    private let collapsedLeadingStack = NSStackView()

    /// Latest pane title, kept rather than read back off the label.
    private var paneTitle = ""
    /// Kept rather than read back off the label, so collapse/expand can re-render
    /// it without the caller having to push the value again.
    private var paneMemoryBytes: UInt64?
    /// First Mate is over the terminal side: the whole header is its — its name,
    /// its memory, an accent tint — and the focused pane's share and fork step
    /// aside, since they would act on a pane that is not on screen.
    private var firstMateMode = false
    private var firstMateMemoryBytes: UInt64?

    /// Compact's pane tab strip lives here permanently rather than being moved
    /// up from the terminal column: reparenting a strip left its clip view seated
    /// at a non-zero vertical origin, which slid every tab out of the visible rect
    /// while all the frames still looked correct. Owning it removes that failure.
    let paneStrip = EditTabStripView()
    private var stripMode: HeaderStripMode = .none
    private var stripConstraints: [NSLayoutConstraint] = []
    private var stripLeadingCollapsed: NSLayoutConstraint?
    private var stripLeadingExpanded: NSLayoutConstraint?

    private var isCollapsed = false
    /// Bumped per collapse animation so a superseded one's completion is a no-op.
    private var collapseGeneration = 0
    private var collapsedConstraints: [NSLayoutConstraint] = []
    private var expandedConstraints: [NSLayoutConstraint] = []
    private var colorSchemeObserver: NSObjectProtocol?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    deinit {
        if let colorSchemeObserver {
            NotificationCenter.default.removeObserver(colorSchemeObserver)
        }
    }

    // MARK: - Title formatting

    /// Chrome title is the current pane title only (repo lives in the fleet row).
    static func formatTitle(repo: String, pane: String) -> String {
        let p = pane.trimmingCharacters(in: .whitespacesAndNewlines)
        if !p.isEmpty { return p }
        return repo.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Public API

    func setTitle(repo: String, pane: String) {
        paneTitle = Self.formatTitle(repo: repo, pane: pane)
        applyTitleText()
    }

    func setPaneTitle(_ pane: String) {
        paneTitle = pane.trimmingCharacters(in: .whitespacesAndNewlines)
        applyTitleText()
    }

    /// Resident memory of the focused pane's session tree, or nil to clear.
    func setPaneMemory(_ bytes: UInt64?) {
        paneMemoryBytes = bytes
        applyMemoryText()
    }

    func setFirstMateMode(_ on: Bool) {
        guard firstMateMode != on else { return }
        firstMateMode = on
        applyTitleText()
        applyMemoryText()
        refreshImmersion()
    }

    func setFirstMateMemory(_ bytes: UInt64?) {
        firstMateMemoryBytes = bytes
        applyMemoryText()
    }

    var isFirstMateModeForTesting: Bool { firstMateMode }

    /// Short by design — this shares a row with a centred title, so it trades
    /// precision for a width that does not move as the number changes.
    static func formatMemory(bytes: UInt64) -> String {
        let mb = Double(bytes) / 1_048_576
        if mb < 1 { return "<1 MB" }
        if mb < 1024 { return String(format: "%.0f MB", mb) }
        return String(format: "%.1f GB", mb / 1024)
    }

    var memoryLabelIsHiddenForTesting: Bool { memoryLabel.isHidden }
    var memoryTextForTesting: String { memoryLabel.stringValue }

    private func applyMemoryText() {
        // Collapsed puts traffic lights, icons and the title on this row already;
        // there is no leading space left to hold a number steady.
        guard !isCollapsed, let bytes = firstMateMode ? firstMateMemoryBytes : paneMemoryBytes, bytes > 0 else {
            memoryLabel.isHidden = true
            return
        }
        memoryLabel.stringValue = Self.formatMemory(bytes: bytes)
        memoryLabel.isHidden = false
    }

    /// `animated` is passed through from the chrome's collapse animation so the
    /// icons this header owns while collapsed fade across the hand-off with the
    /// sidebar instead of popping in at frame 0.
    func setCollapsed(_ collapsed: Bool, animated: Bool = false) {
        guard isCollapsed != collapsed else { return }
        isCollapsed = collapsed
        applyCollapsedState(animated: animated)
    }

    func setActivePane(_ pane: ChromeLeftPane?) {
        iconCluster.setActivePane(pane)
    }

    func setWorktreeContextEnabled(_ enabled: Bool) {
        iconCluster.setWorktreeContextEnabled(enabled)
    }

    // MARK: - Setup

    private func setup() {
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        // Identifier for UITests; children (icon buttons / title) remain interactive a11y elements.
        setAccessibilityIdentifier("chrome.terminalHeader")
        refreshImmersion()

        trafficLightSlot.translatesAutoresizingMaskIntoConstraints = false
        addSubview(trafficLightSlot)

        iconCluster.delegate = delegate
        iconCluster.translatesAutoresizingMaskIntoConstraints = false

        collapsedLeadingStack.orientation = .horizontal
        collapsedLeadingStack.spacing = 8
        collapsedLeadingStack.alignment = .centerY
        collapsedLeadingStack.translatesAutoresizingMaskIntoConstraints = false
        collapsedLeadingStack.addArrangedSubview(iconCluster)
        addSubview(collapsedLeadingStack)

        titleLabel.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.maximumNumberOfLines = 1
        titleLabel.cell?.usesSingleLineMode = true
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        titleLabel.setAccessibilityIdentifier("chrome.terminalTitle")
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleLabel)

        memoryLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        memoryLabel.textColor = Theme.textSecondary
        memoryLabel.maximumNumberOfLines = 1
        memoryLabel.cell?.usesSingleLineMode = true
        // Never steals width from the title, and never gets compressed itself —
        // a half-rendered number is worse than none.
        memoryLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        memoryLabel.setContentHuggingPriority(.required, for: .horizontal)
        memoryLabel.setAccessibilityIdentifier("chrome.terminalMemory")
        memoryLabel.translatesAutoresizingMaskIntoConstraints = false
        memoryLabel.isHidden = true
        addSubview(memoryLabel)

        configureExpandButton()
        addSubview(expandButton)

        configureForkButton()
        addSubview(forkButton)

        configureForkedBadge()
        addSubview(forkedBadge)

        paneStrip.translatesAutoresizingMaskIntoConstraints = false
        paneStrip.isHidden = true
        addSubview(paneStrip)

        colorSchemeObserver = NotificationCenter.default.addObserver(
            forName: .ghosttyColorSchemeDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.refreshImmersion()
        }

        // The fork button ends the trailing chain in both collapse states; only
        // its trailing anchor is swapped per state.
        NSLayoutConstraint.activate([
            forkButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            forkedBadge.centerYAnchor.constraint(equalTo: centerYAnchor),
            forkedBadge.trailingAnchor.constraint(equalTo: forkButton.leadingAnchor, constant: -4),
        ])

        configureShareButton()
        addSubview(shareButton)

        // Expanded: true horizontal center in the terminal column. Share, then
        // the memory readout, sit at the leading edge and the title's
        // minimum-leading clears them, so a long title is truncated rather than
        // overlapping — the title keeps its exact centring while it fits.
        expandedConstraints = [
            shareButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            shareButton.centerYAnchor.constraint(equalTo: centerYAnchor),

            memoryLabel.leadingAnchor.constraint(equalTo: shareButton.trailingAnchor, constant: 6),
            memoryLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

            titleLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            titleLabel.leadingAnchor.constraint(greaterThanOrEqualTo: memoryLabel.trailingAnchor, constant: 8),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: forkedBadge.leadingAnchor, constant: -8),
            forkButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
        ]

        collapsedConstraints = [
            trafficLightSlot.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            trafficLightSlot.centerYAnchor.constraint(equalTo: centerYAnchor),
            trafficLightSlot.widthAnchor.constraint(equalToConstant: 70),
            trafficLightSlot.heightAnchor.constraint(equalToConstant: 14),

            collapsedLeadingStack.leadingAnchor.constraint(
                equalTo: trafficLightSlot.trailingAnchor, constant: 8),
            collapsedLeadingStack.centerYAnchor.constraint(equalTo: centerYAnchor),

            titleLabel.leadingAnchor.constraint(
                equalTo: collapsedLeadingStack.trailingAnchor, constant: 10),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            titleLabel.trailingAnchor.constraint(
                lessThanOrEqualTo: forkedBadge.leadingAnchor, constant: -8),

            forkButton.trailingAnchor.constraint(equalTo: expandButton.leadingAnchor, constant: -4),

            expandButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            expandButton.centerYAnchor.constraint(equalTo: centerYAnchor),
        ]

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: ChromeLayoutMetrics.headerHeight),
        ])

        setupPaneStripConstraints()
        applyCollapsedState()
    }

    /// The strip spans the row between the leading controls and the fork
    /// controls, which stay on the header (forkedBadge → forkButton chain;
    /// hidden ones are 0 wide). Both leading anchors are installed at once and
    /// swapped by collapse state, mirroring how the title label is anchored.
    private func setupPaneStripConstraints() {
        stripLeadingCollapsed = paneStrip.leadingAnchor.constraint(
            equalTo: collapsedLeadingStack.trailingAnchor, constant: 10)
        stripLeadingExpanded = paneStrip.leadingAnchor.constraint(
            equalTo: leadingAnchor, constant: 12)

        stripConstraints = [
            paneStrip.centerYAnchor.constraint(equalTo: centerYAnchor),
            paneStrip.trailingAnchor.constraint(equalTo: forkedBadge.leadingAnchor, constant: -8),
        ]
        NSLayoutConstraint.activate(stripConstraints)
    }

    private func configureShareButton() {
        let config = NSImage.SymbolConfiguration(pointSize: 12, weight: .medium)
        if let image = NSImage(systemSymbolName: "square.and.arrow.up",
                               accessibilityDescription: "Share pane") {
            shareButton.image = image.withSymbolConfiguration(config)
        }
        shareButton.bezelStyle = .recessed
        shareButton.isBordered = false
        shareButton.imagePosition = .imageOnly
        shareButton.contentTintColor = NSColor(hex: 0x888888)
        shareButton.target = self
        shareButton.action = #selector(shareClicked)
        shareButton.translatesAutoresizingMaskIntoConstraints = false
        shareButton.setAccessibilityIdentifier("chrome.icon.sharePane")
        shareButton.setAccessibilityLabel("Share pane")
        shareButton.toolTip = "Copy a link to this pane"
        shareButton.wantsLayer = true
        shareButton.layer?.cornerRadius = 7
        NSLayoutConstraint.activate([
            shareButton.widthAnchor.constraint(equalToConstant: 26),
            shareButton.heightAnchor.constraint(equalToConstant: 26),
        ])
    }

    /// Collapsed and edit-mode rows already fill the leading edge. The button
    /// stays in the constraint graph either way; hiding it is enough because
    /// those rows deactivate the expanded anchors or cover them with strips.
    private func applyShareVisibility() {
        shareButton.isHidden = isCollapsed || hasHoistedStrips || firstMateMode
    }

    @objc private func shareClicked() {
        guard let sharing = paneSharing else {
            NSSound.beep()
            return
        }
        shareButton.isEnabled = false
        sharing.shareFocusedPane(lifetime: ShareLinkLifetime.lastChosen) { [weak self] result in
            guard let self else { return }
            self.shareButton.isEnabled = true
            switch result {
            case .success(let offer):
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(offer.url, forType: .string)
                self.presentSharePopover(offer, sharing: sharing)
            case .failure(let failure):
                self.presentPopover(ShareUnavailableController(message: GatewayClient.describe(failure)))
            }
        }
    }

    private func presentSharePopover(_ offer: PaneShareOffer, sharing: PaneSharing) {
        let controller = SharePopoverController(offer: offer, sharing: sharing)
        let popover = presentPopover(controller)
        controller.dismiss = { [weak popover] in popover?.performClose(nil) }
    }

    @discardableResult
    private func presentPopover(_ controller: NSViewController) -> NSPopover {
        let popover = NSPopover()
        popover.contentViewController = controller
        popover.behavior = .transient
        popover.show(relativeTo: shareButton.bounds, of: shareButton, preferredEdge: .minY)
        return popover
    }

    private func configureExpandButton() {
        let config = NSImage.SymbolConfiguration(pointSize: 12, weight: .medium)
        if let image = NSImage(systemSymbolName: "sidebar.left",
                               accessibilityDescription: "Expand Sidebar") {
            expandButton.image = image.withSymbolConfiguration(config)
        }
        expandButton.bezelStyle = .recessed
        expandButton.isBordered = false
        expandButton.imagePosition = .imageOnly
        expandButton.contentTintColor = NSColor(hex: 0x888888)
        expandButton.target = self
        expandButton.action = #selector(expandClicked)
        expandButton.translatesAutoresizingMaskIntoConstraints = false
        expandButton.setAccessibilityIdentifier("chrome.icon.sidebar")
        expandButton.setAccessibilityLabel("Expand Sidebar")
        expandButton.wantsLayer = true
        expandButton.layer?.cornerRadius = 7
        NSLayoutConstraint.activate([
            expandButton.widthAnchor.constraint(equalToConstant: 26),
            expandButton.heightAnchor.constraint(equalToConstant: 26),
        ])
    }

    private func applyCollapsedState(animated: Bool = false) {
        stripLeadingCollapsed?.isActive = isCollapsed
        stripLeadingExpanded?.isActive = !isCollapsed
        applyMemoryText()
        if isCollapsed {
            NSLayoutConstraint.deactivate(expandedConstraints)
            NSLayoutConstraint.activate(collapsedConstraints)
            titleLabel.alignment = .left
        } else {
            NSLayoutConstraint.deactivate(collapsedConstraints)
            NSLayoutConstraint.activate(expandedConstraints)
            titleLabel.alignment = .center
        }
        // The traffic-light slot is deliberately NOT faded: it hosts the real
        // `standardWindowButton`s, which MainWindowController reparents into it
        // the instant collapse flips. Fading the slot would blink the window's
        // close/minimise/zoom out of existence for the length of the animation.
        trafficLightSlot.isHidden = !isCollapsed
        applyShareVisibility()

        // Collapsed-only chrome. `isHidden` still does the layout/hit-testing
        // work; alpha only covers the transition, so it is reset either side.
        let views = [collapsedLeadingStack, expandButton]
        guard animated else {
            for v in views {
                v.isHidden = !isCollapsed
                v.alphaValue = 1
            }
            needsLayout = true
            return
        }

        if isCollapsed {
            for v in views {
                v.alphaValue = 0
                v.isHidden = false
            }
        }
        // Fast repeat ⌘B leaves an earlier animation in flight; its completion
        // must not settle alpha on top of the newer one.
        collapseGeneration &+= 1
        let generation = collapseGeneration
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = ChromeLayoutMetrics.collapseAnimationDuration
            context.timingFunction = ChromeLayoutMetrics.collapseTimingFunction
            context.allowsImplicitAnimation = true
            for v in views { v.animator().alphaValue = self.isCollapsed ? 1 : 0 }
        }, completionHandler: { [weak self] in
            guard let self, self.collapseGeneration == generation else { return }
            for v in views {
                v.isHidden = !self.isCollapsed
                v.alphaValue = 1
            }
        })
        needsLayout = true
    }

    private func configureForkButton() {
        let config = NSImage.SymbolConfiguration(pointSize: 12, weight: .medium)
        if let image = NSImage(systemSymbolName: "arrow.triangle.branch",
                               accessibilityDescription: "Fork pane") {
            forkButton.image = image.withSymbolConfiguration(config)
        }
        forkButton.bezelStyle = .recessed
        forkButton.isBordered = false
        forkButton.imagePosition = .imageOnly
        forkButton.contentTintColor = NSColor(hex: 0x888888)
        forkButton.target = self
        forkButton.action = #selector(forkClicked)
        forkButton.translatesAutoresizingMaskIntoConstraints = false
        forkButton.setAccessibilityIdentifier("chrome.icon.forkPane")
        forkButton.setAccessibilityLabel("Fork pane")
        forkButton.wantsLayer = true
        forkButton.layer?.cornerRadius = 7
        let width = forkButton.widthAnchor.constraint(equalToConstant: 0)
        forkButtonWidth = width
        NSLayoutConstraint.activate([width, forkButton.heightAnchor.constraint(equalToConstant: 26)])
        applyForkVisibility()
    }

    /// Offer the fork when the focused pane's agent is working in another
    /// worktree. `worktreeName` is that worktree's display name; nil hides it.
    func setForkTarget(_ worktreeName: String?) {
        guard forkTargetName != worktreeName else { return }
        forkTargetName = worktreeName
        forkButton.toolTip = worktreeName.map { "Fork this conversation into \($0) and pause it here" }
        applyForkVisibility()
    }

    var forkButtonIsVisibleForTesting: Bool { !forkButton.isHidden }

    /// Edit mode's strips run up to the edit-mode button, so the fork button
    /// steps aside while they are up.
    private func applyForkVisibility() {
        let visible = forkTargetName != nil && !firstMateMode
        forkButton.isHidden = !visible
        forkButtonWidth?.constant = visible ? 26 : 0
    }

    @objc private func forkClicked() {
        onForkPane?()
    }

    private func configureForkedBadge() {
        let config = NSImage.SymbolConfiguration(pointSize: 11, weight: .medium)
        if let image = NSImage(systemSymbolName: "arrow.triangle.branch",
                               accessibilityDescription: "Forked") {
            forkedBadge.image = image.withSymbolConfiguration(config)
        }
        forkedBadge.bezelStyle = .recessed
        forkedBadge.isBordered = false
        forkedBadge.imagePosition = .imageLeading
        forkedBadge.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        forkedBadge.contentTintColor = NSColor(hex: 0x888888)
        forkedBadge.target = self
        forkedBadge.action = #selector(forkedBadgeClicked)
        forkedBadge.translatesAutoresizingMaskIntoConstraints = false
        forkedBadge.setAccessibilityIdentifier("chrome.forkedBadge")
        forkedBadge.wantsLayer = true
        forkedBadge.layer?.cornerRadius = 7
        forkedBadge.setContentCompressionResistancePriority(.required, for: .horizontal)
        let width = forkedBadge.widthAnchor.constraint(equalToConstant: 0)
        forkedBadgeWidth = width
        NSLayoutConstraint.activate([width, forkedBadge.heightAnchor.constraint(equalToConstant: 26)])
        applyForkedBadgeVisibility()
    }

    /// Mark the focused pane as forked into pane `#n`; nil clears the badge.
    func setForkedInto(title: String?, toolTip: String?) {
        guard forkedBadgeTitle != title || forkedBadge.toolTip != toolTip else { return }
        forkedBadgeTitle = title
        forkedBadge.title = title ?? ""
        forkedBadge.toolTip = toolTip
        forkedBadge.setAccessibilityLabel(toolTip)
        applyForkedBadgeVisibility()
    }

    var forkedBadgeIsVisibleForTesting: Bool { !forkedBadge.isHidden }
    var forkedBadgeTitleForTesting: String { forkedBadge.title }

    private func applyForkedBadgeVisibility() {
        let visible = forkedBadgeTitle != nil && !firstMateMode
        forkedBadge.isHidden = !visible
        forkedBadgeWidth?.constant = visible ? ceil(forkedBadge.intrinsicContentSize.width) + 10 : 0
    }

    @objc private func forkedBadgeClicked() {
        onOpenFork?()
    }

    // MARK: - Hoisted tab strip (compact)

    /// Compact shows the pane tab strip (`.terminalOnly`) in place of the title.
    func setHoistedStrips(_ mode: HeaderStripMode) {
        guard mode != stripMode else { return }
        stripMode = mode
        paneStrip.isHidden = mode == .none
        applyTitleText()
    }

    private var hasHoistedStrips: Bool {
        if case .none = stripMode { return false }
        return true
    }

    private func applyTitleText() {
        // The strips occupy the whole row when hoisted; nothing else fits.
        titleLabel.isHidden = hasHoistedStrips
        applyShareVisibility()
        applyForkVisibility()
        applyForkedBadgeVisibility()
        if firstMateMode {
            titleLabel.attributedStringValue = Self.firstMateTitle
            titleLabel.toolTip = "First Mate — ⌘J or ⌃⌃ to go back"
            return
        }
        let text = paneTitle
        titleLabel.stringValue = text
        // A file path loses the part that identifies it — the filename — to tail
        // truncation, so paths give up their middle instead.
        titleLabel.lineBreakMode = Self.isPathLike(text) ? .byTruncatingMiddle : .byTruncatingTail
        titleLabel.toolTip = text.isEmpty ? nil : text
        titleLabel.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
    }

    /// A single path-shaped token, as opposed to a prose title or a command line
    /// that merely mentions a directory.
    static func isPathLike(_ text: String) -> Bool {
        text.contains("/") && !text.contains(where: { $0 == " " || $0 == "\t" })
    }

    var titleTextForTesting: String { titleLabel.stringValue }
    var titleLineBreakModeForTesting: NSLineBreakMode { titleLabel.lineBreakMode }
    var titleToolTipForTesting: String? { titleLabel.toolTip }
    var isTitleHiddenForTesting: Bool { titleLabel.isHidden }

    @objc private func expandClicked() {
        delegate?.chromeDidToggleSidebar()
    }

    // MARK: - Window drag / zoom

    override var mouseDownCanMoveWindow: Bool { false }

    /// Claim non-button points so `mouseDown` can handle drag/zoom.
    /// Buttons (icon cluster, expand, fork) still get their own hits.
    ///
    /// The pane tab strip also has to be let through: its tabs are plain views
    /// rather than `NSButton`s, so the drag claim below would turn every tab
    /// click into a window drag. The strip only reports hits that land on a tab,
    /// so the empty part of the row still drags the window.
    override func hitTest(_ point: NSPoint) -> NSView? {
        if let hit = super.hitTest(point) {
            if hit is NSButton { return hit }
            if hit.isDescendant(of: paneStrip) {
                return hit
            }
        }
        let local = convert(point, from: superview)
        return bounds.contains(local) ? self : nil
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount >= 2 {
            window?.performZoom(nil)
        } else {
            window?.performDrag(with: event)
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshImmersion()
    }

    /// "⎈ First Mate" in the accent, with the symbol drawn rather than typed:
    /// the mono fonts have no glyph for it.
    private static var firstMateTitle: NSAttributedString {
        let out = NSMutableAttributedString()
        if let symbol = NSImage(systemSymbolName: "steeringwheel", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .semibold)) {
            let attachment = NSTextAttachment()
            attachment.image = symbol
            out.append(NSAttributedString(attachment: attachment))
            out.append(NSAttributedString(string: " "))
        }
        out.append(NSAttributedString(string: "First Mate"))
        out.addAttributes([.font: NSFont.systemFont(ofSize: 13, weight: .semibold),
                           .foregroundColor: SemanticColors.accent],
                          range: NSRange(location: 0, length: out.length))
        return out
    }

    /// Match Ghostty surface colors so the title strip disappears into the terminal —
    /// except for First Mate, whose strip takes an accent tint so it is never
    /// mistaken for a task pane.
    func refreshImmersion() {
        let bridge = GhosttyBridge.shared
        let chrome = bridge.terminalChromeBackground
        layer?.backgroundColor = firstMateMode
            ? (chrome.blended(withFraction: 0.16, of: SemanticColors.accent) ?? chrome).cgColor
            : chrome.cgColor
        // First Mate's title carries its own colour in its attributed string.
        if !firstMateMode {
            titleLabel.textColor = bridge.terminalChromeForeground
        }
        expandButton.contentTintColor = bridge.terminalChromeForeground.withAlphaComponent(0.55)
    }
}
