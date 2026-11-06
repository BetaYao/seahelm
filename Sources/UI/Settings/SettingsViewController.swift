import AppKit

protocol SettingsDelegate: AnyObject {
    func settingsDidUpdateConfig(_ settings: SettingsViewController, config: Config)

    /// Live panes, so a rule's target is picked from a project → worktree →
    /// pane cascade of what actually exists rather than typed from memory.
    func settingsPaneTargets(_ settings: SettingsViewController) -> [PaneSnapshot]

    /// Sessions the running app has panes attached to — flagged in the monitor so
    /// a kill that would take out a live agent is at least an informed one.
    func settingsActiveSessionNames(_ settings: SettingsViewController) -> Set<String>

    /// Show First Mate in the main window.
    func settingsOpenFirstMate(_ settings: SettingsViewController)
}

/// Optional halves of the protocol: only the main window can answer them, and
/// tests conform with just the config callback.
extension SettingsDelegate {
    func settingsActiveSessionNames(_ settings: SettingsViewController) -> Set<String> { [] }
    func settingsPaneTargets(_ settings: SettingsViewController) -> [PaneSnapshot] { [] }
    func settingsOpenFirstMate(_ settings: SettingsViewController) {}
}

/// Settings, as a sidebar of pages built from `SettingsChrome` groups.
///
/// Pages are built on first visit and cached: the session monitor shells out to
/// `seahelmd list` and the gateway pages open a socket, and neither should happen
/// just because someone opened Settings to change a path.
class SettingsViewController: NSViewController {
    weak var settingsDelegate: SettingsDelegate?

    var config: Config
    /// Settings ▸ First Mate's controls (SettingsViewController+FirstMate).
    let fm = FirstMateSettingsControls()

    // Sidebar / page host
    private let sidebar = SettingsSidebarView(items: [
        .init(id: "general", title: "General", symbol: "gearshape",
              keywords: ["projects", "paths", "repo", "scrollback", "cache", "terminal",
                         "copy", "select", "clipboard", "ghostty"]),
        .init(id: "agents", title: "Agents", symbol: "bolt.horizontal",
              keywords: ["detection", "rules", "status", "claude", "codex", "json"]),
        .init(id: "firstMate", title: "First Mate", symbol: "steeringwheel",
              keywords: ["autopilot", "rules", "automation", "ci", "approval", "autonomy",
                         "standing orders", "yml"]),
        .init(id: "telegram", title: "Telegram", symbol: "paperplane",
              keywords: ["bot", "botfather", "token", "phone", "chat", "remote",
                         "bridge", "rules", "trigger"]),
        .init(id: "pairing", title: "Pairing", symbol: "qrcode",
              keywords: ["qr", "remote", "browser", "gateway", "pair",
                         "port", "tunnel", "wss", "cloudflare", "web"]),
        .init(id: "sessions", title: "Sessions", symbol: "rectangle.stack",
              keywords: ["session", "seahelmd", "cleanup", "kill", "detached", "orphan"]),
    ])
    private let contentScroll = NSScrollView()
    var pages: [String: NSView] = [:]
    private lazy var sessionMonitor = SessionMonitorView()
    private let memoryWarnField = SettingsTextField()
    private let memoryStopField = SettingsTextField()
    private let memoryKillField = SettingsTextField()

    // General tab controls
    private let pathListView = NSTableView()
    private let pathScrollView = NSScrollView()
    private var workspacePaths: [String] = []
    private let addButton = NSButton()
    private let removeButton = NSButton()
    private let cacheSizeField = SettingsTextField()
    private lazy var copyOnSelectToggle = SettingsControls.toggle(
        on: GhosttyConfigImporter.copyOnSelectEnabled(),
        target: self, action: #selector(copyOnSelectChanged))
    private lazy var integrationEnabledToggle = SettingsControls.toggle(
        on: config.integrationEnabled, target: self, action: #selector(integrationControlChanged))
    private lazy var autoIntegrateToggle = SettingsControls.toggle(
        on: config.autoIntegrate, target: self, action: #selector(controlChanged))
    private lazy var revealGhosttyConfButton = SettingsControls.button(
        "Reveal ghostty.conf", target: self, action: #selector(revealGhosttyConfClicked))

    // Agent Detection tab controls
    private let ruleTextView = NSTextView()
    private let ruleScrollView = NSScrollView()

    /// Settings ▸ Telegram and ▸ Pairing: seahelm-gateway's, over gateway.sock.
    let gateway = GatewaySettingsPages()

    init(config: Config) {
        self.config = config
        self.workspacePaths = config.workspacePaths
        super.init(nibName: nil, bundle: nil)
        gateway.host = self
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not supported")
    }

    override func loadView() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 820, height: 600))
        container.wantsLayer = true
        container.layer?.backgroundColor = SettingsPalette.windowBg.cgColor
        container.setAccessibilityIdentifier("settings.sheet")
        container.setAccessibilityElement(true)
        container.setAccessibilityRole(.group)
        self.view = container

        sidebar.onSelect = { [weak self] id in self?.showPage(id) }
        container.addSubview(sidebar)

        contentScroll.hasVerticalScroller = true
        contentScroll.drawsBackground = false
        contentScroll.automaticallyAdjustsContentInsets = false
        contentScroll.contentInsets = NSEdgeInsetsZero
        contentScroll.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(contentScroll)

        NSLayoutConstraint.activate([
            sidebar.topAnchor.constraint(equalTo: container.topAnchor),
            sidebar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            sidebar.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            sidebar.widthAnchor.constraint(equalToConstant: SettingsChrome.sidebarWidth),

            contentScroll.topAnchor.constraint(equalTo: container.topAnchor),
            contentScroll.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            contentScroll.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            contentScroll.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        sidebar.select("general")
    }

    // MARK: - Page host

    func selectPage(_ id: String) { sidebar.select(id) }

    private func showPage(_ id: String) {
        let page: NSView
        if let cached = pages[id] {
            page = cached
        } else {
            page = buildPage(id)
            pages[id] = page
        }

        contentScroll.documentView = page
        NSLayoutConstraint.activate([
            page.leadingAnchor.constraint(equalTo: contentScroll.contentView.leadingAnchor),
            page.trailingAnchor.constraint(equalTo: contentScroll.contentView.trailingAnchor),
            page.topAnchor.constraint(equalTo: contentScroll.contentView.topAnchor),
        ])

        // Revisiting shows what seahelmd reports *now*, not what it reported when the
        // page was first built.
        if id == "sessions" {
            sessionMonitor.activeSessionNames = settingsDelegate?.settingsActiveSessionNames(self) ?? []
            sessionMonitor.reload()
        }
        // Same reason: the gateway may have died, or bound, since the page was built.
        if id == "pairing" { gateway.pairingPageShown() }
    }

    private func buildPage(_ id: String) -> NSView {
        switch id {
        case "agents":   return makePage(buildAgentGroups())
        case "telegram": return makePage(gateway.buildTelegramGroups())
        case "pairing":  return makePage(gateway.buildPairingGroups())
        case "sessions": return makePage(buildSessionGroups())
        case "firstMate": return makePage(buildFirstMateGroups())
        default:         return makePage(buildGeneralGroups())
        }
    }

    /// Stack groups top-down in a flipped container, so a short page starts at
    /// the top of the scroll view instead of the bottom.
    private func makePage(_ groups: [NSView]) -> NSView {
        let page = FlippedView()
        page.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: groups)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = SettingsChrome.groupSpacing
        stack.translatesAutoresizingMaskIntoConstraints = false
        page.addSubview(stack)

        var constraints = [
            stack.topAnchor.constraint(equalTo: page.topAnchor, constant: 20),
            stack.leadingAnchor.constraint(equalTo: page.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: page.trailingAnchor, constant: -20),
            stack.bottomAnchor.constraint(equalTo: page.bottomAnchor, constant: -20),
        ]
        for group in groups {
            constraints.append(group.widthAnchor.constraint(equalTo: stack.widthAnchor))
        }
        NSLayoutConstraint.activate(constraints)
        return page
    }

    // MARK: - General

    private func buildGeneralGroups() -> [NSView] {
        pathScrollView.hasVerticalScroller = true
        pathScrollView.borderType = .noBorder
        pathScrollView.drawsBackground = false
        pathScrollView.translatesAutoresizingMaskIntoConstraints = false

        pathListView.headerView = nil
        pathListView.backgroundColor = .clear
        pathListView.rowHeight = 22
        pathListView.delegate = self
        pathListView.dataSource = self
        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("path"))
        col.resizingMask = .autoresizingMask
        pathListView.addTableColumn(col)
        pathListView.setAccessibilityIdentifier("settings.workspacePaths")
        pathScrollView.documentView = pathListView

        addButton.title = "+"
        addButton.bezelStyle = .rounded
        addButton.target = self
        addButton.action = #selector(addPathClicked)
        addButton.setAccessibilityIdentifier("settings.addPath")

        removeButton.title = "−"
        removeButton.bezelStyle = .rounded
        removeButton.target = self
        removeButton.action = #selector(removePathClicked)
        removeButton.setAccessibilityIdentifier("settings.removePath")

        cacheSizeField.stringValue = "\(config.terminalRowCacheSize)"
        cacheSizeField.target = self
        cacheSizeField.action = #selector(controlChanged)

        return [
            SettingsGroupView(title: "Projects", rows: [
                SettingsRow.stacked(nil,
                                    subtitle: "Repositories seahelm watches. Each becomes a project; its git worktrees are listed under it.",
                                    content: SettingsControls.surface(pathScrollView), height: 140),
                SettingsRow.actions([addButton, removeButton]),
            ]),
            makeIntegrationGroup(),
            SettingsGroupView(title: "Terminal", rows: [
                SettingsRow.make("Scrollback rows cached",
                                 subtitle: "How much of each pane's viewport the status poll re-reads every cycle.",
                                 control: cacheSizeField),
                SettingsRow.make("Copy on select",
                                 subtitle: "Copy selected text to the clipboard as soon as you drag-select in a pane.",
                                 control: copyOnSelectToggle),
                SettingsRow.make("Ghostty config",
                                 subtitle: "Seahelm's overlay at ~/.config/seahelm/ghostty.conf. Overrides the bundled defaults.",
                                 control: revealGhosttyConfButton),
            ]),
        ]
    }

    private func makeIntegrationGroup() -> NSView {
        // Built here rather than inline so the dependent toggle's enabled state
        // is set once, at construction, and not left to the first click.
        refreshIntegrationEnabledState()
        return SettingsGroupView(title: "Integration", rows: [
            SettingsRow.make("Integration worktree",
                             subtitle: "A throwaway checkout per project holding every worktree folded onto trunk, to run integration tests in. Off hides it everywhere; a checkout already on disk is left alone.",
                             control: integrationEnabledToggle),
            SettingsRow.make("Keep it current",
                             subtitle: "Rebuild it as agents finish turns. Only ever touches a project that already has a checkout — running /integrate once is what creates one.",
                             control: autoIntegrateToggle),
        ])
    }

    // MARK: - Agents

    private func buildAgentGroups() -> [NSView] {
        ruleScrollView.hasVerticalScroller = true
        ruleScrollView.borderType = .noBorder
        ruleScrollView.drawsBackground = false
        ruleScrollView.translatesAutoresizingMaskIntoConstraints = false

        ruleTextView.isEditable = true
        ruleTextView.isSelectable = true
        ruleTextView.font = AppFont.mono(size: 11, weight: .regular)
        ruleTextView.textContainerInset = NSSize(width: 6, height: 6)
        ruleTextView.isAutomaticQuoteSubstitutionEnabled = false
        ruleTextView.isAutomaticDashSubstitutionEnabled = false
        ruleTextView.isAutomaticTextReplacementEnabled = false
        ruleTextView.drawsBackground = false
        ruleTextView.textColor = SettingsPalette.text
        ruleTextView.delegate = self
        ruleScrollView.documentView = ruleTextView

        // Populate with current agent config as pretty JSON
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(config.agentDetect),
           let json = String(data: data, encoding: .utf8) {
            ruleTextView.string = json
        }

        return [
            SettingsGroupView(title: "Detection rules", rows: [
                SettingsRow.stacked(nil,
                                    subtitle: "Text patterns that classify a pane. This is the last tier of the ladder — process exit and OSC 133 shell phase both win over it.",
                                    content: SettingsControls.surface(ruleScrollView), height: 320),
            ]),
        ]
    }

    // MARK: - Sessions

    private func buildSessionGroups() -> [NSView] {
        sessionMonitor.activeSessionNames = settingsDelegate?.settingsActiveSessionNames(self) ?? []
        sessionMonitor.memoryGuard = config.agentMemoryGuard
        configureMemoryGuardFields()
        return [
            SettingsGroupView(title: "Memory Guard", rows: [
                SettingsRow.make("Warn at",
                                 subtitle: "Highlight and report Claude/Codex panes above this agent-process RSS. No automatic action runs yet.",
                                 control: memoryWarnField,
                                 accessibilityId: "settings.memoryGuard.warn"),
                SettingsRow.make("Stop threshold",
                                 subtitle: "Stored for the future manual/automatic stop policy. Currently display-only.",
                                 control: memoryStopField,
                                 accessibilityId: "settings.memoryGuard.stop"),
                SettingsRow.make("Kill threshold",
                                 subtitle: "Stored for the future manual/automatic session-kill policy. Currently display-only.",
                                 control: memoryKillField,
                                 accessibilityId: "settings.memoryGuard.kill"),
            ]),
            SettingsGroupView(title: "Sessions", rows: [
                SettingsRow.stacked(nil,
                                    subtitle: "Sessions outlive the app, so panes you closed can leave daemons behind. Detached rows (0 clients) are the ones nothing is watching. Killing a session ends whatever runs inside it.",
                                    content: sessionMonitor),
            ]),
        ]
    }

    private func configureMemoryGuardFields() {
        for (field, value) in [
            (memoryWarnField, config.agentMemoryGuard.warnMB),
            (memoryStopField, config.agentMemoryGuard.stopMB),
            (memoryKillField, config.agentMemoryGuard.killMB),
        ] {
            field.stringValue = Self.formatGB(value)
            field.target = self
            field.action = #selector(controlChanged)
        }
    }

    // MARK: - Actions

    @objc private func addPathClicked() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.message = "Select project directories"

        panel.beginSheetModal(for: view.window!) { [weak self] response in
            guard response == .OK, let self else { return }
            for url in panel.urls {
                let path = url.path
                if !self.workspacePaths.contains(path) {
                    self.workspacePaths.append(path)
                }
            }
            self.pathListView.reloadData()
            self.applyChanges()
        }
    }

    @objc private func removePathClicked() {
        let row = pathListView.selectedRow
        guard row >= 0, row < workspacePaths.count else { return }
        workspacePaths.remove(at: row)
        pathListView.reloadData()
        applyChanges()
    }

    /// Any control changed. There is no Save button: the window applies as you
    /// go and persists immediately, so closing it can never lose an edit — and
    /// there is nothing to cancel back to.
    @objc private func controlChanged() { applyChanges() }

    /// The master switch owns whether the finer one can be reached at all.
    @objc private func integrationControlChanged() {
        refreshIntegrationEnabledState()
        applyChanges()
    }

    private func refreshIntegrationEnabledState() {
        autoIntegrateToggle.isEnabled = integrationEnabledToggle.state == .on
    }

    @objc private func copyOnSelectChanged() {
        let enabled = copyOnSelectToggle.state == .on
        guard GhosttyConfigImporter.setCopyOnSelect(enabled) else { return }
        GhosttyBridge.shared.reloadUserConfig()
    }

    @objc private func revealGhosttyConfClicked() {
        let url = GhosttyConfigImporter.ensureOverlayConf()
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func applyChanges() {
        applyFirstMateGlobal()
        // Update config from UI
        config.workspacePaths = workspacePaths
        config.integrationEnabled = integrationEnabledToggle.state == .on
        config.autoIntegrate = autoIntegrateToggle.state == .on
        config.terminalRowCacheSize = Int(cacheSizeField.stringValue) ?? 200
        config.agentMemoryGuard = AgentMemoryGuardConfig(
            warnMB: Self.parseGBField(memoryWarnField, fallbackMB: config.agentMemoryGuard.warnMB),
            stopMB: Self.parseGBField(memoryStopField, fallbackMB: config.agentMemoryGuard.stopMB),
            killMB: Self.parseGBField(memoryKillField, fallbackMB: config.agentMemoryGuard.killMB)
        )
        sessionMonitor.memoryGuard = config.agentMemoryGuard

        // Parse agent detection JSON
        let jsonString = ruleTextView.string
        if let data = jsonString.data(using: .utf8),
           let agentConfig = try? JSONDecoder().decode(AgentDetectConfig.self, from: data) {
            config.agentDetect = agentConfig
        }

        // Flush immediately: closing the window right after an edit must not
        // lose it to a debounced write.
        config.saveNow()
        settingsDelegate?.settingsDidUpdateConfig(self, config: config)
    }


    private static func parseGBField(_ field: NSTextField, fallbackMB: Int) -> Int {
        let raw = field.stringValue
            .replacingOccurrences(of: "GB", with: "", options: [.caseInsensitive])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let gb = Double(raw), gb >= 0 else { return fallbackMB }
        return Int((gb * 1024).rounded())
    }

    private static func formatGB(_ mb: Int) -> String {
        let gb = Double(mb) / 1024
        return gb.rounded() == gb ? String(format: "%.0f GB", gb) : String(format: "%.1f GB", gb)
    }

    /// Called by the window controller as it closes, so an edit still being typed
    /// when the window is dismissed is not lost.
    func commitPendingEdits() {
        view.window?.makeFirstResponder(nil)   // force-ends field editing
        applyChanges()
    }

    /// Replace the editable copy when Settings is reused (⌘, again). Syncs any
    /// already-built page controls so a later apply does not write stale blanks
    /// over secrets that landed after this window was first opened.
    func reload(config: Config) {
        self.config = config
        workspacePaths = config.workspacePaths
        if isViewLoaded {
            pathListView.reloadData()
        }
        if pages["telegram"] != nil || pages["pairing"] != nil {
            gateway.reload()
        }
    }
}

// MARK: - NSTextViewDelegate

extension SettingsViewController: NSTextViewDelegate {
    /// The multi-line editors (handles list, detection JSON) apply when focus
    /// leaves, not per keystroke: half-typed JSON is not a config, and
    /// re-encoding on every character would fight the caret.
    func textDidEndEditing(_ notification: Notification) {
        guard notification.object as? NSTextView === ruleTextView else { return }
        applyChanges()
    }
}

// MARK: - NSTableViewDataSource

extension SettingsViewController: NSTableViewDataSource {
    func numberOfRows(in tableView: NSTableView) -> Int {
        return workspacePaths.count
    }
}

// MARK: - NSTableViewDelegate

extension SettingsViewController: NSTableViewDelegate {
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let path = workspacePaths[row]
        let cell = NSView()

        let label = NSTextField(labelWithString: path)
        label.font = AppFont.mono(size: 11, weight: .regular)
        label.textColor = Theme.textPrimary
        label.lineBreakMode = .byTruncatingHead
        label.frame = NSRect(x: 4, y: 1, width: 500, height: 20)
        cell.addSubview(label)

        return cell
    }
}
