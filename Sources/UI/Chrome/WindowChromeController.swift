import AppKit

/// Two-column window chrome shell: sidebar + divider + terminal content hosts.
final class WindowChromeController: NSViewController {
    var onStateChange: ((ChromeLayoutState) -> Void)?

    weak var headerDelegate: ChromeHeaderDelegate? {
        didSet {
            sidebarHeader.delegate = headerDelegate
            terminalHeader.delegate = headerDelegate
        }
    }

    private var state = ChromeLayoutState(
        width: ChromeLayoutMetrics.defaultSidebarWidth,
        collapsed: false,
        activePane: .firstMate
    )

    private let sidebarColumn = NSView()
    private let sidebarHeader = SidebarHeaderView()
    private let sidebarContentHost = NSView()

    private let divider = ChromeDividerView()

    private let terminalColumn = NSView()
    private let terminalHeader = TerminalHeaderView()
    private let terminalContentHost = NSView()

    private var sidebarWidthConstraint: NSLayoutConstraint!
    private var dividerWidthConstraint: NSLayoutConstraint!

    // MARK: - Lifecycle

    override func loadView() {
        view = NSView()
        view.wantsLayer = true
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        setupHierarchy()
        setupConstraints()
        divider.onDrag = { [weak self] deltaX in
            self?.handleDividerDrag(deltaX: deltaX)
        }
        applyState(state, animated: false)
    }

    // MARK: - Public API

    func setSidebarContent(_ view: NSView) {
        replaceContent(in: sidebarContentHost, with: view)
    }

    func setTerminalContent(_ view: NSView) {
        replaceContent(in: terminalContentHost, with: view)
    }

    func applyState(_ newState: ChromeLayoutState, animated: Bool) {
        state = newState
        syncHeaders()
        layoutColumns(animated: animated)
    }

    var layoutState: ChromeLayoutState { state }

    func updateTerminalTitle(repo: String, pane: String) {
        terminalHeader.setTitle(repo: repo, pane: pane)
    }

    func trafficLightHostView(collapsed: Bool) -> NSView {
        collapsed ? terminalHeader.trafficLightSlot : sidebarHeader.trafficLightSlot
    }

    func setWorktreeContextEnabled(_ enabled: Bool) {
        sidebarHeader.setWorktreeContextEnabled(enabled)
        terminalHeader.setWorktreeContextEnabled(enabled)
    }

    // MARK: - Setup

    private func setupHierarchy() {
        sidebarColumn.translatesAutoresizingMaskIntoConstraints = false
        sidebarColumn.wantsLayer = true
        sidebarColumn.setAccessibilityIdentifier("chrome.sidebarColumn")

        sidebarContentHost.translatesAutoresizingMaskIntoConstraints = false
        sidebarContentHost.setAccessibilityIdentifier("chrome.sidebarContent")

        terminalColumn.translatesAutoresizingMaskIntoConstraints = false
        terminalColumn.wantsLayer = true
        terminalColumn.layer?.backgroundColor = SemanticColors.panel.cgColor
        terminalColumn.setAccessibilityIdentifier("chrome.terminalColumn")

        terminalContentHost.translatesAutoresizingMaskIntoConstraints = false
        terminalContentHost.setAccessibilityIdentifier("chrome.terminalContent")

        sidebarHeader.delegate = headerDelegate
        terminalHeader.delegate = headerDelegate

        view.addSubview(sidebarColumn)
        view.addSubview(divider)
        view.addSubview(terminalColumn)

        sidebarColumn.addSubview(sidebarHeader)
        sidebarColumn.addSubview(sidebarContentHost)

        terminalColumn.addSubview(terminalHeader)
        terminalColumn.addSubview(terminalContentHost)
    }

    private func setupConstraints() {
        sidebarWidthConstraint = sidebarColumn.widthAnchor.constraint(
            equalToConstant: ChromeLayoutMetrics.defaultSidebarWidth)
        // ChromeDividerView also pins its own width; we own an explicit constraint so
        // collapse can zero the hit strip without leaving a layout gap.
        dividerWidthConstraint = divider.widthAnchor.constraint(
            equalToConstant: ChromeLayoutMetrics.dividerHitWidth)
        dividerWidthConstraint.priority = .required

        NSLayoutConstraint.activate([
            sidebarColumn.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            sidebarColumn.topAnchor.constraint(equalTo: view.topAnchor),
            sidebarColumn.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            sidebarWidthConstraint,

            sidebarHeader.leadingAnchor.constraint(equalTo: sidebarColumn.leadingAnchor),
            sidebarHeader.trailingAnchor.constraint(equalTo: sidebarColumn.trailingAnchor),
            sidebarHeader.topAnchor.constraint(equalTo: sidebarColumn.topAnchor),

            sidebarContentHost.leadingAnchor.constraint(equalTo: sidebarColumn.leadingAnchor),
            sidebarContentHost.trailingAnchor.constraint(equalTo: sidebarColumn.trailingAnchor),
            sidebarContentHost.topAnchor.constraint(equalTo: sidebarHeader.bottomAnchor),
            sidebarContentHost.bottomAnchor.constraint(equalTo: sidebarColumn.bottomAnchor),

            divider.leadingAnchor.constraint(equalTo: sidebarColumn.trailingAnchor),
            divider.topAnchor.constraint(equalTo: view.topAnchor),
            divider.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            dividerWidthConstraint,

            terminalColumn.leadingAnchor.constraint(equalTo: divider.trailingAnchor),
            terminalColumn.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            terminalColumn.topAnchor.constraint(equalTo: view.topAnchor),
            terminalColumn.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            terminalHeader.leadingAnchor.constraint(equalTo: terminalColumn.leadingAnchor),
            terminalHeader.trailingAnchor.constraint(equalTo: terminalColumn.trailingAnchor),
            terminalHeader.topAnchor.constraint(equalTo: terminalColumn.topAnchor),

            terminalContentHost.leadingAnchor.constraint(equalTo: terminalColumn.leadingAnchor),
            terminalContentHost.trailingAnchor.constraint(equalTo: terminalColumn.trailingAnchor),
            terminalContentHost.topAnchor.constraint(equalTo: terminalHeader.bottomAnchor),
            terminalContentHost.bottomAnchor.constraint(equalTo: terminalColumn.bottomAnchor),
        ])
    }

    // MARK: - Layout

    private func syncHeaders() {
        sidebarHeader.setActivePane(state.activePane)
        terminalHeader.setActivePane(state.activePane)
        terminalHeader.setCollapsed(state.isCollapsed)
        // Icons live in the collapsed terminal header; hide sidebar chrome icons when collapsed.
        sidebarHeader.isHidden = state.isCollapsed
    }

    private func layoutColumns(animated: Bool) {
        let collapsed = state.isCollapsed
        let targetSidebarWidth = collapsed
            ? 0
            : ChromeLayoutMetrics.clampWidth(state.width, windowWidth: windowWidthForClamp())
        let targetDividerWidth = collapsed ? 0 : ChromeLayoutMetrics.dividerHitWidth

        if !collapsed {
            sidebarColumn.isHidden = false
            divider.isHidden = false
        }

        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let duration: TimeInterval = (!animated || reduceMotion) ? 0 : 0.2

        if duration == 0 {
            sidebarWidthConstraint.constant = targetSidebarWidth
            dividerWidthConstraint.constant = targetDividerWidth
            if collapsed {
                sidebarColumn.isHidden = true
                divider.isHidden = true
            }
            view.layoutSubtreeIfNeeded()
            return
        }

        NSAnimationContext.runAnimationGroup({ context in
            context.duration = duration
            context.allowsImplicitAnimation = true
            self.sidebarWidthConstraint.animator().constant = targetSidebarWidth
            self.dividerWidthConstraint.animator().constant = targetDividerWidth
        }, completionHandler: {
            if collapsed {
                self.sidebarColumn.isHidden = true
                self.divider.isHidden = true
            }
        })
    }

    private func handleDividerDrag(deltaX: CGFloat) {
        guard !state.isCollapsed else { return }
        let next = ChromeLayoutMetrics.clampWidth(
            state.width + deltaX,
            windowWidth: windowWidthForClamp()
        )
        guard next != state.width else { return }
        state.width = next
        sidebarWidthConstraint.constant = next
        onStateChange?(state)
    }

    private func windowWidthForClamp() -> CGFloat {
        let width = view.bounds.width
        return width > 0 ? width : (view.window?.frame.width ?? 1200)
    }

    private func replaceContent(in host: NSView, with content: NSView) {
        host.subviews.forEach { $0.removeFromSuperview() }
        content.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            content.topAnchor.constraint(equalTo: host.topAnchor),
            content.bottomAnchor.constraint(equalTo: host.bottomAnchor),
        ])
    }
}
