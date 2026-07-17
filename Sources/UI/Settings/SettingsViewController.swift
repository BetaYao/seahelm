import AppKit
import CoreImage

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
    private let wechatStatusLabel = NSTextField(labelWithString: "")
    private let wechatQRImageView = NSImageView()
    private let wechatQRHintLabel = NSTextField(labelWithString: "")
    private let wechatBindButton = NSButton()
    private let wechatUnbindButton = NSButton()
    private let wechatAutoConnectCheckbox = NSButton()

    /// Edited copy of the WeChat binding; committed to `config` on save.
    /// Carries `syncBuf`/`contextTokens` through so saving does not drop the
    /// long-poll cursor or the context tokens replies depend on.
    private var wechatDraft: WeChatConfig?
    private var wechatLoginService: WeChatLoginService?

    init(config: Config) {
        self.config = config
        self.workspacePaths = config.workspacePaths
        self.wechatDraft = config.wechat
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

        // Cache size
        let cacheLabel = NSTextField(labelWithString: "Terminal cache rows:")
        cacheLabel.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        cacheLabel.textColor = Theme.textSecondary
        cacheLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(cacheLabel)

        cacheSizeField.stringValue = "\(config.terminalRowCacheSize)"
        cacheSizeField.font = AppFont.mono(size: 12, weight: .regular)
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

            cacheLabel.topAnchor.constraint(equalTo: addButton.bottomAnchor, constant: 16),
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
        ruleTextView.font = AppFont.mono(size: 11, weight: .regular)
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

        let infoLabel = NSTextField(labelWithString: "WeCom smart bot persistent connection settings. Create a smart bot in the WeCom admin console to get a Bot ID and Secret.")
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
        wecomBotIdField.font = AppFont.mono(size: 12, weight: .regular)
        wecomBotIdField.stringValue = config.wecomBot?.botId ?? ""
        wecomBotIdField.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(wecomBotIdField)

        let secretLabel = NSTextField(labelWithString: "Secret:")
        secretLabel.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        secretLabel.textColor = Theme.textSecondary
        secretLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(secretLabel)

        wecomSecretField.placeholderString = "Auth secret"
        wecomSecretField.font = AppFont.mono(size: 12, weight: .regular)
        wecomSecretField.stringValue = config.wecomBot?.secret ?? ""
        wecomSecretField.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(wecomSecretField)

        let nameLabel = NSTextField(labelWithString: "Display name:")
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
        wecomAutoConnectCheckbox.title = "Connect automatically at launch"
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

        let infoLabel = NSTextField(labelWithString: "Personal WeChat iLink long-polling connection. Scan the QR code with WeChat on your phone to connect this Mac.")
        infoLabel.font = NSFont.systemFont(ofSize: 11)
        infoLabel.textColor = Theme.textSecondary
        infoLabel.lineBreakMode = .byWordWrapping
        infoLabel.maximumNumberOfLines = 2
        infoLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(infoLabel)

        wechatStatusLabel.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        wechatStatusLabel.lineBreakMode = .byTruncatingTail
        wechatStatusLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(wechatStatusLabel)

        wechatQRImageView.imageScaling = .scaleProportionallyUpOrDown
        wechatQRImageView.wantsLayer = true
        wechatQRImageView.layer?.backgroundColor = NSColor.white.cgColor
        wechatQRImageView.layer?.cornerRadius = Theme.cardCornerRadius
        wechatQRImageView.isHidden = true
        wechatQRImageView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(wechatQRImageView)

        wechatQRHintLabel.font = NSFont.systemFont(ofSize: 11)
        wechatQRHintLabel.textColor = Theme.textSecondary
        wechatQRHintLabel.alignment = .center
        wechatQRHintLabel.lineBreakMode = .byWordWrapping
        wechatQRHintLabel.maximumNumberOfLines = 2
        wechatQRHintLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(wechatQRHintLabel)

        wechatBindButton.bezelStyle = .rounded
        wechatBindButton.target = self
        wechatBindButton.action = #selector(wechatBindClicked)
        wechatBindButton.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(wechatBindButton)

        wechatUnbindButton.title = "Disconnect"
        wechatUnbindButton.bezelStyle = .rounded
        wechatUnbindButton.target = self
        wechatUnbindButton.action = #selector(wechatUnbindClicked)
        wechatUnbindButton.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(wechatUnbindButton)

        wechatAutoConnectCheckbox.setButtonType(.switch)
        wechatAutoConnectCheckbox.title = "Connect automatically at launch"
        wechatAutoConnectCheckbox.font = NSFont.systemFont(ofSize: 12)
        wechatAutoConnectCheckbox.state = (config.wechat?.resolvedAutoConnect ?? true) ? .on : .off
        wechatAutoConnectCheckbox.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(wechatAutoConnectCheckbox)

        NSLayoutConstraint.activate([
            infoLabel.topAnchor.constraint(equalTo: view.topAnchor, constant: 12),
            infoLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            infoLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),

            wechatStatusLabel.topAnchor.constraint(equalTo: infoLabel.bottomAnchor, constant: 16),
            wechatStatusLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            wechatStatusLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),

            wechatQRImageView.topAnchor.constraint(equalTo: wechatStatusLabel.bottomAnchor, constant: 12),
            wechatQRImageView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            wechatQRImageView.widthAnchor.constraint(equalToConstant: 160),
            wechatQRImageView.heightAnchor.constraint(equalToConstant: 160),

            wechatQRHintLabel.topAnchor.constraint(equalTo: wechatQRImageView.bottomAnchor, constant: 8),
            wechatQRHintLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            wechatQRHintLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),

            wechatBindButton.topAnchor.constraint(equalTo: wechatQRHintLabel.bottomAnchor, constant: 12),
            wechatBindButton.centerXAnchor.constraint(equalTo: view.centerXAnchor, constant: -50),

            wechatUnbindButton.centerYAnchor.constraint(equalTo: wechatBindButton.centerYAnchor),
            wechatUnbindButton.leadingAnchor.constraint(equalTo: wechatBindButton.trailingAnchor, constant: 8),

            wechatAutoConnectCheckbox.topAnchor.constraint(equalTo: wechatBindButton.bottomAnchor, constant: 16),
            wechatAutoConnectCheckbox.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
        ])

        refreshWeChatBindingUI()
        return view
    }

    /// Reflect `wechatDraft` in the tab. Called on load and after every bind change.
    private func refreshWeChatBindingUI() {
        let isLoggingIn = wechatLoginService != nil

        if isLoggingIn {
            wechatBindButton.title = "Cancel"
            wechatUnbindButton.isHidden = true
            wechatAutoConnectCheckbox.isEnabled = false
            return
        }

        wechatAutoConnectCheckbox.isEnabled = true
        wechatQRImageView.isHidden = true
        wechatQRHintLabel.stringValue = ""

        if let draft = wechatDraft, !draft.botToken.isEmpty {
            let account = draft.accountId.map { " (\($0))" } ?? ""
            wechatStatusLabel.stringValue = "Connected\(account)"
            wechatStatusLabel.textColor = Theme.textPrimary
            wechatBindButton.title = "Rescan"
            wechatUnbindButton.isHidden = false
        } else {
            wechatStatusLabel.stringValue = "Not connected"
            wechatStatusLabel.textColor = Theme.textSecondary
            wechatBindButton.title = "Scan to Connect"
            wechatUnbindButton.isHidden = true
        }
    }

    // MARK: - WeChat QR Login

    @objc private func wechatBindClicked() {
        if wechatLoginService != nil {
            cancelWeChatLogin()
            return
        }

        // Send any token we already hold so the server can recognise a re-bind.
        let existing = [wechatDraft?.botToken].compactMap { $0 }.filter { !$0.isEmpty }
        let service = WeChatLoginService(existingBotTokens: existing)
        wechatLoginService = service

        service.onEvent = { [weak self] event in
            self?.handleWeChatLoginEvent(event)
        }

        wechatStatusLabel.stringValue = "Requesting a QR code…"
        wechatStatusLabel.textColor = Theme.textSecondary
        wechatQRHintLabel.stringValue = ""
        refreshWeChatBindingUI()
        service.start()
    }

    @objc private func wechatUnbindClicked() {
        wechatDraft = nil
        refreshWeChatBindingUI()
    }

    private func cancelWeChatLogin() {
        wechatLoginService?.onEvent = nil
        wechatLoginService?.cancel()
        wechatLoginService = nil
        refreshWeChatBindingUI()
    }

    private func handleWeChatLoginEvent(_ event: WeChatLoginService.Event) {
        switch event {
        case .qrCode(let url):
            wechatQRImageView.image = Self.makeQRImage(from: url, size: 160)
            wechatQRImageView.isHidden = wechatQRImageView.image == nil
            wechatStatusLabel.stringValue = "Waiting for scan"
            wechatStatusLabel.textColor = Theme.textSecondary
            wechatQRHintLabel.stringValue = "Open WeChat on your phone and scan this code."

        case .scanned:
            wechatStatusLabel.stringValue = "Scanned — confirm on your phone"
            wechatQRHintLabel.stringValue = ""

        case .needVerifyCode(let retry):
            promptForWeChatVerifyCode(retry: retry)

        case .alreadyBound:
            wechatLoginService = nil
            refreshWeChatBindingUI()
            wechatQRHintLabel.stringValue = "This account is already connected to Seahelm."

        case .succeeded(let result):
            wechatLoginService = nil
            // A fresh binding: the old cursor and context tokens belong to the
            // previous account, so start clean rather than carrying them over.
            wechatDraft = WeChatConfig(
                botToken: result.botToken,
                accountId: result.accountId,
                baseUrl: result.baseUrl,
                autoConnect: wechatAutoConnectCheckbox.state == .on
            )
            refreshWeChatBindingUI()
            wechatQRHintLabel.stringValue = "Connected. Click Save to apply."

        case .failed(let message):
            wechatLoginService = nil
            refreshWeChatBindingUI()
            wechatStatusLabel.stringValue = message
            wechatStatusLabel.textColor = .systemRed
        }
    }

    private func promptForWeChatVerifyCode(retry: Bool) {
        guard let service = wechatLoginService, let window = view.window else { return }

        let alert = NSAlert()
        alert.messageText = retry ? "That code didn't match" : "Enter the pairing code"
        alert.informativeText = "Type the digits shown in WeChat on your phone."
        alert.addButton(withTitle: "Continue")
        alert.addButton(withTitle: "Cancel")

        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
        input.font = AppFont.mono(size: 13, weight: .regular)
        alert.accessoryView = input

        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            guard response == .alertFirstButtonReturn else {
                self.cancelWeChatLogin()
                return
            }
            let code = input.stringValue.trimmingCharacters(in: .whitespaces)
            guard !code.isEmpty else {
                self.promptForWeChatVerifyCode(retry: retry)
                return
            }
            service.submitVerifyCode(code)
        }
        // The sheet steals focus from the tab; put the caret in the field.
        DispatchQueue.main.async { window.makeFirstResponder(input) }
    }

    /// Render `string` as a QR code. Returns nil if the payload can't be encoded.
    private static func makeQRImage(from string: String, size: CGFloat) -> NSImage? {
        guard let data = string.data(using: .utf8),
              let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(data, forKey: "inputMessage")
        // Medium correction — enough redundancy for a screen without inflating density.
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage else { return nil }

        let scale = size / output.extent.width
        let scaled = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))

        let context = CIContext()
        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: size, height: size))
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

        // WeChat config — mutate the draft in place so the long-poll cursor and
        // cached context tokens survive a save.
        if var wechat = wechatDraft, !wechat.botToken.isEmpty {
            wechat.autoConnect = wechatAutoConnectCheckbox.state == .on
            config.wechat = wechat
        } else {
            config.wechat = nil
        }

        cancelWeChatLogin()
        config.save()
        settingsDelegate?.settingsDidUpdateConfig(self, config: config)
        dismiss(nil)
    }

    @objc private func cancelClicked() {
        cancelWeChatLogin()
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
        label.font = AppFont.mono(size: 11, weight: .regular)
        label.textColor = Theme.textPrimary
        label.lineBreakMode = .byTruncatingHead
        label.frame = NSRect(x: 4, y: 1, width: 500, height: 20)
        cell.addSubview(label)

        return cell
    }
}
