import AppKit

/// What the header's share button opens once the link is on the clipboard: the
/// link, how long it lives, and the way to take it back.
final class SharePopoverController: NSViewController, NSTextFieldDelegate {
    private var offer: PaneShareOffer
    private weak var sharing: PaneSharing?
    /// Closes the popover this controller sits in.
    var dismiss: (() -> Void)?

    private let recipientField = NSTextField()
    private let expiryPopup = NSPopUpButton()
    private let expiryHint = NSTextField(labelWithString: "")
    private let revokeAllButton = NSButton()
    private let copyButton = NSButton()

    /// One width for every row, so the link field, the picker and the buttons
    /// line up on both edges instead of each sizing to its own text.
    private static let width: CGFloat = 340

    init(offer: PaneShareOffer, sharing: PaneSharing) {
        self.offer = offer
        self.sharing = sharing
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        let title = NSTextField(labelWithString: "Link copied")
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        let subtitle = NSTextField(wrappingLabelWithString: offer.gatewayListening
            ? "Anyone with it can see and type into this pane, and nothing else."
            : "Host Gateway is not running, so nothing is listening yet.")
        subtitle.font = .systemFont(ofSize: 11)
        subtitle.textColor = offer.gatewayListening ? .secondaryLabelColor : .systemOrange
        subtitle.preferredMaxLayoutWidth = Self.width

        // The token is the part that cannot be read anyway: one line, cut in the
        // middle, so the host and the pane stay visible and nothing wraps mid-word.
        let link = NSTextField(labelWithString: offer.url)
        link.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        link.lineBreakMode = .byTruncatingMiddle
        link.isSelectable = true
        link.toolTip = offer.url
        link.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        copyButton.title = "Copy"
        copyButton.bezelStyle = .rounded
        copyButton.controlSize = .small
        copyButton.font = .systemFont(ofSize: 11)
        copyButton.target = self
        copyButton.action = #selector(copyClicked)
        copyButton.setAccessibilityIdentifier("share.copy")
        let linkRow = NSStackView(views: [link, copyButton])
        linkRow.spacing = 8
        linkRow.edgeInsets = NSEdgeInsets(top: 4, left: 8, bottom: 4, right: 4)
        linkRow.wantsLayer = true
        linkRow.layer?.cornerRadius = 6
        linkRow.layer?.borderWidth = 1
        linkRow.layer?.borderColor = NSColor.separatorColor.cgColor
        linkRow.layer?.backgroundColor = NSColor.textBackgroundColor.withAlphaComponent(0.4).cgColor

        // Named, the link speaks as that person and nobody is asked; blank,
        // whoever opens it gives a name first. Either way the agent sees it.
        let recipientLabel = NSTextField(labelWithString: "For")
        recipientLabel.font = .systemFont(ofSize: 12)
        recipientField.stringValue = offer.recipient ?? ""
        recipientField.placeholderString = "Anyone \u{2014} they enter a name"
        recipientField.font = .systemFont(ofSize: 12)
        recipientField.controlSize = .small
        recipientField.delegate = self
        recipientField.target = self
        recipientField.action = #selector(recipientCommitted)
        recipientField.setAccessibilityIdentifier("share.recipient")
        recipientField.widthAnchor.constraint(equalToConstant: 200).isActive = true
        let recipientSpacer = NSView()
        recipientSpacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let recipientRow = NSStackView(views: [recipientLabel, recipientSpacer, recipientField])
        recipientRow.spacing = 8
        recipientRow.alignment = .firstBaseline

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
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let expiryRow = NSStackView(views: [expiryLabel, spacer, expiryPopup])
        expiryRow.spacing = 8
        expiryRow.alignment = .firstBaseline
        expiryHint.font = .systemFont(ofSize: 11)
        expiryHint.textColor = .secondaryLabelColor
        expiryHint.alignment = .right

        let divider = NSBox()
        divider.boxType = .separator

        let revoke = NSButton(title: "", target: self, action: #selector(revokeClicked))
        revoke.bezelStyle = .rounded
        revoke.controlSize = .small
        revoke.attributedTitle = NSAttributedString(string: "Revoke link", attributes: [
            .foregroundColor: NSColor.systemRed, .font: NSFont.systemFont(ofSize: 11),
        ])
        revoke.setAccessibilityIdentifier("share.revoke")
        revokeAllButton.target = self
        revokeAllButton.action = #selector(revokeAllClicked)
        revokeAllButton.bezelStyle = .rounded
        revokeAllButton.controlSize = .small
        revokeAllButton.setAccessibilityIdentifier("share.revokeAll")
        let gap = NSView()
        gap.setContentHuggingPriority(.init(1), for: .horizontal)
        let buttons = NSStackView(views: [revokeAllButton, gap, revoke])
        buttons.spacing = 8

        let stack = NSStackView(views: [title, subtitle, linkRow, recipientRow, expiryRow, expiryHint, divider, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.setCustomSpacing(2, after: title)
        stack.setCustomSpacing(2, after: expiryRow)
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 12, right: 14)
        for row in [subtitle, linkRow, recipientRow, expiryRow, expiryHint, divider, buttons] as [NSView] {
            row.widthAnchor.constraint(equalToConstant: Self.width).isActive = true
        }
        view = stack
        render()
    }

    private func render() {
        expiryHint.stringValue = offer.expiresAt.map { "Stops working " + Self.formatter.string(from: $0) }
            ?? "Works until you revoke it"
        revokeAllButton.attributedTitle = NSAttributedString(
            string: "Revoke all \(offer.otherLinks + 1) links to this pane",
            attributes: [.foregroundColor: NSColor.systemRed, .font: NSFont.systemFont(ofSize: 11)])
        revokeAllButton.isHidden = offer.otherLinks == 0
        view.layoutSubtreeIfNeeded()
        preferredContentSize = view.fittingSize
    }

    @objc private func copyClicked() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(offer.url, forType: .string)
        copyButton.title = "Copied"
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        // Clicking away closes the popover without ending the edit.
        recipientCommitted()
    }

    func controlTextDidEndEditing(_ obj: Notification) { recipientCommitted() }

    @objc private func recipientCommitted() {
        let name = ShareLinkStore.senderName(recipientField.stringValue)
        guard name != offer.recipient,
              let updated = sharing?.changeShare(offer, recipient: name) else { return }
        offer = updated
        render()
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
