import AppKit

/// Browser pairing UI: 8-digit code + access URL (no QR / long link).
///
/// The page URL the browser already opened is the entry; the code only
/// authorizes. Settings and the menu pairing window share this pane.
final class PairingPaneView: NSView {
    var accessURL: String {
        didSet { urlField.stringValue = accessURL }
    }

    var onRefresh: (() -> String)?
    var onRevokeAll: (() -> Void)?

    private let codeLabel = NSTextField(labelWithString: "")
    private let urlField = NSTextField(labelWithString: "")
    private var currentCode = ""

    init(accessURL: String, code: String) {
        self.accessURL = accessURL
        super.init(frame: .zero)
        build()
        setCode(code)
        urlField.stringValue = accessURL
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func setCode(_ code: String) {
        let n = PairingCodeStore.normalize(code)
        currentCode = n
        guard n.count == 8 else {
            codeLabel.stringValue = n
            return
        }
        let i = n.index(n.startIndex, offsetBy: 4)
        codeLabel.stringValue = "\(n[..<i]) \(n[i...])"
    }

    // MARK: - UI

    private func build() {
        translatesAutoresizingMaskIntoConstraints = false

        let hint = NSTextField(labelWithString:
            "Open the access URL in a browser, then enter this code.")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        hint.maximumNumberOfLines = 2
        hint.lineBreakMode = .byWordWrapping
        hint.preferredMaxLayoutWidth = 360

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
        let copyURL = NSButton(title: "Copy URL", target: self, action: #selector(copyURLClicked))
        let revoke = NSButton(title: "Revoke all remotes", target: self, action: #selector(revokeClicked))
        revoke.hasDestructiveAction = true

        let buttons = NSStackView(views: [copyCode, refresh, copyURL, revoke])
        buttons.orientation = .horizontal
        buttons.spacing = 8
        buttons.alignment = .centerY

        let stack = NSStackView(views: [
            hint, codeLabel, urlCaption, urlField, buttons,
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
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(currentCode, forType: .string)
    }

    @objc private func copyURLClicked() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(accessURL, forType: .string)
    }

    @objc private func refreshClicked() {
        if let next = onRefresh?() { setCode(next) }
    }

    @objc private func revokeClicked() {
        onRevokeAll?()
    }
}

/// Standalone "Pair remote client" window. Settings hosts the same pane; the
/// menu item stays a direct route when pairing with a phone already in hand.
final class PairingWindowController: NSWindowController {
    private let pane: PairingPaneView

    init(accessURL: String, code: String,
         onRefresh: @escaping () -> String,
         onRevokeAll: @escaping () -> Void) {
        pane = PairingPaneView(accessURL: accessURL, code: code)
        pane.onRefresh = onRefresh
        pane.onRevokeAll = onRevokeAll
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 280),
                              styleMask: [.titled, .closable],
                              backing: .buffered, defer: false)
        window.title = "Pair browser client"
        super.init(window: window)

        guard let content = window.contentView else { return }
        let title = NSTextField(labelWithString: "Enter this code in the browser")
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
