import AppKit

// MARK: - PR 列表视图

/// 展示 GitHub PR 列表的 NSTableView。被 CenterOverlayView 包裹或嵌入 SidePanel 使用。
///
/// 用法:
/// ```
/// let list = PRListView(service: service)
/// list.onSelectPR = { pr in /* 打开详情或 diff */ }
/// dashboard.showCenterOverlay(list, title: "Open Pull Requests")
/// ```
final class PRListView: NSView {
    private let scrollView = NSScrollView()
    private let tableView = NSTableView()
    private let headerLabel = NSTextField(labelWithString: "")
    private let loadingSpinner = NSProgressIndicator()
    private let emptyLabel = NSTextField(labelWithString: "")

    private let service: GitHubPRService
    private var prs: [GitHubPR] = []
    private var isLoading = false
    private var currentPage = 1
    private var hasMore = true
    private var loadTask: Task<Void, Never>?

    /// PR 被选中时的回调。
    var onSelectPR: ((GitHubPR) -> Void)?

    init(service: GitHubPRService) {
        self.service = service
        super.init(frame: .zero)
        setup()
        loadPRs()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    deinit {
        loadTask?.cancel()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            window?.makeFirstResponder(tableView)
        }
    }

    // MARK: - Setup

    private func setup() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        setAccessibilityIdentifier("prReview.list")

        headerLabel.font = NSFont.systemFont(ofSize: 14, weight: .semibold)
        headerLabel.textColor = Theme.textPrimary
        headerLabel.stringValue = "Open Pull Requests"
        headerLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(headerLabel)

        emptyLabel.font = NSFont.systemFont(ofSize: 12)
        emptyLabel.textColor = Theme.textSecondary
        emptyLabel.alignment = .center
        emptyLabel.stringValue = "No pull requests found"
        emptyLabel.isHidden = true
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(emptyLabel)

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("pr"))
        column.title = "Pull Requests"
        column.resizingMask = .autoresizingMask

        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.backgroundColor = .clear
        tableView.rowHeight = 52
        tableView.intercellSpacing = NSSize(width: 0, height: 1)
        tableView.selectionHighlightStyle = .regular
        tableView.delegate = self
        tableView.dataSource = self
        tableView.setAccessibilityIdentifier("prReview.list.table")
        tableView.target = self
        tableView.doubleAction = #selector(doubleClickRow)

        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = tableView
        addSubview(scrollView)

        loadingSpinner.style = .spinning
        loadingSpinner.controlSize = .small
        loadingSpinner.translatesAutoresizingMaskIntoConstraints = false
        loadingSpinner.isDisplayedWhenStopped = false
        addSubview(loadingSpinner)

        NSLayoutConstraint.activate([
            headerLabel.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            headerLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            headerLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -16),

            scrollView.topAnchor.constraint(equalTo: headerLabel.bottomAnchor, constant: 8),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),

            loadingSpinner.centerXAnchor.constraint(equalTo: centerXAnchor),
            loadingSpinner.centerYAnchor.constraint(equalTo: centerYAnchor),

            emptyLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    // MARK: - Data

    private func loadPRs(reset: Bool = true) {
        loadTask?.cancel()
        isLoading = true

        if reset {
            currentPage = 1
            hasMore = true
            loadingSpinner.startAnimation(nil)
            emptyLabel.isHidden = true
        }

        var params = GitHubPRListParams()
        params.page = currentPage

        loadTask = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await self.service.listPRs(params: params)
                try Task.checkCancellation()
                await MainActor.run {
                    if reset {
                        self.prs = result
                    } else {
                        self.prs.append(contentsOf: result)
                    }
                    self.hasMore = result.count == params.perPage
                    self.headerLabel.stringValue = "Pull Requests (\(self.prs.count))"
                    self.emptyLabel.isHidden = !self.prs.isEmpty
                    self.tableView.reloadData()
                    self.loadingSpinner.stopAnimation(nil)
                    self.isLoading = false
                }
            } catch is CancellationError {
                await MainActor.run {
                    self.loadingSpinner.stopAnimation(nil)
                    self.isLoading = false
                }
            } catch {
                await MainActor.run {
                    self.headerLabel.stringValue = "Failed to load PRs"
                    self.emptyLabel.stringValue = error.localizedDescription
                    self.emptyLabel.isHidden = false
                    self.loadingSpinner.stopAnimation(nil)
                    self.isLoading = false
                }
            }
        }
    }

    /// 加载下一页（由 scroll 到底部触发，暂未接入）。
    func loadNextPage() {
        guard hasMore, !isLoading else { return }
        currentPage += 1
        loadPRs(reset: false)
    }

    @objc private func doubleClickRow() {
        let row = tableView.clickedRow
        guard row >= 0, row < prs.count else { return }
        onSelectPR?(prs[row])
    }
}

// MARK: - NSTableViewDataSource

extension PRListView: NSTableViewDataSource {
    func numberOfRows(in tableView: NSTableView) -> Int {
        prs.count
    }
}

// MARK: - NSTableViewDelegate

extension PRListView: NSTableViewDelegate {
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < prs.count else { return nil }
        let pr = prs[row]

        let identifier = NSUserInterfaceItemIdentifier("PRCellView")
        let cell = tableView.makeView(withIdentifier: identifier, owner: nil)
            as? PRTableCellView ?? PRTableCellView()
        cell.identifier = identifier
        cell.configure(with: pr)
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let row = tableView.selectedRow
        guard row >= 0, row < prs.count else { return }
        onSelectPR?(prs[row])
    }
}

// MARK: - PR Table Cell

final class PRTableCellView: NSTableCellView {
    private let titleField = NSTextField(labelWithString: "")
    private let metaField = NSTextField(labelWithString: "")
    private let statusBadge = NSView()
    private let statusLabel = NSTextField(labelWithString: "")
    private let draftLabel = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    private func setup() {
        titleField.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        titleField.textColor = Theme.textPrimary
        titleField.lineBreakMode = .byTruncatingTail
        // Explicit: a row whose title drifts to the right edge reads as broken,
        // and `.natural` leaves that to the text's own direction.
        titleField.alignment = .left
        titleField.translatesAutoresizingMaskIntoConstraints = false
        // The title is the row. Letting it compress freely is what allowed the
        // badge to take the whole width — the solver had a cheaper way to
        // satisfy the constraints than keeping the title readable.
        titleField.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        titleField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        addSubview(titleField)

        metaField.font = NSFont.systemFont(ofSize: 11)
        metaField.textColor = Theme.textSecondary
        metaField.lineBreakMode = .byTruncatingMiddle
        metaField.alignment = .left
        metaField.translatesAutoresizingMaskIntoConstraints = false
        addSubview(metaField)

        statusBadge.wantsLayer = true
        statusBadge.layer?.cornerRadius = 4
        statusBadge.translatesAutoresizingMaskIntoConstraints = false
        addSubview(statusBadge)

        statusLabel.font = NSFont.systemFont(ofSize: 10, weight: .bold)
        statusLabel.textColor = .white
        statusLabel.alignment = .center
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        // The badge is sized by its label, so the label has to insist on its
        // own width in both directions. Without this it is happy to stretch,
        // and a badge pinned to it stretches with it.
        statusLabel.setContentHuggingPriority(.required, for: .horizontal)
        statusLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        statusBadge.addSubview(statusLabel)

        draftLabel.font = NSFont.systemFont(ofSize: 10, weight: .bold)
        draftLabel.textColor = Theme.textSecondary
        draftLabel.alignment = .center
        draftLabel.wantsLayer = true
        draftLabel.layer?.cornerRadius = 3
        draftLabel.layer?.borderWidth = 1
        draftLabel.layer?.borderColor = Theme.textSecondary.cgColor
        draftLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(draftLabel)

        NSLayoutConstraint.activate([
            statusBadge.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            statusBadge.centerYAnchor.constraint(equalTo: centerYAnchor),
            // Fixed, not a range. The badge holds one letter, so a range buys
            // nothing and costs a degree of freedom: with `>= 20` and the label
            // pinned to both edges, the solver is *allowed* to widen the badge
            // and take the width from the title. I could not reproduce that
            // outcome in a table, so this is not a diagnosed fix — it removes
            // the freedom that would permit it.
            statusBadge.widthAnchor.constraint(equalToConstant: 22),
            statusBadge.heightAnchor.constraint(equalToConstant: 18),

            statusLabel.centerXAnchor.constraint(equalTo: statusBadge.centerXAnchor),
            statusLabel.centerYAnchor.constraint(equalTo: statusBadge.centerYAnchor),

            titleField.leadingAnchor.constraint(equalTo: statusBadge.trailingAnchor, constant: 10),
            titleField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            titleField.topAnchor.constraint(equalTo: topAnchor, constant: 6),

            metaField.leadingAnchor.constraint(equalTo: titleField.leadingAnchor),
            metaField.topAnchor.constraint(equalTo: titleField.bottomAnchor, constant: 2),

            draftLabel.leadingAnchor.constraint(equalTo: metaField.trailingAnchor, constant: 8),
            draftLabel.centerYAnchor.constraint(equalTo: metaField.centerYAnchor),
            draftLabel.heightAnchor.constraint(equalToConstant: 16),
            // Bound the meta row too, or the author name grows past the cell
            // instead of truncating.
            draftLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -12),
        ])

        draftLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        draftLabel.setContentHuggingPriority(.required, for: .horizontal)
        // Hugs its text: the author sits next to the title, not stretched across
        // the row with the Draft pill shoved to the far edge.
        metaField.setContentHuggingPriority(.defaultHigh, for: .horizontal)
    }

    /// Resolved frames, for the layout regression: the badge is one letter and
    /// must never take width from the title.
    var badgeFrameForTesting: NSRect { statusBadge.frame }
    var titleFrameForTesting: NSRect { titleField.frame }
    var titleTextForTesting: String { titleField.stringValue }
    var metaTextForTesting: String { metaField.stringValue }

    func configure(with pr: GitHubPR) {
        titleField.stringValue = "#\(pr.number) \(pr.title)"
        // Line counts come from the single-PR endpoint; the list has none, so
        // the row shows the author alone rather than a made-up +0 -0.
        if let additions = pr.additions, let deletions = pr.deletions {
            metaField.stringValue = "\(pr.user.login) · +\(additions) -\(deletions)"
        } else {
            metaField.stringValue = pr.user.login
        }

        let (badgeColor, badgeText): (NSColor, String)
        if pr.mergedAt != nil {
            badgeColor = NSColor(red: 0.35, green: 0.27, blue: 0.67, alpha: 1.0)
            badgeText = "M"
        } else if pr.state == "closed" {
            badgeColor = NSColor.systemRed
            badgeText = "C"
        } else {
            badgeColor = NSColor.systemGreen
            badgeText = "O"
        }
        statusBadge.layer?.backgroundColor = badgeColor.cgColor
        statusLabel.stringValue = badgeText

        draftLabel.isHidden = !pr.draft
        if pr.draft {
            draftLabel.stringValue = " Draft "
        }
    }
}
