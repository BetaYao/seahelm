import AppKit

/// First Mate over the terminal side (docs/first-mate-autopilot.md §3): its own
/// terminal, nothing else — it should read like any selected pane, and the
/// terminal is where you talk to it. What it has done is a click away in the
/// dock's history (`FirstMateLogView`), not a column taking a third of the width.
final class FirstMateView: NSView {
    /// The center overlay's title while First Mate is shown — also how the
    /// window recognises that the overlay is First Mate's.
    static let overlayTitle = "First Mate"

    /// Turn it on as the agent picked on the off page.
    var onTurnOn: ((AgentType) -> Void)?
    private let agentPopup = NSPopUpButton()
    private let agentGuard = NSTextField(wrappingLabelWithString: "")

    private let terminalContainer = NSView()
    private let offPanel = NSStackView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    private func setup() {
        setAccessibilityIdentifier("firstMate.view")
        terminalContainer.translatesAutoresizingMaskIntoConstraints = false
        terminalContainer.wantsLayer = true

        let headline = NSTextField(wrappingLabelWithString: """
        First Mate is off.

        Turned on, it runs as an agent session of its own and is woken by your repos' \
        rules (.seahelm/automations.yml, or the built-in ones): when a PR's CI goes red it \
        reads why and tells that worktree's agent; when a PR merges it offers to clean up the \
        worktree. Starting agents and deleting worktrees wait for your approval.
        """)
        headline.font = AppFont.mono(size: 12)
        headline.textColor = GhosttyBridge.shared.terminalChromeForeground.withAlphaComponent(0.7)
        headline.preferredMaxLayoutWidth = 460
        let turnOn = NSButton(title: "Turn on First Mate", target: self, action: #selector(turnOnClicked))
        turnOn.bezelStyle = .rounded
        turnOn.keyEquivalent = "\r"
        // First run: which agent it is, and what keeps that agent in bounds.
        for agent in FirstMatePane.agents {
            agentPopup.addItem(withTitle: agent.displayName)
            agentPopup.lastItem?.representedObject = agent.rawValue
        }
        agentPopup.target = self
        agentPopup.action = #selector(agentChanged)
        let agentLabel = NSTextField(labelWithString: "Run it as")
        agentLabel.font = AppFont.mono(size: 12)
        agentLabel.textColor = headline.textColor
        let agentRow = NSStackView(views: [agentLabel, agentPopup])
        agentRow.spacing = 8
        agentRow.alignment = .centerY
        agentGuard.font = AppFont.mono(size: 11)
        agentGuard.textColor = GhosttyBridge.shared.terminalChromeForeground.withAlphaComponent(0.5)
        agentGuard.preferredMaxLayoutWidth = 460
        agentGuard.stringValue = FirstMatePane.guardDescription(FirstMatePane.agents[0])
        offPanel.orientation = .vertical
        offPanel.alignment = .leading
        offPanel.spacing = 16
        offPanel.addArrangedSubview(headline)
        offPanel.addArrangedSubview(agentRow)
        offPanel.addArrangedSubview(agentGuard)
        offPanel.addArrangedSubview(turnOn)
        offPanel.translatesAutoresizingMaskIntoConstraints = false
        offPanel.isHidden = true

        addSubview(terminalContainer)
        addSubview(offPanel)
        NSLayoutConstraint.activate([
            terminalContainer.topAnchor.constraint(equalTo: topAnchor),
            terminalContainer.leadingAnchor.constraint(equalTo: leadingAnchor),
            terminalContainer.trailingAnchor.constraint(equalTo: trailingAnchor),
            terminalContainer.bottomAnchor.constraint(equalTo: bottomAnchor),
            offPanel.centerXAnchor.constraint(equalTo: centerXAnchor),
            offPanel.centerYAnchor.constraint(equalTo: centerYAnchor),
            offPanel.widthAnchor.constraint(lessThanOrEqualToConstant: 480),
        ])
    }

    /// Put First Mate's terminal in. The first time creates its surface on the
    /// session the coordinator started; later times move the same surface here.
    func embed(_ station: Station?) {
        offPanel.isHidden = station != nil
        terminalContainer.isHidden = station == nil
        guard let station else { return }
        if station.view == nil {
            _ = station.create(in: terminalContainer, workingDirectory: FirstMatePane.directory,
                               paneSessionKey: FirstMatePane.sessionName)
        } else {
            station.reparent(to: terminalContainer)
        }
    }

    /// Keyboard to First Mate's terminal, as selecting a worktree does for its pane.
    func focusTerminal(_ station: Station?) {
        guard let view = station?.view else { return }
        DispatchQueue.main.async { [weak self] in self?.window?.makeFirstResponder(view) }
    }

    /// Preselect the agent First Mate was last set to.
    func selectAgent(_ agent: AgentType) {
        guard let i = FirstMatePane.agents.firstIndex(of: agent) else { return }
        agentPopup.selectItem(at: i)
        agentGuard.stringValue = FirstMatePane.guardDescription(agent)
    }

    private var pickedAgent: AgentType {
        (agentPopup.selectedItem?.representedObject as? String).flatMap(AgentType.init(rawValue:)) ?? .claudeCode
    }

    @objc private func agentChanged() { agentGuard.stringValue = FirstMatePane.guardDescription(pickedAgent) }
    @objc private func turnOnClicked() { onTurnOn?(pickedAgent) }

}

/// What First Mate has done, newest last: the audit log as a list, shown from
/// the dock's history button.
final class FirstMateLogView: NSView {
    private let textView = NSTextView()
    private let scroll = NSScrollView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        textView.isEditable = false
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 12, height: 12)
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    func show(_ entries: [AutopilotAudit.Entry]) {
        textView.textStorage?.setAttributedString(Self.render(entries))
        textView.scrollToEndOfDocument(nil)
    }

    static func render(_ entries: [AutopilotAudit.Entry]) -> NSAttributedString {
        let out = NSMutableAttributedString()
        let time = DateFormatter()
        time.dateFormat = "MM-dd HH:mm"
        let shown = entries.filter { $0.kind != .delivered }
        for entry in shown {
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
        if shown.isEmpty {
            out.append(NSAttributedString(string: "Nothing yet. Events First Mate was woken by, and what it did about them, show up here.", attributes: [
                .font: AppFont.mono(size: 11), .foregroundColor: SemanticColors.subtle,
            ]))
        }
        return out
    }
}

/// What First Mate is waiting on you for — its approval and proposal cards —
/// answerable right here, off the dock's badge. The same cards are in the
/// island and on Telegram; whichever answers first wins.
final class FirstMateApprovalsView: NSView {
    var onAnswer: ((PendingOrder, String) -> Void)?
    private let stack = NSStackView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    func show(_ orders: [PendingOrder]) {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        if orders.isEmpty {
            stack.addArrangedSubview(Self.text("Nothing waiting on you.", SemanticColors.subtle))
            return
        }
        for order in orders {
            let card = NSStackView()
            card.orientation = .vertical
            card.alignment = .leading
            card.spacing = 6
            card.addArrangedSubview(Self.text(order.action.message, SemanticColors.text))
            let buttons = NSStackView()
            buttons.spacing = 6
            var labels = order.action.options ?? []
            if order.action.kind == .autopilotApproval, labels.isEmpty {
                labels = [AutopilotCoordinator.approveLabel, AutopilotCoordinator.rejectLabel]
            }
            for label in labels {
                let button = NSButton(title: label, target: nil, action: nil)
                button.bezelStyle = .rounded
                button.controlSize = .small
                if label == AutopilotCoordinator.approveLabel { button.keyEquivalent = "\r" }
                button.target = self
                button.action = #selector(tapped(_:))
                button.identifier = NSUserInterfaceItemIdentifier(order.id)
                buttons.addArrangedSubview(button)
            }
            card.addArrangedSubview(buttons)
            stack.addArrangedSubview(card)
        }
        orders.forEach { byId[$0.id] = $0 }
    }

    private var byId: [String: PendingOrder] = [:]

    @objc private func tapped(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue, let order = byId[id] else { return }
        onAnswer?(order, sender.title)
    }

    private static func text(_ s: String, _ color: NSColor) -> NSTextField {
        let l = NSTextField(wrappingLabelWithString: s)
        l.font = AppFont.mono(size: 11)
        l.textColor = color
        l.preferredMaxLayoutWidth = 400
        return l
    }
}
