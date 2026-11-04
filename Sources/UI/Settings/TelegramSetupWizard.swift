import AppKit

/// What the wizard hands back when it finishes. seahelm-gateway has already
/// written the pairing down (`allowed_users`, `default_chat_id`); this is for
/// the confirmation line.
struct TelegramSetupResult: Equatable {
    /// The paired Telegram user id.
    let userId: String
    /// `@username` or first name — for the confirmation line, not for config.
    let displayName: String
    /// The chat the pairing happened in; where notifications go.
    let chatId: String
    let autoConnect: Bool
}

/// The one-time code the bot is waiting for, and how long it is good for.
private struct TelegramPairingCode {
    /// How long the wizard shows a code before asking for a fresh one.
    static let ttl: TimeInterval = 10 * 60
    let code: String
    let deepLink: String
    let expiresAt: Date
}

/// Guided Telegram setup: create a bot, paste its token, scan to pair, done.
///
/// The flow this replaces was seven steps across two apps, and two of them —
/// "ask @userinfobot for your numeric id" and "work out what a chat id is" —
/// were asking the user to do a lookup the bot itself performs for free the
/// moment they send it anything. Pairing collapses those into a QR code.
///
/// The bot lives in seahelm-gateway: the token is checked with
/// `telegram.validate_token`, saved with `gateway.config.set` when pairing
/// starts (the gateway has to poll the bot to see `/start`), and the code comes
/// from `telegram.pair.begin`; `telegram.paired` on `events.subscribe` says it
/// was claimed.
final class TelegramSetupWizard: NSViewController {
    enum Step: Int, CaseIterable {
        case createBot, token, pair, done

        var title: String {
            switch self {
            case .createBot: return "Create your bot"
            case .token: return "Paste the token"
            case .pair: return "Scan to connect"
            case .done: return "Ready"
            }
        }
    }

    var onFinish: ((TelegramSetupResult) -> Void)?
    var onCancel: (() -> Void)?

    private let events = GatewayEventStream()
    private var step: Step = .createBot { didSet { render() } }

    // Collected state
    private var token = ""
    private var botUsername: String?
    private var pairResult: TelegramSetupResult?
    private var pairing: TelegramPairingCode?
    /// Bumped per `pair.begin` so a slow answer for an abandoned code cannot
    /// land on the screen showing a newer one.
    private var pairGeneration = 0
    private var autoConnect = true

    // Chrome
    private let dots = NSStackView()
    private let titleLabel = WizardStyle.label("", size: 19, weight: .semibold)
    private let content = NSView()
    private let backButton = WizardSecondaryButton(text: "Back")
    private let cancelButton = WizardSecondaryButton(text: "Cancel")
    private let primaryButton = WizardPrimaryButton()

    // Step 2
    private let tokenTextView = NSTextView()
    private let tokenStatus = WizardStatusPill()
    private var validateWork: DispatchWorkItem?
    /// Bumped per validation so a slow reply for an old token cannot overwrite
    /// the verdict on the one now in the box.
    private var validateGeneration = 0

    // Step 3
    private let qrView = QRCodeView(side: 168)
    private let codeLabel = WizardStyle.monoLabel("", size: 19, weight: .semibold,
                                                      color: WizardStyle.textPrimary)
    private let pairStatus = WizardStatusPill()
    private let expiryLabel = WizardStyle.label("", size: 11,
                                                    color: WizardStyle.textFaint)
    private var expiryTimer: Timer?

    init() {
        super.init(nibName: nil, bundle: nil)
        events.onEvent = { [weak self] type, event in
            guard type == "telegram.paired" else { return }
            self?.paired(event)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    deinit {
        expiryTimer?.invalidate()
        validateWork?.cancel()
        events.stop()
    }

    // MARK: - Layout

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 560, height: 560))
        root.wantsLayer = true
        view = root

        for i in 0..<Step.allCases.count {
            let dot = NSView()
            dot.wantsLayer = true
            dot.layer?.cornerRadius = 3
            dot.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                dot.heightAnchor.constraint(equalToConstant: 6),
                dot.widthAnchor.constraint(equalToConstant: i == 0 ? 18 : 6),
            ])
            dots.addArrangedSubview(dot)
        }
        dots.orientation = .horizontal
        dots.spacing = 5
        dots.translatesAutoresizingMaskIntoConstraints = false

        content.translatesAutoresizingMaskIntoConstraints = false

        backButton.target = self
        backButton.action = #selector(backClicked)
        cancelButton.target = self
        cancelButton.action = #selector(cancelClicked)
        primaryButton.target = self
        primaryButton.action = #selector(primaryClicked)
        primaryButton.keyEquivalent = "\r"
        primaryButton.keyEquivalentModifierMask = .command
        primaryButton.heightAnchor.constraint(equalToConstant: 34).isActive = true

        let footer = NSStackView(views: [cancelButton, backButton, Self.spacer(), primaryButton])
        footer.orientation = .horizontal
        footer.spacing = 8
        footer.translatesAutoresizingMaskIntoConstraints = false

        for v in [dots, titleLabel, content, footer] as [NSView] { root.addSubview(v) }

        NSLayoutConstraint.activate([
            dots.topAnchor.constraint(equalTo: root.topAnchor, constant: 26),
            dots.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 28),

            titleLabel.topAnchor.constraint(equalTo: dots.bottomAnchor, constant: 14),
            titleLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 28),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -28),

            content.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 16),
            content.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 28),
            content.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -28),

            footer.topAnchor.constraint(greaterThanOrEqualTo: content.bottomAnchor, constant: 16),
            footer.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 28),
            footer.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -28),
            footer.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -22),
        ])

        preferredContentSize = NSSize(width: 560, height: 560)
        render()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(primaryButton)
    }

    /// Belt and braces: the sheet can also go away with the Settings window,
    /// and an armed code must not outlive the screen showing it.
    override func viewDidDisappear() {
        super.viewDidDisappear()
        endPairing()
    }

    // MARK: - Rendering

    private func render() {
        titleLabel.stringValue = step.title
        renderDots()

        content.subviews.forEach { $0.removeFromSuperview() }
        let body: NSView
        switch step {
        case .createBot: body = buildCreateBotStep()
        case .token: body = buildTokenStep()
        case .pair: body = buildPairStep()
        case .done: body = buildDoneStep()
        }
        body.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(body)
        NSLayoutConstraint.activate([
            body.topAnchor.constraint(equalTo: content.topAnchor),
            body.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            body.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            body.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])

        backButton.isHidden = step == .createBot
        // Pairing has no "continue": the phone advances the step, so a button
        // that only ever sat there disabled would read as something broken.
        primaryButton.isHidden = step == .pair
        switch step {
        case .createBot: primaryButton.text = "I have a token"
        case .token: primaryButton.text = "Continue"
        case .pair: primaryButton.text = ""
        case .done: primaryButton.text = "Done"
        }
        primaryButton.isEnabled = step != .token || botUsername != nil
        cancelButton.text = step == .done ? "Close" : "Cancel"
    }

    private func renderDots() {
        for (index, dot) in dots.arrangedSubviews.enumerated() {
            let done = index <= step.rawValue
            dot.layer?.backgroundColor = view.resolvedCGColor(
                done ? WizardStyle.accent : WizardStyle.stroke)
            // The current step's dot stretches into a capsule, so the position
            // in the flow reads without counting.
            for c in dot.constraints where c.firstAttribute == .width {
                c.constant = index == step.rawValue ? 18 : 6
            }
        }
    }

    // MARK: - Step 1: create the bot

    private func buildCreateBotStep() -> NSView {
        let blurb = WizardStyle.wrappingLabel(
            "Telegram makes bots, not seahelm — @BotFather is the bot that makes bots. "
            + "It takes about a minute, and the bot is yours: its token stays on this Mac "
            + "and no traffic goes through us.", size: 12.5)

        let panel = WizardPanel()
        panel.showsSelectionGlow = false
        let rows = NSStackView(views: [
            instructionRow(1, "Open @BotFather in Telegram."),
            instructionRow(2, "Send it ", mono: "/newbot", trailing: "."),
            instructionRow(3, "Give the bot a display name — anything, e.g. “My Fleet”."),
            instructionRow(4, "Give it a username ending in ", mono: "bot",
                           trailing: ", e.g. matt_fleet_bot."),
            instructionRow(5, "It replies with a token. Copy the whole message."),
        ])
        rows.orientation = .vertical
        rows.alignment = .leading
        rows.spacing = 9
        rows.translatesAutoresizingMaskIntoConstraints = false
        panel.addSubview(rows)
        NSLayoutConstraint.activate([
            rows.topAnchor.constraint(equalTo: panel.topAnchor, constant: 16),
            rows.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 16),
            rows.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -16),
            rows.bottomAnchor.constraint(equalTo: panel.bottomAnchor, constant: -16),
        ])

        let open = WizardSecondaryButton(text: "Open @BotFather", symbol: "arrow.up.forward.app")
        open.target = self
        open.action = #selector(openBotFatherClicked)

        let hint = WizardStyle.label("Copies /newbot to the clipboard on the way.",
                                         size: 11, color: WizardStyle.textFaint)

        let openRow = NSStackView(views: [open, hint])
        openRow.orientation = .horizontal
        openRow.spacing = 10
        openRow.alignment = .centerY

        return verticalStack([blurb, panel, openRow], spacing: 16)
    }

    // MARK: - Step 2: the token

    private func buildTokenStep() -> NSView {
        let blurb = WizardStyle.wrappingLabel(
            "Paste BotFather's reply — the whole message is fine, the token will be picked "
            + "out of it. It is checked against Telegram as soon as it looks complete.",
            size: 12.5)

        tokenTextView.font = AppFont.mono(size: 12, weight: .regular)
        tokenTextView.isRichText = false
        tokenTextView.isAutomaticQuoteSubstitutionEnabled = false
        tokenTextView.isAutomaticDashSubstitutionEnabled = false
        tokenTextView.drawsBackground = false
        tokenTextView.textColor = WizardStyle.textPrimary
        tokenTextView.textContainerInset = NSSize(width: 8, height: 8)
        tokenTextView.delegate = self
        tokenTextView.setAccessibilityIdentifier("telegram.setup.token")
        // A pasted BotFather reply is several lines; let the view grow and wrap
        // inside the scroller rather than scroll sideways off the token.
        tokenTextView.minSize = NSSize(width: 0, height: 0)
        tokenTextView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                       height: CGFloat.greatestFiniteMagnitude)
        tokenTextView.isVerticallyResizable = true
        tokenTextView.isHorizontallyResizable = false
        tokenTextView.autoresizingMask = [.width]
        tokenTextView.textContainer?.widthTracksTextView = true

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        scroll.documentView = tokenTextView
        scroll.translatesAutoresizingMaskIntoConstraints = false

        let box = WizardPanel()
        box.showsSelectionGlow = false
        box.addSubview(scroll)
        NSLayoutConstraint.activate([
            box.heightAnchor.constraint(equalToConstant: 86),
            scroll.topAnchor.constraint(equalTo: box.topAnchor, constant: 1),
            scroll.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 1),
            scroll.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -1),
            scroll.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -1),
        ])

        let paste = WizardSecondaryButton(text: "Paste", symbol: "doc.on.clipboard")
        paste.target = self
        paste.action = #selector(pasteTokenClicked)

        let statusRow = NSStackView(views: [paste, tokenStatus, Self.spacer()])
        statusRow.orientation = .horizontal
        statusRow.spacing = 10
        statusRow.alignment = .centerY

        // Nothing typed yet is not a state worth a pill; it would only ever say
        // "waiting for input" beside an empty box.
        tokenStatus.isHidden = tokenTextView.string.trimmingCharacters(
            in: .whitespacesAndNewlines).isEmpty

        return verticalStack([blurb, box, statusRow], spacing: 14)
    }

    // MARK: - Step 3: pair

    private func buildPairStep() -> NSView {
        let blurb = WizardStyle.wrappingLabel(
            "Point your phone's camera at the code. Telegram opens on your bot with a Start "
            + "button — tap it, and this Mac learns who you are. Nobody else can use the bot.",
            size: 12.5)

        qrView.payload = pairing?.deepLink ?? ""

        let orLabel = WizardStyle.label("Or send this code to \(botHandle):", size: 11.5,
                                            color: WizardStyle.textSecondary)
        codeLabel.stringValue = pairing.map { formatted($0.code) } ?? "\u{2014}"

        let openTelegram = WizardSecondaryButton(text: "Open in Telegram",
                                                     symbol: "arrow.up.forward.app")
        openTelegram.target = self
        openTelegram.action = #selector(openDeepLinkClicked)

        let newCode = WizardLinkButton(title: "New code", size: 11.5)
        newCode.target = self
        newCode.action = #selector(newCodeClicked)

        let expiryRow = NSStackView(views: [expiryLabel, newCode])
        expiryRow.orientation = .horizontal
        expiryRow.spacing = 8
        expiryRow.alignment = .centerY

        let side = NSStackView(views: [orLabel, codeLabel, openTelegram, expiryRow])
        side.orientation = .vertical
        side.alignment = .leading
        side.spacing = 10

        let columns = NSStackView(views: [qrView, side])
        columns.orientation = .horizontal
        columns.alignment = .top
        columns.spacing = 22

        if pairing == nil {
            pairStatus.state = .pending("Starting the bot in seahelm-gateway…")
            startPairing()
        } else {
            pairStatus.state = .pending("Waiting for you to tap Start…")
            startExpiryTimer()
        }

        return verticalStack([blurb, columns, pairStatus], spacing: 18)
    }

    // MARK: - Step 4: done

    private func buildDoneStep() -> NSView {
        let who = pairResult?.displayName ?? "your account"
        let headline = WizardStyle.wrappingLabel(
            "\(botHandle) is paired with \(who). Agent notifications go to that chat, and "
            + "anything you send it steers the fleet.", size: 12.5)

        let panel = WizardPanel()
        panel.showsSelectionGlow = false
        let rows = NSStackView(views: [
            instructionRow(nil, "Send ", mono: "/status", trailing: " to see what is running."),
            instructionRow(nil, "Type ", mono: "/", trailing: " for the command menu — it is published to Telegram."),
            instructionRow(nil, "In a group, only slash commands reach the bot: ",
                           mono: "/status@\(botUsername ?? "yourbot")", trailing: "."),
        ])
        rows.orientation = .vertical
        rows.alignment = .leading
        rows.spacing = 9
        rows.translatesAutoresizingMaskIntoConstraints = false
        panel.addSubview(rows)
        NSLayoutConstraint.activate([
            rows.topAnchor.constraint(equalTo: panel.topAnchor, constant: 16),
            rows.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 16),
            rows.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -16),
            rows.bottomAnchor.constraint(equalTo: panel.bottomAnchor, constant: -16),
        ])

        let toggleRow = WizardToggleRow(
            title: "Connect at launch",
            subtitle: "Bring the bridge up whenever seahelm starts.",
            symbol: "bolt.horizontal",
            tint: { WizardStyle.accent })
        toggleRow.isOn = autoConnect
        toggleRow.toggle.target = self
        toggleRow.toggle.action = #selector(autoConnectChanged(_:))

        return verticalStack([headline, panel, toggleRow], spacing: 16)
    }

    // MARK: - Pairing

    /// Save the token in the gateway (enabled, so it polls), then ask it for a
    /// code. The gateway adds whoever sends `/start <code>` to the allowlist.
    private func startPairing() {
        pairGeneration += 1
        let generation = pairGeneration
        events.start()
        GatewayClient.setConfig(["telegram": ["bot_token": token, "enabled": true]]) { [weak self] result in
            guard let self, generation == self.pairGeneration else { return }
            if case .failure(let failure) = result {
                self.pairStatus.state = .failed(GatewayClient.describe(failure))
                return
            }
            GatewayClient.beginTelegramPairing { [weak self] result in
                guard let self, generation == self.pairGeneration, self.step == .pair else { return }
                switch result {
                case .success(let begun) where !begun.code.isEmpty:
                    self.showCode(begun)
                case .success:
                    self.pairStatus.state = .failed("seahelm-gateway gave no code.")
                case .failure(let failure):
                    self.pairStatus.state = .failed(GatewayClient.describe(failure))
                }
            }
        }
    }

    private func showCode(_ begun: GatewayTelegramPairing) {
        let link = begun.deepLink.isEmpty ? deepLink(code: begun.code) : begun.deepLink
        pairing = TelegramPairingCode(code: begun.code, deepLink: link,
                                      expiresAt: Date().addingTimeInterval(TelegramPairingCode.ttl))
        qrView.payload = link
        codeLabel.stringValue = formatted(begun.code)
        pairStatus.state = .pending("Waiting for you to tap Start…")
        startExpiryTimer()
    }

    /// `telegram.paired {user_id, display, chat_id}`.
    private func paired(_ event: [String: Any]) {
        guard step == .pair, pairing != nil else { return }
        func text(_ key: String) -> String {
            if let s = event[key] as? String { return s }
            if let n = event[key] as? NSNumber { return n.stringValue }
            return ""
        }
        let userId = text("user_id")
        let display = text("display")
        let result = TelegramSetupResult(userId: userId, displayName: display.isEmpty ? userId : display,
                                         chatId: text("chat_id"), autoConnect: autoConnect)
        pairResult = result
        pairing = nil
        pairStatus.state = .ok("Paired with \(result.displayName)")
        expiryTimer?.invalidate()
        // A beat on the green pill, so the step that just succeeded is seen
        // to have succeeded rather than vanishing under the next one.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard let self, self.step == .pair else { return }
            self.step = .done
        }
    }

    /// Disarm the code, if one is out. Safe to call when none is.
    private func endPairing() {
        expiryTimer?.invalidate()
        events.stop()
        pairGeneration += 1
        if pairing != nil {
            GatewayClient.cancelTelegramPairing()
            pairing = nil
        }
    }

    private func startExpiryTimer() {
        expiryTimer?.invalidate()
        let timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.tickExpiry()
        }
        RunLoop.main.add(timer, forMode: .common)
        expiryTimer = timer
        tickExpiry()
    }

    private func tickExpiry() {
        guard let pairing, step == .pair else { return }
        let remaining = pairing.expiresAt.timeIntervalSinceNow
        guard remaining > 0 else {
            expiryLabel.stringValue = "Code expired."
            pairStatus.state = .failed("Code expired — generate a new one.")
            expiryTimer?.invalidate()
            GatewayClient.cancelTelegramPairing()
            return
        }
        let minutes = Int(remaining) / 60
        let seconds = Int(remaining) % 60
        expiryLabel.stringValue = String(format: "Expires in %d:%02d", minutes, seconds)
    }

    // MARK: - Token validation

    private func scheduleValidation() {
        validateWork?.cancel()
        tokenStatus.isHidden = tokenTextView.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        botUsername = nil
        primaryButton.isEnabled = false

        guard let candidate = Self.extractToken(from: tokenTextView.string) else {
            if !tokenStatus.isHidden {
                tokenStatus.state = .pending("Looking for a token like 123456789:AAF…")
            }
            return
        }
        tokenStatus.state = .pending("Checking with Telegram…")
        let work = DispatchWorkItem { [weak self] in self?.validate(candidate) }
        validateWork = work
        // Typing (or pasting a line at a time) should not fire a round trip per
        // keystroke; the pause is short enough that a paste feels immediate.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
    }

    private func validate(_ candidate: String) {
        validateGeneration += 1
        let generation = validateGeneration
        GatewayClient.validateTelegramToken(candidate) { [weak self] result in
            guard let self, generation == self.validateGeneration else { return }
            switch result {
            case .success(let check) where check.ok:
                self.token = candidate
                self.botUsername = check.username
                self.tokenStatus.state = .ok("Connected as \(self.botHandle)")
                self.primaryButton.isEnabled = true
            case .success(let check):
                self.tokenStatus.state = .failed(check.error ?? "Telegram refused this token.")
                self.primaryButton.isEnabled = false
            case .failure(let failure):
                self.tokenStatus.state = .failed(GatewayClient.describe(failure))
                self.primaryButton.isEnabled = false
            }
        }
    }

    /// Pull a bot token out of whatever was pasted. BotFather's reply is a
    /// paragraph with the token in the middle of it, and asking people to
    /// select exactly the token is asking for a truncated paste.
    static func extractToken(from raw: String) -> String? {
        let pattern = "[0-9]{5,16}:[A-Za-z0-9_-]{30,}"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(raw.startIndex..<raw.endIndex, in: raw)
        guard let match = regex.firstMatch(in: raw, range: range),
              let matched = Range(match.range, in: raw) else { return nil }
        return String(raw[matched])
    }

    // MARK: - Actions

    @objc private func primaryClicked() {
        switch step {
        case .createBot:
            step = .token
        case .token:
            guard botUsername != nil else { return }
            step = .pair
        case .pair:
            break
        case .done:
            finish()
        }
    }

    @objc private func backClicked() {
        switch step {
        case .createBot:
            break
        case .token:
            step = .createBot
        case .pair:
            // Leaving the step disarms the code: it exists only while its QR is
            // on screen.
            endPairing()
            step = .token
        case .done:
            step = .pair
        }
    }

    @objc private func cancelClicked() {
        // `done` reaches here as "Close": pairing already happened and writing
        // it down is the only thing left, so closing saves rather than discards.
        if step == .done {
            finish()
            return
        }
        endPairing()
        onCancel?()
        dismiss(nil)
    }

    private func finish() {
        endPairing()
        guard let result = pairResult else {
            dismiss(nil)
            return
        }
        let finished = TelegramSetupResult(userId: result.userId, displayName: result.displayName,
                                           chatId: result.chatId, autoConnect: autoConnect)
        // The pairing itself is already in the gateway; only the switch is left.
        GatewayClient.setConfig(["telegram": ["enabled": autoConnect]]) { [weak self] _ in
            self?.onFinish?(finished)
        }
        dismiss(nil)
    }

    @objc private func autoConnectChanged(_ sender: NSSwitch) {
        autoConnect = sender.state == .on
    }

    @objc private func openBotFatherClicked() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("/newbot", forType: .string)
        // The https link rather than `tg://`: it opens the app when Telegram is
        // installed and the web client when it is not, where `tg://` would fail
        // with nothing on screen to explain it.
        if let url = URL(string: "https://t.me/BotFather") { NSWorkspace.shared.open(url) }
    }

    @objc private func openDeepLinkClicked() {
        guard let pairing, let url = URL(string: pairing.deepLink) else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func newCodeClicked() {
        endPairing()
        pairStatus.state = .pending("Asking seahelm-gateway for a new code…")
        startPairing()
    }

    @objc private func pasteTokenClicked() {
        guard let pasted = NSPasteboard.general.string(forType: .string) else { return }
        tokenTextView.string = pasted
        scheduleValidation()
    }

    // MARK: - Helpers

    private var botHandle: String {
        if let botUsername, !botUsername.isEmpty { return "@\(botUsername)" }
        return "your bot"
    }

    private func deepLink(code: String) -> String {
        guard let botUsername, !botUsername.isEmpty else { return "" }
        return "https://t.me/\(botUsername)?start=\(code)"
    }

    /// `ABCD 2345` — grouped, because an eight-character code read off a screen
    /// and typed into a phone is read in halves.
    private func formatted(_ code: String) -> String {
        guard code.count == 8 else { return code }
        let mid = code.index(code.startIndex, offsetBy: 4)
        return "\(code[..<mid]) \(code[mid...])"
    }

    /// Vertical stack whose block-level children (prose, panels, the toggle
    /// row) span the full width while inline rows of buttons keep hugging their
    /// content.
    private func verticalStack(_ views: [NSView], spacing: CGFloat) -> NSView {
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = spacing
        for view in views where view is NSTextField || view is WizardPanel
            || view is WizardToggleRow {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        return stack
    }

    /// A stack view divider that soaks up the slack, so what follows it is
    /// pushed to the trailing edge.
    private static func spacer() -> NSView {
        let view = NSView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.setContentHuggingPriority(.init(1), for: .horizontal)
        view.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        return view
    }

    /// `1  Send /newbot.` — the number in an accent circle, the sentence beside
    /// it, with an optional mono run in the middle for the literal to type.
    private func instructionRow(_ number: Int?, _ leading: String,
                                mono: String? = nil, trailing: String = "") -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .firstBaseline
        row.spacing = 9
        row.translatesAutoresizingMaskIntoConstraints = false

        let marker: NSTextField
        if let number {
            marker = WizardStyle.monoLabel("\(number)", size: 11.5, weight: .semibold,
                                               color: WizardStyle.accent)
        } else {
            marker = WizardStyle.label("•", size: 12.5, color: WizardStyle.accent)
        }
        marker.setContentHuggingPriority(.required, for: .horizontal)
        marker.widthAnchor.constraint(equalToConstant: 12).isActive = true

        let text = NSTextField(labelWithAttributedString: sentence(leading, mono: mono,
                                                                   trailing: trailing))
        text.translatesAutoresizingMaskIntoConstraints = false
        text.lineBreakMode = .byWordWrapping
        text.maximumNumberOfLines = 3
        text.preferredMaxLayoutWidth = 430

        row.addArrangedSubview(marker)
        row.addArrangedSubview(text)
        return row
    }

    private func sentence(_ leading: String, mono: String?, trailing: String) -> NSAttributedString {
        let body: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12.5),
            .foregroundColor: WizardStyle.textSecondary,
        ]
        let code: [NSAttributedString.Key: Any] = [
            .font: AppFont.mono(size: 12, weight: .medium),
            .foregroundColor: WizardStyle.textPrimary,
        ]
        let out = NSMutableAttributedString(string: leading, attributes: body)
        if let mono {
            out.append(NSAttributedString(string: mono, attributes: code))
            out.append(NSAttributedString(string: trailing, attributes: body))
        }
        return out
    }
}

// MARK: - NSTextViewDelegate

extension TelegramSetupWizard: NSTextViewDelegate {
    func textDidChange(_ notification: Notification) {
        guard (notification.object as? NSTextView) === tokenTextView else { return }
        scheduleValidation()
    }
}
