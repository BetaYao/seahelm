import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins

/// The pairing UI (design: `docs/remote-clients-design.md` §7.5.4), as a plain
/// view so it can live in two places at once: the Settings sidebar page, and the
/// standalone window the menu item still opens.
///
/// Always shows the **QR + long link** carrying the full pairing payload
/// (`seahelm://pair?…` with the real root secret) — the strong channels for
/// camera/paste-capable clients (iOS scan, Web paste). The **短码** is opt-in:
/// generated only on button click, 1-minute TTL, single-use — the weak channel
/// for no-camera clients (Watch). Not clicking it means no short code exists.
final class PairingPaneView: NSView {
    private let rootSecret: Data
    private let brokerURL: String
    private let macId: String
    private var pairURI: String { MqttCrypto.pairURI(broker: brokerURL, macId: macId, rootSecret: rootSecret) }

    private let linkField = NSTextField(labelWithString: "")
    private let qrView = NSImageView()
    private let codeLabel = NSTextField(labelWithString: "—")
    private let countdownLabel = NSTextField(labelWithString: "")
    private var shortCode: String?
    private var countdown = 0
    private var codeTimer: Timer?

    /// Called when a short code is minted, so the app can arm the live
    /// `MqttChannel` responder to honor a matching `pair/claim`.
    var onShortCode: ((String, TimeInterval) -> Void)?

    /// `qrSide` shrinks for the Settings page, where the QR shares the width
    /// with a sidebar and does not need to be scannable across a room.
    init(rootSecret: Data, brokerURL: String, macId: String, qrSide: CGFloat = 240) {
        self.rootSecret = rootSecret
        self.brokerURL = brokerURL
        self.macId = macId
        super.init(frame: .zero)
        build(qrSide: qrSide)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit { codeTimer?.invalidate() }

    // MARK: - UI

    private func build(qrSide: CGFloat) {
        translatesAutoresizingMaskIntoConstraints = false

        qrView.imageScaling = .scaleProportionallyUpOrDown
        qrView.wantsLayer = true
        qrView.image = Self.qrImage(from: pairURI, side: qrSide)

        let linkCaption = NSTextField(labelWithString: "长链接(Web 粘贴 · iOS 扫上方码):")
        linkCaption.font = .systemFont(ofSize: 11); linkCaption.textColor = .secondaryLabelColor
        linkField.stringValue = pairURI
        linkField.isSelectable = true
        linkField.lineBreakMode = .byTruncatingMiddle
        linkField.font = .monospacedSystemFont(ofSize: 11, weight: .regular)

        let copyBtn = NSButton(title: "复制链接", target: self, action: #selector(copyLink))

        let divider = NSBox(); divider.boxType = .separator

        let codeCaption = NSTextField(labelWithString: "手表 / 无相机端:生成 1 分钟短码")
        codeCaption.font = .systemFont(ofSize: 11); codeCaption.textColor = .secondaryLabelColor
        codeLabel.font = .monospacedSystemFont(ofSize: 30, weight: .bold)
        codeLabel.alignment = .center
        countdownLabel.font = .systemFont(ofSize: 11); countdownLabel.textColor = .secondaryLabelColor
        countdownLabel.alignment = .center
        let genBtn = NSButton(title: "生成短码", target: self, action: #selector(generateShortCode))

        let warn = NSTextField(labelWithString:
            "二维码/长链接含真实密钥,请勿截图外传;配对完成后请关闭此窗口。")
        warn.maximumNumberOfLines = 2
        warn.lineBreakMode = .byWordWrapping
        warn.preferredMaxLayoutWidth = 360
        warn.font = .systemFont(ofSize: 10); warn.textColor = .tertiaryLabelColor

        let stack = NSStackView(views: [
            qrView, linkCaption, linkField, copyBtn, divider,
            codeCaption, codeLabel, countdownLabel, genBtn, warn,
        ])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            qrView.widthAnchor.constraint(equalToConstant: qrSide),
            qrView.heightAnchor.constraint(equalToConstant: qrSide),
            divider.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
    }

    // MARK: - Actions

    @objc private func copyLink() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(pairURI, forType: .string)
    }

    /// Mint an 8-digit code with a 60s single-use countdown. NOTE: the short-code
    /// *handshake* backend (local rate-limited endpoint / PAKE that trades the code
    /// for the root secret) is Watch-phase and not wired yet — this renders the
    /// code + TTL per §7.5.4; wiring lands with the Watch client.
    @objc private func generateShortCode() {
        codeTimer?.invalidate()
        var bytes = [UInt8](repeating: 0, count: 4)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let n = bytes.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) } % 100_000_000
        shortCode = String(format: "%08u", n)
        codeLabel.stringValue = shortCode.map { "\($0.prefix(4)) \($0.suffix(4))" } ?? "—"
        countdown = 60
        onShortCode?(shortCode!, 60)     // arm the live MqttChannel responder
        updateCountdown()
        codeTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] t in
            guard let self else { t.invalidate(); return }
            self.countdown -= 1
            if self.countdown <= 0 { self.expireShortCode(); t.invalidate() } else { self.updateCountdown() }
        }
    }

    private func updateCountdown() { countdownLabel.stringValue = "有效期 \(countdown)s · 一次性" }

    private func expireShortCode() {
        shortCode = nil
        codeLabel.stringValue = "—"
        countdownLabel.stringValue = "已过期,请重新生成"
    }

    // MARK: - QR

    private static func qrImage(from string: String, side: CGFloat) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"
        guard let ci = filter.outputImage else { return nil }
        let scale = side / ci.extent.width
        let scaled = ci.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let rep = NSCIImageRep(ciImage: scaled)
        let img = NSImage(size: rep.size)
        img.addRepresentation(rep)
        return img
    }
}

/// The standalone "配对远程客户端" window. Settings now hosts the same pane, but
/// the menu item stays a direct route: pairing is a thing you do once, in a
/// hurry, with a phone already in your hand.
///
/// The root secret is generated once and persisted to `config.json` (`mqtt.root_secret`);
/// `MqttChannel` derives broker auth + the E2EE key from it on next connect.
final class PairingWindowController: NSWindowController {
    private let pane: PairingPaneView

    var onShortCode: ((String, TimeInterval) -> Void)? {
        get { pane.onShortCode }
        set { pane.onShortCode = newValue }
    }

    /// View-only: the caller (`MainWindowController.showPairing`) owns minting +
    /// persisting the secret on the *live* config and reconnecting the channel;
    /// this window just renders the QR / link / short code for the given secret.
    convenience init(secret: Data, mqtt: MqttConfig) {
        self.init(rootSecret: secret,
                  brokerURL: Self.clientBrokerURL(mqtt),
                  macId: mqtt.macId ?? MqttChannel.deriveMacId())
    }

    /// The WS(S) endpoint clients dial — prefers `mqtt.client_broker`, else
    /// derives from host/port (e.g. `wss://gw.seahelm.dev/mqtt`).
    private static func clientBrokerURL(_ m: MqttConfig) -> String {
        m.resolvedClientBrokerURL
    }

    init(rootSecret: Data, brokerURL: String, macId: String) {
        pane = PairingPaneView(rootSecret: rootSecret, brokerURL: brokerURL, macId: macId)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 560),
                              styleMask: [.titled, .closable],
                              backing: .buffered, defer: false)
        window.title = "配对远程客户端"
        super.init(window: window)

        guard let content = window.contentView else { return }
        let title = NSTextField(labelWithString: "扫码 / 粘贴长链接配对")
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        title.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(title)
        content.addSubview(pane)

        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: content.topAnchor, constant: 18),
            title.centerXAnchor.constraint(equalTo: content.centerXAnchor),

            pane.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 10),
            pane.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 18),
            pane.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -18),
            pane.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -18),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}
