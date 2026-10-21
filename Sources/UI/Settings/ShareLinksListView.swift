import AppKit

/// Settings ▸ Pairing: every pane link still open, each with its own Revoke.
/// Rebuilt by `reload`, since links come and go from the terminal header.
final class ShareLinksListView: NSView {
    /// Current links; called on every reload.
    var links: () -> [ShareLink] = { [] }
    var onRevoke: ((String) -> Void)?
    var onRevokeAll: (() -> Void)?

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
        setAccessibilityIdentifier("settings.shareLinks")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func reload() {
        for view in stack.arrangedSubviews { view.removeFromSuperview() }
        let current = links()
        if current.isEmpty {
            let none = NSTextField(labelWithString: "No pane is shared.")
            none.font = .systemFont(ofSize: 12)
            none.textColor = SettingsPalette.secondary
            stack.addArrangedSubview(none)
            return
        }
        let now = Date()
        for link in current {
            let row = makeRow(link, now: now)
            stack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        if current.count > 1 {
            let all = NSButton(title: "Revoke all \(current.count)", target: self, action: #selector(revokeAllClicked))
            all.bezelStyle = .rounded
            all.font = .systemFont(ofSize: 12)
            all.setAccessibilityIdentifier("settings.shareLinks.revokeAll")
            stack.addArrangedSubview(all)
        }
    }

    private func makeRow(_ link: ShareLink, now: Date) -> NSView {
        let pane = link.label.isEmpty ? link.paneSessionKey : link.label
        let name = NSTextField(labelWithString: link.recipient.map { "\(pane) \u{2192} \($0)" } ?? pane)
        name.font = .systemFont(ofSize: 12, weight: .medium)
        name.lineBreakMode = .byTruncatingTail
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let detail = NSTextField(labelWithString: Self.detail(link, now: now))
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
        revoke.identifier = NSUserInterfaceItemIdentifier(link.id)
        revoke.setAccessibilityIdentifier("settings.shareLinks.revoke")

        let row = NSStackView(views: [text, revoke])
        row.distribution = .fill
        row.spacing = 12
        text.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return row
    }

    /// "Shared 10:42 · expires tomorrow at 10:42", or "· no expiry".
    static func detail(_ link: ShareLink, now: Date) -> String {
        let shared = "Shared " + formatter.string(from: link.createdAt)
        guard let expires = link.expiresAt else { return shared + " \u{00B7} no expiry" }
        return shared + " \u{00B7} expires " + formatter.string(from: expires)
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
        onRevoke?(id)
        reload()
    }

    @objc private func revokeAllClicked() {
        onRevokeAll?()
        reload()
    }
}
