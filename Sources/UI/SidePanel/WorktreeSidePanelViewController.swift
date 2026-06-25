import AppKit

enum SidePanelTab: Int {
    case firstMate = 0
}

protocol WorktreeSidePanelDelegate: AnyObject {
}

final class WorktreeSidePanelViewController: NSViewController {
    private var worktreePath: String?
    private var selectedTab: SidePanelTab

    weak var delegate: WorktreeSidePanelDelegate?

    private let tabBar = NSStackView()
    private let contentView = NSView()

    // First Mate tab
    private var bridgeVC: BridgePanelViewController?
    var pendingOrdersQueue: PendingOrdersQueue? {
        didSet { bridgeVC?.queue = pendingOrdersQueue }
    }
    var watchFeed: WatchFeed? {
        didSet { bridgeVC?.watchFeed = watchFeed }
    }
    var suggestionFeed: SuggestionFeed? {
        didSet { bridgeVC?.suggestionFeed = suggestionFeed }
    }
    var onSuggestionTapped: ((SuggestionItem, String) -> Void)?
    var onBridgeNavigate: ((String) -> Void)?
    var onBridgeApprove: ((PendingOrder) -> Void)?

    var selectedTabForTesting: SidePanelTab { selectedTab }
    var worktreePathForTesting: String? { worktreePath }

    init(worktreePath: String?, initialTab: SidePanelTab = .firstMate) {
        self.worktreePath = worktreePath
        self.selectedTab = initialTab
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    override func loadView() {
        let root = ThemedBackgroundView()
        root.backgroundToken = Theme.background
        root.setAccessibilityIdentifier("sidePanel.view")

        tabBar.orientation = .horizontal
        tabBar.spacing = 2
        tabBar.distribution = .fillEqually
        tabBar.translatesAutoresizingMaskIntoConstraints = false

        let tabs: [(SidePanelTab, String, String)] = [
            (.firstMate, "sailboat", "First Mate"),
        ]
        for (tab, icon, tooltip) in tabs {
            let btn = NSButton()
            btn.bezelStyle = .recessed
            btn.isBordered = false
            btn.imagePosition = .imageOnly
            btn.image = NSImage(systemSymbolName: icon, accessibilityDescription: tooltip)
            btn.contentTintColor = tab == selectedTab ? Theme.accent : Theme.textSecondary
            btn.target = self
            btn.action = #selector(tabButtonClicked(_:))
            btn.tag = tab.rawValue
            btn.toolTip = tooltip
            btn.translatesAutoresizingMaskIntoConstraints = false
            btn.heightAnchor.constraint(equalToConstant: 24).isActive = true
            tabBar.addArrangedSubview(btn)
        }

        // The internal tab bar is hidden — pane switching is driven by the
        // title-bar pane-switch icons now. tabBar is left unused but in place
        // so the highlight bookkeeping in updateTabBarHighlight() stays valid.
        tabBar.isHidden = true

        contentView.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(contentView)

        NSLayoutConstraint.activate([
            contentView.topAnchor.constraint(equalTo: root.topAnchor, constant: 4),
            contentView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            contentView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            contentView.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])

        view = root
        rebuildContent()
    }

    @objc private func tabButtonClicked(_ sender: NSButton) {
        guard let tab = SidePanelTab(rawValue: sender.tag) else { return }
        selectTab(tab)
    }

    private func updateTabBarHighlight() {
        for view in tabBar.arrangedSubviews {
            guard let btn = view as? NSButton, let tab = SidePanelTab(rawValue: btn.tag) else { continue }
            btn.contentTintColor = tab == selectedTab ? Theme.accent : Theme.textSecondary
        }
    }

    func setWorktree(_ path: String?) {
        guard path != worktreePath else { return }
        worktreePath = path
        if isViewLoaded { rebuildContent() }
    }

    /// Switch the visible tab. Driven by the title-bar pane icons.
    func selectTab(_ tab: SidePanelTab) {
        guard tab != selectedTab else { return }
        selectedTab = tab
        if isViewLoaded {
            updateTabBarHighlight()
            rebuildContent()
        }
    }

    private func rebuildContent() {
        // Remove any existing child VC
        bridgeVC?.view.removeFromSuperview()
        bridgeVC?.removeFromParent()
        bridgeVC = nil

        contentView.subviews.forEach { $0.removeFromSuperview() }

        switch selectedTab {
        case .firstMate:
            showFirstMateTab()
        }
    }

    private func showFirstMateTab() {
        let vc = BridgePanelViewController()
        vc.queue = pendingOrdersQueue
        vc.watchFeed = watchFeed
        vc.suggestionFeed = suggestionFeed
        vc.onSuggestionTapped = { [weak self] item, optionText in self?.onSuggestionTapped?(item, optionText) }
        vc.onNavigateToWorktree = { [weak self] path in self?.onBridgeNavigate?(path) }
        vc.onApprove = { [weak self] order in self?.onBridgeApprove?(order) }
        addChild(vc)
        vc.view.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(vc.view)
        NSLayoutConstraint.activate([
            vc.view.topAnchor.constraint(equalTo: contentView.topAnchor),
            vc.view.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            vc.view.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            vc.view.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
        ])
        bridgeVC = vc
    }

    private func showPlaceholder(_ message: String, identifier: String) {
        let label = NSTextField(labelWithString: message)
        label.font = NSFont.systemFont(ofSize: 13)
        label.textColor = Theme.textSecondary
        label.alignment = .center
        label.maximumNumberOfLines = 0
        label.lineBreakMode = .byWordWrapping
        label.setAccessibilityIdentifier(identifier)
        label.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            label.leadingAnchor.constraint(greaterThanOrEqualTo: contentView.leadingAnchor, constant: 16),
            label.trailingAnchor.constraint(lessThanOrEqualTo: contentView.trailingAnchor, constant: -16),
        ])
    }
}
