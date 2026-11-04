import AppKit

/// Browser pairing UI: the pairing code + access URL (no QR / long link).
///
/// The page URL the browser already opened is the entry; the code only
/// authorizes. Settings and the menu pairing window share this pane. Every
/// value comes from seahelm-gateway (`pairing.code.*`, `pairing.revoke_all`);
/// while the gateway does not answer the pane says so and its buttons are off.
final class PairingPaneView: NSView {
    private(set) var accessURL = "" {
        didSet { urlField.stringValue = accessURL.isEmpty ? "\u{2014}" : accessURL }
    }

    /// After a revoke-all, so the page can reload what it lost with it
    /// (share links, devices).
    var onRevokedAll: (() -> Void)?

    private let codeLabel = NSTextField(labelWithString: "")
    private let urlField = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")
    private var buttons: [NSButton] = []
    private var currentCode = ""

    init() {
        super.init(frame: .zero)
        build()
        setReachable(false, message: "Asking seahelm-gateway\u{2026}")
        reload()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Read the code and the access URL from the gateway again.
    func reload() {
        GatewayClient.pairingCode { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let pairing):
                self.apply(pairing)
            case .failure(let failure):
                self.setReachable(false, message: GatewayClient.describe(failure))
            }
        }
    }

    private func apply(_ pairing: GatewayPairingCode) {
        setReachable(true)
        setCode(pairing.code)
        if !pairing.pairURL.isEmpty {
            accessURL = pairing.pairURL
        } else {
            // No public URL: the gateway's own listener on this Mac.
            GatewayClient.config { [weak self] result in
                if case .success(let settings) = result { self?.accessURL = settings.web.pageURL }
            }
        }
    }

    private func setCode(_ code: String) {
        currentCode = GatewayPairingCode.normalize(code)
        codeLabel.stringValue = currentCode.isEmpty ? "\u{2014}" : GatewayPairingCode.grouped(code)
    }

    private func setReachable(_ reachable: Bool, message: String? = nil) {
        for button in buttons { button.isEnabled = reachable }
        statusLabel.stringValue = message ?? ""
        statusLabel.isHidden = reachable && message == nil
        if !reachable {
            codeLabel.stringValue = "\u{2014}"
            currentCode = ""
        }
    }

    // MARK: - UI

    private func build() {
        translatesAutoresizingMaskIntoConstraints = false

        let hint = NSTextField(labelWithString:
            "Open the access URL in a browser, then enter this code. It stays until you change it.")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        hint.maximumNumberOfLines = 2
        hint.lineBreakMode = .byWordWrapping
        hint.preferredMaxLayoutWidth = 360

        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .systemOrange
        statusLabel.setAccessibilityIdentifier("pairing.gatewayStatus")

        codeLabel.font = .monospacedSystemFont(ofSize: 28, weight: .semibold)
        codeLabel.alignment = .center
        codeLabel.setContentHuggingPriority(.required, for: .vertical)

        let urlCaption = NSTextField(labelWithString: "Access URL")
        urlCaption.font = .systemFont(ofSize: 11)
        urlCaption.textColor = .secondaryLabelColor
        urlField.isSelectable = true
        urlField.lineBreakMode = .byTruncatingMiddle
        urlField.font = .monospacedSystemFont(ofSize: 11, weight: .regular)

        let copyCode = NSButton(title: "Copy code", target: self, action: #selector(copyCodeClicked))
        let refresh = NSButton(title: "Refresh code", target: self, action: #selector(refreshClicked))
        let setOwn = NSButton(title: "Set code…", target: self, action: #selector(setClicked))
        let copyURL = NSButton(title: "Copy URL", target: self, action: #selector(copyURLClicked))
        let revoke = NSButton(title: "Revoke all remotes", target: self, action: #selector(revokeClicked))
        revoke.hasDestructiveAction = true
        buttons = [copyCode, refresh, setOwn, copyURL, revoke]

        // Two rows: the code's own actions, then the link's and the reset — five
        // buttons in one row ran past the pairing window.
        func row(_ views: [NSView]) -> NSStackView {
            let row = NSStackView(views: views)
            row.orientation = .horizontal
            row.spacing = 8
            row.alignment = .centerY
            return row
        }

        let stack = NSStackView(views: [
            hint, statusLabel, codeLabel, row([copyCode, refresh, setOwn]), urlCaption, urlField,
            row([copyURL, revoke]),
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            codeLabel.centerXAnchor.constraint(equalTo: stack.centerXAnchor),
        ])
    }

    // MARK: - Actions

    @objc private func copyCodeClicked() {
        guard !currentCode.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(currentCode, forType: .string)
    }

    @objc private func copyURLClicked() {
        guard !accessURL.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(accessURL, forType: .string)
    }

    @objc private func refreshClicked() {
        GatewayClient.refreshPairingCode { [weak self] result in
            switch result {
            case .success(let pairing): self?.apply(pairing)
            case .failure(let failure): self?.setReachable(false, message: GatewayClient.describe(failure))
            }
        }
    }

    @objc private func setClicked() {
        let lengths = GatewayPairingCode.lengths
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.font = .monospacedSystemFont(ofSize: 15, weight: .regular)
        field.placeholderString = "1234 5678"
        promptForCode(field: field, message: "\(lengths.lowerBound)–\(lengths.upperBound) digits. Browsers already paired stay paired.")
    }

    /// Ask until the gateway takes a code or the user cancels.
    private func promptForCode(field: NSTextField, message: String) {
        let lengths = GatewayPairingCode.lengths
        let alert = NSAlert()
        alert.messageText = "Set pairing code"
        alert.informativeText = message
        alert.accessoryView = field
        alert.addButton(withTitle: "Set")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let retry = "Use \(lengths.lowerBound)–\(lengths.upperBound) digits; spaces and dashes are fine."
        let digits = GatewayPairingCode.normalize(field.stringValue)
        guard lengths.contains(digits.count) else {
            promptForCode(field: field, message: retry)
            return
        }
        GatewayClient.setPairingCode(digits) { [weak self] result in
            switch result {
            case .success(let pairing):
                self?.apply(pairing)
            case .failure(.rpc(let code, _)) where code == -32602:
                self?.promptForCode(field: field, message: retry)
            case .failure(let failure):
                self?.setReachable(false, message: GatewayClient.describe(failure))
            }
        }
    }

    @objc private func revokeClicked() {
        GatewayClient.revokeAll { [weak self] result in
            guard let self else { return }
            if case .failure(let failure) = result {
                self.setReachable(false, message: GatewayClient.describe(failure))
                return
            }
            self.reload()
            self.onRevokedAll?()
        }
    }
}

/// Every browser and phone holding its own token (`devices.list`), each with a
/// Revoke that drops its open connections.
final class GatewayDevicesListView: NSView {
    private let stack = NSStackView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        setAccessibilityIdentifier("settings.devices")
        reload()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func reload() {
        GatewayClient.devices { [weak self] result in
            switch result {
            case .success(let devices): self?.show(devices)
            case .failure(let failure): self?.showLine(GatewayClient.describe(failure), warning: true)
            }
        }
    }

    private func show(_ devices: [GatewayDevice]) {
        guard !devices.isEmpty else {
            showLine("No browser or phone is paired.", warning: false)
            return
        }
        clear()
        let now = Date()
        let sorted = devices.sorted { ($0.lastSeenAt ?? .distantPast) > ($1.lastSeenAt ?? .distantPast) }
        for device in sorted {
            let row = makeRow(device, now: now)
            stack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
    }

    private func clear() {
        for view in stack.arrangedSubviews { view.removeFromSuperview() }
    }

    private func showLine(_ text: String, warning: Bool) {
        clear()
        let line = NSTextField(labelWithString: text)
        line.font = .systemFont(ofSize: 12)
        line.textColor = warning ? .systemOrange : SettingsPalette.secondary
        stack.addArrangedSubview(line)
    }

    private func makeRow(_ device: GatewayDevice, now: Date) -> NSView {
        let label = device.label.isEmpty ? "Unnamed device" : device.label
        let name = NSTextField(labelWithString: device.connected ? "\(label) \u{00B7} connected" : label)
        name.font = .systemFont(ofSize: 12, weight: .medium)
        name.lineBreakMode = .byTruncatingTail
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let detail = NSTextField(labelWithString: Self.detail(device, now: now))
        detail.font = .systemFont(ofSize: 11)
        detail.textColor = SettingsPalette.secondary
        detail.lineBreakMode = .byTruncatingTail
        detail.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let text = NSStackView(views: [name, detail])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 2

        let revoke = NSButton(title: "Revoke", target: self, action: #selector(revokeClicked(_:)))
        revoke.bezelStyle = .rounded
        revoke.font = .systemFont(ofSize: 12)
        revoke.identifier = NSUserInterfaceItemIdentifier(device.id)
        revoke.setAccessibilityIdentifier("settings.devices.revoke")

        let row = NSStackView(views: [text, revoke])
        row.distribution = .fill
        row.spacing = 12
        text.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return row
    }

    /// "Pairing code · last seen 10:42", or "· never seen".
    static func detail(_ device: GatewayDevice, now: Date) -> String {
        let via: String
        switch device.via {
        case "code": via = "Pairing code"
        case "telegram": via = "Telegram"
        case "legacy": via = "Paired before devices"
        default: via = device.via.isEmpty ? "Paired" : device.via
        }
        guard let seen = device.lastSeenAt else { return via + " \u{00B7} never seen" }
        return via + " \u{00B7} last seen " + formatter.string(from: seen)
    }

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .short
        f.doesRelativeDateFormatting = true
        return f
    }()

    @objc private func revokeClicked(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue else { return }
        sender.isEnabled = false
        GatewayClient.revokeDevice(id: id) { [weak self] _ in self?.reload() }
    }
}

/// Standalone "Pair remote client" window. Settings hosts the same panes; the
/// menu item stays a direct route when pairing with a phone already in hand.
final class PairingWindowController: NSWindowController {
    private let pane = PairingPaneView()
    private let devices = GatewayDevicesListView()
    private let events = GatewayEventStream()

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 460),
                              styleMask: [.titled, .closable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "Pair browser client"
        super.init(window: window)

        guard let content = window.contentView else { return }
        let title = NSTextField(labelWithString: "Enter this code in the browser")
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        title.translatesAutoresizingMaskIntoConstraints = false
        let devicesTitle = NSTextField(labelWithString: "Paired devices")
        devicesTitle.font = .systemFont(ofSize: 13, weight: .semibold)
        devicesTitle.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(title)
        content.addSubview(pane)
        content.addSubview(devicesTitle)
        content.addSubview(devices)

        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: content.topAnchor, constant: 18),
            title.centerXAnchor.constraint(equalTo: content.centerXAnchor),

            pane.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 10),
            pane.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 18),
            pane.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -18),

            devicesTitle.topAnchor.constraint(equalTo: pane.bottomAnchor, constant: 20),
            devicesTitle.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 18),

            devices.topAnchor.constraint(equalTo: devicesTitle.bottomAnchor, constant: 8),
            devices.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 18),
            devices.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -18),
            devices.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -18),
        ])

        pane.onRevokedAll = { [weak self] in self?.devices.reload() }
        events.onEvent = { [weak self] type, _ in
            switch type {
            case "devices.changed": self?.devices.reload()
            case "config.changed", "gateway.status_changed": self?.pane.reload()
            default: break
            }
        }
        // A gateway that comes up while the window is open fills it in.
        events.onConnected = { [weak self] up in
            guard up else { return }
            self?.reload()
        }
        events.start()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit { events.stop() }

    func reload() {
        pane.reload()
        devices.reload()
    }
}
