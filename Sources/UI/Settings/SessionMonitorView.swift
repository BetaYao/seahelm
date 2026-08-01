import AppKit

/// Live view of `zmx list`, with a way to kill sessions.
///
/// zmx daemons outlive the app, so a session can survive every UI that pointed
/// at it — closed panes, deleted worktrees, a crashed launch. The periodic
/// orphan sweep in `AppDelegate` only reaps what it can *prove* is idle and
/// deliberately fails closed, which is right for an automatic job but leaves a
/// tail of sessions nothing will ever clean up. This is the manual half.
///
/// It shows unmanaged sessions too (anything without the seahelm prefix) so the
/// list matches `zmx list` exactly — a cleanup screen that quietly omits rows is
/// worse than no screen — but it will not offer to kill them.
final class SessionMonitorView: NSView {
    private let tableView = NSTableView()
    private let scrollView = NSScrollView()
    private let summaryLabel = NSTextField(labelWithString: "")
    private let killButton = NSButton()
    private let killDetachedButton = NSButton()

    private var sessions: [ZmxSessionInfo] = []

    /// Sessions the running app is actively using; they get a marker so a kill
    /// that would yank a live pane is at least an informed one.
    var activeSessionNames: Set<String> = []
    /// Display-only thresholds for runaway agent memory. No automatic action is
    /// taken here; the table only highlights rows so the user can decide.
    var memoryGuard: AgentMemoryGuardConfig = .default {
        didSet { tableView.reloadData() }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        build()
        reload()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    // MARK: - Building

    private func build() {
        translatesAutoresizingMaskIntoConstraints = false

        tableView.headerView = NSTableHeaderView()
        tableView.rowHeight = 22
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.allowsMultipleSelection = true
        tableView.delegate = self
        tableView.dataSource = self
        tableView.setAccessibilityIdentifier("settings.sessions.table")

        for (id, title, width) in [
            ("name", "Session", CGFloat(220)),
            ("clients", "Clients", CGFloat(56)),
            ("age", "Age", CGFloat(64)),
            ("memory", "Memory", CGFloat(92)),
            ("dir", "Directory", CGFloat(260)),
        ] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            column.title = title
            column.width = width
            tableView.addTableColumn(column)
        }

        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder
        scrollView.documentView = tableView
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)

        summaryLabel.font = .systemFont(ofSize: 11)
        summaryLabel.textColor = Theme.textSecondary
        summaryLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(summaryLabel)

        let refreshButton = NSButton(title: "Refresh", target: self, action: #selector(refreshClicked))
        refreshButton.bezelStyle = .rounded
        refreshButton.font = .systemFont(ofSize: 11)
        refreshButton.setAccessibilityIdentifier("settings.sessions.refresh")

        killButton.title = "Kill Selected"
        killButton.bezelStyle = .rounded
        killButton.font = .systemFont(ofSize: 11)
        killButton.target = self
        killButton.action = #selector(killSelectedClicked)
        killButton.isEnabled = false
        killButton.setAccessibilityIdentifier("settings.sessions.kill")

        killDetachedButton.title = "Kill All Detached"
        killDetachedButton.bezelStyle = .rounded
        killDetachedButton.font = .systemFont(ofSize: 11)
        killDetachedButton.target = self
        killDetachedButton.action = #selector(killDetachedClicked)
        killDetachedButton.setAccessibilityIdentifier("settings.sessions.killDetached")

        let buttons = NSStackView(views: [refreshButton, killButton, killDetachedButton])
        buttons.spacing = 8
        buttons.translatesAutoresizingMaskIntoConstraints = false
        addSubview(buttons)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.heightAnchor.constraint(equalToConstant: 200),

            summaryLabel.topAnchor.constraint(equalTo: scrollView.bottomAnchor, constant: 8),
            summaryLabel.leadingAnchor.constraint(equalTo: leadingAnchor),

            buttons.topAnchor.constraint(equalTo: scrollView.bottomAnchor, constant: 4),
            buttons.trailingAnchor.constraint(equalTo: trailingAnchor),
            buttons.leadingAnchor.constraint(greaterThanOrEqualTo: summaryLabel.trailingAnchor,
                                             constant: 8),
            buttons.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    // MARK: - Data

    func reload() {
        guard ZmxLocator.isAvailable else {
            sessions = []
            tableView.reloadData()
            summaryLabel.stringValue = "zmx not found — no persistent sessions."
            killDetachedButton.isEnabled = false
            return
        }

        // `zmx list` talks to every daemon's control socket, so it can block for
        // a beat when one is busy. Off the main thread; the window stays live.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let output = ProcessRunner.output([ZmxLocator.executable(), "list"]) ?? ""
            let parsed = SessionManager.parseZmxSessionsWithProcessMemory(listOutput: output)
            DispatchQueue.main.async {
                guard let self else { return }
                self.sessions = parsed
                self.tableView.reloadData()
                self.updateSummary()
                self.updateButtons()
            }
        }
    }

    private func updateSummary() {
        let detached = sessions.filter { $0.isManaged && $0.isDetached }.count
        let total = sessions.count
        let processBytes = sessions.compactMap(\.processMemoryBytes).reduce(UInt64(0), +)
        let memory = processBytes > 0 ? " · \(Self.formatBytes(processBytes)) RSS" : ""
        summaryLabel.stringValue = detached == 0
            ? "\(total) session(s), all attached\(memory)."
            : "\(total) session(s) · \(detached) detached\(memory)"
        summaryLabel.textColor = detached == 0 ? Theme.textSecondary : .systemOrange
    }

    private func updateButtons() {
        let selected = selectedSessions()
        killButton.isEnabled = !selected.isEmpty && selected.allSatisfy(\.isManaged)
        killDetachedButton.isEnabled = sessions.contains { $0.isManaged && $0.isDetached }
    }

    private func selectedSessions() -> [ZmxSessionInfo] {
        tableView.selectedRowIndexes.compactMap { index in
            sessions.indices.contains(index) ? sessions[index] : nil
        }
    }

    // MARK: - Actions

    @objc private func refreshClicked() { reload() }

    @objc private func killSelectedClicked() {
        kill(selectedSessions(), reason: "Kill \(selectedSessions().count) selected session(s)?")
    }

    @objc private func killDetachedClicked() {
        let detached = sessions.filter { $0.isManaged && $0.isDetached }
        kill(detached, reason: "Kill \(detached.count) detached session(s)?")
    }

    /// Killing a session kills the agent running inside it, so this always asks
    /// — and says so louder when the app is still using one of them.
    private func kill(_ targets: [ZmxSessionInfo], reason: String) {
        let killable = targets.filter(\.isManaged)
        guard !killable.isEmpty else { return }

        let live = killable.filter { activeSessionNames.contains($0.name) }
        let alert = NSAlert()
        alert.messageText = reason
        alert.informativeText = live.isEmpty
            ? "Anything running inside them is terminated. This cannot be undone.\n\n"
                + killable.map(\.name).joined(separator: "\n")
            : "\(live.count) of these are in use by an open pane — killing them ends "
                + "whatever is running there.\n\n" + killable.map(\.name).joined(separator: "\n")
        alert.alertStyle = live.isEmpty ? .warning : .critical
        alert.addButton(withTitle: "Kill")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        for session in killable {
            SessionManager.killSession(session.name, backend: "zmx")
        }
        // killSession is async on a utility queue; give the daemons a moment to
        // go away before asking zmx who is left, or the list looks unchanged.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in self?.reload() }
    }
}

// MARK: - Table

extension SessionMonitorView: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { sessions.count }

    func tableView(_ tableView: NSTableView,
                   viewFor tableColumn: NSTableColumn?,
                   row: Int) -> NSView? {
        guard sessions.indices.contains(row), let columnId = tableColumn?.identifier.rawValue else {
            return nil
        }
        let session = sessions[row]

        let text: String
        var color = Theme.textPrimary
        switch columnId {
        case "name":
            text = session.name
            if !session.isManaged { color = Theme.textSecondary }
        case "clients":
            let count = session.clients.map(String.init) ?? "?"
            text = activeSessionNames.contains(session.name) ? "\(count) ●" : count
            if session.isDetached { color = .systemOrange }
        case "age":
            text = session.created.map(Self.age(since:)) ?? "—"
            color = Theme.textSecondary
        case "memory":
            if let agent = session.agentMemoryBytes, agent > 0,
               let total = session.processMemoryBytes, total > agent {
                text = "\(Self.formatBytes(agent)) / \(Self.formatBytes(total))"
            } else if let total = session.processMemoryBytes, total > 0 {
                text = Self.formatBytes(total)
            } else {
                text = "—"
            }
            color = memoryColor(for: session.agentMemoryBytes)
        default:
            text = session.startDir.map { ($0 as NSString).abbreviatingWithTildeInPath } ?? "—"
            color = Theme.textSecondary
        }

        let label = NSTextField(labelWithString: text)
        label.font = columnId == "name" ? AppFont.mono(size: 11, weight: .regular)
                                        : .systemFont(ofSize: 11)
        label.textColor = color
        label.lineBreakMode = .byTruncatingMiddle
        if columnId == "memory" {
            label.toolTip = Self.memoryTooltip(for: session)
        } else if columnId == "dir" {
            label.toolTip = session.processName
        }
        return label
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        updateButtons()
    }

    private static func age(since date: Date) -> String {
        let seconds = Int(Date().timeIntervalSince(date))
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3600 { return "\(seconds / 60)m" }
        if seconds < 86_400 { return "\(seconds / 3600)h" }
        return "\(seconds / 86_400)d"
    }

    private static func formatBytes(_ bytes: UInt64) -> String {
        guard bytes > 0 else { return "0 MB" }
        let mb = Double(bytes) / 1_048_576
        if mb < 1024 { return mb >= 10 ? String(format: "%.0f MB", mb) : String(format: "%.1f MB", mb) }
        return String(format: "%.1f GB", mb / 1024)
    }

    private static func memoryTooltip(for session: ZmxSessionInfo) -> String? {
        guard session.processMemoryBytes != nil || session.agentMemoryBytes != nil else { return nil }
        var parts: [String] = []
        if let agent = session.agentMemoryBytes, agent > 0 {
            parts.append("Agent subtree: \(formatBytes(agent))")
        }
        if let total = session.processMemoryBytes {
            parts.append("Session tree: \(formatBytes(total))")
        }
        if let process = session.processName, !process.isEmpty {
            parts.append(process)
        }
        return parts.isEmpty ? nil : parts.joined(separator: "\n")
    }

    private func memoryColor(for agentBytes: UInt64?) -> NSColor {
        guard let agentBytes, agentBytes > 0 else { return Theme.textSecondary }
        if memoryGuard.killBytes > 0, agentBytes >= memoryGuard.killBytes { return .systemRed }
        if memoryGuard.stopBytes > 0, agentBytes >= memoryGuard.stopBytes { return .systemOrange }
        if memoryGuard.warnBytes > 0, agentBytes >= memoryGuard.warnBytes { return .systemYellow }
        return Theme.textPrimary
    }
}
