import AppKit

/// What the header's share button opens once the link is on the clipboard: the
/// link, how long it lives, and the way to take it back.
final class SharePopoverController: NSViewController {
    private var offer: PaneShareOffer
    private weak var sharing: PaneSharing?
    /// Closes the popover this controller sits in.
    var dismiss: (() -> Void)?

    private let note = NSTextField(labelWithString: "")
    private let expiryPopup = NSPopUpButton()
    private let expiryHint = NSTextField(labelWithString: "")
    private let revokeAllButton = NSButton()

    init(offer: PaneShareOffer, sharing: PaneSharing) {
        self.offer = offer
        self.sharing = sharing
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        note.font = .systemFont(ofSize: 11)
        note.textColor = .secondaryLabelColor
        note.stringValue = offer.gatewayListening
            ? "Link copied \u{2014} it opens this pane and nothing else"
            : "Link copied. Host Gateway is not running, so nothing is listening yet."

        let link = NSTextField(wrappingLabelWithString: offer.url)
        link.isSelectable = true
        link.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        link.preferredMaxLayoutWidth = 340

        let expiryLabel = NSTextField(labelWithString: "Expires after")
        expiryLabel.font = .systemFont(ofSize: 12)
        expiryPopup.controlSize = .small
        expiryPopup.font = .systemFont(ofSize: 12)
        for lifetime in ShareLinkLifetime.allCases {
            expiryPopup.addItem(withTitle: lifetime.label)
            expiryPopup.lastItem?.representedObject = lifetime.rawValue
        }
        expiryPopup.selectItem(at: ShareLinkLifetime.allCases.firstIndex(of: offer.lifetime) ?? 1)
        expiryPopup.target = self
        expiryPopup.action = #selector(expiryChanged)
        expiryPopup.setAccessibilityIdentifier("share.expiry")
        expiryHint.font = .systemFont(ofSize: 11)
        expiryHint.textColor = .secondaryLabelColor
        let expiryRow = NSStackView(views: [expiryLabel, expiryPopup, expiryHint])
        expiryRow.spacing = 8

        let revoke = NSButton(title: "Revoke link", target: self, action: #selector(revokeClicked))
        revoke.controlSize = .small
        revoke.bezelStyle = .rounded
        revoke.contentTintColor = .systemRed
        revoke.setAccessibilityIdentifier("share.revoke")
        revokeAllButton.target = self
        revokeAllButton.action = #selector(revokeAllClicked)
        revokeAllButton.controlSize = .small
        revokeAllButton.bezelStyle = .rounded
        revokeAllButton.setAccessibilityIdentifier("share.revokeAll")
        let buttons = NSStackView(views: [revoke, revokeAllButton])
        buttons.spacing = 8

        let stack = NSStackView(views: [note, link, expiryRow, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 12, right: 12)
        view = stack
        render()
    }

    private func render() {
        expiryHint.stringValue = offer.expiresAt.map { "until " + Self.formatter.string(from: $0) } ?? ""
        revokeAllButton.title = "Revoke all \(offer.otherLinks + 1) links to this pane"
        revokeAllButton.isHidden = offer.otherLinks == 0
        view.frame.size = view.fittingSize
        preferredContentSize = view.fittingSize
    }

    @objc private func expiryChanged() {
        guard let raw = expiryPopup.selectedItem?.representedObject as? String,
              let lifetime = ShareLinkLifetime(rawValue: raw),
              let updated = sharing?.changeShare(offer, lifetime: lifetime) else { return }
        ShareLinkLifetime.lastChosen = lifetime
        offer = updated
        render()
    }

    @objc private func revokeClicked() {
        sharing?.revokeShare(offer)
        dismiss?()
    }

    @objc private func revokeAllClicked() {
        sharing?.revokeAllShares(paneSessionKey: offer.paneSessionKey)
        dismiss?()
    }

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .short
        f.doesRelativeDateFormatting = true
        return f
    }()
}
