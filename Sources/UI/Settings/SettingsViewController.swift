import AppKit

protocol SettingsDelegate: AnyObject {
    func settingsDidUpdateConfig(_ settings: SettingsViewController, config: Config)
}

/// Settings window with tabs: General, Agent Detection, WeCom Bot.
class SettingsViewController: NSViewController {
    weak var settingsDelegate: SettingsDelegate?

    private var config: Config
    private let tabView = NSTabView()

    // General tab controls
    private let pathListView = NSTableView()
    private let pathScrollView = NSScrollView()
    private var workspacePaths: [String] = []
    private let addButton = NSButton()
    private let removeButton = NSButton()
    private let backendPopup = NSPopUpButton()
    private let cacheSizeField = NSTextField()

    // Agent Detection tab controls
    private let agentTableView = NSTableView()
    private let agentScrollView = NSScrollView()
    private let ruleTextView = NSTextView()
    private let ruleScrollView = NSScrollView()

    // WeCom Bot tab controls
    private let wecomBotIdField = NSTextField()
    private let wecomSecretField = NSSecureTextField()
    private let wecomNameField = NSTextField()
    private let wecomAutoConnectCheckbox = NSButton()

    // WeChat tab controls
    private let wechatTokenField = NSSecureTextField()
    private let wechatAutoConnectCheckbox = NSButton()

    init(config: Config) {
        self.config = config
        self.workspacePaths = config.workspacePaths
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not supported")
    }

    override func loadView() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 560, height: 420))
        container.wantsLayer = true
        container.setAccessibilityIdentifier("settings.sheet")
        container.setAccessibilityElement(true)
        container.setAccessibilityRole(.group)
        self.view = container

        tabView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(tabView)

        // Tab 1: General
        let generalTab = NSTabViewItem(identifier: "general")
        generalTab.label = "General"
        generalTab.view = buildGeneralTab()
        tabView.addTabViewItem(generalTab)

        // Tab 2: Agent Detection
        let agentTab = NSTabViewItem(identifier: "agents")
        agentTab.label = "Agent Detection"
        agentTab.view = buildSailorTab()
        tabView.addTabViewItem(agentTab)

        // Tab 3: WeCom Bot
        let wecomTab = NSTabViewItem(identifier: "wecom")
        wecomTab.label = "WeCom Bot"
        wecomTab.view = buildWeComTab()
        tabView.addTabViewItem(wecomTab)

        // Tab 4: WeChat
        let wechatTab = NSTabViewItem(identifier: "wechat")
        wechatTab.label = "WeChat"
        wechatTab.view = buildWeChatTab()
        tabView.addTabViewItem(wechatTab)

        // Buttons
        let saveButton = NSButton(title: "Save", target: self, action: #selector(saveClicked))
        saveButton.bezelStyle = .rounded
        saveButton.keyEquivalent = "\r"
        saveButton.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(saveButton)

        let cancelButton = NSButton(title: "Cancel", target: self, action: #selector(cancelClicked))
        cancelButton.bezelStyle = .rounded
        cancelButton.keyEquivalent = "\u{1b}"
        cancelButton.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(cancelButton)

        NSLayoutConstraint.activate([
            tabView.topAnchor.constraint(equalTo: container.topAnchor, constant: 8),
            tabView.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            tabView.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            tabView.bottomAnchor.constraint(equalTo: saveButton.topAnchor, constant: -12),

            saveButton.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
            saveButton.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -12),

            cancelButton.trailingAnchor.constraint(equalTo: saveButton.leadingAnchor, constant: -8),
            cancelButton.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -12),
        ])
    }

    // MARK: - General Tab

    private func buildGeneralTab() -> NSView {
        let view = NSView()

        // Workspace paths section
        let pathsLabel = NSTextField(labelWithString: "Workspace Paths:")
        pathsLabel.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        pathsLabel.textColor = Theme.textPrimary
        pathsLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(pathsLabel)

        // Path list
        pathScrollView.hasVerticalScroller = true
        pathScrollView.borderType = .bezelBorder
        pathScrollView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(pathScrollView)

        pathListView.headerView = nil
        pathListView.rowHeight = 22
        pathListView.delegate = self
        pathListView.dataSource = self
        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("path"))
        col.resizingMask = .autoresizingMask
        pathListView.addTableColumn(col)
        pathListView.setAccessibilityIdentifier("settings.workspacePaths")
        pathScrollView.documentView = pathListView

        // Add/Remove buttons
        addButton.title = "+"
        addButton.bezelStyle = .rounded
        addButton.target = self
        addButton.action = #selector(addPathClicked)
        addButton.setAccessibilityIdentifier("settings.addPath")
        addButton.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(addButton)

        removeButton.title = "−"
        removeButton.bezelStyle = .rounded
        removeButton.target = self
        removeButton.action = #selector(removePathClicked)
        removeButton.setAccessibilityIdentifier("settings.removePath")
        removeButton.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(removeButton)

        // Backend
        let backendLabel = NSTextField(labelWithString: "Backend:")
        backendLabel.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        backendLabel.textColor = Theme.textSecondary
        backendLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(backendLabel)

        backendPopup.removeAllItems()
        backendPopup.addItems(withTitles: ["zmx"])
        backendPopup.selectItem(withTitle: config.backend)
        if backendPopup.indexOfSelectedItem < 0 {
            backendPopup.selectItem(withTitle: "zmx")
        }
        backendPopup.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(backendPopup)

        // Cache size
        let cacheLabel = NSTextField(labelWithString: "Terminal cache rows:")
        cacheLabel.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        cacheLabel.textColor = Theme.textSecondary
        cacheLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(cacheLabel)

        cacheSizeField.stringValue = "\(config.terminalRowCacheSize)"
        cacheSizeField.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        cacheSizeField.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(cacheSizeField)

        NSLayoutConstraint.activate([
            pathsLabel.topAnchor.constraint(equalTo: view.topAnchor, constant: 12),
            pathsLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),

            pathScrollView.topAnchor.constraint(equalTo: pathsLabel.bottomAnchor, constant: 6),
            pathScrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            pathScrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            pathScrollView.heightAnchor.constraint(equalToConstant: 150),

            addButton.topAnchor.constraint(equalTo: pathScrollView.bottomAnchor, constant: 4),
            addButton.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            addButton.widthAnchor.constraint(equalToConstant: 32),

            removeButton.topAnchor.constraint(equalTo: pathScrollView.bottomAnchor, constant: 4),
            removeButton.leadingAnchor.constraint(equalTo: addButton.trailingAnchor, constant: 4),
            removeButton.widthAnchor.constraint(equalToConstant: 32),

            backendLabel.topAnchor.constraint(equalTo: addButton.bottomAnchor, constant: 16),
            backendLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            backendLabel.widthAnchor.constraint(equalToConstant: 140),

            backendPopup.centerYAnchor.constraint(equalTo: backendLabel.centerYAnchor),
            backendPopup.leadingAnchor.constraint(equalTo: backendLabel.trailingAnchor, constant: 8),
            backendPopup.widthAnchor.constraint(equalToConstant: 120),

            cacheLabel.topAnchor.constraint(equalTo: backendLabel.bottomAnchor, constant: 12),
            cacheLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            cacheLabel.widthAnchor.constraint(equalToConstant: 140),

            cacheSizeField.centerYAnchor.constraint(equalTo: cacheLabel.centerYAnchor),
            cacheSizeField.leadingAnchor.constraint(equalTo: cacheLabel.trailingAnchor, constant: 8),
            cacheSizeField.widthAnchor.constraint(equalToConstant: 80),
        ])

        return view
    }

    // MARK: - Agent Detection Tab

    private func buildSailorTab() -> NSView {
        let view = NSView()

        let infoLabel = NSTextField(labelWithString: "Agent detection rules (JSON). Edit and save to apply.")
        infoLabel.font = NSFont.systemFont(ofSize: 11)
        infoLabel.textColor = Theme.textSecondary
        infoLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(infoLabel)

        ruleScrollView.hasVerticalScroller = true
        ruleScrollView.borderType = .bezelBorder
        ruleScrollView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(ruleScrollView)

        ruleTextView.isEditable = true
        ruleTextView.isSelectable = true
        ruleTextView.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        ruleTextView.textContainerInset = NSSize(width: 6, height: 6)
        ruleTextView.isAutomaticQuoteSubstitutionEnabled = false
        ruleTextView.isAutomaticDashSubstitutionEnabled = false
        ruleTextView.isAutomaticTextReplacementEnabled = false
        ruleScrollView.documentView = ruleTextView

        // Populate with current agent config as pretty JSON
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(config.agentDetect),
           let json = String(data: data, encoding: .utf8) {
            ruleTextView.string = json
        }

        NSLayoutConstraint.activate([
            infoLabel.topAnchor.constraint(equalTo: view.topAnchor, constant: 12),
            infoLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),

            ruleScrollView.topAnchor.constraint(equalTo: infoLabel.bottomAnchor, constant: 6),
            ruleScrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            ruleScrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            ruleScrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -12),
        ])

        return view
    }

    // MARK: - WeCom Bot Tab

    private func buildWeComTab() -> NSView {
        let view = NSView()

        let infoLabel = NSTextField(labelWithString: "企业微信智能机器人长连接配置。需要在企业微信后台创建智能机器人获取 Bot ID 和 Secret。")
        infoLabel.font = NSFont.systemFont(ofSize: 11)
        infoLabel.textColor = Theme.textSecondary
        infoLabel.lineBreakMode = .byWordWrapping
        infoLabel.maximumNumberOfLines = 2
        infoLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(infoLabel)

        let botIdLabel = NSTextField(labelWithString: "Bot ID:")
        botIdLabel.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        botIdLabel.textColor = Theme.textSecondary
        botIdLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(botIdLabel)

        wecomBotIdField.placeholderString = "aib-xxxxxxxx"
        wecomBotIdField.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        wecomBotIdField.stringValue = config.wecomBot?.botId ?? ""
        wecomBotIdField.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(wecomBotIdField)

        let secretLabel = NSTextField(labelWithString: "Secret:")
        secretLabel.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        secretLabel.textColor = Theme.textSecondary
        secretLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(secretLabel)

        wecomSecretField.placeholderString = "认证密钥"
        wecomSecretField.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        wecomSecretField.stringValue = config.wecomBot?.secret ?? ""
        wecomSecretField.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(wecomSecretField)

        let nameLabel = NSTextField(labelWithString: "显示名称:")
        nameLabel.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        nameLabel.textColor = Theme.textSecondary
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(nameLabel)

        wecomNameField.placeholderString = "Seahelm Bot"
        wecomNameField.font = NSFont.systemFont(ofSize: 12, weight: .regular)
        wecomNameField.stringValue = config.wecomBot?.name ?? ""
        wecomNameField.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(wecomNameField)

        wecomAutoConnectCheckbox.setButtonType(.switch)
        wecomAutoConnectCheckbox.title = "启动时自动连接"
        wecomAutoConnectCheckbox.font = NSFont.systemFont(ofSize: 12)
        wecomAutoConnectCheckbox.state = (config.wecomBot?.resolvedAutoConnect ?? true) ? .on : .off
        wecomAutoConnectCheckbox.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(wecomAutoConnectCheckbox)

        let labelWidth: CGFloat = 90

        NSLayoutConstraint.activate([
            infoLabel.topAnchor.constraint(equalTo: view.topAnchor, constant: 12),
            infoLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            infoLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),

            botIdLabel.topAnchor.constraint(equalTo: infoLabel.bottomAnchor, constant: 20),
            botIdLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            botIdLabel.widthAnchor.constraint(equalToConstant: labelWidth),

            wecomBotIdField.centerYAnchor.constraint(equalTo: botIdLabel.centerYAnchor),
            wecomBotIdField.leadingAnchor.constraint(equalTo: botIdLabel.trailingAnchor, constant: 8),
            wecomBotIdField.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),

            secretLabel.topAnchor.constraint(equalTo: botIdLabel.bottomAnchor, constant: 16),
            secretLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            secretLabel.widthAnchor.constraint(equalToConstant: labelWidth),

            wecomSecretField.centerYAnchor.constraint(equalTo: secretLabel.centerYAnchor),
            wecomSecretField.leadingAnchor.constraint(equalTo: secretLabel.trailingAnchor, constant: 8),
            wecomSecretField.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),

            nameLabel.topAnchor.constraint(equalTo: secretLabel.bottomAnchor, constant: 16),
            nameLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            nameLabel.widthAnchor.constraint(equalToConstant: labelWidth),

            wecomNameField.centerYAnchor.constraint(equalTo: nameLabel.centerYAnchor),
            wecomNameField.leadingAnchor.constraint(equalTo: nameLabel.trailingAnchor, constant: 8),
            wecomNameField.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),

            wecomAutoConnectCheckbox.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 20),
            wecomAutoConnectCheckbox.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
        ])

        return view
    }

    // MARK: - WeChat Tab

    private func buildWeChatTab() -> NSView {
        let view = NSView()

        let infoLabel = NSTextField(labelWithString: "微信个人号 iLink 长轮询连接。需通过 QR 码扫码获取 Bot Token。")
        infoLabel.font = NSFont.systemFont(ofSize: 11)
        infoLabel.textColor = Theme.textSecondary
        infoLabel.lineBreakMode = .byWordWrapping
        infoLabel.maximumNumberOfLines = 2
        infoLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(infoLabel)

        let tokenLabel = NSTextField(labelWithString: "Bot Token:")
        tokenLabel.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        tokenLabel.textColor = Theme.textSecondary
        tokenLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(tokenLabel)

        wechatTokenField.placeholderString = "QR 扫码获取的 bot_token"
        wechatTokenField.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        wechatTokenField.stringValue = config.wechat?.botToken ?? ""
        wechatTokenField.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(wechatTokenField)

        wechatAutoConnectCheckbox.setButtonType(.switch)
        wechatAutoConnectCheckbox.title = "启动时自动连接"
        wechatAutoConnectCheckbox.font = NSFont.systemFont(ofSize: 12)
        wechatAutoConnectCheckbox.state = (config.wechat?.resolvedAutoConnect ?? true) ? .on : .off
        wechatAutoConnectCheckbox.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(wechatAutoConnectCheckbox)

        let labelWidth: CGFloat = 90

        NSLayoutConstraint.activate([
            infoLabel.topAnchor.constraint(equalTo: view.topAnchor, constant: 12),
            infoLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            infoLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),

            tokenLabel.topAnchor.constraint(equalTo: infoLabel.bottomAnchor, constant: 20),
            tokenLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            tokenLabel.widthAnchor.constraint(equalToConstant: labelWidth),

            wechatTokenField.centerYAnchor.constraint(equalTo: tokenLabel.centerYAnchor),
            wechatTokenField.leadingAnchor.constraint(equalTo: tokenLabel.trailingAnchor, constant: 8),
            wechatTokenField.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),

            wechatAutoConnectCheckbox.topAnchor.constraint(equalTo: tokenLabel.bottomAnchor, constant: 20),
            wechatAutoConnectCheckbox.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
        ])

        return view
    }

    // MARK: - Actions

    @objc private func addPathClicked() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.message = "Select workspace directories"

        panel.beginSheetModal(for: view.window!) { [weak self] response in
            guard response == .OK, let self else { return }
            for url in panel.urls {
                let path = url.path
                if !self.workspacePaths.contains(path) {
                    self.workspacePaths.append(path)
                }
            }
            self.pathListView.reloadData()
        }
    }

    @objc private func removePathClicked() {
        let row = pathListView.selectedRow
        guard row >= 0, row < workspacePaths.count else { return }
        workspacePaths.remove(at: row)
        pathListView.reloadData()
    }

    @objc private func saveClicked() {
        // Update config from UI
        config.workspacePaths = workspacePaths
        config.backend = backendPopup.titleOfSelectedItem ?? "zmx"
        config.terminalRowCacheSize = Int(cacheSizeField.stringValue) ?? 200

        // Parse agent detection JSON
        let jsonString = ruleTextView.string
        if let data = jsonString.data(using: .utf8),
           let agentConfig = try? JSONDecoder().decode(SailorDetectConfig.self, from: data) {
            config.agentDetect = agentConfig
        }

        // WeCom Bot config
        let botId = wecomBotIdField.stringValue.trimmingCharacters(in: .whitespaces)
        let secret = wecomSecretField.stringValue.trimmingCharacters(in: .whitespaces)
        if !botId.isEmpty && !secret.isEmpty {
            let name = wecomNameField.stringValue.trimmingCharacters(in: .whitespaces)
            config.wecomBot = WeComBotConfig(
                botId: botId,
                secret: secret,
                name: name.isEmpty ? nil : name,
                autoConnect: wecomAutoConnectCheckbox.state == .on
            )
        } else {
            config.wecomBot = nil
        }

        // WeChat config
        let wechatToken = wechatTokenField.stringValue.trimmingCharacters(in: .whitespaces)
        if !wechatToken.isEmpty {
            config.wechat = WeChatConfig(
                botToken: wechatToken,
                autoConnect: wechatAutoConnectCheckbox.state == .on
            )
        } else {
            config.wechat = nil
        }

        config.save()
        settingsDelegate?.settingsDidUpdateConfig(self, config: config)
        dismiss(nil)
    }

    @objc private func cancelClicked() {
        dismiss(nil)
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
        label.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        label.textColor = Theme.textPrimary
        label.lineBreakMode = .byTruncatingHead
        label.frame = NSRect(x: 4, y: 1, width: 500, height: 20)
        cell.addSubview(label)

        return cell
    }
}
