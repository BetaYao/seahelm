import AppKit

/// First Mate over the terminal side (docs/first-mate-autopilot.md §3): its own
/// terminal, the audit timeline beside it, and a line to talk to it. Shown in
/// the dashboard's center overlay, so the fleet stays in view on the left.
final class FirstMateView: NSView, NSTextFieldDelegate {
    var onSend: ((String) -> Void)?
    var onTurnOn: (() -> Void)?

    private let terminalContainer = NSView()
    private let logView = NSTextView()
    private let logScroll = NSScrollView()
    private let input = NSTextField()
    private let offPanel = NSStackView()
    private let divider = NSView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    private func setup() {
        setAccessibilityIdentifier("firstMate.view")
        terminalContainer.translatesAutoresizingMaskIntoConstraints = false
        terminalContainer.wantsLayer = true

        logView.isEditable = false
        logView.drawsBackground = false
        logView.textContainerInset = NSSize(width: 10, height: 10)
        logView.isVerticallyResizable = true
        logView.autoresizingMask = [.width]
        logScroll.documentView = logView
        logScroll.hasVerticalScroller = true
        logScroll.drawsBackground = false
        logScroll.borderType = .noBorder
        logScroll.translatesAutoresizingMaskIntoConstraints = false

        divider.wantsLayer = true
        divider.translatesAutoresizingMaskIntoConstraints = false

        input.placeholderString = "Tell First Mate something…"
        input.font = AppFont.mono(size: 12)
        input.delegate = self
        input.translatesAutoresizingMaskIntoConstraints = false
        input.setAccessibilityIdentifier("firstMate.input")

        let headline = NSTextField(wrappingLabelWithString: """
        First Mate is off.

        Turned on, it runs as a Claude Code session of its own and is woken by your repos' \
        rules (.seahelm/automations.yml, or the built-in ones): when a PR's CI goes red it \
        reads why and tells that worktree's agent; when a PR merges it offers to clean up the \
        worktree. Starting agents and deleting worktrees wait for your approval.
        """)
        headline.font = AppFont.mono(size: 12)
        headline.textColor = SemanticColors.muted
        headline.preferredMaxLayoutWidth = 460
        let turnOn = NSButton(title: "Turn on First Mate", target: self, action: #selector(turnOnClicked))
        turnOn.bezelStyle = .rounded
        turnOn.keyEquivalent = "\r"
        offPanel.orientation = .vertical
        offPanel.alignment = .leading
        offPanel.spacing = 16
        offPanel.addArrangedSubview(headline)
        offPanel.addArrangedSubview(turnOn)
        offPanel.translatesAutoresizingMaskIntoConstraints = false
        offPanel.isHidden = true

        for v in [terminalContainer, divider, logScroll, input, offPanel] as [NSView] { addSubview(v) }
        NSLayoutConstraint.activate([
            terminalContainer.topAnchor.constraint(equalTo: topAnchor),
            terminalContainer.leadingAnchor.constraint(equalTo: leadingAnchor),
            terminalContainer.bottomAnchor.constraint(equalTo: input.topAnchor, constant: -8),
            divider.topAnchor.constraint(equalTo: topAnchor),
            divider.bottomAnchor.constraint(equalTo: terminalContainer.bottomAnchor),
            divider.leadingAnchor.constraint(equalTo: terminalContainer.trailingAnchor),
            divider.widthAnchor.constraint(equalToConstant: 1),
            logScroll.topAnchor.constraint(equalTo: topAnchor),
            logScroll.leadingAnchor.constraint(equalTo: divider.trailingAnchor),
            logScroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            logScroll.bottomAnchor.constraint(equalTo: terminalContainer.bottomAnchor),
            logScroll.widthAnchor.constraint(equalTo: widthAnchor, multiplier: 0.34),
            input.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            input.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            input.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
            offPanel.centerXAnchor.constraint(equalTo: centerXAnchor),
            offPanel.centerYAnchor.constraint(equalTo: centerYAnchor),
            offPanel.widthAnchor.constraint(lessThanOrEqualToConstant: 480),
        ])
        refreshColors()
    }

    /// Put First Mate's terminal in. The first time creates its surface on the
    /// session the coordinator started; later times move the same surface here.
    func embed(_ station: Station?) {
        let on = station != nil
        offPanel.isHidden = on
        for v in [terminalContainer, divider, logScroll, input] as [NSView] { v.isHidden = !on }
        guard let station else { return }
        if station.view == nil {
            _ = station.create(in: terminalContainer, workingDirectory: FirstMatePane.directory,
                               paneSessionKey: FirstMatePane.sessionName)
        } else {
            station.reparent(to: terminalContainer)
        }
    }

    func showLog(_ entries: [AutopilotAudit.Entry]) {
        let out = NSMutableAttributedString()
        let time = DateFormatter()
        time.dateFormat = "HH:mm"
        for entry in entries where entry.kind != .delivered {
            out.append(NSAttributedString(string: time.string(from: entry.at) + "  ", attributes: [
                .font: AppFont.mono(size: 10), .foregroundColor: SemanticColors.subtle,
            ]))
            let color: NSColor = switch entry.kind {
            case .event: SemanticColors.text
            case .action: SemanticColors.running
            case .approval: SemanticColors.attention
            case .denied, .skipped: SemanticColors.danger
            case .message: SemanticColors.accent
            default: SemanticColors.muted
            }
            let rule = entry.rule.map { "[\($0)] " } ?? ""
            out.append(NSAttributedString(string: rule + AutopilotCoordinator.headline(entry) + "\n", attributes: [
                .font: AppFont.mono(size: 11), .foregroundColor: color,
            ]))
        }
        if entries.isEmpty {
            out.append(NSAttributedString(string: "Nothing yet. Events and actions show up here.", attributes: [
                .font: AppFont.mono(size: 11), .foregroundColor: SemanticColors.subtle,
            ]))
        }
        logView.textStorage?.setAttributedString(out)
        logView.scrollToEndOfDocument(nil)
    }

    func focusInput() { window?.makeFirstResponder(input) }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard selector == #selector(NSResponder.insertNewline(_:)) else { return false }
        let text = input.stringValue
        input.stringValue = ""
        onSend?(text)
        return true
    }

    @objc private func turnOnClicked() { onTurnOn?() }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshColors()
    }

    private func refreshColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            divider.layer?.backgroundColor = SemanticColors.line.withAlphaComponent(0.2).cgColor
        }
    }
}
