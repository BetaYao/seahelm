import AppKit

/// Editor for one repo's First Mate rules (`.seahelm/automations.yml`).
///
/// List on the left, the selected rule's form on the right. Edits change
/// `config` in memory and fire `onChange`; writing the file is the page's Save,
/// because saving rewrites the whole file and a hand-written one loses its
/// comments — that should be a deliberate act, not a keystroke.
final class FirstMateRulesView: NSView, NSTableViewDataSource, NSTableViewDelegate, NSTextViewDelegate {
    var onChange: ((AutomationConfig) -> Void)?

    private(set) var config: AutomationConfig

    private let tableView = NSTableView()
    private let tableScroll = NSScrollView()
    private let addButton = NSButton()
    private let removeButton = NSButton()

    private let enabledToggle = NSSwitch()
    private let nameField = SettingsTextField()
    private let triggerPopup = NSPopUpButton()
    private let cronField = SettingsTextField()
    private let branchField = SettingsTextField()
    private let attemptsField = SettingsTextField()
    private var autonomyPopups: [AutopilotAction: NSPopUpButton] = [:]
    private let briefView = NSTextView()
    private let briefScroll = NSScrollView()
    private let form = NSStackView()
    private let emptyLabel = SettingsRow.makeHint("Select a rule to edit it, or add one.")
    private var rendering = false

    private static let triggers: [(title: String, make: (String) -> AutomationTrigger)] = [
        ("CI failed", { _ in .ciFailed }),
        ("PR merged", { _ in .prMerged }),
        ("On a schedule", { .schedule($0) }),
    ]
    private static let inherit = "Default"

    init(config: AutomationConfig) {
        self.config = config
        super.init(frame: .zero)
        build()
        tableView.reloadData()
        if !config.rules.isEmpty { tableView.selectRowIndexes([0], byExtendingSelection: false) }
        renderForm()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    /// Show another repo's rules (or the same repo's, re-read).
    func load(_ config: AutomationConfig) {
        self.config = config
        tableView.reloadData()
        tableView.selectRowIndexes(config.rules.isEmpty ? [] : [0], byExtendingSelection: false)
        renderForm()
    }

    private var selected: Int? {
        config.rules.indices.contains(tableView.selectedRow) ? tableView.selectedRow : nil
    }

    // MARK: - Building

    private func build() {
        translatesAutoresizingMaskIntoConstraints = false

        tableView.headerView = nil
        tableView.rowHeight = 34
        tableView.addTableColumn(NSTableColumn(identifier: .init("rule")))
        tableView.dataSource = self
        tableView.delegate = self
        tableView.backgroundColor = .clear
        tableScroll.documentView = tableView
        tableScroll.hasVerticalScroller = true
        tableScroll.drawsBackground = false
        tableScroll.borderType = .noBorder
        tableScroll.translatesAutoresizingMaskIntoConstraints = false

        for (button, symbol, tip, action) in [
            (addButton, "plus", "Add a rule", #selector(addRule)),
            (removeButton, "minus", "Remove the selected rule", #selector(removeRule)),
        ] {
            button.bezelStyle = .smallSquare
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)
            button.toolTip = tip
            button.target = self
            button.action = action
        }
        let listButtons = NSStackView(views: [addButton, removeButton])
        listButtons.spacing = 0
        let list = NSStackView(views: [tableScroll, listButtons])
        list.orientation = .vertical
        list.alignment = .leading
        list.spacing = 4
        list.translatesAutoresizingMaskIntoConstraints = false

        triggerPopup.addItems(withTitles: Self.triggers.map(\.title))
        cronField.placeholderString = "0 9 * * 1-5"
        branchField.placeholderString = "any — or !main, feat/*"
        attemptsField.placeholderString = "unlimited"
        for field in [nameField, cronField, branchField, attemptsField] {
            field.target = self
            field.action = #selector(formChanged)
            field.delegate = self
        }
        enabledToggle.target = self
        enabledToggle.action = #selector(formChanged)
        triggerPopup.target = self
        triggerPopup.action = #selector(formChanged)

        briefView.font = AppFont.mono(size: 12)
        briefView.isRichText = false
        briefView.isAutomaticQuoteSubstitutionEnabled = false
        briefView.delegate = self
        briefView.textContainerInset = NSSize(width: 6, height: 6)
        briefScroll.documentView = briefView
        briefScroll.hasVerticalScroller = true
        briefScroll.borderType = .bezelBorder
        briefScroll.translatesAutoresizingMaskIntoConstraints = false
        briefView.isVerticallyResizable = true
        briefView.autoresizingMask = [.width]

        var autonomyRows: [NSView] = []
        for action in AutopilotAction.allCases {
            let popup = NSPopUpButton()
            popup.addItems(withTitles: [Self.inherit] + [AutonomyLevel.auto, .ask, .deny].map(\.rawValue))
            popup.target = self
            popup.action = #selector(formChanged)
            autonomyPopups[action] = popup
            autonomyRows.append(Self.row(Self.actionTitle(action), popup))
        }

        form.orientation = .vertical
        form.alignment = .leading
        form.spacing = 8
        form.translatesAutoresizingMaskIntoConstraints = false
        for v in [Self.row("Enabled", enabledToggle), Self.row("Name", nameField),
                  Self.row("When", triggerPopup), Self.row("Schedule (cron)", cronField),
                  Self.row("Branch", branchField), Self.row("Max tries / PR / day", attemptsField)]
            + autonomyRows + [Self.label("Brief — what First Mate is told. {{pr}} {{branch}} {{worktree}} {{repo}} {{pr_url}}"),
                              briefScroll, emptyLabel] {
            form.addArrangedSubview(v)
        }

        addSubview(list)
        addSubview(form)
        NSLayoutConstraint.activate([
            list.topAnchor.constraint(equalTo: topAnchor),
            list.leadingAnchor.constraint(equalTo: leadingAnchor),
            list.bottomAnchor.constraint(equalTo: bottomAnchor),
            list.widthAnchor.constraint(equalToConstant: 170),
            tableScroll.widthAnchor.constraint(equalTo: list.widthAnchor),
            tableScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 220),
            form.topAnchor.constraint(equalTo: topAnchor),
            form.leadingAnchor.constraint(equalTo: list.trailingAnchor, constant: 16),
            form.trailingAnchor.constraint(equalTo: trailingAnchor),
            form.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor),
            briefScroll.widthAnchor.constraint(equalTo: form.widthAnchor),
            briefScroll.heightAnchor.constraint(equalToConstant: 110),
        ])
        for field in [nameField, cronField, branchField, attemptsField] {
            field.widthAnchor.constraint(equalToConstant: 220).isActive = true
        }
    }

    private static func row(_ title: String, _ control: NSView) -> NSView {
        let l = label(title)
        l.widthAnchor.constraint(equalToConstant: 150).isActive = true
        let row = NSStackView(views: [l, control])
        row.alignment = .centerY
        row.spacing = 8
        return row
    }

    private static func label(_ text: String) -> NSTextField {
        let l = NSTextField(labelWithString: text)
        l.font = NSFont.systemFont(ofSize: 12)
        l.textColor = SettingsPalette.secondary
        return l
    }

    static func actionTitle(_ action: AutopilotAction) -> String {
        switch action {
        case .messagePane: return "Message an agent"
        case .startAgent: return "Start an agent"
        case .deleteWorktree: return "Delete a worktree"
        }
    }

    static func triggerText(_ trigger: AutomationTrigger) -> String {
        switch trigger {
        case .ciFailed: return "CI failed"
        case .prMerged: return "PR merged"
        case .schedule(let cron): return "Schedule \(cron)"
        }
    }

    // MARK: - Form

    private func renderForm() {
        rendering = true
        defer { rendering = false }
        removeButton.isEnabled = selected != nil
        let editing = form.arrangedSubviews.filter { $0 !== emptyLabel }
        guard let i = selected else {
            editing.forEach { $0.isHidden = true }
            emptyLabel.isHidden = false
            return
        }
        editing.forEach { $0.isHidden = false }
        emptyLabel.isHidden = true
        let rule = config.rules[i]
        enabledToggle.state = rule.enabled ? .on : .off
        nameField.stringValue = rule.name
        switch rule.trigger {
        case .ciFailed: triggerPopup.selectItem(at: 0); cronField.stringValue = ""
        case .prMerged: triggerPopup.selectItem(at: 1); cronField.stringValue = ""
        case .schedule(let cron): triggerPopup.selectItem(at: 2); cronField.stringValue = cron
        }
        cronField.superview?.isHidden = triggerPopup.indexOfSelectedItem != 2
        branchField.stringValue = rule.branch?.pattern ?? ""
        attemptsField.stringValue = rule.maxAttempts.map(String.init) ?? ""
        for (action, popup) in autonomyPopups {
            popup.selectItem(withTitle: rule.autonomy[action]?.rawValue ?? Self.inherit)
        }
        if briefView.string != rule.brief { briefView.string = rule.brief }
    }

    @objc private func formChanged() {
        guard !rendering, let i = selected else { return }
        var rule = config.rules[i]
        rule.enabled = enabledToggle.state == .on
        let name = nameField.stringValue.trimmingCharacters(in: .whitespaces)
        if !name.isEmpty { rule.name = name }
        let cron = cronField.stringValue.trimmingCharacters(in: .whitespaces)
        rule.trigger = Self.triggers[max(0, triggerPopup.indexOfSelectedItem)].make(cron.isEmpty ? "0 9 * * 1-5" : cron)
        let branch = branchField.stringValue.trimmingCharacters(in: .whitespaces)
        rule.branch = branch.isEmpty ? nil : BranchFilter(pattern: branch)
        rule.maxAttempts = Int(attemptsField.stringValue.trimmingCharacters(in: .whitespaces))
        for (action, popup) in autonomyPopups {
            rule.autonomy[action] = popup.titleOfSelectedItem.flatMap(AutonomyLevel.init(rawValue:))
        }
        rule.brief = briefView.string
        config.rules[i] = rule
        cronField.superview?.isHidden = triggerPopup.indexOfSelectedItem != 2
        tableView.reloadData(forRowIndexes: [i], columnIndexes: [0])
        onChange?(config)
    }

    func textDidChange(_ notification: Notification) { formChanged() }

    @objc private func addRule() {
        config.rules.append(AutomationRule(
            name: "rule-\(config.rules.count + 1)", trigger: .ciFailed,
            brief: "PR #{{pr}} on {{branch}} needs attention."))
        tableView.reloadData()
        tableView.selectRowIndexes([config.rules.count - 1], byExtendingSelection: false)
        renderForm()
        onChange?(config)
    }

    @objc private func removeRule() {
        guard let i = selected else { return }
        config.rules.remove(at: i)
        tableView.reloadData()
        if !config.rules.isEmpty {
            tableView.selectRowIndexes([min(i, config.rules.count - 1)], byExtendingSelection: false)
        }
        renderForm()
        onChange?(config)
    }

    // MARK: - Table

    func numberOfRows(in tableView: NSTableView) -> Int { config.rules.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let rule = config.rules[row]
        let name = NSTextField(labelWithString: rule.name)
        name.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        name.textColor = rule.enabled ? SettingsPalette.text : SettingsPalette.secondary
        name.lineBreakMode = .byTruncatingTail
        let sub = NSTextField(labelWithString: Self.triggerText(rule.trigger) + (rule.enabled ? "" : " · off"))
        sub.font = NSFont.systemFont(ofSize: 10)
        sub.textColor = SettingsPalette.secondary
        let stack = NSStackView(views: [name, sub])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 1
        return stack
    }

    func tableViewSelectionDidChange(_ notification: Notification) { renderForm() }
}

extension FirstMateRulesView: NSTextFieldDelegate {
    func controlTextDidChange(_ obj: Notification) { formChanged() }
}
