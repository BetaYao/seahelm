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

    /// Vibrancy glass for the sidebar only — terminal column is solid Ghostty bg
    /// so the title strip immerses into the surface.
    private let sidebarColumn = NSVisualEffectView()
    private let sidebarHeader = SidebarHeaderView()
    private let sidebarContentHost = NSView()

    /// Overlay hit-target; does not take layout space between the columns.
    private let divider = ChromeDividerView()

    private let terminalColumn = NSView()
    private let terminalHeader = TerminalHeaderView()
    private let terminalContentHost = NSView()

    private var sidebarWidthConstraint: NSLayoutConstraint!
    /// Bumped per collapse animation so a superseded one's completion is a no-op.
    private var collapseGeneration = 0
    private var colorSchemeObserver: NSObjectProtocol?

    /// Last pane/repo title from the live terminal. Restored when an overlay closes.
    private var lastPaneTitle = ""
    /// When set, the chrome title shows the file/changelog overlay name instead
    /// of the pane title (single title strip — no second header in the overlay).
    private var overlayTitle: String?

    // MARK: - Lifecycle

    override func loadView() {
        let root = ChromeRootView()
        root.wantsLayer = true
        root.onAppearanceChange = { [weak self] in
            self?.refreshChromeAppearance()
        }
        view = root
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        setupHierarchy()
        setupConstraints()
        divider.onDragBegan = { [weak self] in
            self?.handleDividerDragBegan()
        }
        divider.onDrag = { [weak self] deltaX in
            self?.handleDividerDrag(deltaX: deltaX)
        }
        divider.onDragEnded = { [weak self] in
            self?.handleDividerDragEnded()
        }
        colorSchemeObserver = NotificationCenter.default.addObserver(
            forName: .ghosttyColorSchemeDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.refreshTerminalImmersion()
        }
        applyState(state, animated: false)
    }

    deinit {
        if let colorSchemeObserver {
            NotificationCenter.default.removeObserver(colorSchemeObserver)
        }
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
        syncHeaders(animated: animated)
        layoutColumns(animated: animated)
    }

    func updateTerminalTitle(repo: String, pane: String) {
        // Immersive chrome: show the current pane title only — unless a file /
        // changelog overlay is borrowing the title strip.
        lastPaneTitle = pane.isEmpty ? repo : pane
        if overlayTitle == nil {
            terminalHeader.setPaneTitle(lastPaneTitle)
        }
    }

    /// Drive the chrome title from a center overlay (file / changelog). Pass
    /// `nil` to restore the live pane title.
    func setOverlayTitle(_ title: String?) {
        overlayTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let overlayTitle, !overlayTitle.isEmpty {
            terminalHeader.setPaneTitle(overlayTitle)
        } else {
            overlayTitle = nil
            terminalHeader.setPaneTitle(lastPaneTitle)
        }
    }

    func trafficLightHostView(collapsed: Bool) -> NSView {
        collapsed ? terminalHeader.trafficLightSlot : sidebarHeader.trafficLightSlot
    }

    func setWorktreeContextEnabled(_ enabled: Bool) {
        sidebarHeader.setWorktreeContextEnabled(enabled)
        terminalHeader.setWorktreeContextEnabled(enabled)
    }

    /// Drive the terminal header's edit-mode toggle (availability + on-state).
    func setEditMode(available: Bool, isOn: Bool) {
        terminalHeader.setEditMode(available: available, isOn: isOn)
    }

    /// `repo · branch` for the columns on screen. Only surfaces in edit mode, where
    /// the per-column tab strips already name the panes but nothing names the cabin.
    func updateCabinContext(_ context: String) {
        terminalHeader.setCabinContext(context)
    }

    /// Edit mode's column tab strips live on the header row, so the two-column
    /// layout costs one row of chrome instead of two. The header owns the strips;
    /// the dashboard populates them through `editStrips`.
    var editStrips: (terminal: EditTabStripView, preview: EditTabStripView) {
        (terminalHeader.editTerminalStrip, terminalHeader.editPreviewStrip)
    }

    func setEditStripsActive(_ active: Bool, ratio: CGFloat) {
        terminalHeader.setEditStripsActive(active, ratio: ratio)
    }

    func setEditStripRatio(_ ratio: CGFloat) {
        terminalHeader.setEditStripRatio(ratio)
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
        configureColumnGlass(sidebarColumn)
        sidebarColumn.translatesAutoresizingMaskIntoConstraints = false
        sidebarColumn.setAccessibilityIdentifier("chrome.sidebarColumn")

        sidebarContentHost.translatesAutoresizingMaskIntoConstraints = false
        sidebarContentHost.wantsLayer = true
        sidebarContentHost.layer?.backgroundColor = NSColor.clear.cgColor
        sidebarContentHost.setAccessibilityIdentifier("chrome.sidebarContent")

        terminalColumn.wantsLayer = true
        terminalColumn.translatesAutoresizingMaskIntoConstraints = false
        terminalColumn.setAccessibilityIdentifier("chrome.terminalColumn")

        terminalContentHost.translatesAutoresizingMaskIntoConstraints = false
        terminalContentHost.wantsLayer = true
        terminalContentHost.layer?.backgroundColor = NSColor.clear.cgColor
        terminalContentHost.setAccessibilityIdentifier("chrome.terminalContent")

        refreshTerminalImmersion()

        sidebarHeader.delegate = headerDelegate
        terminalHeader.delegate = headerDelegate

        // Divider last so its hit strip sits above both columns without a layout gap.
        view.addSubview(sidebarColumn)
        view.addSubview(terminalColumn)
        view.addSubview(divider)

        sidebarColumn.addSubview(sidebarHeader)
        sidebarColumn.addSubview(sidebarContentHost)

        terminalColumn.addSubview(terminalHeader)
        terminalColumn.addSubview(terminalContentHost)
    }

    private func setupConstraints() {
        sidebarWidthConstraint = sidebarColumn.widthAnchor.constraint(
            equalToConstant: ChromeLayoutMetrics.defaultSidebarWidth)

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

            // Columns meet flush — no reserved gutter for the divider.
            terminalColumn.leadingAnchor.constraint(equalTo: sidebarColumn.trailingAnchor),
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

            // 1px line centered on the seam; wider hit target overlays both sides.
            divider.centerXAnchor.constraint(equalTo: sidebarColumn.trailingAnchor),
            divider.topAnchor.constraint(equalTo: view.topAnchor),
            divider.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            divider.widthAnchor.constraint(equalToConstant: ChromeLayoutMetrics.dividerHitWidth),
        ])
    }

    // MARK: - Layout

    private func syncHeaders(animated: Bool) {
        sidebarHeader.setActivePane(state.activePane)
        terminalHeader.setActivePane(state.activePane)
        terminalHeader.setCollapsed(state.isCollapsed, animated: animated)
    }

    private func layoutColumns(animated: Bool) {
        // Fast repeat ⌘B — or a non-animated apply landing mid-slide — leaves an
        // earlier animation in flight; letting its completion run would settle
        // the sidebar to the state it was chasing, not the one we're now in.
        collapseGeneration &+= 1
        let generation = collapseGeneration

        let collapsed = state.isCollapsed
        let targetSidebarWidth = collapsed
            ? 0
            : ChromeLayoutMetrics.clampWidth(state.width, windowWidth: windowWidthForClamp())

        // Icons live in the collapsed terminal header, so the sidebar header is
        // hidden while collapsed — but only once the slide is over, or it
        // vanishes at frame 0 and the hand-off looks like a pop rather than a move.
        if !collapsed {
            sidebarColumn.isHidden = false
            divider.isHidden = false
            sidebarHeader.isHidden = false
        }

        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let duration: TimeInterval = (!animated || reduceMotion)
            ? 0
            : ChromeLayoutMetrics.collapseAnimationDuration

        if duration == 0 {
            sidebarWidthConstraint.constant = targetSidebarWidth
            sidebarColumn.alphaValue = 1
            divider.alphaValue = 1
            settle(collapsed: collapsed)
            view.layoutSubtreeIfNeeded()
            return
        }

        // Cross-fade alongside the width. Sliding alone kept the contents fully
        // opaque right up to the clipping edge, so the panel read as guillotined
        // rather than dismissed.
        sidebarColumn.alphaValue = collapsed ? 1 : 0
        divider.alphaValue = collapsed ? 1 : 0

        // Defer PTY set_size for the whole slide — otherwise every animation
        // frame reflows the terminal grid (SIGWINCH storm) while the sidebar moves.
        // Set the constant plainly, then animate the layout pass that consumes
        // it. Mixing the two AppKit idioms — `.animator().constant` AND an
        // in-group `layoutSubtreeIfNeeded()` — is what made this look instant:
        // the forced layout resolved the constraint immediately, so the group
        // had nothing left to interpolate and its completion fired on the next
        // frame. (Collapse snapped outright; expand only appeared to move.)
        sidebarWidthConstraint.constant = targetSidebarWidth

        GhosttyBridge.shared.beginLiveResize(pinHeight: true)
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = duration
            context.timingFunction = ChromeLayoutMetrics.collapseTimingFunction
            context.allowsImplicitAnimation = true
            self.sidebarColumn.animator().alphaValue = collapsed ? 0 : 1
            self.divider.animator().alphaValue = collapsed ? 0 : 1
            self.view.layoutSubtreeIfNeeded()
        }, completionHandler: nil)

        // Deliberately NOT the group's completionHandler. That fires as soon as
        // the group's own NSAnimations are done, which is roughly the next frame
        // — the width is carried by Core Animation and outlives it. Settling
        // there set `isHidden = true` mid-slide, which cancels the in-flight
        // animation and snaps the sidebar shut. Collapse looked instant; expand
        // survived only because its settle happens to be a no-op.
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self] in
            // Unconditional: every beginLiveResize needs its end, including the
            // one belonging to a slide that a newer ⌘B has already superseded.
            GhosttyBridge.shared.endLiveResize()
            guard let self, self.collapseGeneration == generation else { return }
            self.settle(collapsed: collapsed)
        }
    }

    /// Park the sidebar in its resting state. Alpha is transition-only, so it
    /// always returns to 1 — `isHidden` is what actually keeps a collapsed
    /// sidebar out of layout and hit-testing.
    private func settle(collapsed: Bool) {
        sidebarColumn.isHidden = collapsed
        divider.isHidden = collapsed
        sidebarHeader.isHidden = collapsed
        sidebarColumn.alphaValue = 1
        divider.alphaValue = 1
    }

    private func handleDividerDragBegan() {
        // Pin height: sidebar drag is horizontal-only; avoid row jitter → SIGWINCH.
        GhosttyBridge.shared.beginLiveResize(pinHeight: true)
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
        // Let AppKit layout on the next pass — forcing layout every delta was
        // amplifying sub-pixel height jitter into extra PTY resizes.
    }

    private func handleDividerDragEnded() {
        view.layoutSubtreeIfNeeded()
        // endLiveResize(pinHeight) skips PTY set_size — see GhosttyNSView.
        GhosttyBridge.shared.endLiveResize()
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

    /// Column vibrancy — same materials as `WindowStyling.glassBackgroundConfig`.
    private func configureColumnGlass(_ effect: NSVisualEffectView) {
        effect.blendingMode = .behindWindow
        effect.state = .followsWindowActiveState
        // Theme-independent (see WindowStyling.glassBackgroundConfig): dark's
        // `.hudWindow` let the wallpaper tint the sidebar, and picking by
        // `effectiveAppearance` here raced the toggle's appearance flip anyway.
        effect.material = .underWindowBackground
    }

    private func refreshChromeAppearance() {
        configureColumnGlass(sidebarColumn)
        refreshTerminalImmersion()
    }

    /// Solid Catppuccin bg on the terminal column + immersive title (no glass strip).
    private func refreshTerminalImmersion() {
        let bg = GhosttyBridge.shared.terminalChromeBackground
        terminalColumn.layer?.backgroundColor = bg.cgColor
        terminalHeader.refreshImmersion()
    }

    private func applyRegionHighlight(to view: NSView, focused: Bool) {
        view.wantsLayer = true
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            context.allowsImplicitAnimation = true
            if focused {
                view.layer?.borderWidth = 1.5
                view.layer?.borderColor = Theme.accent.cgColor
                view.layer?.cornerRadius = 6
            } else {
                view.layer?.borderWidth = 0
                view.layer?.borderColor = nil
            }
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

/// Forwards appearance flips so layer fills / vibrancy materials stay in sync.
private final class ChromeRootView: NSView {
    var onAppearanceChange: (() -> Void)?

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        onAppearanceChange?()
    }
}
