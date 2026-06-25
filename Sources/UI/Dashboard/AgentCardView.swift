import AppKit

protocol AgentCardDelegate: AnyObject {
    func agentCardClicked(agentId: String)
    func agentCardDoubleClicked(agentId: String)
    func agentCardDidRequestDelete(agentId: String)
    func agentCardDidRequestCloseRepo(agentId: String)
}

extension AgentCardDelegate {
    func agentCardDoubleClicked(agentId: String) {}
    func agentCardDidRequestDelete(agentId: String) {}
    func agentCardDidRequestCloseRepo(agentId: String) {}
}

final class AgentCardView: NSView {
    override var acceptsFirstResponder: Bool { false }

    enum Typography {
        static let primaryPointSize: CGFloat = 13
        static let bodyPointSize: CGFloat = 12
        static let secondaryPointSize: CGFloat = 11
    }

    weak var delegate: AgentCardDelegate?
    private(set) var agentId: String = ""
    var isSelected: Bool = false { didSet { updateBorder() } }

    /// Container where the Ghostty terminal surface will be embedded.
    let terminalContainer = NSView()

    /// Fixed-height bottom bar showing status dot, branch name, and status text.
    let bottomBar = NSView()

    /// Message overlay shown in grid mode (no live terminal).
    private let messageLabel = NSTextField(labelWithString: "")
    private var feedLabels: [NSTextField] = []

    private let separatorLine = NSView()
    private var statusDots: [NSView] = []
    private let projectLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")
    private let paneCountLabel = NSTextField(labelWithString: "")
    private var isHovered = false
    private var currentStatus: String = ""
    private var currentPaneStatuses: [AgentStatus] = []
    private var projectLeadingConstraint: NSLayoutConstraint?
    private(set) var clickRecognizer: NSClickGestureRecognizer!

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not supported")
    }

    func configure(id: String, project: String, thread: String, status: String, lastMessage: String, totalDuration: String, roundDuration: String, paneCount: Int = 1, paneStatuses: [AgentStatus] = [], tasks: [TaskItem] = [], activityEvents: [ActivityEvent] = []) {
        agentId = id
        currentStatus = status
        setAccessibilityIdentifier("dashboard.card.\(id)")

        projectLabel.stringValue = project
        statusLabel.stringValue = status.capitalized
        // Content priority: tasks > activity feed > last message
        if let taskAttr = TaskListRenderer.attributedString(for: tasks) {
            clearFeedLabels()
            messageLabel.isHidden = false
            messageLabel.attributedStringValue = taskAttr
        } else if !activityEvents.isEmpty {
            messageLabel.isHidden = true
            updateFeedLabels(events: activityEvents)
        } else {
            clearFeedLabels()
            messageLabel.isHidden = false
            messageLabel.attributedStringValue = NSAttributedString(string: lastMessage, attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: Typography.secondaryPointSize, weight: .regular),
                .foregroundColor: SemanticColors.muted,
            ])
        }

        // Rebuild status dots
        statusDots.forEach { $0.removeFromSuperview() }
        statusDots.removeAll()
        projectLeadingConstraint?.isActive = false

        let statuses = paneStatuses.isEmpty ? [AgentStatus(rawValue: status) ?? .unknown] : paneStatuses
        currentPaneStatuses = statuses
        var previousDot: NSView? = nil
        for agentStatus in statuses {
            let dot = NSView()
            dot.wantsLayer = true
            dot.layer?.cornerRadius = 3.5
            dot.layer?.backgroundColor = agentStatus.color.cgColor
            dot.translatesAutoresizingMaskIntoConstraints = false
            bottomBar.addSubview(dot)

            NSLayoutConstraint.activate([
                dot.widthAnchor.constraint(equalToConstant: 7),
                dot.heightAnchor.constraint(equalToConstant: 7),
                dot.centerYAnchor.constraint(equalTo: bottomBar.centerYAnchor),
                dot.leadingAnchor.constraint(equalTo: previousDot?.trailingAnchor ?? bottomBar.leadingAnchor,
                                             constant: previousDot != nil ? 3 : 8),
            ])
            statusDots.append(dot)
            previousDot = dot
        }

        // Anchor project label to the last dot
        if let lastDot = statusDots.last {
            projectLeadingConstraint = projectLabel.leadingAnchor.constraint(equalTo: lastDot.trailingAnchor, constant: 5)
            projectLeadingConstraint?.isActive = true
        }

        if paneCount > 1 {
            paneCountLabel.stringValue = "\(paneCount) panes"
            paneCountLabel.isHidden = false
        } else {
            paneCountLabel.isHidden = true
        }

        updateBorder()
    }

    private func setup() {
        wantsLayer = true
        layer?.cornerRadius = 4
        layer?.masksToBounds = true
        // Colors set in applyColors() via viewDidMoveToWindow/viewDidChangeEffectiveAppearance

        // Terminal container — fills top area
        terminalContainer.wantsLayer = true
        terminalContainer.layer?.masksToBounds = true
        terminalContainer.translatesAutoresizingMaskIntoConstraints = false
        addSubview(terminalContainer)

        // Message label — shown in grid mode when no live terminal is embedded
        messageLabel.font = NSFont.monospacedSystemFont(ofSize: Typography.secondaryPointSize, weight: .regular)
        messageLabel.textColor = SemanticColors.muted
        messageLabel.lineBreakMode = .byWordWrapping
        messageLabel.maximumNumberOfLines = 0
        messageLabel.translatesAutoresizingMaskIntoConstraints = false
        messageLabel.cell?.wraps = true
        messageLabel.cell?.isScrollable = false
        terminalContainer.addSubview(messageLabel)

        // Separator line
        separatorLine.wantsLayer = true
        separatorLine.translatesAutoresizingMaskIntoConstraints = false
        addSubview(separatorLine)

        // Bottom bar
        bottomBar.wantsLayer = true
        bottomBar.translatesAutoresizingMaskIntoConstraints = false
        addSubview(bottomBar)

        // Project label
        projectLabel.font = NSFont.systemFont(ofSize: Typography.bodyPointSize, weight: .medium)
        projectLabel.textColor = SemanticColors.text
        projectLabel.lineBreakMode = .byTruncatingTail
        projectLabel.maximumNumberOfLines = 1
        projectLabel.translatesAutoresizingMaskIntoConstraints = false
        bottomBar.addSubview(projectLabel)

        // Status text label (right-aligned, dim)
        statusLabel.font = NSFont.systemFont(ofSize: Typography.secondaryPointSize, weight: .regular)
        statusLabel.textColor = SemanticColors.muted
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.maximumNumberOfLines = 1
        statusLabel.alignment = .right
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        bottomBar.addSubview(statusLabel)

        // Pane count badge (shown when paneCount > 1, positioned left of status label)
        paneCountLabel.font = NSFont.systemFont(ofSize: Typography.secondaryPointSize - 1, weight: .medium)
        paneCountLabel.textColor = SemanticColors.accent
        paneCountLabel.lineBreakMode = .byTruncatingTail
        paneCountLabel.maximumNumberOfLines = 1
        paneCountLabel.alignment = .right
        paneCountLabel.translatesAutoresizingMaskIntoConstraints = false
        paneCountLabel.isHidden = true
        paneCountLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        bottomBar.addSubview(paneCountLabel)

        NSLayoutConstraint.activate([
            // Terminal container fills top
            terminalContainer.topAnchor.constraint(equalTo: topAnchor),
            terminalContainer.leadingAnchor.constraint(equalTo: leadingAnchor),
            terminalContainer.trailingAnchor.constraint(equalTo: trailingAnchor),
            terminalContainer.bottomAnchor.constraint(equalTo: separatorLine.topAnchor),

            // Message label inside terminal container
            messageLabel.topAnchor.constraint(equalTo: terminalContainer.topAnchor, constant: 10),
            messageLabel.leadingAnchor.constraint(equalTo: terminalContainer.leadingAnchor, constant: 10),
            messageLabel.trailingAnchor.constraint(equalTo: terminalContainer.trailingAnchor, constant: -10),
            messageLabel.bottomAnchor.constraint(lessThanOrEqualTo: terminalContainer.bottomAnchor, constant: -10),

            // Separator line
            separatorLine.leadingAnchor.constraint(equalTo: leadingAnchor),
            separatorLine.trailingAnchor.constraint(equalTo: trailingAnchor),
            separatorLine.heightAnchor.constraint(equalToConstant: 1),
            separatorLine.bottomAnchor.constraint(equalTo: bottomBar.topAnchor),

            // Bottom bar
            bottomBar.leadingAnchor.constraint(equalTo: leadingAnchor),
            bottomBar.trailingAnchor.constraint(equalTo: trailingAnchor),
            bottomBar.bottomAnchor.constraint(equalTo: bottomAnchor),
            bottomBar.heightAnchor.constraint(equalToConstant: 30),

            // Project label (leading constraint set dynamically in configure())
            projectLabel.centerYAnchor.constraint(equalTo: bottomBar.centerYAnchor),
            projectLabel.trailingAnchor.constraint(lessThanOrEqualTo: paneCountLabel.leadingAnchor, constant: -6),

            // Pane count badge (left of status label)
            paneCountLabel.trailingAnchor.constraint(equalTo: statusLabel.leadingAnchor, constant: -6),
            paneCountLabel.centerYAnchor.constraint(equalTo: bottomBar.centerYAnchor),

            // Status text label (right-aligned)
            statusLabel.trailingAnchor.constraint(equalTo: bottomBar.trailingAnchor, constant: -8),
            statusLabel.centerYAnchor.constraint(equalTo: bottomBar.centerYAnchor),
        ])

        // Click handler — stored so container can wire require(toFail:)
        clickRecognizer = NSClickGestureRecognizer(target: self, action: #selector(handleClick))
        addGestureRecognizer(clickRecognizer)

        // Hover tracking
        let trackingArea = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)

        updateBorder()
    }

    @objc private func handleClick() {
        delegate?.agentCardClicked(agentId: agentId)
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        updateBorder()
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        updateBorder()
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        applyColors()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    private func applyColors() {
        layer?.backgroundColor = resolvedCGColor(SemanticColors.tileBg)
        bottomBar.layer?.backgroundColor = resolvedCGColor(SemanticColors.tileBarBg)
        separatorLine.layer?.backgroundColor = resolvedCGColor(SemanticColors.line)
        for (index, dot) in statusDots.enumerated() {
            if index < currentPaneStatuses.count {
                dot.layer?.backgroundColor = resolvedCGColor(currentPaneStatuses[index].color)
            }
        }
        projectLabel.textColor = SemanticColors.text
        statusLabel.textColor = SemanticColors.muted
        paneCountLabel.textColor = SemanticColors.accent
        messageLabel.textColor = SemanticColors.muted
        updateBorder()
    }

    private func updateBorder() {
        guard let layer = layer else { return }
        if isHovered || isSelected {
            layer.borderColor = resolvedCGColor(SemanticColors.accent)
            layer.borderWidth = 1.5
        } else {
            layer.borderColor = resolvedCGColor(SemanticColors.line)
            layer.borderWidth = 1
        }
    }

    private func clearFeedLabels() {
        feedLabels.forEach { $0.removeFromSuperview() }
        feedLabels.removeAll()
    }

    private func updateFeedLabels(events: [ActivityEvent]) {
        clearFeedLabels()

        // Estimate how many lines fit: container height / line height
        // Use a reasonable max (20) as upper bound
        let maxLines = 20
        let rendered = ActivityFeedRenderer.render(events: events, maxLines: maxLines)

        var previousLabel: NSTextField? = nil
        for attrString in rendered {
            let label = NSTextField(labelWithString: "")
            label.attributedStringValue = attrString
            label.lineBreakMode = .byTruncatingTail
            label.maximumNumberOfLines = 1
            label.translatesAutoresizingMaskIntoConstraints = false
            terminalContainer.addSubview(label)

            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: terminalContainer.leadingAnchor, constant: 10),
                label.trailingAnchor.constraint(equalTo: terminalContainer.trailingAnchor, constant: -10),
            ])

            if let prev = previousLabel {
                label.topAnchor.constraint(equalTo: prev.bottomAnchor, constant: 2).isActive = true
            } else {
                label.topAnchor.constraint(equalTo: terminalContainer.topAnchor, constant: 10).isActive = true
            }

            feedLabels.append(label)
            previousLabel = label
        }
    }
}

enum TaskListRenderer {
    static func attributedString(for tasks: [TaskItem]) -> NSAttributedString? {
        guard !tasks.isEmpty else { return nil }

        let result = NSMutableAttributedString()
        let font = NSFont.monospacedSystemFont(ofSize: AgentCardView.Typography.secondaryPointSize, weight: .regular)
        let boldFont = NSFont.monospacedSystemFont(ofSize: AgentCardView.Typography.secondaryPointSize, weight: .bold)
        let mutedColor = SemanticColors.muted
        let textColor = SemanticColors.text
        let successColor = SemanticColors.running

        for (index, task) in tasks.enumerated() {
            if index > 0 {
                result.append(NSAttributedString(string: "\n"))
            }

            let icon: String
            let iconColor: NSColor
            let labelFont: NSFont
            let labelColor: NSColor
            var extraAttrs: [NSAttributedString.Key: Any] = [:]

            switch task.status {
            case .completed:
                icon = " ✓ "
                iconColor = successColor
                labelFont = font
                labelColor = mutedColor
                extraAttrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
                extraAttrs[.strikethroughColor] = mutedColor
            case .inProgress:
                icon = " ■ "
                iconColor = textColor
                labelFont = boldFont
                labelColor = textColor
            case .pending:
                icon = " □ "
                iconColor = mutedColor
                labelFont = font
                labelColor = mutedColor
            }

            result.append(NSAttributedString(string: icon, attributes: [
                .font: font,
                .foregroundColor: iconColor,
            ]))

            var labelAttrs: [NSAttributedString.Key: Any] = [
                .font: labelFont,
                .foregroundColor: labelColor,
            ]
            labelAttrs.merge(extraAttrs) { _, new in new }
            result.append(NSAttributedString(string: task.subject, attributes: labelAttrs))
        }

        return result
    }
}
