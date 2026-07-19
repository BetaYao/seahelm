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
    private let yoloButton = NSButton(checkboxWithTitle: "Yolo — dangerously skip permission checks", target: nil, action: nil)

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
        detectedLabel.translatesAutoresizingMaskIntoConstraints = false

        moreButton.isBordered = false
        moreButton.contentTintColor = OnboardingStyle.accent
        moreButton.target = self
        moreButton.action = #selector(toggleMore)
        moreButton.translatesAutoresizingMaskIntoConstraints = false

        OnboardingStyle.monoTitle(yoloButton, size: 12, color: OnboardingStyle.textSecondary)
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

        let header = NSMutableAttributedString()
        header.append(NSAttributedString(string: "● ", attributes: [
            .font: AppFont.mono(size: 11, weight: .bold),
            .foregroundColor: OnboardingStyle.accent,
        ]))
        header.append(NSAttributedString(string: "detected on this mac · \(detected.count)", attributes: [
            .font: AppFont.mono(size: 11, weight: .medium),
            .foregroundColor: OnboardingStyle.textSecondary,
        ]))
        detectedLabel.attributedStringValue = header

        let visible = showingMore ? agents : detected.isEmpty ? agents : detected
        moreButton.isHidden = hidden.isEmpty
        moreButton.title = showingMore ? "Hide undetected agents" : "Show \(hidden.count) more agents →"
        OnboardingStyle.monoTitle(moreButton, size: 11, color: OnboardingStyle.accent)

        for info in visible {
            let card = makeCard(info)
            stack.addArrangedSubview(card)
            card.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }

        // Show the list from the top (non-flipped scroll views start at bottom).
        DispatchQueue.main.async { [weak self] in
            guard let self, let doc = self.scroll.documentView else { return }
            let topY = max(0, doc.frame.height - self.scroll.contentSize.height)
            self.scroll.contentView.scroll(to: NSPoint(x: 0, y: topY))
            self.scroll.reflectScrolledClipView(self.scroll.contentView)
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
        let box = OnboardingPanel()
        box.isSelected = info.type == defaultType
        let type = info.type
        box.onClick = { [weak self] in
            guard let self else { return }
            self.defaultType = type
            self.hookChecked.insert(type)
            self.rebuildCards()
        }

        // Terminal glyph tile — stands in for per-agent icons.
        let iconTile = NSView()
        iconTile.wantsLayer = true
        iconTile.layer?.cornerRadius = 7
        iconTile.layer?.backgroundColor = (info.type == defaultType
            ? OnboardingStyle.accent.withAlphaComponent(0.22)
            : NSColor.white.withAlphaComponent(0.07)).cgColor
        iconTile.translatesAutoresizingMaskIntoConstraints = false
        let glyph = OnboardingStyle.label("❯_", size: 13, weight: .bold,
                                          color: info.type == defaultType
                                              ? OnboardingStyle.accent
                                              : OnboardingStyle.textSecondary)
        iconTile.addSubview(glyph)

        let title = OnboardingStyle.label(info.type.displayName, size: 13, weight: .semibold)
        let cmd = OnboardingStyle.label(info.command, size: 11, color: OnboardingStyle.textFaint)

        let hook = NSButton(checkboxWithTitle: "Install hooks", target: nil, action: nil)
        hook.state = hookChecked.contains(info.type) ? .on : .off
        hook.tag = agents.firstIndex(where: { $0.type == info.type }) ?? 0
        hook.target = self
        hook.action = #selector(hookToggled(_:))
        OnboardingStyle.monoTitle(hook, size: 11, color: OnboardingStyle.textSecondary)
        hook.translatesAutoresizingMaskIntoConstraints = false

        box.addSubview(iconTile)
        box.addSubview(title)
        box.addSubview(cmd)
        box.addSubview(hook)

        var trailing: NSView = box
        if info.type == defaultType {
            let badge = makeBadge("DEFAULT", color: OnboardingStyle.accent, filled: true)
            box.addSubview(badge)
            NSLayoutConstraint.activate([
                badge.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -14),
                badge.centerYAnchor.constraint(equalTo: box.centerYAnchor),
            ])
            trailing = badge
        } else if !info.detected {
            let badge = makeBadge("not on PATH", color: OnboardingStyle.textFaint, filled: false)
            box.addSubview(badge)
            NSLayoutConstraint.activate([
                badge.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -14),
                badge.centerYAnchor.constraint(equalTo: box.centerYAnchor),
            ])
            trailing = badge
        }
        _ = trailing

        NSLayoutConstraint.activate([
            box.heightAnchor.constraint(equalToConstant: 66),

            iconTile.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 12),
            iconTile.centerYAnchor.constraint(equalTo: box.centerYAnchor),
            iconTile.widthAnchor.constraint(equalToConstant: 36),
            iconTile.heightAnchor.constraint(equalToConstant: 36),
            glyph.centerXAnchor.constraint(equalTo: iconTile.centerXAnchor),
            glyph.centerYAnchor.constraint(equalTo: iconTile.centerYAnchor),

            title.leadingAnchor.constraint(equalTo: iconTile.trailingAnchor, constant: 12),
            title.topAnchor.constraint(equalTo: box.topAnchor, constant: 11),
            cmd.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            cmd.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 1),

            hook.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            hook.topAnchor.constraint(equalTo: cmd.bottomAnchor, constant: 3),
        ])
        return box
    }

    private func makeBadge(_ text: String, color: NSColor, filled: Bool) -> NSView {
        let badge = NSView()
        badge.wantsLayer = true
        badge.layer?.cornerRadius = 5
        if filled {
            badge.layer?.backgroundColor = color.withAlphaComponent(0.18).cgColor
        } else {
            badge.layer?.borderWidth = 1
            badge.layer?.borderColor = color.withAlphaComponent(0.4).cgColor
        }
        badge.translatesAutoresizingMaskIntoConstraints = false
        let label = OnboardingStyle.label(text, size: 9.5, weight: .bold, color: color)
        badge.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: badge.leadingAnchor, constant: 7),
            label.trailingAnchor.constraint(equalTo: badge.trailingAnchor, constant: -7),
            label.topAnchor.constraint(equalTo: badge.topAnchor, constant: 3),
            label.bottomAnchor.constraint(equalTo: badge.bottomAnchor, constant: -3),
        ])
        return badge
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

    override func layout() {
        super.layout()
        if let fill = stack.superview {
            stack.frame.size.width = scroll.contentSize.width
            _ = fill
        }
    }
}
