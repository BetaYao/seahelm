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

    /// Vibrancy glass column (header + navigator). Terminal column stays opaque.
    private let sidebarColumn = NSVisualEffectView()
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

    /// View that owns `Region.titlebar` keyboard focus for the current collapse state.
    func titlebarRegionFocusTarget() -> NSView {
        state.isCollapsed ? terminalHeader : sidebarHeader
    }

    /// Apply / clear the visual + first-responder focus for `Region.titlebar`.
    /// Targets the live chrome header icon strip — never a title-bar accessory.
    func setTitlebarRegionFocused(_ focused: Bool) {
        let target = titlebarRegionFocusTarget()
        let other = state.isCollapsed ? sidebarHeader as NSView : terminalHeader as NSView
        applyRegionHighlight(to: other, focused: false)
        applyRegionHighlight(to: target, focused: focused)
        if focused, let window = view.window {
            // Prefer the first icon button so keyboard activation lands on chrome tools.
            let icon = firstIconButton(in: target) ?? target
            window.makeFirstResponder(icon)
        }
    }

    // MARK: - Setup

    private func setupHierarchy() {
        configureSidebarGlass(sidebarColumn)
        sidebarColumn.translatesAutoresizingMaskIntoConstraints = false
        sidebarColumn.setAccessibilityIdentifier("chrome.sidebarColumn")

        sidebarContentHost.translatesAutoresizingMaskIntoConstraints = false
        sidebarContentHost.wantsLayer = true
        sidebarContentHost.layer?.backgroundColor = NSColor.clear.cgColor
        sidebarContentHost.setAccessibilityIdentifier("chrome.sidebarContent")

        terminalColumn.translatesAutoresizingMaskIntoConstraints = false
        terminalColumn.wantsLayer = true
        // Opaque terminal column — vibrancy stays on the sidebar only.
        terminalColumn.layer?.backgroundColor = SemanticColors.panel2.cgColor
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

    /// Sidebar material: macOS 26+ prefers the newest sidebar/glass semantic material
    /// when the SDK exposes one; otherwise `.sidebar` + `.behindWindow` (works on 14+).
    private func configureSidebarGlass(_ effect: NSVisualEffectView) {
        effect.blendingMode = .behindWindow
        effect.state = .followsWindowActiveState
        if #available(macOS 26.0, *) {
            // Tahoe+: `.sidebar` is the semantic Liquid Glass sidebar material in
            // current SDKs. Prefer it over window-background materials.
            effect.material = .sidebar
        } else {
            effect.material = .sidebar
        }
    }

    private func applyRegionHighlight(to view: NSView, focused: Bool) {
        view.wantsLayer = true
        if focused {
            view.layer?.borderWidth = 1.5
            view.layer?.borderColor = Theme.accent.cgColor
            view.layer?.cornerRadius = 6
        } else {
            view.layer?.borderWidth = 0
            view.layer?.borderColor = nil
        }
    }

    private func firstIconButton(in root: NSView) -> NSView? {
        if root is ChromeIconButton { return root }
        for sub in root.subviews {
            if let found = firstIconButton(in: sub) { return found }
        }
        return nil
    }
}
