import AppKit

protocol NotificationHistoryDelegate: AnyObject {
    func notificationHistory(_ vc: NotificationHistoryViewController, didSelectWorktreePath path: String)
}

/// Sheet showing in-app notification timeline.
class NotificationHistoryViewController: NSViewController {
    weak var historyDelegate: NotificationHistoryDelegate?

    private let tableView = NSTableView()
    private let scrollView = NSScrollView()
    private let clearButton = NSButton()
    private let emptyLabel = NSTextField(labelWithString: "No notifications")

    private var entries: [NotificationEntry] = []

    override func loadView() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 480, height: 400))
        container.wantsLayer = true
        container.setAccessibilityIdentifier("notification.history")
        container.setAccessibilityElement(true)
        container.setAccessibilityRole(.group)
        self.view = container

        // Header
        let titleLabel = NSTextField(labelWithString: "Notifications")
        titleLabel.font = NSFont.systemFont(ofSize: 16, weight: .semibold)
        titleLabel.textColor = Theme.textPrimary
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(titleLabel)

        clearButton.title = "Clear All"
        clearButton.bezelStyle = .recessed
        clearButton.isBordered = false
        clearButton.font = NSFont.systemFont(ofSize: 12)
        clearButton.contentTintColor = Theme.accent
        clearButton.target = self
        clearButton.action = #selector(clearAll)
        clearButton.setAccessibilityIdentifier("notification.clearButton")
        clearButton.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(clearButton)

        // Table
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(scrollView)

        tableView.backgroundColor = .clear
        tableView.headerView = nil
        tableView.rowHeight = 52
        tableView.intercellSpacing = NSSize(width: 0, height: 1)
        tableView.delegate = self
        tableView.dataSource = self
        tableView.doubleAction = #selector(rowDoubleClicked)
        tableView.target = self

        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("notification"))
        col.resizingMask = .autoresizingMask
        tableView.addTableColumn(col)
        scrollView.documentView = tableView

        // Empty state
        emptyLabel.font = NSFont.systemFont(ofSize: 14)
        emptyLabel.textColor = Theme.textSecondary
        emptyLabel.alignment = .center
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(emptyLabel)

        // Close button
        let closeButton = NSButton(title: "Close", target: self, action: #selector(closeClicked))
        closeButton.bezelStyle = .rounded
        closeButton.keyEquivalent = "\u{1b}"
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(closeButton)

        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: container.topAnchor, constant: 16),
            titleLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),

            clearButton.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            clearButton.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),

            scrollView.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 12),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: closeButton.topAnchor, constant: -12),

            emptyLabel.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),

            closeButton.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
            closeButton.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -12),
        ])

        reload()
    }

    func reload() {
        entries = NotificationHistory.shared.entries
        tableView.reloadData()
        emptyLabel.isHidden = !entries.isEmpty
        scrollView.isHidden = entries.isEmpty

        // Mark all as read when viewing
        NotificationHistory.shared.markAllRead()
    }

    @objc private func clearAll() {
        NotificationHistory.shared.clear()
        reload()
    }

    @objc private func rowDoubleClicked() {
        let row = tableView.clickedRow
        guard row >= 0, row < entries.count else { return }
        let entry = entries[row]
        dismiss(nil)
        historyDelegate?.notificationHistory(self, didSelectWorktreePath: entry.worktreePath)
    }

    @objc private func closeClicked() {
        dismiss(nil)
    }
}

// MARK: - NSTableViewDataSource

extension NotificationHistoryViewController: NSTableViewDataSource {
    func numberOfRows(in tableView: NSTableView) -> Int {
        entries.count
    }
}

// MARK: - NSTableViewDelegate

extension NotificationHistoryViewController: NSTableViewDelegate {
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let entry = entries[row]

        let cell = NSView()
        cell.wantsLayer = true

        // Status dot (colored by agent status)
        let dot = NSView(frame: NSRect(x: 12, y: 20, width: 10, height: 10))
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 5
        dot.layer?.backgroundColor = entry.status.color.cgColor
        cell.addSubview(dot)

        // Read indicator
        if !entry.isRead {
            dot.layer?.borderWidth = 2
            dot.layer?.borderColor = Theme.accent.cgColor
        }

        // Time
        let timeFormatter = DateFormatter()
        timeFormatter.dateFormat = "HH:mm"
        let timeStr = timeFormatter.string(from: entry.timestamp)

        let timeLabel = NSTextField(labelWithString: timeStr)
        timeLabel.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
        timeLabel.textColor = Theme.textSecondary
        timeLabel.frame = NSRect(x: 30, y: 30, width: 40, height: 14)
        cell.addSubview(timeLabel)

        // Branch + status
        let target = entry.workspaceName.isEmpty ? entry.branch : "\(entry.workspaceName) / \(entry.branch)"
        let statusText = "\(target)  \(entry.status.rawValue)"
        let branchLabel = NSTextField(labelWithString: statusText)
        branchLabel.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        branchLabel.textColor = Theme.textPrimary
        branchLabel.frame = NSRect(x: 76, y: 28, width: 380, height: 18)
        branchLabel.lineBreakMode = .byTruncatingTail
        cell.addSubview(branchLabel)

        // Message
        let messageLabel = NSTextField(labelWithString: entry.message)
        messageLabel.font = NSFont.systemFont(ofSize: 11)
        messageLabel.textColor = Theme.textSecondary
        messageLabel.frame = NSRect(x: 76, y: 8, width: 380, height: 16)
        messageLabel.lineBreakMode = .byTruncatingTail
        cell.addSubview(messageLabel)

        return cell
    }
}
