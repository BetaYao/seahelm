import AppKit

/// Settings ▸ Telegram and Settings ▸ Pairing: seahelm-gateway's settings,
/// read and written over `gateway.sock` (docs/seahelm-gateway-plan.md). Nothing
/// here touches config.json. Each control writes its one field as it changes
/// (`gateway.config.set` with a partial object), and the pages follow the
/// gateway's own events so a change made elsewhere — the setup wizard, a
/// device pairing, a link revoked — shows up. While the gateway does not
/// answer, every control is off and the pages say "seahelm-gateway is not
/// running".
final class GatewaySettingsPages: NSObject {
    /// The window's controller: presents the wizard, knows the live panes.
    weak var host: SettingsViewController?

    private(set) var settings = GatewaySettings()
    private(set) var status = GatewayStatus()
    private(set) var reachable = false
    private let events = GatewayEventStream()
    private var telegramBuilt = false
    private var pairingBuilt = false

    // Telegram page
    private let telegramGatewayLine = NSTextField(labelWithString: "")
    private let telegramTokenField = SettingsTextField()
    private let telegramUsersView = NSTextView()
    private let telegramUsersScrollView = NSScrollView()
    private let telegramDefaultChatField = SettingsTextField()
    private let telegramMiniAppField = SettingsTextField()
    private let telegramMiniAppStatus = NSTextField(labelWithString: "")
    private lazy var telegramEnabledToggle = SettingsControls.toggle(
        on: false, target: self, action: #selector(telegramEnabledChanged))
    private let telegramStatusLabel = NSTextField(labelWithString: "")
    private let telegramSetupSummary = NSTextField(labelWithString: "")
    private lazy var telegramSetupButton = SettingsControls.button(
        "Set up Telegram\u{2026}", target: self, action: #selector(telegramSetupClicked))
    private lazy var telegramTestButton = SettingsControls.button(
        "Test connection", target: self, action: #selector(testTelegramClicked))
    private lazy var copyMiniAppButton = SettingsControls.button(
        "Copy URL", target: self, action: #selector(copyMiniAppURLClicked))
    private let telegramRulesView = TelegramRulesView(rules: [])
    /// The test result outranks the live status until the next status change.
    private var telegramStatusPinned = false

    // Pairing page
    private let pairingGatewayLine = NSTextField(labelWithString: "")
    private lazy var webEnabledToggle = SettingsControls.toggle(
        on: false, target: self, action: #selector(webControlChanged))
    private let webPortField = SettingsTextField()
    private let webPublicURLField = SettingsTextField()
    private let webStatusLabel = NSTextField(labelWithString: "")
    private lazy var webOpenPageButton = SettingsControls.button(
        "Open web client", target: self, action: #selector(openWebPageClicked))
    private var pairingPane: PairingPaneView?
    private var devicesList: GatewayDevicesListView?
    private var shareLinksList: ShareLinksListView?

    override init() {
        super.init()
        events.onEvent = { [weak self] type, _ in self?.gatewayEvent(type) }
        events.onConnected = { [weak self] up in
            if up { self?.reload() } else { self?.setReachable(false) }
        }
    }

    deinit { events.stop() }

    // MARK: - Loading

    /// Read the gateway's settings and status again, and every list.
    func reload() {
        GatewayClient.config { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let settings):
                self.settings = settings
                self.setReachable(true)
                self.fill()
            case .failure:
                self.setReachable(false)
            }
        }
        refreshStatus()
        pairingPane?.reload()
        devicesList?.reload()
        shareLinksList?.reload()
    }

    private func refreshStatus() {
        GatewayClient.status { [weak self] result in
            guard let self, case .success(let status) = result else { return }
            self.status = status
            self.telegramStatusPinned = false
            self.renderStatus()
        }
    }

    private func gatewayEvent(_ type: String) {
        switch type {
        case "config.changed", "telegram.paired":
            reload()
        case "gateway.status_changed":
            refreshStatus()
        case "devices.changed":
            devicesList?.reload()
        case "share.changed":
            shareLinksList?.reload()
        default:
            break
        }
    }

    private func startFollowing() {
        events.start()
        reload()
    }

    private func setReachable(_ up: Bool) {
        reachable = up
        let line = up ? "" : GatewayClient.notRunningMessage
        for label in [telegramGatewayLine, pairingGatewayLine] {
            label.stringValue = line
            label.isHidden = up
        }
        let controls: [NSControl] = [
            telegramTokenField, telegramDefaultChatField, telegramMiniAppField, telegramEnabledToggle,
            telegramSetupButton, telegramTestButton, copyMiniAppButton,
            webEnabledToggle, webPortField, webPublicURLField, webOpenPageButton,
        ]
        for control in controls { control.isEnabled = up }
        telegramUsersView.isEditable = up
        telegramRulesView.isHidden = !up
        if !up {
            webStatusLabel.stringValue = GatewayClient.notRunningMessage
            telegramStatusLabel.stringValue = GatewayClient.notRunningMessage
            telegramStatusLabel.textColor = .systemOrange
        } else {
            renderStatus()
        }
    }

    /// Put the gateway's settings into the controls.
    private func fill() {
        let t = settings.telegram
        telegramTokenField.stringValue = ""
        telegramTokenField.placeholderString = t.botTokenSet
            ? "Saved \u{2014} paste a new token to replace it"
            : "123456789:AAF\u{2026}"
        if telegramUsersView.window?.firstResponder !== telegramUsersView {
            telegramUsersView.string = t.allowedUsers.joined(separator: "\n")
        }
        telegramDefaultChatField.stringValue = t.defaultChatId ?? ""
        telegramEnabledToggle.state = t.enabled ? .on : .off
        telegramMiniAppField.stringValue = t.miniAppURL ?? ""
        refreshTelegramMiniAppStatus()
        telegramRulesView.setRules(t.rules)
        refreshTelegramSetupSummary()

        let w = settings.web
        webEnabledToggle.state = w.enabled ? .on : .off
        webPortField.stringValue = String(w.port)
        webPortField.placeholderString = "2783"
        webPublicURLField.stringValue = w.publicURL ?? ""
        webPublicURLField.placeholderString = "http://127.0.0.1:\(w.port)/"
        renderStatus()
    }

    private func renderStatus() {
        guard reachable else { return }
        // Web access
        let w = status.web
        webOpenPageButton.isEnabled = settings.web.enabled
        if !settings.web.enabled {
            webStatusLabel.stringValue = "Not serving."
        } else if w.listening {
            let clients = w.clients == 1 ? "1 client" : "\(w.clients) clients"
            webStatusLabel.stringValue = "Serving \(settings.web.pageURL) \u{00B7} \(clients)"
        } else {
            let why = w.error.map { " \u{2014} \($0)" } ?? " \u{2014} the bind failed."
            webStatusLabel.stringValue = "Enabled, but nothing is listening on port \(settings.web.port)\(why)"
        }
        if !status.coreReachable {
            webStatusLabel.stringValue += " seahelm-core is not answering, so the fleet shows empty."
        }

        // Telegram
        guard !telegramStatusPinned else { return }
        let t = status.telegram
        telegramStatusLabel.textColor = Theme.textSecondary
        if !settings.telegram.botTokenSet {
            telegramStatusLabel.stringValue = "Paste a bot token to get started."
        } else if !settings.telegram.enabled {
            telegramStatusLabel.stringValue = "Token saved. The bot is off."
        } else if t.connected {
            let name = t.botUsername.map { "@\($0)" } ?? "the bot"
            telegramStatusLabel.stringValue = "Connected as \(name)."
        } else if let error = t.error {
            telegramStatusLabel.stringValue = error
            telegramStatusLabel.textColor = .systemRed
        } else {
            telegramStatusLabel.stringValue = "Connecting\u{2026}"
        }
    }

    private func write(_ patch: [String: Any]) {
        GatewayClient.setConfig(patch) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let settings):
                self.settings = settings
                self.fill()
                // The listener rebinds and the bot reconnects on their own time.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in self?.refreshStatus() }
            case .failure(.unreachable):
                self.setReachable(false)
            case .failure(let failure):
                self.telegramStatusPinned = true
                self.telegramStatusLabel.stringValue = GatewayClient.describe(failure)
                self.telegramStatusLabel.textColor = .systemRed
                self.webStatusLabel.stringValue = GatewayClient.describe(failure)
                self.fill()
            }
        }
    }

    private static func gatewayLine(_ label: NSTextField) -> NSTextField {
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.textColor = .systemOrange
        label.setAccessibilityIdentifier("settings.gateway.notRunning")
        label.isHidden = true
        return label
    }

    // MARK: - Telegram page

    func buildTelegramGroups() -> [NSView] {
        telegramBuilt = true
        telegramTokenField.font = AppFont.mono(size: 12, weight: .regular)
        telegramTokenField.setAccessibilityIdentifier("settings.telegram.token")
        telegramTokenField.target = self
        telegramTokenField.action = #selector(telegramTokenChanged)

        telegramUsersView.font = AppFont.mono(size: 12, weight: .regular)
        telegramUsersView.isRichText = false
        telegramUsersView.isAutomaticQuoteSubstitutionEnabled = false
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
        telegramDefaultChatField.setAccessibilityIdentifier("settings.telegram.chat")
        telegramDefaultChatField.target = self
        telegramDefaultChatField.action = #selector(telegramChatChanged)

        telegramEnabledToggle.setAccessibilityIdentifier("settings.telegram.autoConnect")

        telegramMiniAppField.placeholderString = "https://tg.example.com/"
        telegramMiniAppField.font = AppFont.mono(size: 12, weight: .regular)
        telegramMiniAppField.setAccessibilityIdentifier("settings.telegram.miniApp")
        telegramMiniAppField.target = self
        telegramMiniAppField.action = #selector(telegramMiniAppChanged)
        telegramMiniAppStatus.font = NSFont.systemFont(ofSize: 11)
        telegramMiniAppStatus.lineBreakMode = .byWordWrapping
        telegramMiniAppStatus.maximumNumberOfLines = 4
        telegramMiniAppStatus.preferredMaxLayoutWidth = 460
        telegramMiniAppStatus.translatesAutoresizingMaskIntoConstraints = false
        telegramMiniAppStatus.isSelectable = true
        let miniAppStack = NSStackView(views: [telegramMiniAppField, telegramMiniAppStatus, copyMiniAppButton])
        miniAppStack.orientation = .vertical
        miniAppStack.alignment = .leading
        miniAppStack.spacing = 6
        telegramMiniAppField.widthAnchor.constraint(greaterThanOrEqualToConstant: 320).isActive = true

        telegramStatusLabel.font = NSFont.systemFont(ofSize: 11)
        telegramStatusLabel.preferredMaxLayoutWidth = 460
        telegramStatusLabel.lineBreakMode = .byWordWrapping
        telegramStatusLabel.maximumNumberOfLines = 3
        telegramStatusLabel.translatesAutoresizingMaskIntoConstraints = false
        telegramStatusLabel.textColor = Theme.textSecondary
        let statusStack = NSStackView(views: [telegramStatusLabel, telegramTestButton])
        statusStack.orientation = .vertical
        statusStack.alignment = .leading
        statusStack.spacing = 6

        if let host { telegramRulesView.panes = host.settingsDelegate?.settingsPaneTargets(host) ?? [] }
        telegramRulesView.onChange = { [weak self] rules in
            self?.write(["telegram": ["rules": GatewaySettings.rulesJSON(rules)]])
        }

        telegramSetupSummary.font = NSFont.systemFont(ofSize: 11)
        telegramSetupSummary.textColor = Theme.textSecondary
        telegramSetupSummary.lineBreakMode = .byWordWrapping
        telegramSetupSummary.maximumNumberOfLines = 2
        telegramSetupSummary.preferredMaxLayoutWidth = 460
        telegramSetupSummary.translatesAutoresizingMaskIntoConstraints = false
        telegramSetupButton.setAccessibilityIdentifier("settings.telegram.setup")
        let setupStack = NSStackView(views: [Self.gatewayLine(telegramGatewayLine), telegramSetupSummary,
                                             telegramSetupButton])
        setupStack.orientation = .vertical
        setupStack.alignment = .leading
        setupStack.spacing = 8

        defer { startFollowing() }
        setReachable(reachable)
        return [
            // First, because it is what almost everyone should use. The fields
            // below are the same values by hand, kept for a second account
            // added without re-pairing.
            SettingsGroupView(title: "Setup", rows: [
                SettingsRow.stacked(nil,
                                    subtitle: "Walks through creating a bot with @BotFather, checks the token, "
                                            + "and pairs your Telegram account by QR code \u{2014} no user IDs to look up.",
                                    content: setupStack),
            ]),
            SettingsGroupView(title: "Bot", rows: [
                SettingsRow.make("Bot token",
                                 subtitle: "Create a bot with @BotFather and paste its token here. seahelm-gateway keeps it in its own secrets file; it is never shown again.",
                                 control: telegramTokenField),
                SettingsRow.stacked("Allowed users",
                                    subtitle: "One per line: numeric user IDs (ask @userinfobot for yours) or @usernames. Only these may command the fleet; anyone else who messages the bot is ignored \u{2014} or matched against the triggers below. Empty ignores everyone.",
                                    content: SettingsControls.surface(telegramUsersScrollView),
                                    height: 90),
                SettingsRow.make("Notify",
                                 subtitle: "Chat id where agent-finished notifications go. Empty means the first numeric allowed user, or failing that the chat your last command came from.",
                                 control: telegramDefaultChatField),
                SettingsRow.make("Bot on", control: telegramEnabledToggle),
                SettingsRow.make("In a group",
                                 subtitle: "Send a slash command (/status, or /status@yourbot when several bots share the group), start a line with @yourbot, or reply to one of the bot's messages. A bare line in a group stays conversation \u{2014} only a private chat takes plain prose as an order."),
                SettingsRow.stacked(nil, content: statusStack),
            ]),
            SettingsGroupView(title: "Mini App", rows: [
                SettingsRow.stacked("Mini App URL",
                                    subtitle: "Opens seahelm-web inside Telegram, signed in as you \u{2014} no pairing code. It must be an https address that reaches seahelm-gateway's web port (a Cloudflare Tunnel, Tailscale Funnel or similar) and is not behind a login page of its own, since Telegram frames it. On that host the pairing code is refused: only a Telegram user on the list above gets in.",
                                    content: miniAppStack),
            ]),
            SettingsGroupView(title: "Triggers", rows: [
                SettingsRow.stacked(nil,
                                    subtitle: "Messages from anyone not on the allowed list \u{2014} a monitoring channel the bot sits in, a colleague in a group \u{2014} can put an agent to work. The first matching rule wins; nothing is replied to, and no pane or worktree is ever created.",
                                    content: telegramRulesView),
            ]),
        ]
    }

    private func refreshTelegramSetupSummary() {
        let t = settings.telegram
        let paired = t.allowedUsers.filter { !$0.isEmpty }.count
        switch (t.botTokenSet, paired) {
        case (false, _):
            telegramSetupSummary.stringValue = "Not set up yet."
            telegramSetupButton.title = "Set up Telegram\u{2026}"
        case (true, 0):
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

    /// What the Mini App URL will do, or why it will not.
    private func refreshTelegramMiniAppStatus() {
        let text = telegramMiniAppField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty {
            telegramMiniAppStatus.stringValue = "Off."
            telegramMiniAppStatus.textColor = Theme.textSecondary
        } else if !Self.isHTTPS(text) {
            telegramMiniAppStatus.stringValue = "Needs a full https:// address."
            telegramMiniAppStatus.textColor = .systemRed
        } else {
            telegramMiniAppStatus.stringValue = "The bot's menu button opens it. For the \u{201C}Open\u{201D} button in the chat list as well, "
                + "tell @BotFather: /mybots \u{25B8} your bot \u{25B8} Bot Settings \u{25B8} Configure Mini App, and send it this URL."
            telegramMiniAppStatus.textColor = Theme.textSecondary
        }
    }

    static func isHTTPS(_ text: String) -> Bool {
        guard let url = URL(string: text), url.scheme?.lowercased() == "https",
              let host = url.host, !host.isEmpty else { return false }
        return true
    }

    private static func lines(_ text: String) -> [String] {
        text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    @objc private func telegramTokenChanged() {
        let token = telegramTokenField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        // Empty leaves the saved token alone: the field never shows it.
        guard !token.isEmpty else { return }
        write(["telegram": ["bot_token": token]])
    }

    @objc private func telegramChatChanged() {
        write(["telegram": ["default_chat_id": telegramDefaultChatField.stringValue.trimmingCharacters(in: .whitespaces)]])
    }

    @objc private func telegramEnabledChanged() {
        write(["telegram": ["enabled": telegramEnabledToggle.state == .on]])
    }

    @objc private func telegramMiniAppChanged() {
        refreshTelegramMiniAppStatus()
        let text = telegramMiniAppField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.isEmpty || Self.isHTTPS(text) else { return }
        write(["telegram": ["mini_app_url": text]])
    }

    @objc private func copyMiniAppURLClicked() {
        let text = telegramMiniAppField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    @objc private func telegramSetupClicked() {
        let wizard = TelegramSetupWizard()
        wizard.onFinish = { [weak self] result in
            guard let self else { return }
            self.telegramStatusPinned = true
            self.telegramStatusLabel.stringValue =
                "Paired with \(result.displayName). Send /status from Telegram to check."
            self.telegramStatusLabel.textColor = Theme.textSecondary
            self.reload()
        }
        host?.presentAsSheet(wizard)
    }

    /// A token typed into the field is checked as typed; with the field empty,
    /// the saved one is asked about through the gateway's own status.
    @objc private func testTelegramClicked() {
        let token = telegramTokenField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        telegramStatusPinned = true
        telegramStatusLabel.textColor = Theme.textSecondary
        guard !token.isEmpty else {
            guard settings.telegram.botTokenSet else {
                telegramStatusLabel.stringValue = "Enter a bot token first."
                telegramStatusLabel.textColor = .systemOrange
                return
            }
            telegramStatusPinned = false
            refreshStatus()
            return
        }
        telegramStatusLabel.stringValue = "Contacting Telegram\u{2026}"
        GatewayClient.validateTelegramToken(token) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let check) where check.ok:
                let name = check.username.map { "@\($0)" } ?? "the bot"
                self.telegramStatusLabel.stringValue = "Telegram accepts it: \(name). Press Return in the field to save it."
                self.telegramStatusLabel.textColor = Theme.textSecondary
            case .success(let check):
                self.telegramStatusLabel.stringValue = check.error ?? "Telegram refused this token."
                self.telegramStatusLabel.textColor = .systemRed
            case .failure(let failure):
                self.telegramStatusLabel.stringValue = GatewayClient.describe(failure)
                self.telegramStatusLabel.textColor = .systemOrange
            }
        }
    }

    // MARK: - Pairing page

    func buildPairingGroups() -> [NSView] {
        pairingBuilt = true
        webPortField.target = self
        webPortField.action = #selector(webControlChanged)
        webPublicURLField.target = self
        webPublicURLField.action = #selector(webControlChanged)
        // A URL right-aligned truncates its host, which is the half worth seeing.
        webPublicURLField.alignment = .left
        webPublicURLField.font = AppFont.mono(size: 11, weight: .regular)

        webStatusLabel.font = .systemFont(ofSize: 11)
        webStatusLabel.textColor = SettingsPalette.secondary
        webStatusLabel.lineBreakMode = .byTruncatingMiddle
        webStatusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let pane = PairingPaneView()
        let devices = GatewayDevicesListView()
        let links = ShareLinksListView()
        pane.onRevokedAll = { [weak devices, weak links] in
            devices?.reload()
            links?.reload()
        }
        pairingPane = pane
        devicesList = devices
        shareLinksList = links

        defer { startFollowing() }
        setReachable(reachable)
        return [
            SettingsGroupView(title: "Web access", rows: [
                SettingsRow.stacked(nil, content: Self.gatewayLine(pairingGatewayLine)),
                SettingsRow.make("Serve browser clients",
                                 subtitle: "seahelm-gateway runs the web client and its WebSocket on one port of this Mac. Turning it on publishes nothing by itself \u{2014} reachability is whatever you point at that port \u{2014} and every session still has to pair.",
                                 control: webEnabledToggle,
                                 accessibilityId: "settings.hostGateway.enabled"),
                SettingsRow.make("Port",
                                 control: webPortField,
                                 accessibilityId: "settings.hostGateway.port"),
                SettingsRow.stacked("Public URL",
                                    subtitle: "Optional override for the access URL shown under Browser access (and Open page). Point a tunnel at the port above and paste its `http(s)://\u{2026}/` or leave empty for this Mac only.",
                                    content: webPublicURLField,
                                    height: 28),
                SettingsRow.actions([webOpenPageButton], leading: [webStatusLabel]),
            ]),
            SettingsGroupView(title: "Browser access", rows: [
                SettingsRow.stacked(nil,
                                    subtitle: "Open the access URL below in a browser and enter the pairing code.",
                                    content: pane),
            ]),
            SettingsGroupView(title: "Paired devices", rows: [
                SettingsRow.stacked(nil,
                                    subtitle: "Every browser and phone that signed in holds its own token. Revoking one signs it out and closes what it has open; the others stay paired.",
                                    content: devices),
            ]),
            SettingsGroupView(title: "Shared pane links", rows: [
                SettingsRow.stacked(nil,
                                    subtitle: "Links copied from the share button in the terminal header. Each opens its one pane without the pairing code, until it expires or is revoked here \u{2014} and a page open on it is closed the moment it is.",
                                    content: links),
            ]),
        ]
    }

    /// Revisiting the page shows what the gateway reports now.
    func pairingPageShown() {
        guard pairingBuilt else { return }
        reload()
    }

    @objc private func webControlChanged() {
        var web: [String: Any] = ["enabled": webEnabledToggle.state == .on]
        // A port that is not one keeps what is stored: 0 is the ephemeral
        // wildcard and would publish a link to nothing predictable.
        if let port = Int(webPortField.stringValue.trimmingCharacters(in: .whitespaces)), (1...65535).contains(port) {
            web["port"] = port
        } else {
            webPortField.stringValue = String(settings.web.port)
        }
        web["public_url"] = webPublicURLField.stringValue.trimmingCharacters(in: .whitespaces)
        write(["web": web])
    }

    @objc private func openWebPageClicked() {
        guard let url = URL(string: settings.web.pageURL) else { return }
        NSWorkspace.shared.open(url)
    }
}

// MARK: - NSTextViewDelegate

extension GatewaySettingsPages: NSTextViewDelegate {
    /// The allowlist applies when focus leaves, not per keystroke.
    func textDidEndEditing(_ notification: Notification) {
        guard notification.object as? NSTextView === telegramUsersView else { return }
        let users = Self.lines(telegramUsersView.string)
        guard users != settings.telegram.allowedUsers else { return }
        write(["telegram": ["allowed_users": users]])
    }
}
