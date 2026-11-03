import AppKit

/// Settings ▸ First Mate: the switch, the user's default per action, the
/// standing orders, and each repo's rules.
///
/// The global part saves like every other setting. A repo's rules are a file in
/// that repo, written only by "Save to repo".
extension SettingsViewController {
    func buildFirstMateGroups() -> [NSView] {
        fm.enabled.state = config.autopilotEnabled ? .on : .off
        fm.paused.state = config.autopilotPaused ? .on : .off
        fm.enabled.target = self
        fm.enabled.action = #selector(firstMateGlobalChanged)
        fm.paused.target = self
        fm.paused.action = #selector(firstMateGlobalChanged)
        let defaults = AutomationConfig.defaults(overriding: config.autopilotAutonomy)
        var autonomyRows: [NSView] = []
        for action in AutopilotAction.allCases {
            let popup = NSPopUpButton()
            popup.addItems(withTitles: [AutonomyLevel.auto, .ask, .deny].map(\.rawValue))
            popup.selectItem(withTitle: defaults[action]?.rawValue ?? "ask")
            popup.target = self
            popup.action = #selector(firstMateGlobalChanged)
            fm.autonomy[action] = popup
            autonomyRows.append(SettingsRow.make(FirstMateRulesView.actionTitle(action),
                                                 subtitle: Self.autonomyHint(action), control: popup))
        }
        fm.agent.removeAllItems()
        for agent in FirstMatePane.agents {
            fm.agent.addItem(withTitle: agent.displayName)
            fm.agent.lastItem?.representedObject = agent.rawValue
        }
        let chosen = AgentType(rawValue: config.autopilotAgent) ?? .claudeCode
        fm.agent.selectItem(at: FirstMatePane.agents.firstIndex(of: chosen) ?? 0)
        fm.agent.target = self
        fm.agent.action = #selector(firstMateAgentChanged)
        fm.agentGuard.stringValue = FirstMatePane.guardDescription(chosen)
        fm.agentGuard.font = NSFont.systemFont(ofSize: 11)
        fm.agentGuard.textColor = SettingsPalette.secondary
        let open = SettingsControls.button("Open First Mate", target: self, action: #selector(openFirstMateClicked))
        let orders = SettingsControls.button("Edit standing orders…", target: self, action: #selector(editStandingOrdersClicked))

        fm.repoPopup.removeAllItems()
        for path in config.workspacePaths {
            fm.repoPopup.addItem(withTitle: URL(fileURLWithPath: path).lastPathComponent)
            fm.repoPopup.lastItem?.representedObject = path
        }
        fm.repoPopup.target = self
        fm.repoPopup.action = #selector(firstMateRepoChanged)
        for (field, placeholder) in [(fm.maxAgents, "no limit"), (fm.usage, "no limit"), (fm.quiet, "e.g. 23:00-08:00")] {
            field.placeholderString = placeholder
            field.target = self
            field.action = #selector(firstMateBudgetChanged)
            field.widthAnchor.constraint(equalToConstant: 160).isActive = true
        }
        fm.source.font = NSFont.systemFont(ofSize: 11)
        fm.source.textColor = SettingsPalette.secondary
        fm.source.maximumNumberOfLines = 3
        fm.source.lineBreakMode = .byWordWrapping
        fm.rules.onChange = { [weak self] config in
            self?.fm.loaded = config
            self?.setFirstMateDirty(true)
        }
        fm.save = SettingsControls.button("Save to repo", target: self, action: #selector(saveFirstMateRules))
        let openFile = SettingsControls.button("Open file", target: self, action: #selector(openFirstMateRulesFile))
        let builtIn = SettingsControls.button("Use built-in rules", target: self, action: #selector(useBuiltInFirstMateRules))
        loadFirstMateRepo()

        return [
            SettingsGroupView(title: "First Mate", rows: [
                SettingsRow.make("Enabled", subtitle: "An agent session of its own, woken by your repos' rules: CI going red, PRs merging.", control: fm.enabled),
                SettingsRow.make("Paused", subtitle: "Events are still recorded; nothing is handed to First Mate until you resume.", control: fm.paused),
                SettingsRow.make("Agent", subtitle: "Changing it restarts First Mate's session as the new agent.", control: fm.agent),
                SettingsRow.stacked(nil, content: fm.agentGuard),
                SettingsRow.actions([open, orders]),
            ]),
            SettingsGroupView(title: "What it may do on its own", rows: autonomyRows + [
                SettingsRow.stacked(nil, content: SettingsRow.makeHint(
                    "auto: it just does it. ask: you approve a card (island, Telegram) first. deny: never. "
                    + "A repo's rule can be stricter or looser for the events it handles; "
                    + "talking to First Mate never loosens a rule.")),
            ]),
            SettingsGroupView(title: "Rules", rows: [
                SettingsRow.make("Project", control: fm.repoPopup),
                SettingsRow.stacked(nil, content: fm.source),
                SettingsRow.stacked(nil, content: fm.rules),
                SettingsRow.make("Max agents it starts", subtitle: "At once, in this project.", control: fm.maxAgents),
                SettingsRow.make("Pause above usage %", subtitle: "Claude's or Codex's 5-hour window: no new agents past this.", control: fm.usage),
                SettingsRow.make("Quiet hours", subtitle: "Events wait until these end.", control: fm.quiet),
                SettingsRow.actions([fm.save!], leading: [openFile, builtIn]),
                SettingsRow.stacked(nil, content: SettingsRow.makeHint(
                    "Saved as .seahelm/automations.yml in the project — commit it so the rules travel with the repo. "
                    + "Saving rewrites the file: comments written by hand are not kept.")),
            ]),
        ]
    }

    private static func autonomyHint(_ action: AutopilotAction) -> String {
        switch action {
        case .messagePane: return "Tell a worktree's agent what broke."
        case .startAgent: return "Open a new worktree with an agent on a task."
        case .deleteWorktree: return "Remove a worktree that is done with (its usual safety checks apply)."
        }
    }

    func applyFirstMateGlobal() {
        guard pages["firstMate"] != nil else { return }
        config.autopilotEnabled = fm.enabled.state == .on
        config.autopilotPaused = fm.paused.state == .on
        var raw: [String: String] = [:]
        for (action, popup) in fm.autonomy {
            if let title = popup.titleOfSelectedItem, AutomationConfig.defaultAutonomy[action]?.rawValue != title {
                raw[action.rawValue] = title
            }
        }
        config.autopilotAutonomy = raw
        if let raw = fm.agent.selectedItem?.representedObject as? String { config.autopilotAgent = raw }
    }

    @objc private func firstMateAgentChanged() {
        if let raw = fm.agent.selectedItem?.representedObject as? String, let agent = AgentType(rawValue: raw) {
            fm.agentGuard.stringValue = FirstMatePane.guardDescription(agent)
        }
        applyChanges()
    }

    @objc private func firstMateGlobalChanged() { applyChanges() }

    @objc private func openFirstMateClicked() { settingsDelegate?.settingsOpenFirstMate(self) }

    @objc private func editStandingOrdersClicked() {
        FirstMatePane.provision()
        NSWorkspace.shared.open(URL(fileURLWithPath: FirstMatePane.standingOrdersPath))
    }

    // MARK: Per repo

    private var selectedRepo: String? { fm.repoPopup.selectedItem?.representedObject as? String }

    private func loadFirstMateRepo() {
        guard let repo = selectedRepo else {
            fm.source.stringValue = "Add a project in General to give First Mate rules."
            return
        }
        let loaded = AutomationConfig.load(repoPath: repo)
        let config: AutomationConfig
        if let error = loaded.error {
            config = AutomationConfig(rules: [])
            fm.source.stringValue = "This project's .seahelm/automations.yml does not parse, so First Mate ignores the project: \(error)"
            fm.source.textColor = NSColor.systemRed
        } else {
            config = loaded.config ?? .builtIn
            fm.source.stringValue = AutomationConfig.hasFile(repoPath: repo)
                ? "From this project's .seahelm/automations.yml."
                : "No .seahelm/automations.yml — the built-in rules apply. Saving writes them into the project."
            fm.source.textColor = SettingsPalette.secondary
        }
        fm.loaded = config
        fm.rules.load(config)
        fm.maxAgents.stringValue = config.settings.maxConcurrentAgents.map(String.init) ?? ""
        fm.usage.stringValue = config.settings.pauseAboveUsage.map { String(Int($0)) } ?? ""
        fm.quiet.stringValue = config.settings.quietHours?.text ?? ""
        setFirstMateDirty(false)
    }

    @objc private func firstMateRepoChanged() {
        if fm.dirty, !confirm("Discard unsaved rule changes?", "Your edits to the previous project's rules are not saved.") {
            return
        }
        loadFirstMateRepo()
    }

    @objc private func firstMateBudgetChanged() {
        var config = fm.loaded
        config.settings.maxConcurrentAgents = Int(fm.maxAgents.stringValue.trimmingCharacters(in: .whitespaces))
        config.settings.pauseAboveUsage = Double(fm.usage.stringValue.trimmingCharacters(in: .whitespaces))
        let quiet = fm.quiet.stringValue.trimmingCharacters(in: .whitespaces)
        config.settings.quietHours = quiet.isEmpty ? nil : QuietHours(quiet)
        fm.loaded = config
        setFirstMateDirty(true)
    }

    @objc private func saveFirstMateRules() {
        guard let repo = selectedRepo else { return }
        firstMateBudgetChanged()
        var config = fm.loaded
        config.rules = fm.rules.config.rules
        do {
            try config.write(repoPath: repo)
            fm.source.stringValue = "Saved to .seahelm/automations.yml — commit it so the rules travel with the repo."
            fm.source.textColor = SettingsPalette.secondary
            setFirstMateDirty(false)
        } catch {
            fm.source.stringValue = "Could not save: \(error.localizedDescription)"
            fm.source.textColor = NSColor.systemRed
        }
    }

    @objc private func openFirstMateRulesFile() {
        guard let repo = selectedRepo else { return }
        let path = (repo as NSString).appendingPathComponent(AutomationConfig.relativePath)
        if !AutomationConfig.hasFile(repoPath: repo) { saveFirstMateRules() }
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    @objc private func useBuiltInFirstMateRules() {
        guard let repo = selectedRepo, AutomationConfig.hasFile(repoPath: repo) else { return }
        guard confirm("Remove this project's rules?",
                      "Deletes .seahelm/automations.yml; the built-in rules apply again.") else { return }
        try? FileManager.default.removeItem(atPath: (repo as NSString).appendingPathComponent(AutomationConfig.relativePath))
        loadFirstMateRepo()
    }

    private func setFirstMateDirty(_ dirty: Bool) {
        fm.dirty = dirty
        fm.save?.title = dirty ? "Save to repo •" : "Save to repo"
        fm.save?.isEnabled = dirty
    }

    private func confirm(_ title: String, _ text: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }
}

/// The First Mate page's controls, kept together.
final class FirstMateSettingsControls {
    let enabled = NSSwitch()
    let paused = NSSwitch()
    let agent = NSPopUpButton()
    let agentGuard = NSTextField(wrappingLabelWithString: "")
    var autonomy: [AutopilotAction: NSPopUpButton] = [:]
    let repoPopup = NSPopUpButton()
    let source = NSTextField(wrappingLabelWithString: "")
    let rules = FirstMateRulesView(config: AutomationConfig(rules: []))
    let maxAgents = SettingsTextField()
    let usage = SettingsTextField()
    let quiet = SettingsTextField()
    var save: NSButton?
    var loaded = AutomationConfig(rules: [])
    var dirty = false
}
