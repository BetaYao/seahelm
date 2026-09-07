import AppKit

protocol SettingsDelegate: AnyObject {
    func settingsDidUpdateConfig(_ settings: SettingsViewController, config: Config)

    /// Mint (if needed) and persist the pairing root secret on the *live* config.
    /// Still required so Host Gateway can issue long-lived tokens after a code auth.
    func settingsPairingContext(_ settings: SettingsViewController) -> (secret: Data, mqtt: PairingIdentity)?

    /// Current 8-digit pairing code (ensures one exists).
    func settingsPairingCode(_ settings: SettingsViewController) -> String

    /// Generate a new code; previous code stops working. Does not revoke tokens.
    func settingsRefreshPairingCode(_ settings: SettingsViewController) -> String

    /// Rotate root secret + refresh code; all stored browser tokens die.
    func settingsRevokeAllRemotes(_ settings: SettingsViewController)

    /// Live panes, so a rule's target is picked from a project → worktree →
    /// pane cascade of what actually exists rather than typed from memory.
    func settingsPaneTargets(_ settings: SettingsViewController) -> [PaneSnapshot]

    /// Sessions the running app has panes attached to — flagged in the monitor so
    /// a kill that would take out a live agent is at least an informed one.
    func settingsActiveSessionNames(_ settings: SettingsViewController) -> Set<String>
    func settings(_ settings: SettingsViewController, connectGmailAccount email: String)

    /// Whether the Host Gateway listener is actually up, so the page reports what
    /// happened rather than what was asked for.
    func settingsHostGatewayListening(_ settings: SettingsViewController) -> Bool

    /// Bring a Telegram bridge up on `token` with `session` armed, so the setup
    /// wizard's QR can be claimed. Nothing is persisted: the wizard writes the
    /// config through `settingsDidUpdateConfig` like every other change.
    ///
    /// Pairing needs a live poller and Telegram allows exactly one per bot, so
    /// the wizard borrows the app's channel rather than opening a second one
    /// that would collide with it (409).
    func settings(_ settings: SettingsViewController,
                  beginTelegramPairing token: String,
                  session: TelegramPairingSession,
                  onPaired: @escaping (TelegramPairingResult) -> Void)

    /// Drop the pairing bridge and put back whatever the saved config asks for.
    /// Safe to call when no pairing is running.
    func settingsEndTelegramPairing(_ settings: SettingsViewController)
}

/// Optional halves of the protocol: only the main window can answer them, and
/// tests conform with just the config callback.
extension SettingsDelegate {
    func settingsPairingContext(_ settings: SettingsViewController) -> (secret: Data, mqtt: PairingIdentity)? { nil }
    func settingsPairingCode(_ settings: SettingsViewController) -> String {
        var store = PairingCodeStore(code: nil)
        return store.ensureCode()
    }
    func settingsRefreshPairingCode(_ settings: SettingsViewController) -> String {
        var store = PairingCodeStore(code: nil)
        return store.refresh()
    }
    func settingsRevokeAllRemotes(_ settings: SettingsViewController) {}
    func settingsActiveSessionNames(_ settings: SettingsViewController) -> Set<String> { [] }
    func settingsPaneTargets(_ settings: SettingsViewController) -> [PaneSnapshot] { [] }
    func settings(_ settings: SettingsViewController, connectGmailAccount email: String) {}
    func settingsHostGatewayListening(_ settings: SettingsViewController) -> Bool { false }
    func settings(_ settings: SettingsViewController,
                  beginTelegramPairing token: String,
                  session: TelegramPairingSession,
                  onPaired: @escaping (TelegramPairingResult) -> Void) {}
    func settingsEndTelegramPairing(_ settings: SettingsViewController) {}
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
        .init(id: "telegram", title: "Telegram", symbol: "paperplane",
              keywords: ["bot", "botfather", "token", "phone", "chat", "remote",
                         "bridge", "rules", "trigger"]),
        .init(id: "gmail", title: "Gmail", symbol: "envelope",
              keywords: ["email", "mail", "oauth", "google", "alias"]),
        .init(id: "pairing", title: "Pairing", symbol: "qrcode",
              keywords: ["qr", "remote", "browser", "gateway", "pair",
                         "port", "tunnel", "wss", "cloudflare", "web"]),
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
    private lazy var integrationEnabledToggle = SettingsControls.toggle(
        on: config.integrationEnabled, target: self, action: #selector(integrationControlChanged))
    private lazy var autoIntegrateToggle = SettingsControls.toggle(
        on: config.autoIntegrate, target: self, action: #selector(controlChanged))
    private lazy var revealGhosttyConfButton = SettingsControls.button(
        "Reveal ghostty.conf", target: self, action: #selector(revealGhosttyConfClicked))

    // Agent Detection tab controls
    private let ruleTextView = NSTextView()
    private let ruleScrollView = NSScrollView()

    // Telegram tab controls
    private let telegramTokenField = SettingsTextField()
    private let telegramUsersView = NSTextView()
    private let telegramUsersScrollView = NSScrollView()
    private let telegramDefaultChatField = SettingsTextField()
    private lazy var telegramAutoConnectToggle = SettingsControls.toggle(
        on: config.telegram?.resolvedAutoConnect ?? true, target: self, action: #selector(controlChanged))
    private let telegramStatusLabel = NSTextField(labelWithString: "")
    private let telegramSetupSummary = NSTextField(labelWithString: "")
    private lazy var telegramSetupButton = SettingsControls.button(
        "Set up Telegram\u{2026}", target: self, action: #selector(telegramSetupClicked))
    private lazy var telegramRulesView = TelegramRulesView(rules: config.telegram?.resolvedRules ?? [])
    private let gmailAccountField = SettingsTextField()
    private let gmailAliasLabel = NSTextField(labelWithString: "")
    private let gmailAllowedSendersField = SettingsTextField()
    private let gmailStatusLabel = NSTextField(labelWithString: "Not connected")
    private lazy var gmailEnabledToggle = SettingsControls.toggle(on: config.gmailMail?.enabled ?? false, target: self, action: #selector(controlChanged))

    // Pairing tab: Host Gateway server + the pair link it feeds
    private lazy var gatewayEnabledToggle = SettingsControls.toggle(
        on: config.hostGateway?.resolvedEnabled ?? false,
        target: self, action: #selector(gatewayControlChanged))
    private let gatewayPortField = SettingsTextField()
    private let gatewayPublicURLField = SettingsTextField()
    private let gatewayStatusLabel = NSTextField(labelWithString: "")
    private lazy var gatewayOpenPageButton = SettingsControls.button(
        "Open web client", target: self, action: #selector(openGatewayPageClicked))
    /// Held so an edited public URL can re-encode the QR in place.
    private var pairingPane: PairingPaneView?
    /// The mqtt half of the pairing context, cached from the page build: asking
    /// the delegate again mints and reloads the gateway, which is not what a
    /// typed URL should cost.
    private var pairingMqtt: PairingIdentity?

    init(config: Config) {
        self.config = config
        self.workspacePaths = config.workspacePaths
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
        // Same reason: the gateway may have died, or bound, since the page was built.
        if id == "pairing" {
            refreshHostGatewayStatus()
        }
    }

    private func buildPage(_ id: String) -> NSView {
        switch id {
        case "agents":   return makePage(buildAgentGroups())
        case "telegram": return makePage(buildTelegramGroups())
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
            makeIntegrationGroup(),
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

    private func makeIntegrationGroup() -> NSView {
        // Built here rather than inline so the dependent toggle's enabled state
        // is set once, at construction, and not left to the first click.
        refreshIntegrationEnabledState()
        return SettingsGroupView(title: "Integration", rows: [
            SettingsRow.make("Integration worktree",
                             subtitle: "A throwaway checkout per project holding every worktree folded onto trunk, to run integration tests in. Off hides it everywhere; a checkout already on disk is left alone.",
                             control: integrationEnabledToggle),
            SettingsRow.make("Keep it current",
                             subtitle: "Rebuild it as agents finish turns. Only ever touches a project that already has a checkout — running /integrate once is what creates one.",
                             control: autoIntegrateToggle),
        ])
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

    // MARK: - Telegram

    private func buildTelegramGroups() -> [NSView] {
        let cfg = config.telegram

        telegramTokenField.placeholderString = "123456789:AAF\u{2026}"
        telegramTokenField.font = AppFont.mono(size: 12, weight: .regular)
        telegramTokenField.stringValue = cfg?.botToken ?? ""
        telegramTokenField.setAccessibilityIdentifier("settings.telegram.token")
        telegramTokenField.target = self
        telegramTokenField.action = #selector(controlChanged)

        telegramUsersView.font = AppFont.mono(size: 12, weight: .regular)
        telegramUsersView.isRichText = false
        telegramUsersView.isAutomaticQuoteSubstitutionEnabled = false
        telegramUsersView.string = (cfg?.allowedUsers ?? []).joined(separator: "\n")
        telegramUsersView.setAccessibilityIdentifier("settings.telegram.users")
        telegramUsersView.drawsBackground = false
        telegramUsersView.textColor = SettingsPalette.text
        telegramUsersView.textContainerInset = NSSize(width: 6, height: 6)
        telegramUsersView.delegate = self
        telegramUsersScrollView.hasVerticalScroller = true
        telegramUsersScrollView.borderType = .noBorder
        telegramUsersScrollView.drawsBackground = false
        telegramUsersScrollView.documentView = telegramUsersView
        telegramUsersScrollView.translatesAutoresizingMaskIntoConstraints = false

        telegramDefaultChatField.placeholderString = "First allowed user id"
        telegramDefaultChatField.font = AppFont.mono(size: 12, weight: .regular)
        telegramDefaultChatField.stringValue = cfg?.defaultChatId ?? ""
        telegramDefaultChatField.setAccessibilityIdentifier("settings.telegram.chat")
        telegramDefaultChatField.target = self
        telegramDefaultChatField.action = #selector(controlChanged)

        telegramAutoConnectToggle.setAccessibilityIdentifier("settings.telegram.autoConnect")

        telegramStatusLabel.font = NSFont.systemFont(ofSize: 11)
        telegramStatusLabel.preferredMaxLayoutWidth = 460
        telegramStatusLabel.lineBreakMode = .byWordWrapping
        telegramStatusLabel.maximumNumberOfLines = 3
        telegramStatusLabel.translatesAutoresizingMaskIntoConstraints = false
        telegramStatusLabel.textColor = Theme.textSecondary
        telegramStatusLabel.stringValue = cfg?.resolvedBotToken == nil
            ? "Paste a bot token to get started."
            : "Token saved. Test to confirm Telegram accepts it."

        let testButton = SettingsControls.button("Test connection", target: self,
                                                 action: #selector(testTelegramClicked))
        let statusStack = NSStackView(views: [telegramStatusLabel, testButton])
        statusStack.orientation = .vertical
        statusStack.alignment = .leading
        statusStack.spacing = 6

        telegramRulesView.panes = settingsDelegate?.settingsPaneTargets(self) ?? []
        telegramRulesView.onChange = { [weak self] _ in self?.applyChanges() }

        telegramSetupSummary.font = NSFont.systemFont(ofSize: 11)
        telegramSetupSummary.textColor = Theme.textSecondary
        telegramSetupSummary.lineBreakMode = .byWordWrapping
        telegramSetupSummary.maximumNumberOfLines = 2
        telegramSetupSummary.preferredMaxLayoutWidth = 460
        telegramSetupSummary.translatesAutoresizingMaskIntoConstraints = false
        telegramSetupButton.setAccessibilityIdentifier("settings.telegram.setup")
        refreshTelegramSetupSummary()

        let setupStack = NSStackView(views: [telegramSetupSummary, telegramSetupButton])
        setupStack.orientation = .vertical
        setupStack.alignment = .leading
        setupStack.spacing = 8

        return [
            // First, because it is what almost everyone should use. The fields
            // below are the same values by hand, kept for a config edited from
            // a script or a second account added without re-pairing.
            SettingsGroupView(title: "Setup", rows: [
                SettingsRow.stacked(nil,
                                    subtitle: "Walks through creating a bot with @BotFather, checks the token, "
                                            + "and pairs your Telegram account by QR code \u{2014} no user IDs to look up.",
                                    content: setupStack),
            ]),
            SettingsGroupView(title: "Bot", rows: [
                SettingsRow.make("Bot token",
                                 subtitle: "Create a bot with @BotFather and paste its token here. Kept in config.json.",
                                 control: telegramTokenField),
                SettingsRow.stacked("Allowed users",
                                    subtitle: "One per line: numeric user IDs (ask @userinfobot for yours) or @usernames. Only these may command the fleet; anyone else who messages the bot is ignored \u{2014} or matched against the triggers below. Empty ignores everyone.",
                                    content: SettingsControls.surface(telegramUsersScrollView),
                                    height: 90),
                SettingsRow.make("Notify",
                                 subtitle: "Chat id where agent-finished notifications go. Empty means the first numeric allowed user, or failing that the chat your last command came from.",
                                 control: telegramDefaultChatField),
                SettingsRow.make("Connect at launch", control: telegramAutoConnectToggle),
                SettingsRow.make("In a group",
                                 subtitle: "Send a slash command: /status, /help. Telegram's privacy mode hands a bot only the group messages that begin with a slash, so \u{201C}@yourbot /status\u{201D} never arrives at all \u{2014} put the mention last instead, /status@yourbot, when several bots share the group. Plain prose is an order in a private chat only; in a group it stays conversation."),
                SettingsRow.stacked(nil, content: statusStack),
            ]),
            SettingsGroupView(title: "Triggers", rows: [
                SettingsRow.stacked(nil,
                                    subtitle: "Messages from anyone not on the allowed list \u{2014} a monitoring channel the bot sits in, a colleague in a group \u{2014} can put an agent to work. The first matching rule wins; nothing is replied to, and no pane or worktree is ever created.",
                                    content: telegramRulesView),
            ]),
        ]
    }

    // MARK: - Pairing

    private func buildPairingGroups() -> [NSView] {
        let gatewayGroup = buildHostGatewayGroup()

        // Ensure a root secret exists so code auth can issue tokens.
        if let context = settingsDelegate?.settingsPairingContext(self) {
            pairingMqtt = context.mqtt
            config.pairing = context.mqtt
        }

        let accessURL = (config.hostGateway ?? HostGatewayConfig()).resolvedPageURL
        let code: String = {
            if let fromDelegate = settingsDelegate?.settingsPairingCode(self) {
                return fromDelegate
            }
            var store = PairingCodeStore(code: config.hostGateway?.pairCode)
            return store.ensureCode()
        }()
        // Sync into our editable copy so applyChanges does not wipe it.
        if config.hostGateway == nil { config.hostGateway = HostGatewayConfig() }
        config.hostGateway?.pairCode = PairingCodeStore.normalize(code)

        let pane = PairingPaneView(accessURL: accessURL, code: code)
        pane.onRefresh = { [weak self] in
            guard let self else { return "" }
            let next = self.settingsDelegate?.settingsRefreshPairingCode(self) ?? {
                var store = PairingCodeStore(code: self.config.hostGateway?.pairCode)
                return store.refresh()
            }()
            self.config.hostGateway?.pairCode = next
            return next
        }
        pane.onRevokeAll = { [weak self] in
            guard let self else { return }
            self.settingsDelegate?.settingsRevokeAllRemotes(self)
            let next = self.settingsDelegate?.settingsPairingCode(self) ?? {
                var store = PairingCodeStore(code: nil)
                return store.ensureCode()
            }()
            self.config.hostGateway?.pairCode = next
            pane.setCode(next)
            pane.accessURL = (self.config.hostGateway ?? HostGatewayConfig()).resolvedPageURL
        }
        pairingPane = pane

        return [
            gatewayGroup,
            SettingsGroupView(title: "Browser access", rows: [
                SettingsRow.stacked(nil,
                                    subtitle: "Open the access URL below in a browser and enter the 8-digit code.",
                                    content: pane),
            ]),
        ]
    }

    private func buildHostGatewayGroup() -> NSView {
        let gateway = config.hostGateway ?? HostGatewayConfig()

        gatewayPortField.stringValue = String(gateway.resolvedPort)
        gatewayPortField.placeholderString = String(HostGatewayConfig().resolvedPort)
        gatewayPortField.target = self
        gatewayPortField.action = #selector(gatewayControlChanged)

        gatewayPublicURLField.stringValue = gateway.publicURL ?? ""
        // The derived localhost URL, so an empty field reads as "localhost only"
        // rather than "unset".
        gatewayPublicURLField.placeholderString = HostGatewayConfig(port: gateway.port).resolvedPublicURL
        gatewayPublicURLField.target = self
        gatewayPublicURLField.action = #selector(gatewayControlChanged)
        // A URL right-aligned truncates its host, which is the half worth seeing.
        gatewayPublicURLField.alignment = .left
        gatewayPublicURLField.font = AppFont.mono(size: 11, weight: .regular)

        gatewayStatusLabel.font = .systemFont(ofSize: 11)
        gatewayStatusLabel.textColor = SettingsPalette.secondary
        gatewayStatusLabel.lineBreakMode = .byTruncatingMiddle
        gatewayStatusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        refreshHostGatewayStatus()

        return SettingsGroupView(title: "Host Gateway", rows: [
            SettingsRow.make("Serve browser clients",
                             subtitle: "Runs the web client and its WebSocket on one port of this Mac. Turning it on publishes nothing by itself \u{2014} reachability is whatever you point at that port \u{2014} and every session still has to pair.",
                             control: gatewayEnabledToggle,
                             accessibilityId: "settings.hostGateway.enabled"),
            SettingsRow.make("Port",
                             control: gatewayPortField,
                             accessibilityId: "settings.hostGateway.port"),
            SettingsRow.stacked("Public URL",
                                subtitle: "Optional override for the access URL shown under Browser access (and Open page). Point a tunnel at the port above and paste its `http(s)://\u{2026}/` or leave empty for this Mac only. Pairing no longer embeds this URL in a secret.",
                                content: gatewayPublicURLField,
                                height: 28),
            SettingsRow.actions([gatewayOpenPageButton], leading: [gatewayStatusLabel]),
        ])
    }

    /// Gateway edits move a listener, so they refresh the access URL shown on
    /// the pairing pane and whether the bind actually took.
    @objc private func gatewayControlChanged() {
        applyChanges()
        // Echo back what was stored, so a rejected port does not sit in the field
        // looking accepted.
        gatewayPortField.stringValue = String((config.hostGateway ?? HostGatewayConfig()).resolvedPort)
        refreshPairingDisplay()
        refreshHostGatewayStatus()
        // The listener binds on its own queue; ask again once it has had a moment
        // to succeed or fail, or a taken port reads as running.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            self?.refreshHostGatewayStatus()
        }
    }

    @objc private func openGatewayPageClicked() {
        guard let url = URL(string: (config.hostGateway ?? HostGatewayConfig()).resolvedPageURL) else { return }
        NSWorkspace.shared.open(url)
    }

    private func refreshPairingDisplay() {
        guard let pairingPane else { return }
        pairingPane.accessURL = (config.hostGateway ?? HostGatewayConfig()).resolvedPageURL
        if let code = config.hostGateway?.pairCode {
            pairingPane.setCode(code)
        }
    }

    private func refreshHostGatewayStatus() {
        let gateway = config.hostGateway ?? HostGatewayConfig()
        gatewayOpenPageButton.isEnabled = gateway.resolvedEnabled
        guard gateway.resolvedEnabled else {
            gatewayStatusLabel.stringValue = "Not serving."
            return
        }
        if settingsDelegate?.settingsHostGatewayListening(self) == true {
            gatewayStatusLabel.stringValue = "Serving \(gateway.resolvedPageURL)"
        } else {
            gatewayStatusLabel.stringValue =
                "Enabled, but nothing is listening on port \(gateway.resolvedPort) \u{2014} the bind failed."
        }
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

    // MARK: - Telegram setup wizard

    private func refreshTelegramSetupSummary() {
        let cfg = config.telegram
        let paired = cfg?.allowedUsers.filter { !$0.isEmpty }.count ?? 0
        switch (cfg?.resolvedBotToken != nil, paired) {
        case (false, _):
            telegramSetupSummary.stringValue = "Not set up yet."
            telegramSetupButton.title = "Set up Telegram\u{2026}"
        case (true, 0):
            // The state that used to be silent and baffling: a valid token, a
            // bridge that connects, and a bot that answers nobody.
            telegramSetupSummary.stringValue =
                "A bot token is saved, but nobody is allowed to command it yet."
            telegramSetupButton.title = "Pair an account\u{2026}"
        case (true, let count):
            telegramSetupSummary.stringValue = count == 1
                ? "Paired with 1 account."
                : "Paired with \(count) accounts."
            telegramSetupButton.title = "Pair another account\u{2026}"
        }
    }

    @objc private func telegramSetupClicked() {
        let services = TelegramSetupServices(
            beginPairing: { [weak self] token, session, onPaired in
                guard let self else { return }
                self.settingsDelegate?.settings(self, beginTelegramPairing: token,
                                                session: session, onPaired: onPaired)
            },
            endPairing: { [weak self] in
                guard let self else { return }
                self.settingsDelegate?.settingsEndTelegramPairing(self)
            })

        let wizard = TelegramSetupWizard(services: services)
        wizard.onFinish = { [weak self] result in self?.applyTelegramSetup(result) }
        presentAsSheet(wizard)
    }

    /// Fold a finished pairing into the editable config and save it.
    ///
    /// Whether the allowlist is replaced or added to turns on the bot: pairing
    /// against the same token again is someone adding a teammate's phone, and
    /// wiping their own id would lock them out of the bot they just shared. A
    /// different token is a different bot, where the old ids mean nothing.
    private func applyTelegramSetup(_ result: TelegramSetupResult) {
        let sameBot = config.telegram?.resolvedBotToken == result.token
        var users = sameBot
            ? telegramUsersView.string
                .split(whereSeparator: \.isNewline)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            : []
        if !users.contains(where: { TelegramConfig.normalize($0) == result.userId }) {
            users.append(result.userId)
        }

        telegramTokenField.stringValue = result.token
        telegramUsersView.string = users.joined(separator: "\n")
        // Only claim the notification chat when nothing else has it: on a
        // second pairing that chat belongs to whoever set the bot up first.
        let existingChat = telegramDefaultChatField.stringValue.trimmingCharacters(in: .whitespaces)
        if !sameBot || existingChat.isEmpty {
            telegramDefaultChatField.stringValue = result.chatId
        }
        telegramAutoConnectToggle.state = result.autoConnect ? .on : .off
        telegramStatusLabel.stringValue =
            "Paired with \(result.displayName). Send /status from Telegram to check."
        telegramStatusLabel.textColor = Theme.textSecondary

        applyChanges()
        refreshTelegramSetupSummary()
    }

    /// `getMe` is the cheapest call that proves a token: it needs no chat, and
    /// nobody has to have messaged the bot yet.
    @objc private func testTelegramClicked() {
        let token = telegramTokenField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else {
            telegramStatusLabel.stringValue = "Enter a bot token first."
            telegramStatusLabel.textColor = .systemOrange
            return
        }
        telegramStatusLabel.stringValue = "Contacting Telegram\u{2026}"
        telegramStatusLabel.textColor = Theme.textSecondary

        let api = TelegramBotAPI(token: token)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let outcome = Result { try api.getMe() }
            api.invalidate()
            DispatchQueue.main.async {
                guard let self else { return }
                switch outcome {
                case .success(let me):
                    let name = me.username.map { "@\($0)" } ?? me.firstName ?? String(me.id)
                    self.telegramStatusLabel.stringValue = "Connected as \(name). Message it from an allowed account to start."
                    self.telegramStatusLabel.textColor = Theme.textSecondary
                case .failure(let error):
                    self.telegramStatusLabel.stringValue = error.localizedDescription
                    self.telegramStatusLabel.textColor = .systemRed
                }
            }
        }
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

    /// The master switch owns whether the finer one can be reached at all.
    @objc private func integrationControlChanged() {
        refreshIntegrationEnabledState()
        applyChanges()
    }

    private func refreshIntegrationEnabledState() {
        autoIntegrateToggle.isEnabled = integrationEnabledToggle.state == .on
    }

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
        config.integrationEnabled = integrationEnabledToggle.state == .on
        config.autoIntegrate = autoIntegrateToggle.state == .on
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

        // Telegram config — only once the page has been built. `pages` is
        // lazy, and reading never-populated fields would wipe the token and
        // the allowlist on a save from any other tab.
        if pages["telegram"] != nil {
            let token = telegramTokenField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            let users = telegramUsersView.string
                .split(whereSeparator: \.isNewline)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            let chat = telegramDefaultChatField.stringValue.trimmingCharacters(in: .whitespaces)
            // Keep the row even when everything is cleared: the user may be
            // turning the bridge off, and dropping to nil would silently
            // re-enable the default-on autoConnect next launch.
            if token.isEmpty && users.isEmpty && chat.isEmpty && config.telegram == nil {
                config.telegram = nil
            } else {
                config.telegram = TelegramConfig(
                    botToken: token.isEmpty ? nil : token,
                    allowedUsers: users,
                    defaultChatId: chat.isEmpty ? nil : chat,
                    autoConnect: telegramAutoConnectToggle.state == .on,
                    // Carried through rather than re-read: no field in this
                    // tab, so rebuilding the struct would erase it.
                    backfillSeconds: config.telegram?.backfillSeconds,
                    rules: telegramRulesView.rules
                )
            }
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

        // Host Gateway. Guarded like Gmail: the fields only carry real values once
        // the page has been built, so an unvisited page must not write its blank
        // defaults over a config edited by hand.
        if pages["pairing"] != nil {
            config.hostGateway = HostGatewayConfig.edited(
                enabled: gatewayEnabledToggle.state == .on,
                portText: gatewayPortField.stringValue,
                publicURLText: gatewayPublicURLField.stringValue,
                from: config.hostGateway)
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
        applyChanges()
    }
}

// MARK: - NSTextViewDelegate

extension SettingsViewController: NSTextViewDelegate {
    /// The multi-line editors (handles list, detection JSON) apply when focus
    /// leaves, not per keystroke: half-typed JSON is not a config, and
    /// re-encoding on every character would fight the caret.
    func textDidEndEditing(_ notification: Notification) {
        guard notification.object as? NSTextView === telegramUsersView
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
