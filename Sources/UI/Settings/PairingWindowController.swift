import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins

/// Browser pairing UI (QR + long link), shared by Settings and the menu-item window.
///
/// Always shows the **QR + long link** carrying the full pairing payload
/// (`seahelm://pair?…` with the real root secret) for camera/paste-capable
/// clients (browser paste, phone scan of the Host Gateway entry URL).
final class PairingPaneView: NSView {
    private let rootSecret: Data
    /// Settable: Settings edits the Gateway's public URL on the same page that
    /// shows this QR, and a code still encoding the old endpoint pairs a browser
    /// to an address nothing answers on.
    var brokerURL: String {
        didSet {
            guard brokerURL != oldValue else { return }
            refresh()
        }
    }
    private let macId: String
    private let qrSide: CGFloat
    private var pairURI: String { MqttCrypto.pairURI(broker: brokerURL, macId: macId, rootSecret: rootSecret) }

    private let linkField = NSTextField(labelWithString: "")
    private let qrView = NSImageView()

    /// `qrSide` shrinks for the Settings page, where the QR shares the width
    /// with a sidebar and does not need to be scannable across a room.
    init(rootSecret: Data, brokerURL: String, macId: String, qrSide: CGFloat = 240) {
        self.rootSecret = rootSecret
        self.brokerURL = brokerURL
        self.macId = macId
        self.qrSide = qrSide
        super.init(frame: .zero)
        build(qrSide: qrSide)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: - UI

    private func build(qrSide: CGFloat) {
        translatesAutoresizingMaskIntoConstraints = false

        qrView.imageScaling = .scaleProportionallyUpOrDown
        qrView.wantsLayer = true
        qrView.image = Self.qrImage(from: pairURI, side: qrSide)

        let linkCaption = NSTextField(labelWithString: "Long link (paste in the browser client):")
        linkCaption.font = .systemFont(ofSize: 11); linkCaption.textColor = .secondaryLabelColor
        linkField.stringValue = pairURI
        linkField.isSelectable = true
        linkField.lineBreakMode = .byTruncatingMiddle
        linkField.font = .monospacedSystemFont(ofSize: 11, weight: .regular)

        let copyBtn = NSButton(title: "Copy link", target: self, action: #selector(copyLink))

        let warn = NSTextField(labelWithString:
            "The QR / long link contain the real secret — do not screenshot or share them. Close this window after pairing.")
        warn.maximumNumberOfLines = 2
        warn.lineBreakMode = .byWordWrapping
        warn.preferredMaxLayoutWidth = 360
        warn.font = .systemFont(ofSize: 10); warn.textColor = .tertiaryLabelColor

        let stack = NSStackView(views: [
            qrView, linkCaption, linkField, copyBtn, warn,
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
        ])
    }

    /// Re-encode both renderings of the payload from the current endpoint.
    private func refresh() {
        qrView.image = Self.qrImage(from: pairURI, side: qrSide)
        linkField.stringValue = pairURI
    }

    // MARK: - Actions

    @objc private func copyLink() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(pairURI, forType: .string)
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

/// Standalone "Pair remote client" window. Settings hosts the same pane; the
/// menu item stays a direct route when pairing with a phone already in hand.
///
/// The root secret is generated once and persisted to `config.json`
/// (`mqtt.root_secret`); Host Gateway auth derives from it on the next connect.
final class PairingWindowController: NSWindowController {
    private let pane: PairingPaneView

    /// View-only: the caller (`MainWindowController.showPairing`) owns minting +
    /// persisting the secret on the *live* config and reloading the gateway;
    /// this window just renders the QR / link for the given secret.
    convenience init(secret: Data, hostGateway: HostGatewayConfig?, mqtt: MqttConfig) {
        self.init(rootSecret: secret,
                  brokerURL: HostGatewayPairing.clientEntryURL(hostGateway: hostGateway, mqtt: mqtt),
                  macId: mqtt.macId ?? MqttConfig.deriveMacId())
    }

    init(rootSecret: Data, brokerURL: String, macId: String) {
        pane = PairingPaneView(rootSecret: rootSecret, brokerURL: brokerURL, macId: macId)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 420),
                              styleMask: [.titled, .closable],
                              backing: .buffered, defer: false)
        window.title = "Pair browser client"
        super.init(window: window)

        guard let content = window.contentView else { return }
        let title = NSTextField(labelWithString: "Scan / paste the long link to pair")
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
