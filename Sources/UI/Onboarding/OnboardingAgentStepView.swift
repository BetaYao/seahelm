import AppKit

/// Step 1: pick default agent, multi-select hooks, Yolo toggle.
final class OnboardingAgentStepView: NSView {
    private var agents: [OnboardingAgentDetector.AgentInfo] = []
    private var hookChecked: Set<SailorType> = []
    private var defaultType: SailorType = .claudeCode
    private var showingMore = false

    private let scroll = NSScrollView()
    private let stack = NSStackView()
    private let detectedLabel = NSTextField(labelWithString: "")
    private let moreButton = NSButton(title: "Show more agents →", target: nil, action: nil)
    private let yoloButton = NSButton(checkboxWithTitle: "Yolo / dangerously skip permission checks", target: nil, action: nil)

    var isYoloEnabled: Bool { yoloButton.state == .on }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func configure(config: Config) {
        agents = OnboardingAgentDetector.scan()
        defaultType = SailorType(rawValue: config.defaultAgent)
            ?? OnboardingAgentDetector.preferredDefault(from: agents)
        hookChecked = Set(agents.filter(\.detected).map(\.type))
        if hookChecked.isEmpty { hookChecked.insert(defaultType) }
        yoloButton.state = config.agentYolo ? .on : .off
        rebuildCards()
    }

    func selectedDefaultAgent() -> SailorType { defaultType }

    func selectedHookAgentIds() -> [String] {
        hookChecked.map(\.manifestId).sorted()
    }

    private func setup() {
        detectedLabel.font = .systemFont(ofSize: 12, weight: .medium)
        detectedLabel.textColor = .secondaryLabelColor
        detectedLabel.translatesAutoresizingMaskIntoConstraints = false

        moreButton.isBordered = false
        moreButton.font = .systemFont(ofSize: 12, weight: .medium)
        moreButton.contentTintColor = .controlAccentColor
        moreButton.target = self
        moreButton.action = #selector(toggleMore)
        moreButton.translatesAutoresizingMaskIntoConstraints = false

        yoloButton.font = .systemFont(ofSize: 13)
        yoloButton.translatesAutoresizingMaskIntoConstraints = false

        stack.orientation = .vertical
        stack.spacing = 8
        stack.alignment = .leading
        stack.translatesAutoresizingMaskIntoConstraints = false

        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.documentView = stack
        scroll.translatesAutoresizingMaskIntoConstraints = false

        addSubview(detectedLabel)
        addSubview(scroll)
        addSubview(moreButton)
        addSubview(yoloButton)

        NSLayoutConstraint.activate([
            detectedLabel.topAnchor.constraint(equalTo: topAnchor),
            detectedLabel.leadingAnchor.constraint(equalTo: leadingAnchor),

            scroll.topAnchor.constraint(equalTo: detectedLabel.bottomAnchor, constant: 12),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: moreButton.topAnchor, constant: -8),

            moreButton.leadingAnchor.constraint(equalTo: leadingAnchor),
            moreButton.bottomAnchor.constraint(equalTo: yoloButton.topAnchor, constant: -12),

            yoloButton.leadingAnchor.constraint(equalTo: leadingAnchor),
            yoloButton.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    private func rebuildCards() {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let detected = agents.filter(\.detected)
        let hidden = agents.filter { !$0.detected }
        detectedLabel.stringValue = "● Detected on this Mac · \(detected.count)"

        let visible = showingMore ? agents : detected.isEmpty ? agents : detected
        moreButton.isHidden = hidden.isEmpty
        moreButton.title = showingMore ? "Hide undetected agents" : "Show \(hidden.count) more agents →"

        for info in visible {
            let card = makeCard(info)
            stack.addArrangedSubview(card)
            card.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }

        // Ensure stack width tracks scroll
        stack.setFrameSize(NSSize(width: bounds.width > 0 ? bounds.width : 640, height: 1))
        stack.translatesAutoresizingMaskIntoConstraints = false
        if let doc = scroll.documentView {
            doc.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                stack.topAnchor.constraint(equalTo: doc.topAnchor),
                stack.leadingAnchor.constraint(equalTo: doc.leadingAnchor),
                stack.trailingAnchor.constraint(equalTo: doc.trailingAnchor),
                stack.widthAnchor.constraint(equalTo: scroll.widthAnchor),
            ])
        }
    }

    private func makeCard(_ info: OnboardingAgentDetector.AgentInfo) -> NSView {
        let box = NSView()
        box.wantsLayer = true
        box.layer?.cornerRadius = 10
        box.layer?.borderWidth = info.type == defaultType ? 2 : 1
        box.layer?.borderColor = (info.type == defaultType
            ? NSColor.controlAccentColor
            : NSColor.separatorColor).cgColor
        box.translatesAutoresizingMaskIntoConstraints = false

        let title = NSTextField(labelWithString: info.type.displayName)
        title.font = .systemFont(ofSize: 14, weight: .semibold)
        title.translatesAutoresizingMaskIntoConstraints = false

        let cmd = NSTextField(labelWithString: info.command)
        cmd.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        cmd.textColor = .secondaryLabelColor
        cmd.translatesAutoresizingMaskIntoConstraints = false

        let hook = NSButton(checkboxWithTitle: "Install hooks", target: nil, action: nil)
        hook.state = hookChecked.contains(info.type) ? .on : .off
        hook.tag = agents.firstIndex(where: { $0.type == info.type }) ?? 0
        hook.target = self
        hook.action = #selector(hookToggled(_:))
        hook.translatesAutoresizingMaskIntoConstraints = false

        let pick = NSButton(title: info.type == defaultType ? "Default ✓" : "Set default", target: nil, action: nil)
        pick.bezelStyle = .roundRect
        pick.tag = agents.firstIndex(where: { $0.type == info.type }) ?? 0
        pick.target = self
        pick.action = #selector(defaultTapped(_:))
        pick.translatesAutoresizingMaskIntoConstraints = false

        if !info.detected {
            let badge = NSTextField(labelWithString: "Not on PATH")
            badge.font = .systemFont(ofSize: 10, weight: .medium)
            badge.textColor = .secondaryLabelColor
            badge.translatesAutoresizingMaskIntoConstraints = false
            box.addSubview(badge)
            NSLayoutConstraint.activate([
                badge.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -12),
                badge.topAnchor.constraint(equalTo: box.topAnchor, constant: 10),
            ])
        }

        box.addSubview(title)
        box.addSubview(cmd)
        box.addSubview(hook)
        box.addSubview(pick)

        NSLayoutConstraint.activate([
            box.heightAnchor.constraint(equalToConstant: 64),
            title.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 14),
            title.topAnchor.constraint(equalTo: box.topAnchor, constant: 12),
            cmd.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            cmd.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 2),
            hook.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 14),
            hook.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -8),
            pick.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -12),
            pick.centerYAnchor.constraint(equalTo: box.centerYAnchor),
        ])
        return box
    }

    @objc private func toggleMore() {
        showingMore.toggle()
        rebuildCards()
    }

    @objc private func hookToggled(_ sender: NSButton) {
        guard agents.indices.contains(sender.tag) else { return }
        let type = agents[sender.tag].type
        if sender.state == .on {
            hookChecked.insert(type)
        } else {
            hookChecked.remove(type)
        }
    }

    @objc private func defaultTapped(_ sender: NSButton) {
        guard agents.indices.contains(sender.tag) else { return }
        defaultType = agents[sender.tag].type
        hookChecked.insert(defaultType)
        rebuildCards()
    }

    override func layout() {
        super.layout()
        if let fill = stack.superview {
            stack.frame.size.width = scroll.contentSize.width
            _ = fill
        }
    }
}
