import AppKit

/// Editor for the message-triggered dispatch rules.
///
/// List on top, form for the selected rule below. The three things a rule is
/// made of get their own block — filter, prompt, target — because that's the
/// order you think in: *which* messages, *what* to say about them, *where* it
/// goes.
///
/// Edits write straight back through `onChange`; there is no Save here either.
final class IMessageRulesView: NSView {
    /// Fired whenever the rule set changes. The owner persists.
    var onChange: (([IMessageRule]) -> Void)?

    private(set) var rules: [IMessageRule]

    private let tableView = NSTableView()
    private let scrollView = NSScrollView()
    private let removeButton = NSButton()

    private let enabledToggle = NSSwitch()
    private let nameField = SettingsTextField()
    private let fromField = SettingsTextField()
    private let matchField = SettingsTextField()
    private let promptView = NSTextView()
    private let promptScroll = NSScrollView()
    private let projectPopup = NSPopUpButton()
    private let worktreePopup = NSPopUpButton()
    private let panePopup = NSPopUpButton()

    /// The card swaps between the form and the empty hint. One container, one
    /// set of edge constraints — pinning both to the card would leave two
    /// competing height equalities and Auto Layout would resolve them by
    /// squeezing the form until its labels vanished.
    private let cardStack = NSStackView()
    private var formRows: [NSView] = []
    private let emptyLabel = SettingsRow.makeHint(
        "Select a rule to edit it, or add one. Rules run only on messages that "
        + "are not commands, and never reply.")

    /// Live panes, the menu of everything a rule can target.
    var panes: [PaneSnapshot] = [] {
        didSet {
            renderForm()
            tableView.reloadData()   // target labels are resolved from the panes
        }
    }

    private static let anyWorktree = "Any worktree"
    private static let anyPane = "Any pane"

    /// A popup entry: what the user reads, and what the rule stores. They differ
    /// on purpose — a worktree reads as its branch and a pane as its title, but
    /// a rule still has to be pinned to a path / session key.
    private struct Choice {
        let title: String
        let value: String
    }

    private var selectedIndex: Int? {
        let row = tableView.selectedRow
        return rules.indices.contains(row) ? row : nil
    }

    init(rules: [IMessageRule]) {
        self.rules = rules
        super.init(frame: .zero)
        build()
        renderForm()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    // MARK: - Building

    private func build() {
        translatesAutoresizingMaskIntoConstraints = false

        tableView.headerView = nil
        tableView.rowHeight = 24
        tableView.backgroundColor = .clear
        tableView.delegate = self
        tableView.dataSource = self
        tableView.setAccessibilityIdentifier("settings.imessage.rules")
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("rule"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)

        scrollView.hasVerticalScroller = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.documentView = tableView

        let addButton = SettingsControls.button("+", target: self, action: #selector(addRule))
        addButton.setAccessibilityIdentifier("settings.imessage.addRule")
        removeButton.title = "−"
        removeButton.bezelStyle = .rounded
        removeButton.font = .systemFont(ofSize: 12)
        removeButton.target = self
        removeButton.action = #selector(removeRule)
        removeButton.isEnabled = false

        let listActions = NSStackView(views: [addButton, removeButton])
        listActions.spacing = 6
        listActions.translatesAutoresizingMaskIntoConstraints = false

        let listBox = SettingsControls.surface(scrollView, height: 96)
        listBox.translatesAutoresizingMaskIntoConstraints = false

        enabledToggle.target = self
        enabledToggle.action = #selector(formChanged)

        for (field, placeholder) in [(nameField, "aliyun-cpu"),
                                     (fromField, "^106\\d+$"),
                                     (matchField, "CPU.*?(\\d+)%")] {
            field.placeholderString = placeholder
            field.alignment = .left
            field.target = self
            field.action = #selector(formChanged)
        }
        nameField.setAccessibilityIdentifier("settings.imessage.ruleName")

        promptView.isEditable = true
        promptView.font = AppFont.mono(size: 11, weight: .regular)
        promptView.drawsBackground = false
        promptView.textColor = SettingsPalette.text
        promptView.textContainerInset = NSSize(width: 6, height: 6)
        promptView.isAutomaticQuoteSubstitutionEnabled = false
        promptView.isAutomaticDashSubstitutionEnabled = false
        promptView.isAutomaticTextReplacementEnabled = false
        promptView.delegate = self
        promptScroll.hasVerticalScroller = true
        promptScroll.borderType = .noBorder
        promptScroll.drawsBackground = false
        promptScroll.documentView = promptView

        for (popup, id) in [(projectPopup, "Project"), (worktreePopup, "Worktree"),
                            (panePopup, "Pane")] {
            popup.target = self
            popup.action = #selector(targetChanged(_:))
            popup.setAccessibilityIdentifier("settings.imessage.ruleTarget\(id)")
            // Three popups share one line, so each must be willing to shrink and
            // truncate rather than push its neighbours off the card.
            (popup.cell as? NSPopUpButtonCell)?.lineBreakMode = .byTruncatingTail
            popup.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }

        formRows = [
            SettingsRow.make("Enabled", control: enabledToggle),
            SettingsRow.make("Name", control: nameField),
            SettingsRow.make("Sender matches",
                             subtitle: "Regex over the sender handle. Empty matches anyone.",
                             control: fromField),
            SettingsRow.make("Body matches",
                             subtitle: "Regex over the message text. Capture groups fill {{1}}…{{9}} in the prompt. Empty matches anything.",
                             control: matchField),
            SettingsRow.stacked("Prompt",
                                subtitle: "Typed into the target pane as if you had typed it. {{text}} is the whole message, {{from}} the sender, {{1}}… the capture groups.",
                                content: SettingsControls.surface(promptScroll), height: 84),
            SettingsRow.stacked("Target",
                                subtitle: "Project · worktree · pane. Narrow as far as you want: stop at the project or worktree and the rule takes the first pane there, which survives panes being closed and reopened.",
                                content: targetStack()),
        ]

        cardStack.orientation = .vertical
        cardStack.alignment = .leading
        cardStack.spacing = 0
        cardStack.translatesAutoresizingMaskIntoConstraints = false

        let card = NSView()
        card.wantsLayer = true
        card.layer?.backgroundColor = SettingsPalette.cardBg.cgColor
        card.layer?.cornerRadius = SettingsChrome.cornerRadius
        card.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(cardStack)

        addSubview(listBox)
        addSubview(listActions)
        addSubview(card)

        NSLayoutConstraint.activate([
            listBox.topAnchor.constraint(equalTo: topAnchor),
            listBox.leadingAnchor.constraint(equalTo: leadingAnchor),
            listBox.trailingAnchor.constraint(equalTo: trailingAnchor),

            listActions.topAnchor.constraint(equalTo: listBox.bottomAnchor, constant: 6),
            listActions.leadingAnchor.constraint(equalTo: leadingAnchor),

            card.topAnchor.constraint(equalTo: listActions.bottomAnchor, constant: 12),
            card.leadingAnchor.constraint(equalTo: leadingAnchor),
            card.trailingAnchor.constraint(equalTo: trailingAnchor),
            card.bottomAnchor.constraint(equalTo: bottomAnchor),

            cardStack.topAnchor.constraint(equalTo: card.topAnchor),
            cardStack.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            cardStack.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            cardStack.bottomAnchor.constraint(equalTo: card.bottomAnchor),
        ])
    }

    /// The three target popups on one line, each taking a third of the width.
    private func targetStack() -> NSView {
        let stack = NSStackView(views: [projectPopup, worktreePopup, panePopup])
        stack.orientation = .horizontal
        stack.distribution = .fillEqually
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }

    private func setCardContent(_ views: [NSView]) {
        for view in cardStack.arrangedSubviews {
            cardStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        for (index, view) in views.enumerated() {
            if index > 0 { cardStack.addArrangedSubview(hairline()) }
            cardStack.addArrangedSubview(view)
        }
        for child in cardStack.arrangedSubviews {
            child.leadingAnchor.constraint(equalTo: cardStack.leadingAnchor).isActive = true
            child.trailingAnchor.constraint(equalTo: cardStack.trailingAnchor).isActive = true
        }
    }

    private func hairline() -> NSView {
        let line = NSView()
        line.wantsLayer = true
        line.layer?.backgroundColor = SettingsPalette.separator.cgColor
        line.translatesAutoresizingMaskIntoConstraints = false
        line.heightAnchor.constraint(equalToConstant: 1).isActive = true
        return line
    }

    /// Select a rule by index — also the seam layout tests use to get the form
    /// on screen without driving the table view.
    func selectRule(at index: Int) {
        guard rules.indices.contains(index) else { return }
        tableView.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        renderForm()
    }

    // MARK: - Form

    /// Push the selected rule into the fields. With nothing selected the card
    /// shows a hint instead of editable blanks that would write into nothing.
    private func renderForm() {
        let rule = selectedIndex.map { rules[$0] }
        removeButton.isEnabled = rule != nil

        guard let rule else {
            setCardContent([SettingsRow.stacked(nil, content: emptyLabel)])
            return
        }

        setCardContent(formRows)
        enabledToggle.state = rule.isEnabled ? .on : .off
        nameField.stringValue = rule.name
        fromField.stringValue = rule.from ?? ""
        matchField.stringValue = rule.match ?? ""
        promptView.string = rule.prompt
        rebuildTargetPopups(for: rule.target)
    }

    // MARK: - Target cascade

    /// Fill the three popups from the live panes, then select whatever the rule
    /// already points at.
    ///
    /// A saved target whose pane is gone is kept as its own item rather than
    /// silently reset — a worktree you closed for the day should not quietly
    /// re-point a rule at some other project's pane.
    private func rebuildTargetPopups(for target: IMessageRuleTarget) {
        let stored = target.value.trimmingCharacters(in: .whitespaces)
        let storedPane = IMessageRuleEngine.resolvePane(target, panes: panes)

        var projects = Array(Set(panes.map(\.project))).sorted()
        let selectedProject: String
        switch target.kind {
        case .project: selectedProject = stored
        default: selectedProject = storedPane?.project ?? ""
        }
        if !selectedProject.isEmpty, !projects.contains(selectedProject) {
            projects.insert(selectedProject, at: 0)   // offline target stays selectable
        }
        fill(projectPopup, choices: projects.map { Choice(title: $0, value: $0) },
             select: selectedProject, emptyTitle: "No running panes")

        let project = selectedValue(projectPopup)
        var worktrees = uniqued(panes.filter { $0.project == project }
            .map { Choice(title: worktreeLabel($0), value: $0.worktreePath) })
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        let selectedWorktree: String
        switch target.kind {
        case .worktree: selectedWorktree = stored
        case .pane: selectedWorktree = storedPane?.worktreePath ?? ""
        case .project: selectedWorktree = ""
        }
        if !selectedWorktree.isEmpty, !worktrees.contains(where: { $0.value == selectedWorktree }) {
            // Offline worktree: no pane left to name it, so fall back to the path.
            worktrees.insert(Choice(title: (selectedWorktree as NSString).lastPathComponent,
                                    value: selectedWorktree), at: 0)
        }
        fill(worktreePopup, choices: [Choice(title: Self.anyWorktree, value: "")] + worktrees,
             select: selectedWorktree, emptyTitle: Self.anyWorktree)

        let worktree = resolvedWorktreePath()
        var paneChoices = panes.filter { $0.worktreePath == worktree }
            .filter { !$0.paneSessionKey.isEmpty }
            .map { Choice(title: paneLabel($0), value: $0.paneSessionKey) }
        let selectedPane = target.kind == .pane ? stored : ""
        if !selectedPane.isEmpty, !paneChoices.contains(where: { $0.value == selectedPane }) {
            paneChoices.insert(Choice(title: selectedPane, value: selectedPane), at: 0)
        }
        fill(panePopup, choices: [Choice(title: Self.anyPane, value: "")] + paneChoices,
             select: selectedPane, emptyTitle: Self.anyPane)

        worktreePopup.isEnabled = !projects.isEmpty
        panePopup.isEnabled = worktree != nil
    }

    /// A worktree reads as its branch — that is how it is named everywhere else
    /// in the app, so a rule's target matches what the sidebar and First Mate
    /// show. Only a branchless worktree falls back to its directory name.
    private func worktreeLabel(_ pane: PaneSnapshot) -> String {
        let branch = pane.branch.trimmingCharacters(in: .whitespaces)
        return branch.isEmpty ? (pane.worktreePath as NSString).lastPathComponent : branch
    }

    /// A pane reads as its title; the session key is the fallback for a pane
    /// that has not reported one yet.
    private func paneLabel(_ pane: PaneSnapshot) -> String {
        let title = pane.title.trimmingCharacters(in: .whitespaces)
        return title.isEmpty ? pane.paneSessionKey : title
    }

    /// First choice wins per value — several panes in a worktree agree on the
    /// branch, and the menu wants one entry.
    private func uniqued(_ choices: [Choice]) -> [Choice] {
        var seen = Set<String>()
        return choices.filter { seen.insert($0.value).inserted }
    }

    private func fill(_ popup: NSPopUpButton, choices: [Choice], select: String, emptyTitle: String) {
        popup.removeAllItems()
        let choices = choices.isEmpty ? [Choice(title: emptyTitle, value: "")] : choices
        for choice in choices {
            // Titles repeat freely (two panes named "claude"), so the menu is
            // built item by item and the real value rides along represented.
            let item = NSMenuItem(title: choice.title, action: nil, keyEquivalent: "")
            item.representedObject = choice.value
            popup.menu?.addItem(item)
        }
        let index = choices.firstIndex { $0.value == select } ?? 0
        popup.selectItem(at: index)
    }

    /// How a target reads in the rule list — the same branch/title names the
    /// popups use, so the list and the form agree.
    private func label(for target: IMessageRuleTarget) -> String {
        switch target.kind {
        case .project:
            return target.value
        case .worktree:
            let pane = panes.first { $0.worktreePath == target.value }
            return pane.map(worktreeLabel) ?? (target.value as NSString).lastPathComponent
        case .pane:
            let pane = panes.first { $0.paneSessionKey == target.value }
            return pane.map(paneLabel) ?? target.value
        }
    }

    private func selectedValue(_ popup: NSPopUpButton) -> String {
        popup.selectedItem?.representedObject as? String ?? ""
    }

    private func resolvedWorktreePath() -> String? {
        let value = selectedValue(worktreePopup)
        return value.isEmpty ? nil : value
    }

    /// Re-cascade, then write the result back. Changing the project invalidates
    /// the worktree below it, so the whole chain is rebuilt from the new
    /// selection rather than patched.
    @objc private func targetChanged(_ sender: NSPopUpButton) {
        guard selectedIndex != nil else { return }

        // Which popup moved decides the depth. Reading the deepest non-empty
        // popup instead would let a stale pane below the one you just changed
        // win, and the change would appear to snap back — most visibly when the
        // rule points at a pane that is no longer running, so its key sits in
        // the pane popup while the worktree above reads "Any worktree".
        let target: IMessageRuleTarget
        switch sender {
        case projectPopup:
            target = IMessageRuleTarget(kind: .project, value: selectedValue(projectPopup))
        case worktreePopup:
            if let worktree = resolvedWorktreePath() {
                target = IMessageRuleTarget(kind: .worktree, value: worktree)
            } else {
                target = IMessageRuleTarget(kind: .project, value: selectedValue(projectPopup))
            }
        default:
            target = currentTarget()
        }

        rebuildTargetPopups(for: target)
        commit(target: target)
    }

    @objc private func formChanged() {
        commit(target: currentTarget())
    }

    /// Deepest concrete choice wins: a named pane beats its worktree, which
    /// beats its project.
    private func currentTarget() -> IMessageRuleTarget {
        let paneKey = selectedValue(panePopup)
        if !paneKey.isEmpty {
            return IMessageRuleTarget(kind: .pane, value: paneKey)
        }
        if let worktree = resolvedWorktreePath() {
            return IMessageRuleTarget(kind: .worktree, value: worktree)
        }
        return IMessageRuleTarget(kind: .project, value: selectedValue(projectPopup))
    }

    private func commit(target: IMessageRuleTarget) {
        guard let index = selectedIndex else { return }

        rules[index] = IMessageRule(
            name: nameField.stringValue,
            enabled: enabledToggle.state == .on,
            from: nonEmpty(fromField.stringValue),
            match: nonEmpty(matchField.stringValue),
            prompt: promptView.string,
            target: target
        )
        tableView.reloadData(forRowIndexes: IndexSet(integer: index),
                             columnIndexes: IndexSet(integer: 0))
        onChange?(rules)
    }

    private func nonEmpty(_ s: String) -> String? {
        let trimmed = s.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }

    // MARK: - List actions

    @objc private func addRule() {
        rules.append(IMessageRule(name: "New rule", enabled: true, prompt: "{{text}}"))
        tableView.reloadData()
        tableView.selectRowIndexes(IndexSet(integer: rules.count - 1), byExtendingSelection: false)
        renderForm()
        onChange?(rules)
    }

    @objc private func removeRule() {
        guard let index = selectedIndex else { return }
        rules.remove(at: index)
        tableView.reloadData()
        renderForm()
        onChange?(rules)
    }
}

// MARK: - Table

extension IMessageRulesView: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { rules.count }

    func tableView(_ tableView: NSTableView,
                   viewFor tableColumn: NSTableColumn?,
                   row: Int) -> NSView? {
        guard rules.indices.contains(row) else { return nil }
        let rule = rules[row]

        let name = rule.name.isEmpty ? "(unnamed)" : rule.name
        let targetLabel = label(for: rule.target)
        let label = NSTextField(labelWithString: "\(name)  →  \(targetLabel)")
        label.font = .systemFont(ofSize: 12)
        // A disabled rule stays listed but reads as inert, so "why didn't it
        // fire" is answerable from this list alone.
        label.textColor = rule.isEnabled ? SettingsPalette.text : SettingsPalette.secondary
        label.lineBreakMode = .byTruncatingTail
        return label
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        renderForm()
    }
}

// MARK: - Prompt editing

extension IMessageRulesView: NSTextViewDelegate {
    func textDidEndEditing(_ notification: Notification) {
        guard notification.object as? NSTextView === promptView else { return }
        formChanged()
    }
}
