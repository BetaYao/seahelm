import AppKit

/// The left-side panes, switched via the top-left icon cluster.
/// (Worktrees are no longer a pane — they live in a title-bar popover.)
enum LeftPane: Int, CaseIterable {
    case bridge = 0
    case file = 1
    case change = 2
}

protocol TitleBarDelegate: AnyObject {
    func titleBarDidToggleTheme()
    func titleBarDidRequestCollapseLeftColumn()
    func titleBarDidSelectLeftPane(_ pane: LeftPane)
    func titleBarDidToggleWorktreeList(from sourceView: NSView)
    func titleBarDidSelectWorktree(_ path: String)
    /// Return to the Dashboard overview (spread First Mate) from a worktree.
    func titleBarDidRequestOverview()
    /// Toggle the First Mate side panel (the Dashboard opened as a left sidebar).
    func titleBarDidToggleFirstMate()
}

final class TitleBarView: NSView {
    enum Layout {
        static let barHeight: CGFloat = 28
        static let capsuleHeight: CGFloat = 24
        static let arcVerticalOffset: CGFloat = 1
        /// Right edge of the dashboard's first (worktree) column — keeps the
        /// collapse-left icon aligned with that column. = edge(8) + leftColumnWidth(260).
        static let firstColumnRightEdge: CGFloat = 268
        /// With a unified toolbar, the title-bar accessory's content origin is
        /// inset past the traffic-light region. Subtract it so window-x math lines up.
        static let toolbarLeadingInset: CGFloat = 76
        /// Window-x of the centre content area's left edge:
        /// edge(8) + leftColumnWidth(300) + columnSpacing(8). The worktree icon +
        /// tab strip align here so tabs sit above the centre terminal.
        static let centerContentLeftEdge: CGFloat = 316
    }

    weak var delegate: TitleBarDelegate?

    // MARK: - Subviews

    private let titleLabel = NSTextField(labelWithString: "")
    private let pathLabel = NSTextField(labelWithString: "")
    private let titleStack = NSStackView()

    // Left control — collapse the worktrees sidebar. Aligned to the first
    // column's right edge when expanded; tucked next to the traffic lights when collapsed.
    private let collapseLeftButton = TitleBarIconButton()

    // Left control cluster — First Mate · files · changes.
    private let leftClusterStack = NSStackView()
    private let themeButton = TitleBarIconButton()
    private let firstMateButton = TitleBarIconButton()
    private var paneButtons: [LeftPane: NSButton] = [:]
    private var selectedLeftPane: LeftPane = .file

    // Fixed worktree-list icon at the front of the tab strip; opens a popover.
    private let tabWorktreeButton = TitleBarIconButton()
    private var worktreeButtonExpandedLeading: NSLayoutConstraint?
    private var worktreeButtonCollapsedLeading: NSLayoutConstraint?

    // Worktree tab strip (horizontally scrollable) + overflow menu for idle tabs.
    private let tabStripScroll = NSScrollView()
    private let tabStripStack = NSStackView()
    private let tabOverflowButton = NSButton()
    private var scrollTrailingToOverflow: NSLayoutConstraint?
    private var scrollTrailingToEdge: NSLayoutConstraint?
    private var worktreeTabPaths: [String] = []
    private var selectedTabPath: String?
    private var collapsedTabs: [(path: String, title: String, statusColor: NSColor)] = []
    /// Live tab buttons keyed by worktree path, reused across setWorktreeTabs calls.
    private var tabButtonsByPath: [String: WorktreeTabButton] = [:]

    // State
    private var isWindowHovered = false
    private var hoverTrackingArea: NSTrackingArea?

    // MARK: - Init

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    // MARK: - Public API

    func setWindowHovered(_ hovered: Bool) {
        isWindowHovered = hovered
    }

    /// Highlight the active pane switcher in the left cluster.
    func setSelectedLeftPane(_ pane: LeftPane) {
        selectedLeftPane = pane
        updatePaneHighlight()
    }

    /// Toggle the left-cluster chrome by display mode. In the Dashboard overview
    /// there is no active worktree, so the collapse control and the file/change
    /// pane switchers are hidden — only the theme toggle remains. Entering a
    /// worktree reveals them so the file tree / changes are operable.
    func setChromeMode(overview: Bool) {
        // All icons stay VISIBLE in both modes. Worktree-context controls
        // (files, changes, First Mate) are disabled — not hidden — in the
        // Dashboard overview, where there is no active worktree.
        func setWorktreeContext(_ b: NSButton) {
            b.isEnabled = !overview
            b.alphaValue = overview ? 0.3 : 1
        }
        setWorktreeContext(firstMateButton)
        paneButtons.values.forEach(setWorktreeContext)
    }

    /// The single lit toolbar tool. Exactly one icon shows the accent tint; every
    /// other reverts to the idle grey (only the selected one lights up).
    enum ActiveTool { case files, changes, firstMate, none }
    func setActiveTool(_ tool: ActiveTool) {
        let idle = NSColor(hex: 0x888888)
        paneButtons[.file]?.contentTintColor = tool == .files ? Theme.accent : idle
        paneButtons[.change]?.contentTintColor = tool == .changes ? Theme.accent : idle
        firstMateButton.contentTintColor = tool == .firstMate ? Theme.accent : idle
    }

    func updateChromeState(isGridLayout: Bool, hasWorkspaces: Bool = true, canCleanWorktrees: Bool = false) {
        // The clean-worktree control was removed; parameters kept for source
        // compatibility. Nothing to update — in particular, no forced
        // layoutSubtreeIfNeeded: this runs on every title-bar refresh.
    }

    func updateNotificationSummary(entry: NotificationEntry?, unreadCount: Int) {}

    /// Collapse whitespace/newlines and cap a resolved worktree title to a
    /// label-length string (with an ellipsis) so it fits the title-bar label.
    static func clampTitle(_ title: String, limit: Int = 64) -> String {
        let collapsed = title
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard collapsed.count > limit else { return collapsed }
        return collapsed.prefix(limit).trimmingCharacters(in: .whitespaces) + "\u{2026}"
    }

    private var focusedTitle = ""
    private var focusedPath = ""

    func updateFocusedWorktree(title: String, path: String = "", tokenText: String = "\u{2014}") {
        focusedTitle = Self.clampTitle(title)
        focusedPath = path
        recomposeFocusedTitle()
        titleLabel.toolTip = path.isEmpty ? title : "\(title) — \(path)"
        // Single-line layout: the path rides at the end of the title line.
        pathLabel.isHidden = true
    }

    /// One line: "repo · branch · title" emphasized, then the path muted.
    /// Rebuilt (not just recolored) on theme change because the colors live in
    /// the attributed string.
    private func recomposeFocusedTitle() {
        let composed = NSMutableAttributedString(
            string: focusedTitle,
            attributes: [.font: NSFont.systemFont(ofSize: 12, weight: .semibold),
                         .foregroundColor: SemanticColors.text])
        if !focusedPath.isEmpty {
            let display = (focusedPath as NSString).abbreviatingWithTildeInPath
            composed.append(NSAttributedString(
                string: "  ·  \(display)",
                attributes: [.font: NSFont.systemFont(ofSize: 10, weight: .regular),
                             .foregroundColor: SemanticColors.muted]))
        }
        titleLabel.attributedStringValue = composed
    }

    // MARK: - Setup

    private func setup() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityIdentifier("titlebar")

        // The left cluster must exist before setupTitleLabel()/setupTabStrip(),
        // which anchor against its trailing edge.
        setupLeftButton()
        setupLeftCluster()
        setupTitleLabel()
        setupTabStrip()
    }

    private func setupLeftCluster() {
        leftClusterStack.orientation = .horizontal
        leftClusterStack.spacing = 2
        leftClusterStack.alignment = .centerY
        leftClusterStack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(leftClusterStack)

        // Order: First Mate · Files · Changes. The theme toggle lives at the
        // far right of the title bar (see the tab-strip section).
        // (Each pane icon toggles its own panel: click to open, click again
        // to collapse. The dashboard icon was removed — First Mate covers it.)
        configureArcIconButton(firstMateButton, symbol: "sailboat",
                               identifier: "titlebar.firstMate", label: "First Mate",
                               hoverTracking: false, action: #selector(firstMateClicked))
        leftClusterStack.addArrangedSubview(firstMateButton)

        let panes: [(LeftPane, String, String)] = [
            (.file, "folder", "Files"),
            (.change, "plusminus", "Changes"),
        ]
        for (pane, symbol, label) in panes {
            let btn = TitleBarIconButton()
            configureArcIconButton(btn, symbol: symbol,
                                   identifier: "titlebar.pane.\(pane.rawValue)", label: label,
                                   hoverTracking: false, action: #selector(paneButtonClicked(_:)))
            btn.tag = pane.rawValue
            paneButtons[pane] = btn
            leftClusterStack.addArrangedSubview(btn)
        }

        NSLayoutConstraint.activate([
            leftClusterStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            leftClusterStack.centerYAnchor.constraint(equalTo: centerYAnchor, constant: Layout.arcVerticalOffset),
        ])
        updatePaneHighlight()
    }

    private func updatePaneHighlight() {
        // Superseded by setActiveTool(), which owns the single-lit-icon state.
    }

    private func setupTabStrip() {
        tabStripStack.orientation = .horizontal
        tabStripStack.spacing = 2
        tabStripStack.alignment = .centerY
        tabStripStack.translatesAutoresizingMaskIntoConstraints = false

        // A horizontal scroll view so a long row of tabs scrolls rather than
        // forcing the title-bar accessory — and the window — wider.
        tabStripScroll.translatesAutoresizingMaskIntoConstraints = false
        tabStripScroll.drawsBackground = false
        tabStripScroll.borderType = .noBorder
        tabStripScroll.hasHorizontalScroller = false
        tabStripScroll.hasVerticalScroller = false
        tabStripScroll.horizontalScrollElasticity = .allowed
        tabStripScroll.verticalScrollElasticity = .none
        tabStripScroll.isHidden = true
        tabStripScroll.documentView = tabStripStack
        addSubview(tabStripScroll)

        // Fixed worktree-list icon at the front of the tab strip — aligned to the
        // centre content's left edge — opening the worktree popover on click.
        configureArcIconButton(tabWorktreeButton, symbol: "rectangle.stack",
                               identifier: "titlebar.worktreeList", label: "Worktrees",
                               action: #selector(worktreeListClicked))
        addSubview(tabWorktreeButton)
        // Removed: worktree switching now lives in the Dashboard fleet list.
        tabWorktreeButton.isHidden = true
        // Tabs always tuck right after the left icon cluster — no middle gap.
        worktreeButtonExpandedLeading = tabWorktreeButton.leadingAnchor.constraint(
            equalTo: leftClusterStack.trailingAnchor, constant: 10)
        worktreeButtonCollapsedLeading = tabWorktreeButton.leadingAnchor.constraint(
            equalTo: leftClusterStack.trailingAnchor, constant: 10)
        worktreeButtonExpandedLeading?.isActive = true
        NSLayoutConstraint.activate([
            tabWorktreeButton.centerYAnchor.constraint(equalTo: centerYAnchor, constant: Layout.arcVerticalOffset),
        ])

        // Top-right overflow badge — collapsed (idle) worktrees live in its
        // pull-down menu; the title shows how many. Hidden when none.
        tabOverflowButton.bezelStyle = .recessed
        tabOverflowButton.isBordered = false
        tabOverflowButton.imagePosition = .imageLeading
        tabOverflowButton.image = NSImage(systemSymbolName: "chevron.left.chevron.right",
                                          accessibilityDescription: "Idle worktrees")?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 10, weight: .semibold))
        tabOverflowButton.contentTintColor = Theme.accent
        tabOverflowButton.target = self
        tabOverflowButton.action = #selector(overflowClicked)
        tabOverflowButton.translatesAutoresizingMaskIntoConstraints = false
        tabOverflowButton.isHidden = true
        tabOverflowButton.setAccessibilityIdentifier("titlebar.tabOverflow")
        addSubview(tabOverflowButton)

        // Theme toggle — anchored at the far right of the title bar.
        configureArcIconButton(themeButton, symbol: "circle.lefthalf.filled",
                               identifier: "titlebar.themeToggle", label: "Toggle Theme",
                               action: #selector(themeClicked))
        addSubview(themeButton)

        scrollTrailingToOverflow = tabStripScroll.trailingAnchor.constraint(equalTo: tabOverflowButton.leadingAnchor, constant: -6)
        scrollTrailingToEdge = tabStripScroll.trailingAnchor.constraint(equalTo: themeButton.leadingAnchor, constant: -6)
        scrollTrailingToEdge?.isActive = true

        NSLayoutConstraint.activate([
            tabStripScroll.leadingAnchor.constraint(equalTo: tabWorktreeButton.trailingAnchor, constant: 6),
            tabStripScroll.centerYAnchor.constraint(equalTo: centerYAnchor, constant: Layout.arcVerticalOffset),
            tabStripScroll.heightAnchor.constraint(equalToConstant: 22),

            themeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            themeButton.centerYAnchor.constraint(equalTo: centerYAnchor, constant: Layout.arcVerticalOffset),

            tabOverflowButton.trailingAnchor.constraint(equalTo: themeButton.leadingAnchor, constant: -6),
            tabOverflowButton.centerYAnchor.constraint(equalTo: centerYAnchor, constant: Layout.arcVerticalOffset),
            tabOverflowButton.heightAnchor.constraint(equalToConstant: 22),

            tabStripStack.topAnchor.constraint(equalTo: tabStripScroll.contentView.topAnchor),
            tabStripStack.bottomAnchor.constraint(equalTo: tabStripScroll.contentView.bottomAnchor),
            tabStripStack.leadingAnchor.constraint(equalTo: tabStripScroll.contentView.leadingAnchor),
            tabStripStack.heightAnchor.constraint(equalToConstant: 22),
        ])
    }

    func setWorktreeTabs(_ tabs: [(path: String, title: String, agentGlyph: String?, agentColor: NSColor, statusColor: NSColor, paneCount: Int, isSelected: Bool, collapsed: Bool)]) {
        // The horizontal worktree tab strip was removed — worktree switching now
        // lives in the Dashboard overview's fleet list (the worktree-list popover
        // button stays as a compact switcher). We still record the ordered paths
        // and current selection so keyboard next/prev cycling keeps working, then
        // bail before building any tab-strip UI.
        worktreeTabPaths = tabs.map(\.path)
        selectedTabPath = tabs.first(where: \.isSelected)?.path
        tabStripScroll.isHidden = true
        tabOverflowButton.isHidden = true
        titleStack.isHidden = false
    }

    private func legacySetWorktreeTabs(_ tabs: [(path: String, title: String, agentGlyph: String?, agentColor: NSColor, statusColor: NSColor, paneCount: Int, isSelected: Bool, collapsed: Bool)]) {
        worktreeTabPaths = tabs.map(\.path)
        let previousSelectedPath = selectedTabPath
        selectedTabPath = tabs.first(where: \.isSelected)?.path

        let active = tabs.filter { !$0.collapsed }
        collapsedTabs = tabs.filter(\.collapsed).map { ($0.path, $0.title, $0.statusColor) }

        // Reuse existing buttons keyed by path — this runs on every status
        // update, and rebuilding every button (constraints, gestures, tracking
        // areas) each time is far more expensive than updating in place.
        var reused: [String: WorktreeTabButton] = [:]
        var orderedButtons: [WorktreeTabButton] = []
        var selectedButton: WorktreeTabButton?
        for tab in active {
            let btn: WorktreeTabButton
            if let existing = tabButtonsByPath[tab.path] {
                btn = existing
            } else {
                btn = WorktreeTabButton(path: tab.path)
                btn.onTap = { [weak self] path in
                    self?.delegate?.titleBarDidSelectWorktree(path)
                }
            }
            btn.update(title: tab.title, agentGlyph: tab.agentGlyph, agentColor: tab.agentColor,
                       statusColor: tab.statusColor, paneCount: tab.paneCount, isSelected: tab.isSelected)
            reused[tab.path] = btn
            orderedButtons.append(btn)
            if tab.isSelected { selectedButton = btn }
        }
        for (path, btn) in tabButtonsByPath where reused[path] == nil {
            btn.removeFromSuperview()
        }
        tabButtonsByPath = reused

        // Only rebuild the stack's arrangement when membership or order changed.
        let currentButtons = tabStripStack.arrangedSubviews.compactMap { $0 as? WorktreeTabButton }
        if currentButtons != orderedButtons {
            tabStripStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
            orderedButtons.forEach { tabStripStack.addArrangedSubview($0) }
        }

        let hasTabs = !tabs.isEmpty
        tabStripScroll.isHidden = !hasTabs
        titleStack.isHidden = hasTabs

        // Top-right overflow badge: count of collapsed worktrees, hidden if none.
        let collapsedCount = collapsedTabs.count
        tabOverflowButton.isHidden = collapsedCount == 0
        tabOverflowButton.attributedTitle = NSAttributedString(
            string: " \(collapsedCount)",
            attributes: [
                .foregroundColor: Theme.accent,
                .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
            ]
        )
        scrollTrailingToOverflow?.isActive = collapsedCount > 0
        scrollTrailingToEdge?.isActive = collapsedCount == 0

        // Keep the selected tab in view after layout settles. Only needed when
        // the selection actually moved — not on every status refresh.
        if let selectedButton, selectedTabPath != previousSelectedPath {
            DispatchQueue.main.async {
                selectedButton.scrollToVisible(selectedButton.bounds)
            }
        }
    }

    // MARK: - Keyboard worktree-tab navigation

    /// Pure adjacency: the path `forward`/backward from `current` in `paths`, wrapping
    /// around. Returns nil only when `paths` is empty. When `current` is nil or not in
    /// the list, forward starts at the first tab and backward at the last. Includes all
    /// tabs (collapsed ones too) so keyboard cycling reaches idle worktrees the overflow
    /// menu hides.
    static func adjacentPath(paths: [String], from current: String?, forward: Bool) -> String? {
        guard !paths.isEmpty else { return nil }
        guard let current, let idx = paths.firstIndex(of: current) else {
            return forward ? paths.first : paths.last
        }
        let n = paths.count
        let nextIdx = ((idx + (forward ? 1 : -1)) % n + n) % n
        return paths[nextIdx]
    }

    /// Select the next/previous worktree tab via the same delegate path a click uses.
    /// Fills the previously mouse-only titlebar gap (see docs/keyboard-redesign.md §7).
    func selectAdjacentWorktree(forward: Bool) {
        guard let path = TitleBarView.adjacentPath(
            paths: worktreeTabPaths, from: selectedTabPath, forward: forward
        ) else { return }
        delegate?.titleBarDidSelectWorktree(path)
    }

    @objc private func overflowClicked() {
        guard !collapsedTabs.isEmpty else { return }
        let menu = NSMenu()
        for tab in collapsedTabs {
            let item = NSMenuItem(title: tab.title, action: #selector(overflowItemClicked(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = tab.path
            // Custom 2-line view (repo line + branch line) so long titles don't truncate.
            item.view = OverflowItemView(title: tab.title, statusColor: tab.statusColor,
                                         target: self, action: #selector(overflowItemClicked(_:)), item: item)
            menu.addItem(item)
        }
        menu.popUp(positioning: nil,
                   at: NSPoint(x: 0, y: tabOverflowButton.bounds.height + 4),
                   in: tabOverflowButton)
    }

    @objc private func overflowItemClicked(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        delegate?.titleBarDidSelectWorktree(path)
    }

    private static func statusDotImage(color: NSColor) -> NSImage {
        let size = NSSize(width: 8, height: 8)
        let image = NSImage(size: size)
        image.lockFocus()
        color.setFill()
        NSBezierPath(ovalIn: NSRect(origin: .zero, size: size)).fill()
        image.unlockFocus()
        return image
    }

    private func setupLeftButton() {
        // The collapse-sidebar control is configured here but added to the ordered
        // left cluster in setupLeftCluster().
        configureArcIconButton(collapseLeftButton, symbol: "sidebar.left",
                               identifier: "titlebar.collapseLeft", label: "Toggle Worktrees",
                               action: #selector(collapseLeftClicked))
    }

    /// No-op now that the collapse icon lives in the fixed left cluster (it no
    /// longer repositions with the worktree column). Kept for call-site compat.
    func setLeftColumnCollapsed(_ collapsed: Bool) {}

    private func setupTitleLabel() {
        titleLabel.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        titleLabel.textColor = SemanticColors.text
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.maximumNumberOfLines = 1
        titleLabel.cell?.usesSingleLineMode = true
        titleLabel.cell?.lineBreakMode = .byTruncatingTail
        titleLabel.alignment = .center

        // Second line: full path of the current worktree, dimmer and smaller.
        pathLabel.font = NSFont.systemFont(ofSize: 10, weight: .regular)
        pathLabel.textColor = SemanticColors.muted
        pathLabel.lineBreakMode = .byTruncatingMiddle
        pathLabel.maximumNumberOfLines = 1
        pathLabel.cell?.usesSingleLineMode = true
        pathLabel.cell?.lineBreakMode = .byTruncatingMiddle
        pathLabel.alignment = .center

        titleStack.orientation = .vertical
        titleStack.alignment = .centerX
        titleStack.spacing = 1
        titleStack.translatesAutoresizingMaskIntoConstraints = false
        titleStack.addArrangedSubview(titleLabel)
        titleStack.addArrangedSubview(pathLabel)
        addSubview(titleStack)

        NSLayoutConstraint.activate([
            titleStack.centerXAnchor.constraint(equalTo: centerXAnchor),
            titleStack.centerYAnchor.constraint(equalTo: centerYAnchor, constant: Layout.arcVerticalOffset),
            titleStack.leadingAnchor.constraint(greaterThanOrEqualTo: leftClusterStack.trailingAnchor, constant: 8),
            titleStack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -12),
        ])
    }

    // MARK: - Arc Icon Button Helper

    private func configureArcIconButton(_ button: NSButton, symbol: String,
                                        identifier: String, label: String? = nil,
                                        hoverTracking: Bool = true, action: Selector) {
        let desc = label ?? identifier
        let config = NSImage.SymbolConfiguration(pointSize: 12, weight: .medium)
        if let image = NSImage(systemSymbolName: symbol, accessibilityDescription: desc) {
            button.image = image.withSymbolConfiguration(config)
        }
        button.bezelStyle = .recessed
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.contentTintColor = NSColor(hex: 0x888888)
        button.target = self
        button.action = action
        button.translatesAutoresizingMaskIntoConstraints = false
        button.setAccessibilityIdentifier(identifier)
        button.setAccessibilityLabel(desc)
        button.wantsLayer = true
        button.layer?.cornerRadius = 7
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: 26),
            button.heightAnchor.constraint(equalToConstant: 26),
        ])
        if hoverTracking { setupHoverTracking(for: button) }
    }

    // MARK: - Hover Tracking

    private func setupHoverTracking(for button: NSButton, defaultTint: NSColor = NSColor(hex: 0x888888)) {
        let hover = HoverTrackingView()
        hover.translatesAutoresizingMaskIntoConstraints = false
        button.addSubview(hover)
        NSLayoutConstraint.activate([
            hover.topAnchor.constraint(equalTo: button.topAnchor),
            hover.leadingAnchor.constraint(equalTo: button.leadingAnchor),
            hover.trailingAnchor.constraint(equalTo: button.trailingAnchor),
            hover.bottomAnchor.constraint(equalTo: button.bottomAnchor),
        ])
        hover.onHoverChanged = { [weak self, weak button] hovered in
            guard let self, let button else { return }
            self.updateIconButtonAppearance(button, hovered: hovered, defaultTint: defaultTint, animated: true)
        }
    }

    private func updateIconButtonAppearance(_ button: NSButton, hovered: Bool, defaultTint: NSColor, animated: Bool) {
        let apply = {
            button.layer?.backgroundColor = hovered
                ? button.resolvedCGColor(SemanticColors.iconButtonHoverBg)
                : NSColor.clear.cgColor
            if animated {
                button.animator().contentTintColor = hovered
                    ? SemanticColors.iconButtonHoverTint
                    : defaultTint
            } else {
                button.contentTintColor = hovered
                    ? SemanticColors.iconButtonHoverTint
                    : defaultTint
            }
        }

        if animated {
            animateHoverTransition(apply)
        } else {
            apply()
        }
    }

    private func animateHoverTransition(_ changes: @escaping () -> Void) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            context.allowsImplicitAnimation = true
            changes()
        }
    }

    // MARK: - Actions

    @objc private func themeClicked() {
        delegate?.titleBarDidToggleTheme()
    }

    @objc private func collapseLeftClicked() { delegate?.titleBarDidRequestCollapseLeftColumn() }

    @objc private func firstMateClicked() { delegate?.titleBarDidToggleFirstMate() }

    @objc private func paneButtonClicked(_ sender: NSButton) {
        guard let pane = LeftPane(rawValue: sender.tag) else { return }
        setSelectedLeftPane(pane)
        delegate?.titleBarDidSelectLeftPane(pane)
    }

    @objc private func worktreeListClicked() {
        delegate?.titleBarDidToggleWorktreeList(from: tabWorktreeButton)
    }

    // MARK: - Theme

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    private func applyColors() {
        let saved = NSAppearance.current
        NSAppearance.current = window?.effectiveAppearance ?? NSApp.effectiveAppearance
        titleLabel.textColor = SemanticColors.text
        pathLabel.textColor = SemanticColors.muted
        recomposeFocusedTitle()
        NSAppearance.current = saved
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = hoverTrackingArea {
            removeTrackingArea(existing)
        }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        hoverTrackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        setWindowHovered(true)
        super.mouseEntered(with: event)
    }

    override func mouseExited(with event: NSEvent) {
        setWindowHovered(false)
        super.mouseExited(with: event)
    }
}

// MARK: - WorktreeTabButton

private final class WorktreeTabButton: NSView {
    var onTap: ((String) -> Void)?
    let path: String
    private let dotView = NSView()
    private let glyphLabel = NSTextField(labelWithString: "")
    private let label = NSTextField(labelWithString: "")
    private let paneCountLabel = NSTextField(labelWithString: "")
    private var hovered = false
    private var isSelected = false

    // Constraint constants that depend on glyph/paneCount visibility — kept so
    // update(...) can adjust them in place instead of rebuilding the button.
    private var glyphWidthConstraint: NSLayoutConstraint!
    private var labelLeadingConstraint: NSLayoutConstraint!
    private var countWidthConstraint: NSLayoutConstraint!
    private var countLeadingConstraint: NSLayoutConstraint!

    init(path: String) {
        self.path = path
        super.init(frame: .zero)
        glyphWidthConstraint = glyphLabel.widthAnchor.constraint(equalToConstant: 0)
        labelLeadingConstraint = label.leadingAnchor.constraint(equalTo: glyphLabel.trailingAnchor, constant: 0)
        countWidthConstraint = paneCountLabel.widthAnchor.constraint(equalToConstant: 0)
        countLeadingConstraint = paneCountLabel.leadingAnchor.constraint(equalTo: dotView.trailingAnchor, constant: 0)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 5

        // Agent sigil (✻ Claude / ⟡ Codex / …) — leads the tab. Hidden when no AI agent.
        glyphLabel.font = AppFont.mono(size: 11, weight: .bold)
        glyphLabel.alignment = .center
        glyphLabel.translatesAutoresizingMaskIntoConstraints = false

        label.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        label.cell?.usesSingleLineMode = true
        label.translatesAutoresizingMaskIntoConstraints = false

        // Status dot — trails the label.
        dotView.wantsLayer = true
        dotView.layer?.cornerRadius = 3
        dotView.translatesAutoresizingMaskIntoConstraints = false

        // Pane-count number — after the dot. Hidden for a single pane.
        paneCountLabel.font = AppFont.mono(size: 10, weight: .medium)
        paneCountLabel.textColor = SemanticColors.muted
        paneCountLabel.translatesAutoresizingMaskIntoConstraints = false

        addSubview(glyphLabel)
        addSubview(label)
        addSubview(dotView)
        addSubview(paneCountLabel)

        NSLayoutConstraint.activate([
            glyphLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            glyphLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            glyphWidthConstraint,

            labelLeadingConstraint,
            label.centerYAnchor.constraint(equalTo: centerYAnchor),

            dotView.widthAnchor.constraint(equalToConstant: 6),
            dotView.heightAnchor.constraint(equalToConstant: 6),
            dotView.centerYAnchor.constraint(equalTo: centerYAnchor),
            dotView.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: 6),

            countLeadingConstraint,
            paneCountLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            countWidthConstraint,
            paneCountLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),

            heightAnchor.constraint(equalToConstant: 22),
            // Cap very long titles so a single tab can't dominate the strip.
            widthAnchor.constraint(lessThanOrEqualToConstant: 220),
        ])
        // Let the label truncate (tail) instead of stretching the tab.
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let click = NSClickGestureRecognizer(target: self, action: #selector(handleClick))
        addGestureRecognizer(click)

        updateTrackingAreas()
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Refresh the button's content in place. Called on every title-bar update,
    /// so it only touches what actually changed.
    func update(title: String, agentGlyph: String?, agentColor: NSColor, statusColor: NSColor, paneCount: Int, isSelected: Bool) {
        if glyphLabel.stringValue != (agentGlyph ?? "") || glyphLabel.isHidden != (agentGlyph == nil) {
            glyphLabel.stringValue = agentGlyph ?? ""
            glyphLabel.isHidden = (agentGlyph == nil)
            // When the glyph is hidden it collapses to zero width so the title leads.
            glyphWidthConstraint.constant = agentGlyph == nil ? 0 : 12
            labelLeadingConstraint.constant = agentGlyph == nil ? 0 : 5
        }
        glyphLabel.textColor = agentColor
        if label.stringValue != title { label.stringValue = title }
        dotView.layer?.backgroundColor = statusColor.cgColor
        let countText = "\(paneCount)"
        if paneCountLabel.stringValue != countText || paneCountLabel.isHidden != (paneCount <= 1) {
            paneCountLabel.stringValue = countText
            paneCountLabel.isHidden = (paneCount <= 1)
            // When the count is hidden it collapses so the dot trails the tab.
            countWidthConstraint.constant = paneCount <= 1 ? 0 : 10
            countLeadingConstraint.constant = paneCount <= 1 ? 0 : 4
        }
        self.isSelected = isSelected
        label.textColor = isSelected ? SemanticColors.text : SemanticColors.muted
        if !hovered { applySelectedStyle(isSelected) }
    }

    private func applySelectedStyle(_ selected: Bool) {
        layer?.backgroundColor = selected
            ? NSColor.white.withAlphaComponent(0.12).cgColor
            : NSColor.clear.cgColor
    }

    @objc private func handleClick() {
        onTap?(path)
    }

    private var trackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingArea { removeTrackingArea(existing) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp], owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        hovered = true
        layer?.backgroundColor = NSColor.white.withAlphaComponent(0.08).cgColor
    }

    override func mouseExited(with event: NSEvent) {
        hovered = false
        applySelectedStyle(isSelected)
    }
}

// MARK: - TitleBarIconButton

/// Icon button that behaves reliably inside the title-bar accessory: it takes
/// the very first click even when the window isn't key (no click-to-activate
/// swallowing the press) and never hands its area to window dragging.
final class TitleBarIconButton: NSButton {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
}

// MARK: - HoverTrackingView

private final class HoverTrackingView: NSView {
    var onHoverChanged: ((Bool) -> Void)?
    private var trackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingArea {
            removeTrackingArea(existing)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInActiveApp],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        onHoverChanged?(true)
    }

    override func mouseExited(with event: NSEvent) {
        onHoverChanged?(false)
    }
}

// MARK: - OverflowItemView

/// A 2-line custom menu item for the worktree overflow pulldown: repo on the
/// first line, branch on the second, with a status dot — so long titles wrap
/// instead of truncating.
private final class OverflowItemView: NSView {
    private weak var item: NSMenuItem?
    private weak var actionTarget: AnyObject?
    private let action: Selector
    private let dot = NSView()
    private var trackingArea: NSTrackingArea?

    init(title: String, statusColor: NSColor, target: AnyObject, action: Selector, item: NSMenuItem) {
        self.item = item
        self.actionTarget = target
        self.action = action
        super.init(frame: NSRect(x: 0, y: 0, width: 300, height: 44))
        wantsLayer = true
        autoresizingMask = [.width]

        let repo: String
        let branch: String
        if let r = title.range(of: " · ") {
            repo = String(title[..<r.lowerBound])
            branch = String(title[r.upperBound...])
        } else {
            repo = title
            branch = ""
        }

        dot.wantsLayer = true
        dot.layer?.cornerRadius = 3
        dot.layer?.backgroundColor = statusColor.cgColor
        dot.translatesAutoresizingMaskIntoConstraints = false
        addSubview(dot)

        let repoLabel = NSTextField(labelWithString: repo)
        repoLabel.font = AppFont.mono(size: 12, weight: .medium)
        repoLabel.textColor = SemanticColors.text
        repoLabel.lineBreakMode = .byTruncatingTail
        repoLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(repoLabel)

        let branchLabel = NSTextField(labelWithString: branch)
        branchLabel.font = AppFont.mono(size: 11, weight: .regular)
        branchLabel.textColor = SemanticColors.muted
        branchLabel.lineBreakMode = .byTruncatingTail
        branchLabel.isHidden = branch.isEmpty
        branchLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(branchLabel)

        NSLayoutConstraint.activate([
            dot.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            dot.topAnchor.constraint(equalTo: topAnchor, constant: 9),
            dot.widthAnchor.constraint(equalToConstant: 6),
            dot.heightAnchor.constraint(equalToConstant: 6),

            repoLabel.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: 9),
            repoLabel.topAnchor.constraint(equalTo: topAnchor, constant: 5),
            repoLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),

            branchLabel.leadingAnchor.constraint(equalTo: repoLabel.leadingAnchor),
            branchLabel.topAnchor.constraint(equalTo: repoLabel.bottomAnchor, constant: 2),
            branchLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = trackingArea { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                               owner: self, userInfo: nil)
        addTrackingArea(t); trackingArea = t
    }
    override func mouseEntered(with event: NSEvent) {
        layer?.backgroundColor = NSColor.selectedContentBackgroundColor.withAlphaComponent(0.25).cgColor
    }
    override func mouseExited(with event: NSEvent) {
        layer?.backgroundColor = NSColor.clear.cgColor
    }
    override func mouseUp(with event: NSEvent) {
        if let item, let target = actionTarget { _ = NSApp.sendAction(action, to: target, from: item) }
        enclosingMenuItem?.menu?.cancelTracking()
    }
}
