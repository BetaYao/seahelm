import AppKit

/// A row of the Issues list: a section heading or an issue.
enum IssueRow {
    case group(String)
    /// `worktreeBranch` is set when some worktree of this repo is on it.
    case issue(GitHubIssue, worktreeBranch: String?)
}

/// Whose issues the list shows.
enum IssueScope: Int, CaseIterable {
    case all, created, assigned

    var title: String {
        switch self {
        case .all: return "All"
        case .created: return "Created"
        case .assigned: return "Assigned"
        }
    }

    /// With no known viewer only `.all` can say anything.
    func includes(_ issue: GitHubIssue, viewer: String?) -> Bool {
        switch self {
        case .all: return true
        case .created: return viewer.map { issue.user.login.caseInsensitiveCompare($0) == .orderedSame } ?? false
        case .assigned:
            guard let viewer else { return false }
            return (issue.assignees ?? []).contains { $0.login.caseInsensitiveCompare(viewer) == .orderedSame }
        }
    }
}

/// Orders a repo's open issues by how close they are to the selected worktree:
/// the ones it is working on, then the ones another worktree has taken, then
/// the rest. Kept apart from the view so it can be tested.
enum IssueListSections {
    static func rows(snapshot: GitHubIssueSnapshot, currentBranch: String?,
                     otherBranches: [String], filter: String = "", scope: IssueScope = .all) -> [IssueRow] {
        let query = filter.trimmingCharacters(in: .whitespaces).lowercased()
        let issues = snapshot.issues.filter {
            scope.includes($0, viewer: snapshot.viewerLogin) && (query.isEmpty || matches($0, query))
        }

        let current = Set(currentBranch.map { snapshot.linkedIssues(branch: $0).map(\.number) } ?? [])
        var takenBy: [Int: String] = [:]
        for branch in otherBranches where branch != currentBranch {
            for issue in snapshot.linkedIssues(branch: branch) where takenBy[issue.number] == nil {
                takenBy[issue.number] = branch
            }
        }

        let mine = issues.filter { current.contains($0.number) }
        let taken = issues.filter { !current.contains($0.number) && takenBy[$0.number] != nil }
        let rest = issues.filter { !current.contains($0.number) && takenBy[$0.number] == nil }

        var rows: [IssueRow] = []
        if !mine.isEmpty {
            rows.append(.group("This worktree"))
            rows += mine.map { .issue($0, worktreeBranch: currentBranch) }
        }
        if !taken.isEmpty {
            rows.append(.group("In a worktree · \(taken.count)"))
            rows += taken.map { .issue($0, worktreeBranch: takenBy[$0.number]) }
        }
        if !rest.isEmpty {
            // Only worth a heading when something sits above it.
            if !rows.isEmpty { rows.append(.group("Open · \(rest.count)")) }
            rows += rest.map { .issue($0, worktreeBranch: nil) }
        }
        return rows
    }

    /// `#12`/`12` matches the number; anything else the title or a label.
    static func matches(_ issue: GitHubIssue, _ query: String) -> Bool {
        let digits = query.hasPrefix("#") ? String(query.dropFirst()) : query
        if let n = Int(digits) { return String(issue.number).hasPrefix(String(n)) }
        if issue.title.lowercased().contains(query) { return true }
        return issue.labels.contains { $0.name.lowercased().contains(query) }
    }

    /// `bug, ui · @alice · 3d` — what is worth a glance below the title.
    static func meta(for issue: GitHubIssue, now: Date = Date()) -> String {
        var parts: [String] = []
        if !issue.labels.isEmpty { parts.append(issue.labels.map(\.name).joined(separator: ", ")) }
        if let assignees = issue.assignees, !assignees.isEmpty {
            parts.append(assignees.map { "@\($0.login)" }.joined(separator: " "))
        }
        if issue.comments > 0 { parts.append(issue.comments == 1 ? "1 comment" : "\(issue.comments) comments") }
        if let updated = parseDate(issue.updatedAt) { parts.append(age(since: updated, now: now)) }
        return parts.joined(separator: " · ")
    }

    static func parseDate(_ iso: String) -> Date? { ISO8601DateFormatter().date(from: iso) }

    /// "45m", "3h", "2d".
    static func age(since date: Date, now: Date) -> String {
        let minutes = max(0, Int(now.timeIntervalSince(date) / 60))
        if minutes < 60 { return "\(minutes)m" }
        if minutes < 60 * 24 { return "\(minutes / 60)h" }
        return "\(minutes / (60 * 24))d"
    }
}

/// Scope switch with a search toggle on one row, the (hidden until asked for)
/// filter field, then the issue table. The pane header and the placeholder for an
/// unreadable repo are the side panel's; this only lists.
final class IssueListView: NSView {
    var onSelectIssue: ((GitHubIssue) -> Void)?

    private let searchField = NSTextField(string: "")
    private let searchButton = NSButton()
    private let searchRow = NSView()
    private var searchRowHeight: NSLayoutConstraint?
    private var isSearching: Bool { !searchRow.isHidden }
    private let scopeControl = NSSegmentedControl(labels: IssueScope.allCases.map(\.title),
                                                  trackingMode: .selectOne, target: nil, action: nil)
    private static let scopeDefaultsKey = "seahelm.issues.scope"
    private var scope: IssueScope {
        IssueScope(rawValue: scopeControl.selectedSegment) ?? .all
    }
    private let tableView = NSTableView()
    private let scrollView = NSScrollView()
    private var snapshot: GitHubIssueSnapshot?
    private var currentBranch: String?
    private var otherBranches: [String] = []
    private(set) var rows: [IssueRow] = []

    private static let sea = NSColor(srgbRed: 0x1f/255, green: 0xc8/255, blue: 0xda/255, alpha: 1)
    private static let ink: NSColor = SemanticColors.text
    private static let inkDim: NSColor = SemanticColors.muted
    private static let inkFaint: NSColor = SemanticColors.subtle

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    func show(_ snapshot: GitHubIssueSnapshot, currentBranch: String?, otherBranches: [String]) {
        self.snapshot = snapshot
        self.currentBranch = currentBranch
        self.otherBranches = otherBranches
        // Without a viewer, Created/Assigned would always be empty.
        let knowsViewer = snapshot.viewerLogin != nil
        for segment in 1..<scopeControl.segmentCount { scopeControl.setEnabled(knowsViewer, forSegment: segment) }
        if !knowsViewer { scopeControl.selectedSegment = IssueScope.all.rawValue }
        scopeControl.toolTip = snapshot.viewerLogin.map { "Issues created by / assigned to @\($0)" }
            ?? "Sign in to GitHub (`gh auth login`) to filter by you"
        reload()
    }

    private func reload() {
        guard let snapshot else { return }
        rows = IssueListSections.rows(snapshot: snapshot, currentBranch: currentBranch,
                                      otherBranches: otherBranches, filter: searchField.stringValue,
                                      scope: scope)
        tableView.reloadData()
    }

    private func setup() {
        translatesAutoresizingMaskIntoConstraints = false

        searchButton.bezelStyle = .recessed
        searchButton.isBordered = false
        searchButton.imagePosition = .imageOnly
        searchButton.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: "Search issues")?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .regular))
        searchButton.contentTintColor = Self.inkDim
        searchButton.toolTip = "Search issues"
        searchButton.target = self
        searchButton.action = #selector(toggleSearch)
        searchButton.translatesAutoresizingMaskIntoConstraints = false
        searchButton.setAccessibilityIdentifier("sidePanel.issueSearchToggle")

        searchRow.translatesAutoresizingMaskIntoConstraints = false
        searchRow.isHidden = true
        searchRow.addSubview(searchField)

        searchField.isEditable = true
        searchField.isSelectable = true
        searchField.isBordered = false
        searchField.isBezeled = false
        searchField.drawsBackground = false
        searchField.focusRingType = .none
        searchField.font = AppFont.mono(size: 12)
        searchField.textColor = Self.ink
        searchField.placeholderAttributedString = NSAttributedString(
            string: "Filter issues",
            attributes: [.foregroundColor: Self.inkDim, .font: AppFont.mono(size: 12)]
        )
        searchField.delegate = self
        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.setAccessibilityIdentifier("sidePanel.issueSearch")

        scopeControl.segmentStyle = .roundRect
        scopeControl.controlSize = .small
        scopeControl.font = AppFont.mono(size: 10.5)
        scopeControl.target = self
        scopeControl.action = #selector(scopeChanged)
        scopeControl.translatesAutoresizingMaskIntoConstraints = false
        scopeControl.setAccessibilityIdentifier("sidePanel.issueScope")
        let saved = UserDefaults.standard.integer(forKey: Self.scopeDefaultsKey)
        scopeControl.selectedSegment = IssueScope(rawValue: saved)?.rawValue ?? 0

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("IssueColumn"))
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.style = .sourceList
        tableView.usesAutomaticRowHeights = false
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.action = #selector(rowClicked)
        tableView.floatsGroupRows = false
        tableView.backgroundColor = .clear
        tableView.setAccessibilityIdentifier("sidePanel.issuesTable")

        scrollView.documentView = tableView
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.scrollerStyle = .overlay
        scrollView.autohidesScrollers = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        addSubview(scopeControl)
        addSubview(searchButton)
        addSubview(searchRow)
        addSubview(scrollView)
        let searchRowHeight = searchRow.heightAnchor.constraint(equalToConstant: 0)
        self.searchRowHeight = searchRowHeight
        NSLayoutConstraint.activate([
            scopeControl.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            scopeControl.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            scopeControl.trailingAnchor.constraint(lessThanOrEqualTo: searchButton.leadingAnchor, constant: -8),

            searchButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            searchButton.centerYAnchor.constraint(equalTo: scopeControl.centerYAnchor),
            searchButton.widthAnchor.constraint(equalToConstant: 22),
            searchButton.heightAnchor.constraint(equalToConstant: 22),

            searchRow.topAnchor.constraint(equalTo: scopeControl.bottomAnchor, constant: 6),
            searchRow.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            searchRow.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            searchRowHeight,

            searchField.leadingAnchor.constraint(equalTo: searchRow.leadingAnchor),
            searchField.trailingAnchor.constraint(equalTo: searchRow.trailingAnchor),
            searchField.centerYAnchor.constraint(equalTo: searchRow.centerYAnchor),

            scrollView.topAnchor.constraint(equalTo: searchRow.bottomAnchor, constant: 4),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @objc private func scopeChanged() {
        UserDefaults.standard.set(scopeControl.selectedSegment, forKey: Self.scopeDefaultsKey)
        reload()
    }

    /// The magnifier opens the filter field under the scope row and focuses
    /// it; pressed again (or Esc in the field) it closes and clears the filter.
    @objc private func toggleSearch() {
        setSearching(!isSearching)
    }

    private func setSearching(_ on: Bool) {
        searchRow.isHidden = !on
        searchRowHeight?.constant = on ? 24 : 0
        searchButton.contentTintColor = on ? Self.sea : Self.inkDim
        if on {
            window?.makeFirstResponder(searchField)
        } else {
            if !searchField.stringValue.isEmpty {
                searchField.stringValue = ""
                reload()
            }
            if window?.firstResponder === searchField.currentEditor() { window?.makeFirstResponder(tableView) }
        }
    }

    @objc private func rowClicked() {
        let row = tableView.clickedRow
        guard row >= 0, row < rows.count, case .issue(let issue, _) = rows[row] else { return }
        onSelectIssue?(issue)
    }
}

extension IssueListView: NSTextFieldDelegate {
    func controlTextDidChange(_ obj: Notification) { reload() }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard selector == #selector(cancelOperation(_:)) else { return false }
        setSearching(false)
        return true
    }
}

extension IssueListView: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        if case .group = rows[row] { return 24 }
        return 42
    }

    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
        if case .group = rows[row] { return true }
        return false
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        if case .issue = rows[row] { return true }
        return false
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        switch rows[row] {
        case .group(let title):
            return groupCell(title)
        case .issue(let issue, let branch):
            return issueCell(issue, branch: branch)
        }
    }

    private func groupCell(_ title: String) -> NSView {
        let id = NSUserInterfaceItemIdentifier("IssueGroupCell")
        let cell = tableView.makeView(withIdentifier: id, owner: self) as? NSTableCellView ?? {
            let cell = NSTableCellView()
            cell.identifier = id
            // Not the cell's `textField`: AppKit restyles that on a group row
            // in the system font, and this panel is mono throughout.
            let label = NSTextField(labelWithString: "")
            label.font = AppFont.mono(size: 10.5, weight: .semibold)
            label.textColor = Self.inkDim
            label.lineBreakMode = .byTruncatingTail
            label.translatesAutoresizingMaskIntoConstraints = false
            label.tag = 200
            cell.addSubview(label)
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
                label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8),
                label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
            return cell
        }()
        (cell.viewWithTag(200) as? NSTextField)?.stringValue = title
        return cell
    }

    private func issueCell(_ issue: GitHubIssue, branch: String?) -> NSView {
        let id = NSUserInterfaceItemIdentifier("IssueCell")
        let cell = tableView.makeView(withIdentifier: id, owner: self) as? NSTableCellView ?? {
            let cell = NSTableCellView()
            cell.identifier = id
            func label(_ tag: Int, _ font: NSFont, _ color: NSColor) -> NSTextField {
                let l = NSTextField(labelWithString: "")
                l.font = font
                l.textColor = color
                l.lineBreakMode = .byTruncatingTail
                l.maximumNumberOfLines = 1
                l.translatesAutoresizingMaskIntoConstraints = false
                l.tag = tag
                cell.addSubview(l)
                return l
            }
            let number = label(100, AppFont.mono(size: 11, weight: .semibold), Self.sea)
            let title = label(101, AppFont.mono(size: 12), Self.ink)
            let meta = label(102, AppFont.mono(size: 10.5), Self.inkFaint)
            let branch = label(103, AppFont.mono(size: 10.5), Self.sea)
            number.setContentHuggingPriority(.required, for: .horizontal)
            number.setContentCompressionResistancePriority(.required, for: .horizontal)
            title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            meta.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            branch.setContentHuggingPriority(.required, for: .horizontal)
            NSLayoutConstraint.activate([
                number.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
                number.topAnchor.constraint(equalTo: cell.topAnchor, constant: 5),
                title.leadingAnchor.constraint(equalTo: number.trailingAnchor, constant: 6),
                title.firstBaselineAnchor.constraint(equalTo: number.firstBaselineAnchor),
                title.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -8),
                meta.leadingAnchor.constraint(equalTo: title.leadingAnchor),
                meta.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 3),
                meta.trailingAnchor.constraint(lessThanOrEqualTo: branch.leadingAnchor, constant: -6),
                branch.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8),
                branch.firstBaselineAnchor.constraint(equalTo: meta.firstBaselineAnchor),
                branch.widthAnchor.constraint(lessThanOrEqualTo: cell.widthAnchor, multiplier: 0.45),
            ])
            return cell
        }()
        (cell.viewWithTag(100) as? NSTextField)?.stringValue = "#\(issue.number)"
        (cell.viewWithTag(101) as? NSTextField)?.stringValue = issue.title
        (cell.viewWithTag(102) as? NSTextField)?.stringValue = IssueListSections.meta(for: issue)
        let branchLabel = cell.viewWithTag(103) as? NSTextField
        branchLabel?.stringValue = branch.map { "⎇ \($0)" } ?? ""
        branchLabel?.toolTip = branch
        cell.toolTip = issue.title
        return cell
    }
}
