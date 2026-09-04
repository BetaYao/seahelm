import AppKit
import QuartzCore

// MARK: - Dashboard overview (spread First Mate fleet page)

private final class FlippedStackView: NSStackView {
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }
}

/// NSScrollView that never steals keyboard focus from the terminal.
private final class NonFirstResponderScrollView: NSScrollView {
    override var acceptsFirstResponder: Bool { false }
}

/// A fleet row that paints a pointer-hover tint.
///
/// Hover is owned by the list, not by the row's own tracking area. AppKit pairs
/// `mouseEntered` / `mouseExited` off pointer *movement*: scrolling the fleet
/// under a stationary cursor delivers an enter for every row that slides beneath
/// the pointer and no matching exit, so each one it passed stayed tinted and the
/// list read as a dozen rows selected at once. Routing both edges through the
/// list keeps at most one row lit no matter which events AppKit drops.
private protocol FleetHoverRow: NSView {
    func setHovered(_ hovered: Bool)
}

/// Full-width fleet overview: every worktree as a row grouped by the chosen mode,
/// with a shortcut cheat-strip along the bottom. This is the landing surface (the
/// "spread First Mate"); clicking a row drills into that worktree. Commands and
/// pending orders live in the island, not here.
final class DashboardOverviewView: NSView {

    /// Resolves a worktree's current-pane title for order cards.
    var currentPaneTitleProvider: ((String) -> String?)?
    var onSelectWorktree: ((String) -> Void)?
    /// A pane row was clicked in the expanded "Group by Pane" mode. Args:
    /// the pane's worktree path and its Station id.
    var onSelectPane: ((String, String) -> Void)?
    var onDeleteWorktree: ((String) -> Void)?
    /// Move a repo's integration checkout back onto origin/main. Only offered
    /// on rows that are one.
    var onResetIntegration: ((String) -> Void)?
    /// Right-click "Close Project…" on a project group header. Untracks the repo
    /// and tears down its sessions; worktrees stay on disk.
    var onCloseProject: ((String) -> Void)?
    var onGroupingChanged: (() -> Void)?
    /// The "+" on a project group header was clicked. Args: the project title,
    /// the button's rect in this view's coordinates, and this view (the popover's
    /// anchor — see `addWorktreeClicked`).
    var onAddWorktree: ((String, NSRect, NSView) -> Void)?
    var onIntegrate: ((String) -> Void)?
    /// The header "+" was clicked: add a repo via the folder picker.
    var onAddRepo: (() -> Void)?
    /// The bottom shortcut strip was clicked — show the full `?` cheat-sheet.
    var onShowAllShortcuts: (() -> Void)?

    // Palette — accent hues stay fixed; text/line/panel adapt to light/dark so
    // the navigator stays readable on the glass sidebar in both appearances.
    private static let line = NSColor(name: nil) { appearance in
        appearance.isDark
            ? NSColor(srgbRed: 150/255, green: 215/255, blue: 225/255, alpha: 0.10)
            : NSColor(srgbRed: 0x1f/255, green: 0x23/255, blue: 0x2b/255, alpha: 0.10)
    }
    // Dynamic: the raw #1fc8da cyan is unreadable as label ink on the light
    // panel (ORDERS header, `/` trigger glyph).
    private static let sea: NSColor = SemanticColors.accent
    fileprivate static let ink: NSColor = SemanticColors.text
    fileprivate static let inkDim: NSColor = SemanticColors.muted
    fileprivate static let inkFaint: NSColor = SemanticColors.subtle
    fileprivate static let red        = NSColor(srgbRed: 0xe0/255, green: 0x7a/255, blue: 0x6a/255, alpha: 1)
    fileprivate static let emerald    = NSColor(srgbRed: 0x5f/255, green: 0xb8/255, blue: 0x7a/255, alpha: 1)

    private let headerTitle = NSTextField(labelWithString: "First mate")
    private let headerSub = NSTextField(labelWithString: "")
    private let groupingButton = NSButton()
    private let addRepoButton = NSButton()
    private let groupingMenu = NSMenu()
    private let headerLine = NSView()
    private let scroll = NonFirstResponderScrollView()
    private let stack = FlippedStackView()

    // Bottom shortcut cheat-strip (replaced the composer).
    private let hintBar = ShortcutHintBar()

    private let groupingPreference: WorktreeGroupingPreference
    private let now: () -> Date
    private var groupingMode: WorktreeGroupingMode
    private var latestPanes: [WorktreeRowInfo] = []
    private var rowViewsByID: [String: RowView] = [:]
    private var renderedGroupTitles: [String] = []
    /// Project title per "add worktree" button, indexed by the button's tag —
    /// rebuilt with the rows on every render.
    private var addWorktreeProjects: [String] = []
    /// Tag → project for the integrate buttons, rebuilt on every full render
    /// exactly like `addWorktreeProjects`.
    private var integrateProjects: [String] = []
    /// Tag → project for the close-project buttons, rebuilt on every full render.
    private var closeProjectProjects: [String] = []
    /// Integration checkouts, shown above the fleet in the modes that group by
    /// status or time. Deliberately outside `stack`: those groupings leave the
    /// checkout out, and a banner inside the scrolling stack would go stale
    /// whenever `render` takes the incremental path.
    /// Seams, so a test can describe a fleet with an integration checkout
    /// without writing into the user's real config directory.
    private let isIntegrationWorktree: (String) -> Bool
    private let integrationStatus: (String) -> String?
    /// Master switch, pushed down from settings. Off hides the button, the
    /// banner and the pinned row — the checkout on disk is left alone.
    var integrationEnabled: Bool = true {
        didSet {
            guard integrationEnabled != oldValue else { return }
            // The flag changes what the header and banner hold, which the
            // structure signature does not describe — drop it so the next pass
            // is a full render rather than an incremental one.
            lastStructureSignature = nil
            render(latestPanes, revealSelection: false)
        }
    }
    private let integrationBanner = NSStackView()
    private var integrationBannerHeight: NSLayoutConstraint!
    private var integrationBannerLines: [String] = []
    private static let addWorktreeButtonIdentifier = NSUserInterfaceItemIdentifier("seahelm.addWorktree")
    private static let integrateButtonIdentifier = NSUserInterfaceItemIdentifier("seahelm.integrate")
    private static let closeProjectButtonIdentifier = NSUserInterfaceItemIdentifier("seahelm.closeProject")
    private var revealedRowID: String?
    /// The one row currently painting the hover tint, if any.
    private weak var hoveredRow: FleetHoverRow?
    private var paneRowViewsByStationID: [String: PaneRowView] = [:]
    private var lastStructureSignature: String?
    private var fullRenderCount = 0
    #if DEBUG
    private var incrementalUpdateCount = 0
    private var fullRenderTotalDurationMs: Double = 0
    private var incrementalTotalDurationMs: Double = 0
    private var lastTelemetryLogAt = Date.distantPast
    #endif

    override init(frame frameRect: NSRect) {
        let preference = WorktreeGroupingPreference(defaults: .standard)
        groupingPreference = preference
        now = Date.init
        isIntegrationWorktree = { IntegrationWorktreeStore.shared.isIntegrationWorktree($0) }
        integrationStatus = { IntegrationStatusStore.shared.status(forWorktree: $0) }
        groupingMode = preference.load()
        super.init(frame: frameRect)
        setup()
    }
    required init?(coder: NSCoder) {
        let preference = WorktreeGroupingPreference(defaults: .standard)
        groupingPreference = preference
        now = Date.init
        isIntegrationWorktree = { IntegrationWorktreeStore.shared.isIntegrationWorktree($0) }
        integrationStatus = { IntegrationStatusStore.shared.status(forWorktree: $0) }
        groupingMode = preference.load()
        super.init(coder: coder)
        setup()
    }

    init(
        frame frameRect: NSRect,
        defaults: UserDefaults,
        now: @escaping () -> Date,
        isIntegrationWorktree: @escaping (String) -> Bool = { IntegrationWorktreeStore.shared.isIntegrationWorktree($0) },
        integrationStatus: @escaping (String) -> String? = { IntegrationStatusStore.shared.status(forWorktree: $0) }
    ) {
        let preference = WorktreeGroupingPreference(defaults: defaults)
        groupingPreference = preference
        self.now = now
        self.isIntegrationWorktree = isIntegrationWorktree
        self.integrationStatus = integrationStatus
        groupingMode = preference.load()
        super.init(frame: frameRect)
        setup()
    }


    private func setup() {
        wantsLayer = true
        // Clear so WindowChromeController's sidebar vibrancy shows through.
        layer?.backgroundColor = NSColor.clear.cgColor

        // --- Header: ◍ First mate   N worktrees · M running  (border-bottom) ---
        let headerIcon = NSTextField(labelWithString: "◍")
        headerIcon.font = AppFont.mono(size: 13)
        headerIcon.textColor = Self.sea
        headerTitle.stringValue = "First mate"
        headerTitle.font = AppFont.mono(size: 12.5, weight: .bold)
        headerTitle.textColor = Self.ink
        headerSub.font = AppFont.mono(size: 11)
        headerSub.textColor = Self.inkFaint
        configureGroupingMenu()
        configureAddRepoButton()
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        spacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let headerRow = NSStackView(views: [headerIcon, headerTitle, headerSub, spacer,
                                            addRepoButton, groupingButton])
        headerRow.orientation = .horizontal
        headerRow.spacing = 10
        headerRow.alignment = .centerY
        headerRow.translatesAutoresizingMaskIntoConstraints = false
        addSubview(headerRow)
        headerLine.wantsLayer = true
        headerLine.translatesAutoresizingMaskIntoConstraints = false
        addSubview(headerLine)

        // --- Fleet scroll ---
        stack.orientation = .vertical
        stack.spacing = 2
        stack.alignment = .leading
        stack.edgeInsets = NSEdgeInsets(top: 2, left: 0, bottom: 12, right: 0)
        stack.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.scrollerStyle = .overlay
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = stack
        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(fleetDidScroll),
                                               name: NSView.boundsDidChangeNotification,
                                               object: scroll.contentView)
        addSubview(scroll)

        // --- Integration banner (status / time groupings only) ---
        integrationBanner.orientation = .vertical
        integrationBanner.spacing = 3
        integrationBanner.alignment = .leading
        integrationBanner.translatesAutoresizingMaskIntoConstraints = false
        addSubview(integrationBanner)

        // --- Bottom shortcut strip ---
        hintBar.onShowAllShortcuts = { [weak self] in self?.onShowAllShortcuts?() }
        addSubview(hintBar)

        NSLayoutConstraint.activate([
            headerRow.topAnchor.constraint(equalTo: topAnchor, constant: 13),
            headerRow.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 15),
            headerRow.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -15),

            headerLine.topAnchor.constraint(equalTo: headerRow.bottomAnchor, constant: 11),
            headerLine.leadingAnchor.constraint(equalTo: leadingAnchor),
            headerLine.trailingAnchor.constraint(equalTo: trailingAnchor),
            headerLine.heightAnchor.constraint(equalToConstant: 1),

            integrationBanner.topAnchor.constraint(equalTo: headerLine.bottomAnchor, constant: 10),
            integrationBanner.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 15),
            integrationBanner.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -15),

            scroll.topAnchor.constraint(equalTo: integrationBanner.bottomAnchor, constant: 4),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: hintBar.topAnchor),

            hintBar.leadingAnchor.constraint(equalTo: leadingAnchor),
            hintBar.trailingAnchor.constraint(equalTo: trailingAnchor),
            hintBar.bottomAnchor.constraint(equalTo: bottomAnchor),

            stack.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
        ])
        // Collapsed by default; height is the only thing that moves, so showing
        // and hiding it never reflows the rest of the column.
        integrationBannerHeight = integrationBanner.heightAnchor.constraint(equalToConstant: 0)
        integrationBannerHeight.isActive = true
    }

    /// Rebuilds the banner from the panes that are integration checkouts.
    ///
    /// Called on every update, including the ones that take the incremental
    /// path, because the line changes far more often than the fleet's structure
    /// does — that is the whole reason it lives outside `stack`.
    private func refreshIntegrationBanner(_ panes: [WorktreeRowInfo]) {
        let checkouts = integrationEnabled && (groupingMode == .status || groupingMode == .activityTime)
            ? panes.filter { isIntegrationWorktree($0.worktreePath) }
            : []

        // Compare the rendered text, not the paths: the line changes far more
        // often than the set of checkouts does, and rebuilding labels on every
        // poll would churn views for nothing.
        let lines = checkouts.map { checkout in
            "⑃  " + (integrationStatus(checkout.worktreePath) ?? "integration · not built yet")
        }
        guard lines != integrationBannerLines else { return }
        integrationBannerLines = lines

        integrationBanner.arrangedSubviews.forEach { $0.removeFromSuperview() }
        guard !lines.isEmpty else {
            integrationBannerHeight.constant = 0
            return
        }

        for line in lines {
            let label = NSTextField(labelWithString: line)
            label.font = AppFont.mono(size: 11)
            label.textColor = Self.inkDim
            label.lineBreakMode = .byTruncatingTail
            integrationBanner.addArrangedSubview(label)
        }
        integrationBannerHeight.constant = CGFloat(lines.count) * 15 + CGFloat(max(0, lines.count - 1)) * 3
    }

    /// Header: add a whole repo via the folder picker.
    ///
    /// Deliberately *not* a bare "+" — the per-project group headers already use
    /// that for "add one worktree inside this project", and two identical glyphs on
    /// one screen made the two scopes indistinguishable. `folder.badge.plus` says
    /// "pick a folder", which is literally what this opens, and matches the
    /// empty-state add-project button.
    private func configureAddRepoButton() {
        addRepoButton.isBordered = false
        if let image = NSImage(systemSymbolName: "folder.badge.plus", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .medium)) {
            addRepoButton.image = image
            addRepoButton.title = ""
            addRepoButton.imagePosition = .imageOnly
        } else {
            addRepoButton.title = "+"
            addRepoButton.font = AppFont.mono(size: 13)
        }
        addRepoButton.contentTintColor = Self.inkDim
        addRepoButton.refusesFirstResponder = true
        addRepoButton.toolTip = "Add project"
        addRepoButton.setAccessibilityLabel("Add project")
        addRepoButton.setAccessibilityIdentifier("dashboard.addRepoButton")
        addRepoButton.target = self
        addRepoButton.action = #selector(addRepoClicked)
    }

    @objc private func addRepoClicked() { onAddRepo?() }

    private func configureGroupingMenu() {
        groupingButton.isBordered = false
        let groupingImage = NSImage(systemSymbolName: "rectangle.3.group", accessibilityDescription: nil)
        groupingButton.image = groupingImage?.withSymbolConfiguration(.init(pointSize: 13, weight: .medium))
        groupingButton.contentTintColor = Self.inkDim
        if groupingButton.image == nil {
            groupingButton.title = "☷"
            groupingButton.font = AppFont.mono(size: 13)
        } else {
            groupingButton.title = ""
            groupingButton.imagePosition = .imageOnly
        }
        groupingButton.refusesFirstResponder = true
        groupingButton.target = self
        groupingButton.action = #selector(showGroupingMenu(_:))

        let entries: [(WorktreeGroupingMode, String)] = [
            (.repository, "Group by Project"),
            (.status, "Group by Status"),
            (.activityTime, "Group by Time"),
            (.pane, "Expand All Panes"),
        ]
        for (mode, title) in entries {
            let item = NSMenuItem(title: title, action: #selector(selectGroupingMode(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = mode.rawValue
            groupingMenu.addItem(item)
        }
        refreshGroupingMenuPresentation()
    }

    @objc private func showGroupingMenu(_ sender: NSButton) {
        groupingMenu.popUp(positioning: nil,
                           at: NSPoint(x: 0, y: sender.bounds.maxY + 4),
                           in: sender)
    }

    @objc private func selectGroupingMode(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? String,
              let mode = WorktreeGroupingMode(rawValue: rawValue) else { return }
        applyGroupingMode(mode)
    }

    private func applyGroupingMode(_ mode: WorktreeGroupingMode) {
        groupingMode = mode
        groupingPreference.save(mode)
        refreshGroupingMenuPresentation()
        render(latestPanes, revealSelection: true)
        onGroupingChanged?()
    }

    private func refreshGroupingMenuPresentation() {
        for item in groupingMenu.items {
            item.state = (item.representedObject as? String) == groupingMode.rawValue ? .on : .off
        }
        let description: String
        switch groupingMode {
        case .repository: description = "Group worktrees by project"
        case .status: description = "Group worktrees by status"
        case .activityTime: description = "Group worktrees by time"
        case .pane: description = "Expand worktrees into panes"
        }
        groupingButton.toolTip = description
        groupingButton.setAccessibilityLabel(description)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshChromeColors()
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    // MARK: - Hover

    @objc private func fleetDidScroll() { refreshHoverForPointer() }

    /// A row reported a tracking-area edge. Enters win outright; an exit only
    /// counts for the row the list still believes is lit, so a stale exit
    /// arriving after the pointer already moved on can't blank the new row.
    private func rowHoverChanged(_ row: FleetHoverRow, entered: Bool) {
        if entered {
            setHoveredRow(row)
        } else if hoveredRow === row {
            setHoveredRow(nil)
        }
    }

    private func setHoveredRow(_ row: FleetHoverRow?) {
        guard hoveredRow !== row else { return }
        hoveredRow?.setHovered(false)
        hoveredRow = row
        row?.setHovered(true)
    }

    /// Re-resolve the hovered row from where the pointer actually is.
    ///
    /// Scrolling moves rows under a still cursor, which AppKit reports as a run
    /// of enters with no exits — so the fleet asks the pointer instead of
    /// trusting the events every time the content offset changes.
    private func refreshHoverForPointer() {
        guard let window, window.isKeyWindow else { setHoveredRow(nil); return }
        let point = scroll.contentView.convert(window.mouseLocationOutsideOfEventStream, from: nil)
        guard scroll.contentView.bounds.contains(point) else { setHoveredRow(nil); return }
        var hit = stack.hitTest(point)
        while let view = hit, !(view is FleetHoverRow) { hit = view.superview }
        setHoveredRow(hit as? FleetHoverRow)
    }

    /// Layer `CGColor`s don't auto-track dynamic `NSColor`s — re-resolve on appearance flips.
    private func refreshChromeColors() {
        layer?.backgroundColor = NSColor.clear.cgColor
        headerLine.layer?.backgroundColor = resolvedCGColor(Self.line)
        headerTitle.textColor = Self.ink
        headerSub.textColor = Self.inkFaint
    }

    /// Worktrees in display (grouped) order — the sequence keyboard nav walks.
    private(set) var orderedRows: [(id: String, path: String)] = []
    /// Indices into `orderedRows` where each rendered group starts — the boundaries
    /// `{` / `}` jump between. Pane rows never enter `orderedRows`, so cruising
    /// stays at worktree level in `.pane` mode too.

    /// Holds the row rebuild while an anchored form (the "+" create popover) is
    /// open, so the list doesn't churn under it on every 2s status poll. Data
    /// still lands; it just paints when the form goes away.
    var isRenderPaused = false {
        didSet {
            guard oldValue, !isRenderPaused else { return }
            render(latestPanes, revealSelection: false)
        }
    }

    func update(_ panes: [WorktreeRowInfo]) {
        latestPanes = panes
        guard !isRenderPaused else { return }
        render(panes, revealSelection: false)
    }

    private func render(_ panes: [WorktreeRowInfo], revealSelection: Bool) {
        let running = panes.filter { $0.rolledUpStatus == .running }.count
        // Tight enough to survive the 300pt docked column next to two buttons:
        // total count, then only the running slice.
        headerSub.stringValue = running > 0 ? "\(panes.count) · \(running) running" : "\(panes.count)"

        let panesByPath = Dictionary(panes.map { ($0.worktreePath, $0) }, uniquingKeysWith: { first, _ in first })
        let groupingItems = panes.map {
            $0.groupingItem(
                creationDate: Self.creationDate($0.worktreePath),
                isIntegration: integrationEnabled && isIntegrationWorktree($0.worktreePath)
            )
        }
        let groups = WorktreeGrouping.groups(groupingItems, mode: groupingMode, now: now())

        // A mode switch is an explicit navigation action. If its previous
        // identity is stale, land on the first row in the new ordering before
        // constructing rows so the resolved selection is highlighted and can be
        // revealed. Ordinary data refreshes intentionally preserve stale/empty
        // selection without moving the user's focus.
        if revealSelection, !selectedId.isEmpty,
           !groups.contains(where: { group in group.items.contains(where: { $0.id == selectedId }) }) {
            selectedId = groups.first?.items.first?.id ?? ""
        }

        refreshIntegrationBanner(panes)

        let structureSignature = Self.structureSignature(for: groups, panesByPath: panesByPath, groupingMode: groupingMode)
        if !revealSelection, structureSignature == lastStructureSignature {
            #if DEBUG
            let start = DispatchTime.now().uptimeNanoseconds
            #endif
            applyIncrementalUpdates(groups: groups, panesByPath: panesByPath)
            #if DEBUG
            recordTelemetry(kind: "incremental",
                            elapsedMs: elapsedMilliseconds(since: start),
                            rowCount: orderedRows.count)
            #endif
            return
        }

        #if DEBUG
        let start = DispatchTime.now().uptimeNanoseconds
        #endif
        fullRenderCount += 1
        lastStructureSignature = structureSignature
        setHoveredRow(nil)
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        orderedRows = []
        rowViewsByID = [:]
        paneRowViewsByStationID = [:]
        renderedGroupTitles = []
        addWorktreeProjects = []
        integrateProjects = []
        closeProjectProjects = []
        revealedRowID = nil

        for (groupIndex, group) in groups.enumerated() {
            renderedGroupTitles.append(group.title)
            let header = makeGroupHeader(group: group, topGap: groupIndex == 0 ? 0 : 13)
            stack.addArrangedSubview(header)
            pin(header)
            let rowsBox = NSStackView()
            rowsBox.orientation = .vertical
            rowsBox.spacing = 4
            rowsBox.alignment = .leading
            rowsBox.translatesAutoresizingMaskIntoConstraints = false
            for groupedItem in group.items {
                guard let pane = panesByPath[groupedItem.path] else { continue }
                let row = RowView(pane: pane,
                                  status: groupedItem.status,
                                  selected: groupedItem.id == selectedId,
                                  showsRepository: groupingMode != .repository,
                                  isIntegration: groupedItem.isIntegration)
                row.onTap = { [weak self] path in self?.onSelectWorktree?(path) }
                row.onDelete = { [weak self] path in self?.onDeleteWorktree?(path) }
                row.onResetIntegration = { [weak self] path in self?.onResetIntegration?(path) }
                row.onHoverChanged = { [weak self] row, entered in
                    self?.rowHoverChanged(row, entered: entered)
                }
                rowsBox.addArrangedSubview(row)
                row.widthAnchor.constraint(equalTo: rowsBox.widthAnchor).isActive = true
                orderedRows.append((groupedItem.id, groupedItem.path))
                rowViewsByID[groupedItem.id] = row

                // Fully-expanded third level: one clickable row per pane. A
                // single-pane worktree is already represented by its own row, so
                // expanding it would just duplicate — only expand 2+ panes.
                if groupingMode == .pane, pane.panes.count > 1 {
                    // `paneInfo`, not `pane`: the enclosing `pane` is the
                    // worktree row that owns these, and shadowing it here loses
                    // the worktree path the child row needs.
                    for paneInfo in pane.panes {
                        let paneRow = PaneRowView(pane: paneInfo, worktreePath: pane.worktreePath)
                        paneRow.onTap = { [weak self] worktreePath, stationId in
                            self?.onSelectPane?(worktreePath, stationId)
                        }
                        paneRow.onHoverChanged = { [weak self] row, entered in
                            self?.rowHoverChanged(row, entered: entered)
                        }
                        rowsBox.addArrangedSubview(paneRow)
                        paneRow.widthAnchor.constraint(equalTo: rowsBox.widthAnchor).isActive = true
                        paneRowViewsByStationID[paneInfo.stationId] = paneRow
                    }
                }
            }
            stack.addArrangedSubview(rowsBox)
            pin(rowsBox)
        }

        if revealSelection, let selectedRow = rowViewsByID[selectedId] {
            layoutSubtreeIfNeeded()
            selectedRow.scrollToVisible(selectedRow.bounds)
            revealedRowID = selectedId
        }
        #if DEBUG
        recordTelemetry(kind: "full",
                        elapsedMs: elapsedMilliseconds(since: start),
                        rowCount: orderedRows.count)
        #endif
    }

    private static func structureSignature(
        for groups: [WorktreeGroup],
        panesByPath: [String: WorktreeRowInfo],
        groupingMode: WorktreeGroupingMode
    ) -> String {
        groups.map { group in
            let rows = group.items.map { item in
                let paneIDs: [String]
                if groupingMode == .pane, let pane = panesByPath[item.path], pane.panes.count > 1 {
                    paneIDs = pane.panes.map(\.stationId)
                } else {
                    paneIDs = []
                }
                return "\(item.id){\(paneIDs.joined(separator: ","))}"
            }
            return "\(String(describing: group.id))|\(group.title)|\(rows.joined(separator: ";"))"
        }.joined(separator: "||")
    }

    private func applyIncrementalUpdates(
        groups: [WorktreeGroup],
        panesByPath: [String: WorktreeRowInfo]
    ) {
        orderedRows = groups.flatMap { group in group.items.map { ($0.id, $0.path) } }
        renderedGroupTitles = groups.map(\.title)

        for group in groups {
            for item in group.items {
                guard let pane = panesByPath[item.path] else { continue }
                if let row = rowViewsByID[item.id] {
                    row.update(pane: pane, status: item.status, selected: item.id == selectedId,
                               isIntegration: item.isIntegration)
                }
                if groupingMode == .pane, pane.panes.count > 1 {
                    for paneInfo in pane.panes {
                        paneRowViewsByStationID[paneInfo.stationId]?
                            .update(pane: paneInfo, worktreePath: pane.worktreePath)
                    }
                }
            }
        }
    }

    #if DEBUG
    private func elapsedMilliseconds(since start: UInt64) -> Double {
        Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000.0
    }

    private func recordTelemetry(kind: String, elapsedMs: Double, rowCount: Int) {
        if kind == "full" {
            fullRenderTotalDurationMs += elapsedMs
        } else {
            incrementalUpdateCount += 1
            incrementalTotalDurationMs += elapsedMs
        }
        let now = Date()
        guard now.timeIntervalSince(lastTelemetryLogAt) >= 30 else { return }
        lastTelemetryLogAt = now
        let fullAvg = fullRenderCount > 0 ? fullRenderTotalDurationMs / Double(fullRenderCount) : 0
        let incrementalAvg = incrementalUpdateCount > 0 ? incrementalTotalDurationMs / Double(incrementalUpdateCount) : 0
        NSLog("[DashboardOverview] rows=%d full_count=%d full_avg_ms=%.2f incremental_count=%d incremental_avg_ms=%.2f last=%@ %.2fms",
              rowCount, fullRenderCount, fullAvg, incrementalUpdateCount, incrementalAvg, kind, elapsedMs)
    }
    #endif

    /// Move the highlight to `id` in place, cross-fading between the two rows and
    /// scrolling the new one into view.
    ///
    /// The `⌃⇥` path deliberately avoids `update(_:)`: a full re-render tears down
    /// every row view and builds new ones, which cannot animate and reads as the
    /// whole list flickering. Returns false when `id` has no row on screen (the
    /// list hasn't rendered, or the target is filtered out) so the caller can fall
    /// back to a plain re-render.
    @discardableResult
    func moveSelection(to id: String, animated: Bool) -> Bool {
        guard let target = rowViewsByID[id] else { return false }
        guard id != selectedId else { return true }
        rowViewsByID[selectedId]?.setSelected(false, animated: animated)
        target.setSelected(true, animated: animated)
        selectedId = id
        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = RowView.selectionFadeDuration
                context.allowsImplicitAnimation = true
                target.scrollToVisible(target.bounds)
            }
        } else {
            target.scrollToVisible(target.bounds)
        }
        revealedRowID = id
        return true
    }

    /// Worktree directory creation date, cached — the sort key inside a repo
    /// group. Missing/unreadable paths sort first (distantPast).
    private static var creationDateCache: [String: Date] = [:]
    /// Also used to build grouping items for remote clients (TabCoordinator).
    static func creationDate(_ path: String) -> Date {
        if let cached = creationDateCache[path] { return cached }
        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        let date = attrs?[.creationDate] as? Date ?? .distantPast
        creationDateCache[path] = date
        return date
    }

    /// Selected worktree id, so the fleet can mark the current row (accent border).
    var selectedId: String = ""

    // Focused AppKit contract exposed to unit tests without leaking mutable UI.
    var groupingModeForTesting: WorktreeGroupingMode { groupingMode }
    var groupingMenuTitlesForTesting: [String] { groupingMenu.items.map(\.title) }
    var groupingMenuKeyEquivalentsForTesting: [String] { groupingMenu.items.map(\.keyEquivalent) }
    var checkedGroupingModesForTesting: [WorktreeGroupingMode] {
        groupingMenu.items.compactMap { item in
            guard item.state == .on, let rawValue = item.representedObject as? String else { return nil }
            return WorktreeGroupingMode(rawValue: rawValue)
        }
    }
    var renderedGroupTitlesForTesting: [String] { renderedGroupTitles }
    var fullRenderCountForTesting: Int { fullRenderCount }
    /// Project titles behind the rendered "add worktree" buttons, in group order.
    var addWorktreeProjectsForTesting: [String] {
        headerButtons(matching: Self.addWorktreeButtonIdentifier)
            .compactMap { addWorktreeProjects[safeIndex: $0.tag] }
    }
    /// Lines currently shown in the integration banner, top to bottom.
    var integrationBannerLinesForTesting: [String] {
        integrationBanner.arrangedSubviews
            .compactMap { ($0 as? NSTextField)?.stringValue }
    }
    /// Project titles behind the rendered "integrate" buttons, in group order.
    var integrateProjectsForTesting: [String] {
        headerButtons(matching: Self.integrateButtonIdentifier)
            .compactMap { integrateProjects[safeIndex: $0.tag] }
    }
    /// Project titles whose group headers offer "Close Project…".
    var closeableProjectsForTesting: [String] {
        stack.arrangedSubviews
            .compactMap { ($0 as? GroupHeaderView)?.projectNameForTesting }
    }
    /// Project titles behind the rendered "close project" buttons, in group order.
    var closeProjectButtonsForTesting: [String] {
        headerButtons(matching: Self.closeProjectButtonIdentifier)
            .compactMap { closeProjectProjects[safeIndex: $0.tag] }
    }
    func simulateCloseProjectForTesting(_ project: String) {
        onCloseProject?(project)
    }

    private func headerButtons(matching identifier: NSUserInterfaceItemIdentifier) -> [NSButton] {
        stack.arrangedSubviews
            .compactMap { ($0 as? GroupHeaderView)?.contentRowForTesting }
            .flatMap { $0.arrangedSubviews }
            .compactMap { $0 as? NSButton }
            .filter { $0.identifier == identifier }
    }
    var renderedSelectedRowIDForTesting: String? { rowViewsByID[selectedId] == nil ? nil : selectedId }
    /// Ids of every row currently painting the hover tint — more than one means
    /// the scroll-leaves-a-trail bug is back.
    var hoveredRowIDsForTesting: [String] {
        rowViewsByID.filter { $0.value.isHoveredForTesting }.keys.sorted()
    }
    func simulateRowHoverForTesting(id: String, entered: Bool) {
        guard let row = rowViewsByID[id] else { return }
        rowHoverChanged(row, entered: entered)
    }
    var revealedRowIDForTesting: String? { revealedRowID }
    func rowRuntimeTextForTesting(id: String) -> String? { rowViewsByID[id]?.runtimeTextForTesting }
    func rowTitleTextForTesting(id: String) -> String? { rowViewsByID[id]?.titleTextForTesting }
    func rowTitleFrameForTesting(id: String) -> NSRect? { rowViewsByID[id]?.titleFrameForTesting }
    var groupingButtonToolTipForTesting: String? { groupingButton.toolTip }
    var groupingButtonAccessibilityLabelForTesting: String? { groupingButton.accessibilityLabel() }
    var groupingButtonRefusesFirstResponderForTesting: Bool { groupingButton.refusesFirstResponder }
    func selectGroupingModeForTesting(_ mode: WorktreeGroupingMode) { applyGroupingMode(mode) }

    private func pin(_ v: NSView) {
        v.translatesAutoresizingMaskIntoConstraints = false
        v.leadingAnchor.constraint(equalTo: stack.leadingAnchor, constant: 15).isActive = true
        v.trailingAnchor.constraint(equalTo: stack.trailingAnchor, constant: -15).isActive = true
    }

    private func makeGroupHeader(group: WorktreeGroup, topGap: CGFloat) -> NSView {
        var views: [NSView] = []
        if let status = group.status {
            if status == .running {
                views.append(SpinnerDotView(color: status.color))
            } else {
                let glyph = NSTextField(labelWithString: status.glyph)
                glyph.font = AppFont.mono(size: 8)
                glyph.textColor = status.color
                views.append(glyph)
            }

            let title = NSTextField(labelWithString: status.groupLabel)
            title.font = AppFont.mono(size: 11)
            title.textColor = status.color
            title.lineBreakMode = .byTruncatingTail
            views.append(title)

            let count = NSTextField(labelWithString: "\(group.items.count)")
            count.font = AppFont.mono(size: 11)
            count.textColor = Self.inkFaint
            views.append(count)
        } else {
            let title = NSTextField(labelWithString: group.title)
            title.font = AppFont.mono(size: 11, weight: .semibold)
            title.textColor = Self.inkDim
            title.lineBreakMode = .byTruncatingTail
            views.append(title)
        }

        // Project groups (Group by Project / Expand All Panes) carry a trailing
        // "+" that opens the helm prefilled with `/worktree @<project>`.
        var trailingButtons: [NSButton] = []
        if case .repository = group.id {
            let spacer = NSView()
            spacer.setContentHuggingPriority(.defaultLow - 1, for: .horizontal)
            views.append(spacer)
            // Only worth offering once there is more than one worktree to fold
            // together — on a single-worktree project it would integrate a repo
            // with itself.
            if integrationEnabled, group.items.count > 1 {
                views.append(makeIntegrateButton(project: group.title))
            }
            trailingButtons.append(makeAddWorktreeButton(project: group.title))
            trailingButtons.append(makeCloseProjectButton(project: group.title))
            views.append(contentsOf: trailingButtons)
        }

        let row = NSStackView(views: views)
        row.orientation = .horizontal
        row.spacing = 7
        row.alignment = .centerY
        row.edgeInsets = NSEdgeInsets(top: topGap, left: 0, bottom: 7, right: 0)
        for button in trailingButtons {
            button.setContentHuggingPriority(.required, for: .horizontal)
            button.setContentCompressionResistancePriority(.required, for: .horizontal)
        }

        let projectName: String?
        if case .repository = group.id {
            projectName = group.title
        } else {
            projectName = nil
        }
        let header = GroupHeaderView(contentRow: row, projectName: projectName)
        header.onCloseProject = { [weak self] project in self?.onCloseProject?(project) }
        return header
    }

    /// Project group header — carries a context menu to close/untrack the repo.
    private final class GroupHeaderView: NSView {
        var onCloseProject: ((String) -> Void)?
        private let projectName: String?
        private let contentRow: NSStackView

        init(contentRow: NSStackView, projectName: String?) {
            self.contentRow = contentRow
            self.projectName = projectName
            super.init(frame: .zero)
            addSubview(contentRow)
            contentRow.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                contentRow.leadingAnchor.constraint(equalTo: leadingAnchor),
                contentRow.trailingAnchor.constraint(equalTo: trailingAnchor),
                contentRow.topAnchor.constraint(equalTo: topAnchor),
                contentRow.bottomAnchor.constraint(equalTo: bottomAnchor),
            ])
            if let projectName {
                setAccessibilityIdentifier("dashboard.projectHeader.\(projectName)")
            }
        }
        required init?(coder: NSCoder) { fatalError() }

        var projectNameForTesting: String? { projectName }
        var contentRowForTesting: NSStackView { contentRow }

        override func menu(for event: NSEvent) -> NSMenu? {
            guard let projectName else { return nil }
            let menu = NSMenu()
            let item = NSMenuItem(title: "Close Project…", action: #selector(closeProjectAction), keyEquivalent: "")
            item.target = self
            menu.addItem(item)
            return menu
        }

        @objc private func closeProjectAction() {
            guard let projectName else { return }
            onCloseProject?(projectName)
        }
    }

    /// Trailing "integrate" affordance on a project group header. Equivalent to
    /// `/integrate` with that repo selected, and the only place the feature
    /// announces itself — otherwise it is a command you have to already know.
    private func makeIntegrateButton(project: String) -> NSButton {
        let button = NSButton()
        button.isBordered = false
        button.bezelStyle = .inline
        button.refusesFirstResponder = true
        if let image = NSImage(systemSymbolName: "arrow.trianglehead.merge", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .medium))
            ?? NSImage(systemSymbolName: "arrow.triangle.merge", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .medium)) {
            button.image = image
            button.title = ""
            button.imagePosition = .imageOnly
        } else {
            button.title = "⑃"
            button.font = AppFont.mono(size: 12)
        }
        button.contentTintColor = Self.inkFaint
        let description = "Integrate \(project)"
        button.toolTip = description
        button.setAccessibilityLabel(description)
        button.identifier = Self.integrateButtonIdentifier
        button.target = self
        button.action = #selector(integrateClicked(_:))
        button.tag = integrateProjects.count
        integrateProjects.append(project)
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
        return button
    }

    @objc private func integrateClicked(_ sender: NSButton) {
        guard let project = integrateProjects[safeIndex: sender.tag] else { return }
        onIntegrate?(project)
    }

    /// Trailing "add worktree" affordance on a project group header. Equivalent
    /// to typing `/worktree @<project>` in the helm.
    private func makeAddWorktreeButton(project: String) -> NSButton {
        let button = NSButton()
        button.isBordered = false
        button.bezelStyle = .inline
        button.refusesFirstResponder = true
        if let image = NSImage(systemSymbolName: "plus", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .medium)) {
            button.image = image
            button.title = ""
            button.imagePosition = .imageOnly
        } else {
            button.title = "+"
            button.font = AppFont.mono(size: 12)
        }
        button.contentTintColor = Self.inkFaint
        let description = "Add worktree to \(project)"
        button.toolTip = description
        button.setAccessibilityLabel(description)
        button.identifier = Self.addWorktreeButtonIdentifier
        button.target = self
        button.action = #selector(addWorktreeClicked(_:))
        button.tag = addWorktreeProjects.count
        addWorktreeProjects.append(project)
        return button
    }

    @objc private func addWorktreeClicked(_ sender: NSButton) {
        guard let project = addWorktreeProjects[safeIndex: sender.tag] else { return }
        // Anchor to this long-lived view, not the button: the fleet re-renders on
        // every status poll, and a popover whose anchor view leaves the hierarchy
        // closes itself — which read as "the form collapses while I type".
        onAddWorktree?(project, sender.convert(sender.bounds, to: self), self)
    }

    /// Trailing "close project" affordance on a project group header. Equivalent
    /// to `/return @<project>` — untracks the repo and tears down its sessions.
    private func makeCloseProjectButton(project: String) -> NSButton {
        let button = NSButton()
        button.isBordered = false
        button.bezelStyle = .inline
        button.refusesFirstResponder = true
        if let image = NSImage(systemSymbolName: "xmark", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .medium)) {
            button.image = image
            button.title = ""
            button.imagePosition = .imageOnly
        } else {
            button.title = "×"
            button.font = AppFont.mono(size: 12)
        }
        button.contentTintColor = Self.inkFaint
        let description = "Close project \(project)"
        button.toolTip = description
        button.setAccessibilityLabel(description)
        button.identifier = Self.closeProjectButtonIdentifier
        button.target = self
        button.action = #selector(closeProjectClicked(_:))
        button.tag = closeProjectProjects.count
        closeProjectProjects.append(project)
        return button
    }

    @objc private func closeProjectClicked(_ sender: NSButton) {
        guard let project = closeProjectProjects[safeIndex: sender.tag] else { return }
        onCloseProject?(project)
    }

    // MARK: - Fleet row

    /// Two-line navigator item under a repo group:
    /// ```
    /// ●  current pane title                         time
    ///    branch  git info                           N panes
    /// ```
    /// Title and branch share a text column so their leading edges align.
    private final class RowView: NSView, FleetHoverRow {
        var onTap: ((String) -> Void)?
        /// Pointer entered (`true`) or left (`false`) this row. The list, not the
        /// row, decides what that means — see `FleetHoverRow`.
        var onHoverChanged: ((FleetHoverRow, Bool) -> Void)?
        var onDelete: ((String) -> Void)?
        var onResetIntegration: ((String) -> Void)?
        /// Refreshed by `update` rather than fixed at init: a row is keyed by its
        /// station id, and a worktree transfer (`handleNewBranch`) re-registers the
        /// same stations under a new path. A reused row that kept its original
        /// `path` would open, reveal, and *delete* the worktree it used to be.
        private var path: String
        private var isMainWorktree: Bool
        /// The repo's integration checkout, which gets a Reset in its menu.
        private var isIntegration: Bool
        private var selected: Bool
        private let showsRepository: Bool
        private let staticDot: NSTextField
        private let runningDot: SpinnerDotView
        private let titleLabel: NSTextField
        private let timeLabel: NSTextField
        private let branchLabel: NSTextField
        private let gitLabel: NSTextField
        private let paneCountLabel: NSTextField
        private let repositoryLabel: NSTextField?
        /// Whether the pointer is currently inside, so a selection change can
        /// repaint without losing the hover tint on the row being left behind.
        private var hovered = false

        private static let cornerRadius: CGFloat = 8
        /// One beat, matched to the fleet list's other selection feedback.
        static let selectionFadeDuration: CFTimeInterval = 0.18
        private static let highlightFill = NSColor(name: nil) { appearance in
            appearance.isDark
                ? NSColor.white.withAlphaComponent(0.10)
                : NSColor.black.withAlphaComponent(0.08)
        }
        private static let hoverFill = NSColor(name: nil) { appearance in
            appearance.isDark
                ? NSColor.white.withAlphaComponent(0.05)
                : NSColor.black.withAlphaComponent(0.04)
        }

        private static func label(_ s: String, _ color: NSColor, _ size: CGFloat,
                                  weight: NSFont.Weight = .regular) -> NSTextField {
            let l = NSTextField(labelWithString: s)
            l.font = AppFont.mono(size: size, weight: weight)
            l.textColor = color
            l.lineBreakMode = .byTruncatingTail
            // Every label in this row is one line by design. Without the cap, a
            // title carrying newlines wraps and the row grows to fit it.
            l.maximumNumberOfLines = 1
            return l
        }
        private static func spacer() -> NSView {
            let v = NSView()
            v.translatesAutoresizingMaskIntoConstraints = false
            v.setContentHuggingPriority(.defaultLow, for: .horizontal)
            v.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            return v
        }

        init(pane: WorktreeRowInfo, status: AgentStatus, selected: Bool,
             showsRepository: Bool, isIntegration: Bool = false) {
            self.path = pane.worktreePath
            self.isMainWorktree = pane.isMainWorktree
            self.isIntegration = isIntegration
            self.selected = selected
            self.showsRepository = showsRepository
            self.staticDot = Self.label(status.glyph, status.color, 8)
            // The spinner is only ever visible while the row is `.running`, and it
            // now outlives the status it was built under (rows are reused across
            // incremental updates), so pin it to `.running`'s colour rather than
            // whatever status happened to be current at construction time.
            self.runningDot = SpinnerDotView(color: AgentStatus.running.color)
            self.titleLabel = Self.label(pane.currentPaneTitle, DashboardOverviewView.ink, 12)
            self.timeLabel = Self.label(pane.currentPaneRunTime, DashboardOverviewView.inkFaint, 10)
            let branch = pane.thread.isEmpty ? pane.name : pane.thread
            self.branchLabel = Self.label(branch, DashboardOverviewView.inkDim, 11)
            self.gitLabel = NSTextField(labelWithString: "")
            self.paneCountLabel = Self.label(pane.paneCount > 0 ? "\(pane.paneCount) panes" : "—",
                                             DashboardOverviewView.inkFaint, 10)
            if showsRepository {
                let repo = Self.label(pane.project.isEmpty ? "Unknown project" : pane.project,
                                      ProjectColor.color(for: pane.project), 10, weight: .semibold)
                self.repositoryLabel = repo
            } else {
                self.repositoryLabel = nil
            }
            super.init(frame: .zero)
            wantsLayer = true
            layer?.cornerRadius = Self.cornerRadius
            layer?.masksToBounds = true
            setAccessibilityElement(true)
            setAccessibilityIdentifier("chrome.worktreeRow.\(pane.id)")
            setAccessibilityLabel(pane.name)
            applyBackground(hovered: false)
            // Both dots are plain `addSubview` children (not stack-arranged), so
            // the label-backed one has to opt out of autoresizing constraints by
            // hand — `SpinnerDotView` already does it in its own init.
            staticDot.translatesAutoresizingMaskIntoConstraints = false
            staticDot.setContentHuggingPriority(.required, for: .horizontal)
            staticDot.setContentCompressionResistancePriority(.required, for: .horizontal)
            runningDot.setContentHuggingPriority(.required, for: .horizontal)
            runningDot.setContentCompressionResistancePriority(.required, for: .horizontal)
            titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            timeLabel.setContentHuggingPriority(.required, for: .horizontal)

            // Line 1: current pane title                         time
            let line1 = NSStackView()
            line1.orientation = .horizontal
            line1.alignment = .centerY
            line1.spacing = 7
            line1.translatesAutoresizingMaskIntoConstraints = false
            line1.addArrangedSubview(titleLabel)
            line1.addArrangedSubview(Self.spacer())
            line1.addArrangedSubview(timeLabel)

            // Line 2: branch  git info                              N panes
            branchLabel.setContentHuggingPriority(.defaultHigh, for: .horizontal)
            branchLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

            gitLabel.attributedStringValue = Self.gitInfoAttributed(pane.gitStats)
            gitLabel.translatesAutoresizingMaskIntoConstraints = false
            gitLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
            gitLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            paneCountLabel.setContentHuggingPriority(.required, for: .horizontal)

            let line2 = NSStackView()
            line2.orientation = .horizontal
            line2.alignment = .firstBaseline
            line2.spacing = 8
            line2.translatesAutoresizingMaskIntoConstraints = false
            if let repository = repositoryLabel {
                repository.setContentHuggingPriority(.defaultHigh, for: .horizontal)
                repository.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
                line2.addArrangedSubview(repository)
            }
            line2.addArrangedSubview(branchLabel)
            line2.addArrangedSubview(gitLabel)
            line2.addArrangedSubview(Self.spacer())
            line2.addArrangedSubview(paneCountLabel)

            let textCol = NSStackView(views: [line1, line2])
            textCol.orientation = .vertical
            textCol.spacing = 3
            textCol.alignment = .leading
            textCol.translatesAutoresizingMaskIntoConstraints = false

            addSubview(staticDot)
            addSubview(runningDot)
            addSubview(textCol)
            NSLayoutConstraint.activate([
                textCol.leadingAnchor.constraint(equalTo: staticDot.trailingAnchor, constant: 7),
                textCol.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
                textCol.topAnchor.constraint(equalTo: topAnchor, constant: 8),
                textCol.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),

                staticDot.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
                staticDot.centerYAnchor.constraint(equalTo: line1.centerYAnchor),
                runningDot.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
                runningDot.centerYAnchor.constraint(equalTo: line1.centerYAnchor),

                line1.widthAnchor.constraint(equalTo: textCol.widthAnchor),
                line2.widthAnchor.constraint(equalTo: textCol.widthAnchor),
            ])
            applyContent(pane: pane, status: status)
        }
        required init?(coder: NSCoder) { fatalError() }

        /// Compact git summary "+adds −dels  ↑ahead↓behind", colored. Empty when
        /// there are no changes and no divergence (or stats not yet resolved).
        static func gitInfoAttributed(_ stats: WorktreeGitStats?) -> NSAttributedString {
            guard let stats, !stats.isEmpty else { return NSAttributedString() }
            let font = AppFont.mono(size: 10)
            let result = NSMutableAttributedString()
            func append(_ s: String, _ color: NSColor) {
                result.append(NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: color]))
            }
            if stats.added > 0 { append("+\(stats.added)", DashboardOverviewView.emerald) }
            if stats.removed > 0 {
                if result.length > 0 { append(" ", DashboardOverviewView.inkFaint) }
                append("\u{2212}\(stats.removed)", DashboardOverviewView.red)
            }
            if stats.hasAheadBehind {
                if result.length > 0 { append("  ", DashboardOverviewView.inkFaint) }
                var ab = ""
                if let ahead = stats.ahead, ahead > 0 { ab += "\u{2191}\(ahead)" }
                if let behind = stats.behind, behind > 0 { ab += "\u{2193}\(behind)" }
                append(ab, DashboardOverviewView.inkFaint)
            }
            return result
        }

        func update(pane: WorktreeRowInfo, status: AgentStatus, selected: Bool, isIntegration: Bool = false) {
            path = pane.worktreePath
            isMainWorktree = pane.isMainWorktree
            self.isIntegration = isIntegration
            setSelected(selected, animated: false)
            setAccessibilityLabel(pane.name)
            applyContent(pane: pane, status: status)
        }

        var runtimeTextForTesting: String { timeLabel.stringValue }
        var titleTextForTesting: String { titleLabel.stringValue }
        var titleFrameForTesting: NSRect { titleLabel.frame }

        private func applyContent(pane: WorktreeRowInfo, status: AgentStatus) {
            let nextTitle = pane.currentPaneTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            if !nextTitle.isEmpty {
                titleLabel.stringValue = nextTitle
            } else if titleLabel.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                titleLabel.stringValue = PaneTitleResolver.shortenPath(pane.worktreePath)
            }

            // Unlike the title, a duration must be allowed to disappear: it falls
            // back to the activity age once the pane stops, and that is "" when
            // unknown. Holding the last value there would leave a dead pane
            // reading "12s" next to an idle dot. Only a *running* row keeps its
            // last known figure, so a live counter never blanks mid-flight.
            let nextRuntime = pane.currentPaneRunTime.trimmingCharacters(in: .whitespacesAndNewlines)
            if !nextRuntime.isEmpty || status != .running {
                timeLabel.stringValue = nextRuntime
            }

            let nextBranch = (pane.thread.isEmpty ? pane.name : pane.thread)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !nextBranch.isEmpty {
                branchLabel.stringValue = nextBranch
            }
            gitLabel.attributedStringValue = Self.gitInfoAttributed(pane.gitStats)
            paneCountLabel.stringValue = pane.paneCount > 0 ? "\(pane.paneCount) panes" : "—"
            if let repositoryLabel, showsRepository {
                let project = pane.project.isEmpty ? "Unknown project" : pane.project
                repositoryLabel.stringValue = project
                repositoryLabel.textColor = ProjectColor.color(for: project)
            }
            staticDot.stringValue = status.glyph
            staticDot.textColor = status.color
            staticDot.isHidden = status == .running
            runningDot.isHidden = status != .running
        }

        override func mouseDown(with event: NSEvent) { onTap?(path) }

        // MARK: - Context menu

        override func menu(for event: NSEvent) -> NSMenu? {
            let menu = NSMenu()
            for (title, action) in [
                ("Open in Editor", #selector(openInEditorAction)),
                ("Reveal in Finder", #selector(revealInFinderAction)),
                ("Copy Path", #selector(copyPathAction)),
            ] {
                let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
                item.target = self
                menu.addItem(item)
            }
            menu.addItem(.separator())
            if isIntegration {
                let resetItem = NSMenuItem(title: "Reset to origin/main",
                                           action: #selector(resetIntegrationAction), keyEquivalent: "")
                resetItem.target = self
                resetItem.toolTip = "Fetch origin and move the integration checkout onto trunk."
                    + " Asks first if edits or commits made here would be lost."
                menu.addItem(resetItem)
            }
            // One Delete, and it takes the branch with it. Whether to ask is
            // decided from what would be lost, not by a second menu item —
            // see `TerminalCoordinator.confirmAndDeleteWorktree`.
            let deleteItem = NSMenuItem(title: "Delete", action: #selector(deleteAction), keyEquivalent: "")
            deleteItem.target = self
            deleteItem.toolTip = "Remove the worktree and its branch."
                + " Asks first if uncommitted changes or unmerged commits would be lost."
            menu.addItem(deleteItem)
            if isMainWorktree {
                deleteItem.isEnabled = false
                deleteItem.toolTip = "Main worktree cannot be deleted."
            }
            return menu
        }

        @objc private func openInEditorAction() {
            if !WorktreeShellActions.openInEditor(path) {
                let alert = NSAlert()
                alert.messageText = "No supported editor found"
                alert.informativeText = "Install VS Code, Cursor, Zed, or Xcode to use Open in Editor."
                alert.runModal()
            }
        }

        @objc private func revealInFinderAction() { WorktreeShellActions.revealInFinder(path) }

        @objc private func copyPathAction() { WorktreeShellActions.copyPath(path) }

        @objc private func deleteAction() { onDelete?(path) }

        @objc private func resetIntegrationAction() { onResetIntegration?(path) }

        private var tracking: NSTrackingArea?
        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let tracking { removeTrackingArea(tracking) }
            let t = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
            addTrackingArea(t); tracking = t
        }
        override func mouseEntered(with event: NSEvent) { onHoverChanged?(self, true) }
        override func mouseExited(with event: NSEvent) { onHoverChanged?(self, false) }

        func setHovered(_ hovered: Bool) {
            guard self.hovered != hovered else { return }
            applyBackground(hovered: hovered)
        }

        /// Move the selection highlight on or off this row.
        ///
        /// `⌃⇥` cycles worktrees one row at a time, and repainting instantly made the
        /// highlight teleport — with the fleet list re-rendered underneath it, the
        /// jump read as the list blinking rather than as a move. Cross-fading the
        /// two rows' fills over one short beat is what makes it read as the
        /// highlight travelling to the next / previous worktree.
        func setSelected(_ isSelected: Bool, animated: Bool) {
            guard selected != isSelected else { return }
            selected = isSelected
            guard animated else { applyBackground(hovered: hovered); return }
            let fade = CABasicAnimation(keyPath: "backgroundColor")
            fade.fromValue = layer?.backgroundColor
            fade.duration = Self.selectionFadeDuration
            fade.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            applyBackground(hovered: hovered)
            layer?.add(fade, forKey: "selectionFade")
        }

        private func applyBackground(hovered: Bool) {
            self.hovered = hovered
            if selected {
                layer?.backgroundColor = resolvedCGColor(Self.highlightFill)
            } else if hovered {
                layer?.backgroundColor = resolvedCGColor(Self.hoverFill)
            } else {
                layer?.backgroundColor = NSColor.clear.cgColor
            }
        }

        override func viewDidChangeEffectiveAppearance() {
            super.viewDidChangeEffectiveAppearance()
            applyBackground(hovered: hovered)
        }

        var isHoveredForTesting: Bool { hovered }
    }

    // MARK: - Pane row (Group by Pane)

    /// Third-level row under a worktree in the expanded "Group by Pane" mode:
    /// an indented, clickable pane. `● pane title`, dimmed unless focused.
    private final class PaneRowView: NSView, FleetHoverRow {
        var onTap: ((String, String) -> Void)?
        /// See `RowView.onHoverChanged`.
        var onHoverChanged: ((FleetHoverRow, Bool) -> Void)?
        private let stationId: String
        /// Carried on the view, not captured in `onTap`: rows outlive a single
        /// render now, and a transferred worktree keeps its station ids.
        private var worktreePath: String
        private let dotLabel: NSTextField
        private let titleLabel: NSTextField
        private var hovered = false

        private static let cornerRadius: CGFloat = 6
        private static let hoverFill = NSColor(name: nil) { appearance in
            appearance.isDark
                ? NSColor.white.withAlphaComponent(0.05)
                : NSColor.black.withAlphaComponent(0.04)
        }

        init(pane: PaneDisplayInfo, worktreePath: String) {
            self.stationId = pane.stationId
            self.worktreePath = worktreePath
            self.dotLabel = NSTextField(labelWithString: "\u{25CF}")
            self.titleLabel = NSTextField(labelWithString: pane.title)
            super.init(frame: .zero)
            wantsLayer = true
            layer?.cornerRadius = Self.cornerRadius
            layer?.masksToBounds = true
            setAccessibilityElement(true)
            setAccessibilityIdentifier("chrome.paneRow.\(pane.stationId)")
            setAccessibilityLabel(pane.title)

            dotLabel.font = AppFont.mono(size: 7)
            dotLabel.translatesAutoresizingMaskIntoConstraints = false
            dotLabel.setContentHuggingPriority(.required, for: .horizontal)
            dotLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

            titleLabel.font = AppFont.mono(size: 11)
            titleLabel.lineBreakMode = .byTruncatingTail
            titleLabel.translatesAutoresizingMaskIntoConstraints = false
            titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

            addSubview(dotLabel)
            addSubview(titleLabel)
            NSLayoutConstraint.activate([
                // Indent under the worktree row's status dot + text column.
                dotLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 27),
                dotLabel.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
                titleLabel.leadingAnchor.constraint(equalTo: dotLabel.trailingAnchor, constant: 7),
                titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
                titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 4),
                titleLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
            ])
            update(pane: pane, worktreePath: worktreePath)
        }
        required init?(coder: NSCoder) { fatalError() }

        override func mouseDown(with event: NSEvent) { onTap?(worktreePath, stationId) }

        func update(pane: PaneDisplayInfo, worktreePath: String) {
            self.worktreePath = worktreePath
            setAccessibilityLabel(pane.title)
            dotLabel.textColor = pane.status.color
            titleLabel.stringValue = pane.title
            titleLabel.textColor = pane.isFocused ? DashboardOverviewView.inkDim : DashboardOverviewView.inkFaint
        }

        private var tracking: NSTrackingArea?
        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let tracking { removeTrackingArea(tracking) }
            let t = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
            addTrackingArea(t); tracking = t
        }
        override func mouseEntered(with event: NSEvent) { onHoverChanged?(self, true) }
        override func mouseExited(with event: NSEvent) { onHoverChanged?(self, false) }

        func setHovered(_ hovered: Bool) {
            guard self.hovered != hovered else { return }
            self.hovered = hovered
            layer?.backgroundColor = hovered ? resolvedCGColor(Self.hoverFill) : NSColor.clear.cgColor
        }

        var isHoveredForTesting: Bool { hovered }
    }

}
