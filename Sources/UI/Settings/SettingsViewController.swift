import AppKit
import CoreImage

protocol SettingsDelegate: AnyObject {
    func settingsDidUpdateConfig(_ settings: SettingsViewController, config: Config)

    /// Mint (if needed) and persist the pairing secret on the *live* config, and
    /// hand back what the QR needs. Settings edits a copy of the config, and a
    /// secret minted into a copy would be lost or clobbered — so the owner of the
    /// live config does it, exactly as the standalone pairing window does.
    func settingsPairingContext(_ settings: SettingsViewController) -> (secret: Data, mqtt: MqttConfig)?

    /// A short code was minted, so the live MQTT channel can arm its responder.
    func settings(_ settings: SettingsViewController, didMintShortCode code: String, ttl: TimeInterval)

    /// Live panes, so a rule's target is picked from a project → worktree →
    /// pane cascade of what actually exists rather than typed from memory.
    func settingsPaneTargets(_ settings: SettingsViewController) -> [PaneSnapshot]

    /// Sessions the running app has panes attached to — flagged in the monitor so
    /// a kill that would take out a live agent is at least an informed one.
    func settingsActiveSessionNames(_ settings: SettingsViewController) -> Set<String>
    func settings(_ settings: SettingsViewController, connectGmailAccount email: String)
}

/// Optional halves of the protocol: only the main window can answer them, and
/// tests conform with just the config callback.
extension SettingsDelegate {
    func settingsPairingContext(_ settings: SettingsViewController) -> (secret: Data, mqtt: MqttConfig)? { nil }
    func settings(_ settings: SettingsViewController, didMintShortCode code: String, ttl: TimeInterval) {}
    func settingsActiveSessionNames(_ settings: SettingsViewController) -> Set<String> { [] }
    func settingsPaneTargets(_ settings: SettingsViewController) -> [PaneSnapshot] { [] }
    func settings(_ settings: SettingsViewController, connectGmailAccount email: String) {}
}

/// Settings, as a sidebar of pages built from `SettingsChrome` groups.
///
/// Pages are built on first visit and cached: the session monitor shells out to
/// `zmx list` and the pairing page mints a secret, and neither should happen
/// just because someone opened Settings to change a path.
class SettingsViewController: NSViewController {
    weak var settingsDelegate: SettingsDelegate?

    private var config: Config

    // Sidebar / page host
    private let sidebar = SettingsSidebarView(items: [
        .init(id: "general", title: "General", symbol: "gearshape",
              keywords: ["projects", "paths", "repo", "scrollback", "cache", "terminal",
                         "copy", "select", "clipboard", "ghostty"]),
        .init(id: "agents", title: "Agents", symbol: "bolt.horizontal",
              keywords: ["detection", "rules", "status", "claude", "codex", "json"]),
        .init(id: "imessage", title: "iMessage", symbol: "message",
              keywords: ["messages", "sms", "phone", "prefix", "sea", "helm",
                         "full disk access", "permission", "bridge"]),
        .init(id: "gmail", title: "Gmail", symbol: "envelope",
              keywords: ["email", "mail", "oauth", "google", "alias"]),
        .init(id: "pairing", title: "Pairing", symbol: "qrcode",
              keywords: ["qr", "remote", "watch", "mqtt", "code"]),
        .init(id: "sessions", title: "Sessions", symbol: "rectangle.stack",
              keywords: ["zmx", "cleanup", "kill", "detached", "orphan"]),
    ])
    private let contentScroll = NSScrollView()
    private var pages: [String: NSView] = [:]
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
    private lazy var revealGhosttyConfButton = SettingsControls.button(
        "Reveal ghostty.conf", target: self, action: #selector(revealGhosttyConfClicked))

    // Agent Detection tab controls
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
    private var wechatDraft: WeChatConfig?
    private var wechatLoginService: WeChatLoginService?

    // iMessage tab controls
    private let imessageHandlesView = NSTextView()
    private let imessageHandlesScrollView = NSScrollView()
    private let imessageDefaultRecipientField = SettingsTextField()
    private let imessageCommandPrefixField = SettingsTextField()
    private let imessageReplyPrefixField = SettingsTextField()
    private lazy var imessageAutoConnectToggle = SettingsControls.toggle(
        on: config.imessage?.resolvedAutoConnect ?? true, target: self, action: #selector(controlChanged))
    private let imessagePermissionLabel = NSTextField(labelWithString: "")
    private lazy var imessageRulesView = IMessageRulesView(rules: config.imessage?.resolvedRules ?? [])
    private let gmailAccountField = SettingsTextField()
    private let gmailAliasLabel = NSTextField(labelWithString: "")
    private let gmailAllowedSendersField = SettingsTextField()
    private let gmailStatusLabel = NSTextField(labelWithString: "Not connected")
    private lazy var gmailEnabledToggle = SettingsControls.toggle(on: config.gmailMail?.enabled ?? false, target: self, action: #selector(controlChanged))

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
        // Content clears the transparent titlebar the traffic lights float in.
        contentScroll.contentInsets = NSEdgeInsets(top: SettingsChrome.titlebarInset,
                                                   left: 0, bottom: 0, right: 0)
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

        // Revisiting shows what zmx reports *now*, not what it reported when the
        // page was first built.
        if id == "sessions" {
            sessionMonitor.activeSessionNames = settingsDelegate?.settingsActiveSessionNames(self) ?? []
            sessionMonitor.reload()
        }
    }

    private func buildPage(_ id: String) -> NSView {
        switch id {
        case "agents":   return makePage(buildAgentGroups())
        case "imessage": return makePage(buildIMessageGroups())
        case "gmail":    return makePage(buildGmailGroups())
        case "pairing":  return makePage(buildPairingGroups())
        case "sessions": return makePage(buildSessionGroups())
        default:         return makePage(buildGeneralGroups())
        }
    }

    private func buildGmailGroups() -> [NSView] {
        gmailAccountField.stringValue = config.gmailMail?.accountEmail ?? ""
        gmailAccountField.placeholderString = "you@gmail.com"
        gmailAccountField.target = self
        gmailAccountField.action = #selector(gmailAccountChanged)
        gmailAliasLabel.stringValue = config.gmailMail?.derivedInboundAlias ?? "Enter an account to see the alias"
        gmailAliasLabel.textColor = SettingsPalette.secondary
        if let account = config.gmailMail?.accountEmail,
           (try? GmailOAuthCredentialStore().load(accountEmail: account)) != nil {
            gmailStatusLabel.stringValue = "Connected. Gmail credentials are stored in Keychain."
        } else {
            gmailStatusLabel.stringValue = "Not connected"
        }
        gmailAllowedSendersField.stringValue = (config.gmailMail?.allowedSenders ?? []).joined(separator: ", ")
        gmailAllowedSendersField.placeholderString = "work@example.com, phone@example.com"
        gmailAllowedSendersField.target = self
        gmailAllowedSendersField.action = #selector(controlChanged)
        let connect = SettingsControls.button("Connect Gmail", target: self, action: #selector(connectGmailClicked))
        return [
            SettingsGroupView(title: "Gmail", rows: [
                SettingsRow.make("Google account", subtitle: "The mailbox Seahelm reads, and always allowed to command it.", control: gmailAccountField),
                SettingsRow.make("Inbound alias", subtitle: "Commands must be addressed here — ordinary mail to your account is ignored.", control: gmailAliasLabel),
                SettingsRow.make("Also accept from", subtitle: "Other addresses allowed to command Seahelm, comma separated. Accepted only when Google's SPF/DKIM check passes, since a From header can be forged.", control: gmailAllowedSendersField),
                SettingsRow.make("Enable mail", subtitle: "Poll only while Seahelm is running. Use a configured project alias to route mail.", control: gmailEnabledToggle),
                SettingsRow.actions([connect]),
                SettingsRow.stacked(nil, content: gmailStatusLabel),
            ]),
        ]
    }

    @objc private func gmailAccountChanged() {
        let email = GmailMailConfig.normalizeEmail(gmailAccountField.stringValue)
        gmailAliasLabel.stringValue = GmailMailConfig(accountEmail: email).derivedInboundAlias
        applyChanges()
    }

    @objc private func connectGmailClicked() {
        let email = GmailMailConfig.normalizeEmail(gmailAccountField.stringValue)
        guard GmailMailConfig.isEmail(email) else { gmailStatusLabel.stringValue = "Enter a valid Gmail address."; return }
        gmailStatusLabel.stringValue = "Opening Google sign-in…"
        settingsDelegate?.settings(self, connectGmailAccount: email)
    }

    func setGmailConnectionStatus(_ text: String) {
        gmailStatusLabel.stringValue = text
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

    // MARK: - iMessage

    private func buildIMessageGroups() -> [NSView] {
        let cfg = config.imessage

        imessageHandlesView.font = AppFont.mono(size: 12, weight: .regular)
        imessageHandlesView.isRichText = false
        imessageHandlesView.isAutomaticQuoteSubstitutionEnabled = false
        imessageHandlesView.string = (cfg?.allowedHandles ?? []).joined(separator: "\n")
        imessageHandlesView.setAccessibilityIdentifier("settings.imessage.handles")
        imessageHandlesView.drawsBackground = false
        imessageHandlesView.textColor = SettingsPalette.text
        imessageHandlesView.textContainerInset = NSSize(width: 6, height: 6)
        imessageHandlesView.delegate = self
        imessageHandlesScrollView.hasVerticalScroller = true
        imessageHandlesScrollView.borderType = .noBorder
        imessageHandlesScrollView.drawsBackground = false
        imessageHandlesScrollView.documentView = imessageHandlesView
        imessageHandlesScrollView.translatesAutoresizingMaskIntoConstraints = false

        imessageDefaultRecipientField.placeholderString = "First allowed sender"
        imessageDefaultRecipientField.font = AppFont.mono(size: 12, weight: .regular)
        imessageDefaultRecipientField.stringValue = cfg?.defaultRecipient ?? ""
        imessageDefaultRecipientField.setAccessibilityIdentifier("settings.imessage.recipient")
        imessageDefaultRecipientField.target = self
        imessageDefaultRecipientField.action = #selector(controlChanged)

        imessageCommandPrefixField.placeholderString = "sea"
        imessageCommandPrefixField.font = AppFont.mono(size: 12, weight: .regular)
        imessageCommandPrefixField.stringValue = cfg?.commandPrefix ?? ""
        imessageCommandPrefixField.setAccessibilityIdentifier("settings.imessage.commandPrefix")
        imessageCommandPrefixField.target = self
        imessageCommandPrefixField.action = #selector(controlChanged)

        imessageReplyPrefixField.placeholderString = "helm"
        imessageReplyPrefixField.font = AppFont.mono(size: 12, weight: .regular)
        imessageReplyPrefixField.stringValue = cfg?.replyPrefix ?? ""
        imessageReplyPrefixField.setAccessibilityIdentifier("settings.imessage.replyPrefix")
        imessageReplyPrefixField.target = self
        imessageReplyPrefixField.action = #selector(controlChanged)

        imessageAutoConnectToggle.setAccessibilityIdentifier("settings.imessage.autoConnect")

        imessagePermissionLabel.font = NSFont.systemFont(ofSize: 11)
        imessagePermissionLabel.preferredMaxLayoutWidth = 460
        imessagePermissionLabel.lineBreakMode = .byWordWrapping
        imessagePermissionLabel.maximumNumberOfLines = 3
        imessagePermissionLabel.translatesAutoresizingMaskIntoConstraints = false

        let permissionButton = SettingsControls.button("Open Full Disk Access", target: self,
                                                       action: #selector(openFullDiskAccessClicked))

        let permissionStack = NSStackView(views: [imessagePermissionLabel, permissionButton])
        permissionStack.orientation = .vertical
        permissionStack.alignment = .leading
        permissionStack.spacing = 6

        refreshIMessagePermissionUI()

        imessageRulesView.panes = settingsDelegate?.settingsPaneTargets(self) ?? []
        imessageRulesView.onChange = { [weak self] _ in self?.applyChanges() }

        return [
            SettingsGroupView(title: "Bridge", rows: [
                SettingsRow.stacked("Allowed senders",
                                    subtitle: "One per line: phone numbers (+8613800138000) or Apple IDs. Gates who may command you, and \u{2014} for commands you text yourself \u{2014} which thread counts. Empty ignores everyone.",
                                    content: SettingsControls.surface(imessageHandlesScrollView),
                                    height: 90),
                SettingsRow.make("Notify",
                                 subtitle: "Where agent-finished notifications are sent.",
                                 control: imessageDefaultRecipientField),
                SettingsRow.make("Connect at launch", control: imessageAutoConnectToggle),
            ]),
            SettingsGroupView(title: "Prefixes", rows: [
                SettingsRow.make("Command", control: imessageCommandPrefixField),
                SettingsRow.make("Reply",
                                 subtitle: "You text \"sea status\"; seahelm answers \"helm \u{2026}\". Lines without the command prefix are left alone, so the thread stays usable for notes \u{2014} and the reply prefix is how seahelm knows not to obey itself.",
                                 control: imessageReplyPrefixField),
            ]),
            SettingsGroupView(title: "Triggers", rows: [
                SettingsRow.stacked(nil,
                                    subtitle: "Messages that are not commands \u{2014} alerts, texts from other people \u{2014} can put an agent to work. The first matching rule wins; nothing is replied to, and no pane or worktree is ever created.",
                                    content: imessageRulesView),
            ]),
            SettingsGroupView(title: "Permissions", rows: [
                SettingsRow.stacked("Messages database", content: permissionStack),
            ]),
        ]
    }

    // MARK: - Pairing

    private func buildPairingGroups() -> [NSView] {
        guard let context = settingsDelegate?.settingsPairingContext(self) else {
            return [
                SettingsGroupView(title: "Remote clients", rows: [
                    SettingsRow.stacked("Pairing unavailable",
                                        subtitle: "Enable Host Gateway or MQTT in config, then reopen Settings to mint a pairing link.",
                                        content: NSView()),
                ]),
            ]
        }

        let pane = PairingPaneView(rootSecret: context.secret,
                                   brokerURL: HostGatewayPairing.clientEntryURL(
                                       hostGateway: config.hostGateway, mqtt: context.mqtt),
                                   macId: context.mqtt.macId ?? MqttChannel.deriveMacId(),
                                   qrSide: 180)
        pane.onShortCode = { [weak self] code, ttl in
            guard let self else { return }
            self.settingsDelegate?.settings(self, didMintShortCode: code, ttl: ttl)
        }

        return [
            SettingsGroupView(title: "Remote clients", rows: [
                SettingsRow.stacked(nil,
                                    subtitle: "Scan or paste to pair a phone, watch, or browser.",
                                    content: pane),
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
            SettingsGroupView(title: "zmx sessions", rows: [
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

    /// Reading chat.db is the half that fails silently, so check it up front and
    /// say so here rather than letting the bridge look connected but deaf.
    private func refreshIMessagePermissionUI() {
        switch IMessageChatDB().probe() {
        case .ok:
            imessagePermissionLabel.stringValue = "Messages database readable. Sending will ask for permission to control Messages the first time."
            imessagePermissionLabel.textColor = Theme.textSecondary
        case .missing:
            imessagePermissionLabel.stringValue = "No Messages database found — sign in to iMessage in Messages.app first."
            imessagePermissionLabel.textColor = .systemOrange
        case .denied:
            imessagePermissionLabel.stringValue = "Seahelm cannot read Messages. Grant Full Disk Access, then reopen Settings."
            imessagePermissionLabel.textColor = .systemRed
        }
    }

    @objc private func openFullDiskAccessClicked() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: - WeChat Tab (retired — not reachable from the tab bar)

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
        // Drop the resume state too — leaving it behind would hand a stale cursor
        // to whoever binds this account next.
        if let accountId = wechatDraft?.accountId {
            WeChatSessionStore.clear(accountId: accountId)
        }
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
            // Resume state is keyed by account in WeChatSessionStore, so rebinding
            // the same account keeps its cursor and a new one starts clean.
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

    @objc private func copyOnSelectChanged() {
        let enabled = copyOnSelectToggle.state == .on
        guard GhosttyConfigImporter.setCopyOnSelect(enabled) else { return }
        GhosttyBridge.shared.reloadUserConfig()
    }

    @objc private func revealGhosttyConfClicked() {
        let url = GhosttyConfigImporter.ensureOverlayConf()
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func applyChanges() {
        // Update config from UI
        config.workspacePaths = workspacePaths
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

        // WeCom / WeChat are no longer editable here; their config keys are left
        // exactly as loaded so a retired binding survives a save untouched.

        // iMessage config
        let handles = imessageHandlesView.string
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let recipient = imessageDefaultRecipientField.stringValue.trimmingCharacters(in: .whitespaces)
        let commandPrefix = imessageCommandPrefixField.stringValue.trimmingCharacters(in: .whitespaces)
        let replyPrefix = imessageReplyPrefixField.stringValue.trimmingCharacters(in: .whitespaces)
        // Keep the row even with no handles: the user may be turning the bridge
        // off by clearing the list, and dropping to nil would silently re-enable
        // the default-on autoConnect next launch.
        if handles.isEmpty && recipient.isEmpty && config.imessage == nil {
            config.imessage = nil
        } else {
            config.imessage = IMessageConfig(
                allowedHandles: handles,
                defaultRecipient: recipient.isEmpty ? nil : recipient,
                autoConnect: imessageAutoConnectToggle.state == .on,
                // Carried through rather than re-read: no field in this tab, so
                // rebuilding the struct would erase it.
                backfillSeconds: config.imessage?.backfillSeconds,
                // Blank means "use the default", which is what the placeholder
                // already shows — storing "" would resolve to the default anyway
                // but would read as a deliberate empty prefix in the JSON.
                commandPrefix: commandPrefix.isEmpty ? nil : commandPrefix,
                replyPrefix: replyPrefix.isEmpty ? nil : replyPrefix,
                // `pages` is lazy, so an untouched iMessage page must not wipe
                // rules the config already carries.
                rules: pages["imessage"] == nil ? config.imessage?.rules
                                                : imessageRulesView.rules
            )
        }

        if pages["gmail"] != nil {
            let email = GmailMailConfig.normalizeEmail(gmailAccountField.stringValue)
            let senders = gmailAllowedSendersField.stringValue
                .split(whereSeparator: { ", ;\n".contains($0) })
                .map { GmailMailConfig.normalizeEmail(String($0)) }
                .filter { GmailMailConfig.isEmail($0) }
            config.gmailMail = GmailMailConfig(enabled: gmailEnabledToggle.state == .on, accountEmail: email,
                                                inboundAlias: GmailMailConfig(accountEmail: email).derivedInboundAlias,
                                                allowedSenders: senders)
        }

        config.save()
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
        cancelWeChatLogin()
        applyChanges()
    }
}

// MARK: - NSTextViewDelegate

extension SettingsViewController: NSTextViewDelegate {
    /// The multi-line editors (handles list, detection JSON) apply when focus
    /// leaves, not per keystroke: half-typed JSON is not a config, and
    /// re-encoding on every character would fight the caret.
    func textDidEndEditing(_ notification: Notification) {
        guard notification.object as? NSTextView === imessageHandlesView
                || notification.object as? NSTextView === ruleTextView else { return }
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
