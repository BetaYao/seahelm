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
}

final class TitleBarView: NSView {
    enum Layout {
        static let barHeight: CGFloat = 38
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
    private let collapseLeftButton = NSButton()
    private var collapseLeftExpandedConstraint: NSLayoutConstraint?
    private var collapseLeftCollapsedConstraint: NSLayoutConstraint?

    // Left control cluster — theme toggle + the four pane switchers.
    private let leftClusterStack = NSStackView()
    private let themeButton = NSButton()
    private var paneButtons: [LeftPane: NSButton] = [:]
    private var selectedLeftPane: LeftPane = .bridge

    // Fixed worktree-list icon at the front of the tab strip; opens a popover.
    private let tabWorktreeButton = NSButton()
    private var worktreeButtonExpandedLeading: NSLayoutConstraint?
    private var worktreeButtonCollapsedLeading: NSLayoutConstraint?

    // Worktree tab strip (horizontally scrollable) + overflow menu for idle tabs.
    private let tabStripScroll = NSScrollView()
    private let tabStripStack = NSStackView()
    private let tabOverflowButton = NSButton()
    private var scrollTrailingToOverflow: NSLayoutConstraint?
    private var scrollTrailingToEdge: NSLayoutConstraint?
    private var worktreeTabPaths: [String] = []
    private var collapsedTabs: [(path: String, title: String, statusColor: NSColor)] = []

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

    func updateChromeState(isGridLayout: Bool, hasWorkspaces: Bool = true, canCleanWorktrees: Bool = false) {
        // The clean-worktree control was removed; parameters kept for source compatibility.
        layoutSubtreeIfNeeded()
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

    func updateFocusedWorktree(title: String, path: String = "", tokenText: String = "\u{2014}") {
        titleLabel.stringValue = Self.clampTitle(title)
        titleLabel.toolTip = title
        // Abbreviate the home directory so the second line stays readable.
        let display = path.isEmpty ? "" : (path as NSString).abbreviatingWithTildeInPath
        pathLabel.stringValue = display
        pathLabel.toolTip = path
        pathLabel.isHidden = display.isEmpty
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

        configureArcIconButton(themeButton, symbol: "circle.lefthalf.filled",
                               identifier: "titlebar.themeToggle", label: "Toggle Theme",
                               action: #selector(themeClicked))
        leftClusterStack.addArrangedSubview(themeButton)

        // Pane switchers: bridge only.
        let panes: [(LeftPane, String, String)] = [
            (.bridge, "sailboat", "First Mate"),
            (.file, "folder", "Files"),
            (.change, "plusminus", "Changes"),
        ]
        for (pane, symbol, label) in panes {
            let btn = NSButton()
            configureArcIconButton(btn, symbol: symbol,
                                   identifier: "titlebar.pane.\(pane.rawValue)", label: label,
                                   hoverTracking: false, action: #selector(paneButtonClicked(_:)))
            btn.tag = pane.rawValue
            paneButtons[pane] = btn
            leftClusterStack.addArrangedSubview(btn)
        }

        NSLayoutConstraint.activate([
            leftClusterStack.leadingAnchor.constraint(equalTo: collapseLeftButton.trailingAnchor, constant: 8),
            leftClusterStack.centerYAnchor.constraint(equalTo: centerYAnchor, constant: Layout.arcVerticalOffset),
        ])
        updatePaneHighlight()
    }

    private func updatePaneHighlight() {
        for (pane, btn) in paneButtons {
            btn.contentTintColor = pane == selectedLeftPane ? Theme.accent : NSColor(hex: 0x888888)
        }
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
        // Expanded: align to the centre content's left edge. Collapsed: the
        // centre content slides under the traffic lights, so instead tuck the
        // worktree icon right after the left icon cluster.
        worktreeButtonExpandedLeading = tabWorktreeButton.leadingAnchor.constraint(
            equalTo: leadingAnchor, constant: Layout.centerContentLeftEdge - Layout.toolbarLeadingInset)
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

        scrollTrailingToOverflow = tabStripScroll.trailingAnchor.constraint(equalTo: tabOverflowButton.leadingAnchor, constant: -6)
        scrollTrailingToEdge = tabStripScroll.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12)
        scrollTrailingToEdge?.isActive = true

        NSLayoutConstraint.activate([
            tabStripScroll.leadingAnchor.constraint(equalTo: tabWorktreeButton.trailingAnchor, constant: 6),
            tabStripScroll.centerYAnchor.constraint(equalTo: centerYAnchor, constant: Layout.arcVerticalOffset),
            tabStripScroll.heightAnchor.constraint(equalToConstant: 22),

            tabOverflowButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            tabOverflowButton.centerYAnchor.constraint(equalTo: centerYAnchor, constant: Layout.arcVerticalOffset),
            tabOverflowButton.heightAnchor.constraint(equalToConstant: 22),

            tabStripStack.topAnchor.constraint(equalTo: tabStripScroll.contentView.topAnchor),
            tabStripStack.bottomAnchor.constraint(equalTo: tabStripScroll.contentView.bottomAnchor),
            tabStripStack.leadingAnchor.constraint(equalTo: tabStripScroll.contentView.leadingAnchor),
            tabStripStack.heightAnchor.constraint(equalToConstant: 22),
        ])
    }

    func setWorktreeTabs(_ tabs: [(path: String, title: String, statusColor: NSColor, isSelected: Bool, collapsed: Bool)]) {
        worktreeTabPaths = tabs.map(\.path)
        tabStripStack.arrangedSubviews.forEach { $0.removeFromSuperview() }

        let active = tabs.filter { !$0.collapsed }
        collapsedTabs = tabs.filter(\.collapsed).map { ($0.path, $0.title, $0.statusColor) }

        var selectedButton: WorktreeTabButton?
        for tab in active {
            let btn = WorktreeTabButton(path: tab.path, title: tab.title, statusColor: tab.statusColor, isSelected: tab.isSelected)
            btn.onTap = { [weak self] path in
                self?.delegate?.titleBarDidSelectWorktree(path)
            }
            tabStripStack.addArrangedSubview(btn)
            if tab.isSelected { selectedButton = btn }
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

        // Keep the selected tab in view after layout settles.
        if let selectedButton {
            DispatchQueue.main.async {
                selectedButton.scrollToVisible(selectedButton.bounds)
            }
        }
    }

    @objc private func overflowClicked() {
        guard !collapsedTabs.isEmpty else { return }
        let menu = NSMenu()
        for tab in collapsedTabs {
            let item = NSMenuItem(title: tab.title, action: #selector(overflowItemClicked(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = tab.path
            item.image = Self.statusDotImage(color: tab.statusColor)
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
        configureArcIconButton(collapseLeftButton, symbol: "sidebar.left",
                               identifier: "titlebar.collapseLeft", label: "Toggle Worktrees",
                               action: #selector(collapseLeftClicked))
        addSubview(collapseLeftButton)
        // Pinned to the far left so the pane-switch cluster reads as a single
        // top-left group regardless of the worktree column's collapsed state.
        collapseLeftExpandedConstraint = collapseLeftButton.leadingAnchor.constraint(
            equalTo: leadingAnchor, constant: 4)
        collapseLeftCollapsedConstraint = collapseLeftButton.leadingAnchor.constraint(
            equalTo: leadingAnchor, constant: 4)
        collapseLeftExpandedConstraint?.isActive = true
        NSLayoutConstraint.activate([
            collapseLeftButton.centerYAnchor.constraint(equalTo: centerYAnchor, constant: Layout.arcVerticalOffset),
        ])
    }

    /// Reposition the collapse-left icon: tucked by the traffic lights when the
    /// worktree column is collapsed, aligned to that column's right edge otherwise.
    func setLeftColumnCollapsed(_ collapsed: Bool) {
        collapseLeftExpandedConstraint?.isActive = !collapsed
        collapseLeftCollapsedConstraint?.isActive = collapsed
        // Re-align the worktree icon + tab strip: to the centre content's left
        // edge when expanded, tucked after the icon cluster when collapsed.
        worktreeButtonExpandedLeading?.isActive = !collapsed
        worktreeButtonCollapsedLeading?.isActive = collapsed
        layoutSubtreeIfNeeded()
    }

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
            button.widthAnchor.constraint(equalToConstant: 24),
            button.heightAnchor.constraint(equalToConstant: 24),
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
    private let path: String
    private let dotView = NSView()
    private let label = NSTextField(labelWithString: "")
    private var hovered = false

    init(path: String, title: String, statusColor: NSColor, isSelected: Bool) {
        self.path = path
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 5

        dotView.wantsLayer = true
        dotView.layer?.cornerRadius = 3
        dotView.layer?.backgroundColor = statusColor.cgColor
        dotView.translatesAutoresizingMaskIntoConstraints = false

        label.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        label.textColor = isSelected ? SemanticColors.text : SemanticColors.muted
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        label.cell?.usesSingleLineMode = true
        label.translatesAutoresizingMaskIntoConstraints = false
        label.stringValue = title

        addSubview(dotView)
        addSubview(label)

        NSLayoutConstraint.activate([
            dotView.widthAnchor.constraint(equalToConstant: 6),
            dotView.heightAnchor.constraint(equalToConstant: 6),
            dotView.centerYAnchor.constraint(equalTo: centerYAnchor),
            dotView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            label.leadingAnchor.constraint(equalTo: dotView.trailingAnchor, constant: 4),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: 22),
            // Cap very long titles so a single tab can't dominate the strip.
            widthAnchor.constraint(lessThanOrEqualToConstant: 200),
        ])
        // Let the label truncate (tail) instead of stretching the tab.
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        applySelectedStyle(isSelected)

        let click = NSClickGestureRecognizer(target: self, action: #selector(handleClick))
        addGestureRecognizer(click)

        updateTrackingAreas()
    }

    required init?(coder: NSCoder) { fatalError() }

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
        applySelectedStyle(label.textColor == SemanticColors.text)
    }
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
