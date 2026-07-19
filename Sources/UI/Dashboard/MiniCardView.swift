import AppKit

protocol SailorCardDelegate: AnyObject {
    func agentCardClicked(agentId: String)
    func agentCardDoubleClicked(agentId: String)
    func agentCardDidRequestBrowseFiles(agentId: String)
    func agentCardDidRequestShowChanges(agentId: String)
    func agentCardDidRequestDelete(agentId: String)
    func agentCardDidRequestCloseRepo(agentId: String)
}

extension SailorCardDelegate {
    func agentCardDoubleClicked(agentId: String) {}
    func agentCardDidRequestBrowseFiles(agentId: String) {}
    func agentCardDidRequestShowChanges(agentId: String) {}
    func agentCardDidRequestDelete(agentId: String) {}
    func agentCardDidRequestCloseRepo(agentId: String) {}
}

final class MiniCardView: NSView {
    enum Typography {
        static let primaryPointSize: CGFloat = 12
        static let secondaryPointSize: CGFloat = 10
    }

    weak var delegate: SailorCardDelegate?
    private(set) var agentId: String = ""
    var isSelected: Bool = false { didSet { updateAppearance() } }
    var isKeyboardFocused: Bool = false { didSet { updateAppearance() } }

    // Line 1–2: title (wraps up to 2 lines)
    private let titleLabel = NSTextField(labelWithString: "")
    // Line 3: status text (right) + duration (left), with leading status dots
    private let durationLabel = NSTextField(labelWithString: "")
    private let statusTextLabel = NSTextField(labelWithString: "")
    private var statusDots: [NSView] = []
    private var durationLeadingConstraint: NSLayoutConstraint?
    // Line 4: repo badge + worktree name (left), git summary (right)
    private let agentBadge = SailorBadgeView()
    private let repoWorktreeLabel = NSTextField(labelWithString: "")
    private let gitStatsLabel = NSTextField(labelWithString: "")
    private var repoLeadingDefault: NSLayoutConstraint!
    private var repoLeadingAfterBadge: NSLayoutConstraint!

    private var isHovered = false
    private var dimOverlayLayer: CALayer?

    // Test hooks
    var titleTextForTesting: String { titleLabel.stringValue }
    var repoWorktreeTextForTesting: String { repoWorktreeLabel.stringValue }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    func configure(id: String, project: String, thread: String, status: String, lastMessage: String, lastUserPrompt: String = "", totalDuration: String, roundDuration: String, lastActivityAge: String = "", gitStats: WorktreeGitStats? = nil, paneStatuses: [SailorStatus] = [], isMainWorktree: Bool = false, tasks: [TaskItem] = [], activityEvents: [ActivityEvent] = [], agentType: SailorType = .unknown) {
        agentId = id
        setAccessibilityIdentifier("dashboard.miniCard.\(id)")

        let title = lastUserPrompt.isEmpty ? project : lastUserPrompt
        titleLabel.stringValue = title

        // Line 4: repo badge + worktree branch. The repo name reuses the old
        // agent-badge pill style; each repo gets a stable pseudo-random color so
        // different projects are easy to tell apart at a glance.
        repoWorktreeLabel.stringValue = thread
        if project.isEmpty {
            agentBadge.isHidden = true
            repoLeadingAfterBadge.isActive = false
            repoLeadingDefault.isActive = true
        } else {
            agentBadge.configure(text: project, color: Self.repoColor(for: project), symbol: "folder")
            agentBadge.isHidden = false
            repoLeadingDefault.isActive = false
            repoLeadingAfterBadge.isActive = true
        }

        // Status dots before the duration line
        statusDots.forEach { $0.removeFromSuperview() }
        statusDots.removeAll()
        durationLeadingConstraint?.isActive = false
        let statuses = paneStatuses.isEmpty ? [SailorStatus(rawValue: status) ?? .unknown] : paneStatuses
        var previousDot: NSView? = nil
        for agentStatus in statuses {
            let dot = NSView()
            dot.wantsLayer = true
            dot.layer?.cornerRadius = 3
            dot.layer?.backgroundColor = agentStatus.color.cgColor
            dot.translatesAutoresizingMaskIntoConstraints = false
            addSubview(dot)
            NSLayoutConstraint.activate([
                dot.widthAnchor.constraint(equalToConstant: 6),
                dot.heightAnchor.constraint(equalToConstant: 6),
                dot.centerYAnchor.constraint(equalTo: durationLabel.centerYAnchor),
                dot.leadingAnchor.constraint(equalTo: previousDot?.trailingAnchor ?? leadingAnchor,
                                             constant: previousDot != nil ? 3 : 8),
            ])
            statusDots.append(dot)
            previousDot = dot
        }
        if let lastDot = statusDots.last {
            durationLeadingConstraint = durationLabel.leadingAnchor.constraint(equalTo: lastDot.trailingAnchor, constant: 5)
            durationLeadingConstraint?.isActive = true
        }

        // Line 3 left: time since last activity (not run duration).
        durationLabel.stringValue = lastActivityAge.isEmpty ? "" : "\u{23F1} \(lastActivityAge)"

        // Line 4 right: git summary — "+adds −dels  ↑ahead↓behind".
        gitStatsLabel.attributedStringValue = Self.gitStatsAttributed(gitStats)

        statusTextLabel.stringValue = status.capitalized
        statusTextLabel.textColor = SailorDisplayHelpers.statusColor(status)

        updateAppearance()
    }

    private func setup() {
        wantsLayer = true
        layer?.cornerRadius = 6

        titleLabel.font = NSFont.systemFont(ofSize: Typography.primaryPointSize, weight: .semibold)
        titleLabel.textColor = SemanticColors.text
        titleLabel.lineBreakMode = .byWordWrapping
        titleLabel.maximumNumberOfLines = 2
        titleLabel.cell?.wraps = true
        titleLabel.cell?.usesSingleLineMode = false
        titleLabel.cell?.lineBreakMode = .byWordWrapping
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.setContentCompressionResistancePriority(.defaultHigh, for: .vertical)
        addSubview(titleLabel)

        statusTextLabel.font = NSFont.systemFont(ofSize: Typography.secondaryPointSize, weight: .regular)
        statusTextLabel.lineBreakMode = .byTruncatingTail
        statusTextLabel.maximumNumberOfLines = 1
        statusTextLabel.alignment = .right
        statusTextLabel.translatesAutoresizingMaskIntoConstraints = false
        statusTextLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        statusTextLabel.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        addSubview(statusTextLabel)

        durationLabel.font = NSFont.systemFont(ofSize: Typography.secondaryPointSize, weight: .regular)
        durationLabel.textColor = SemanticColors.muted
        durationLabel.lineBreakMode = .byTruncatingTail
        durationLabel.maximumNumberOfLines = 1
        durationLabel.translatesAutoresizingMaskIntoConstraints = false
        durationLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addSubview(durationLabel)

        repoWorktreeLabel.font = NSFont.systemFont(ofSize: Typography.secondaryPointSize, weight: .regular)
        repoWorktreeLabel.textColor = SemanticColors.muted
        repoWorktreeLabel.lineBreakMode = .byTruncatingTail
        repoWorktreeLabel.maximumNumberOfLines = 1
        repoWorktreeLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(repoWorktreeLabel)

        gitStatsLabel.font = NSFont.monospacedDigitSystemFont(ofSize: Typography.secondaryPointSize, weight: .regular)
        gitStatsLabel.lineBreakMode = .byClipping
        gitStatsLabel.maximumNumberOfLines = 1
        gitStatsLabel.alignment = .right
        gitStatsLabel.translatesAutoresizingMaskIntoConstraints = false
        gitStatsLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        gitStatsLabel.setContentHuggingPriority(.required, for: .horizontal)
        addSubview(gitStatsLabel)

        agentBadge.translatesAutoresizingMaskIntoConstraints = false
        agentBadge.isHidden = true
        agentBadge.setContentHuggingPriority(.required, for: .horizontal)
        addSubview(agentBadge)

        let padding: CGFloat = 8
        let durationFallbackLeading = durationLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: padding)
        durationFallbackLeading.priority = .defaultLow

        repoLeadingDefault = repoWorktreeLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: padding)
        repoLeadingAfterBadge = repoWorktreeLabel.leadingAnchor.constraint(equalTo: agentBadge.trailingAnchor, constant: 6)

        // Layout guide spanning the content block (title → repo), centered
        // vertically so a 1-line title gets balanced top/bottom margins instead
        // of dumping all the slack at the bottom of the fixed-height card.
        let contentGuide = NSLayoutGuide()
        addLayoutGuide(contentGuide)

        NSLayoutConstraint.activate([
            contentGuide.topAnchor.constraint(equalTo: titleLabel.topAnchor),
            contentGuide.bottomAnchor.constraint(equalTo: repoWorktreeLabel.bottomAnchor),
            contentGuide.centerYAnchor.constraint(equalTo: centerYAnchor),

            titleLabel.topAnchor.constraint(greaterThanOrEqualTo: topAnchor, constant: padding),
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: padding),
            titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -padding),

            durationLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 4),
            durationFallbackLeading,
            durationLabel.trailingAnchor.constraint(lessThanOrEqualTo: statusTextLabel.leadingAnchor, constant: -4),

            statusTextLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -padding),
            statusTextLabel.centerYAnchor.constraint(equalTo: durationLabel.centerYAnchor),

            agentBadge.leadingAnchor.constraint(equalTo: leadingAnchor, constant: padding),
            agentBadge.centerYAnchor.constraint(equalTo: repoWorktreeLabel.centerYAnchor),

            repoWorktreeLabel.topAnchor.constraint(equalTo: durationLabel.bottomAnchor, constant: 4),
            repoLeadingDefault,
            repoWorktreeLabel.trailingAnchor.constraint(lessThanOrEqualTo: gitStatsLabel.leadingAnchor, constant: -6),
            repoWorktreeLabel.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -padding),

            gitStatsLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -padding),
            gitStatsLabel.centerYAnchor.constraint(equalTo: repoWorktreeLabel.centerYAnchor),
        ])

        let click = NSClickGestureRecognizer(target: self, action: #selector(handleClick))
        addGestureRecognizer(click)
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: self, userInfo: nil
        ))
        updateAppearance()
    }

    @objc private func handleClick() { delegate?.agentCardClicked(agentId: agentId) }
    override func mouseEntered(with event: NSEvent) { isHovered = true; updateAppearance() }
    override func mouseExited(with event: NSEvent) { isHovered = false; updateAppearance() }

    func showDimOverlay(opacity: CGFloat) {
        if dimOverlayLayer == nil {
            let overlay = CALayer()
            overlay.backgroundColor = NSColor.white.withAlphaComponent(opacity).cgColor
            overlay.frame = bounds
            overlay.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
            layer?.addSublayer(overlay)
            dimOverlayLayer = overlay
        }
    }

    func hideDimOverlay() {
        dimOverlayLayer?.removeFromSuperlayer()
        dimOverlayLayer = nil
    }

    override func layout() {
        super.layout()
        // Explicit shadowPath: without it Core Animation derives the shadow
        // shape from the layer contents every frame (offscreen pass per card).
        layer?.shadowPath = CGPath(
            roundedRect: bounds, cornerWidth: 6, cornerHeight: 6, transform: nil
        )
    }

    override var acceptsFirstResponder: Bool { false }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() { updateAppearance() }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }

    private func updateAppearance() {
        guard let layer = layer else { return }
        if isKeyboardFocused {
            layer.backgroundColor = resolvedCGColor(SemanticColors.panel2)
            layer.borderColor = resolvedCGColor(SemanticColors.accent)
            layer.borderWidth = 2
            layer.shadowColor = resolvedCGColor(SemanticColors.accent)
            layer.shadowOpacity = 0.6
            layer.shadowRadius = 8
            layer.shadowOffset = .zero
            layer.masksToBounds = false
        } else if isSelected {
            layer.backgroundColor = resolvedCGColor(SemanticColors.panel2)
            layer.borderColor = resolvedCGColor(SemanticColors.accent)
            layer.borderWidth = 1.5
            layer.shadowOpacity = 0
        } else if isHovered {
            layer.backgroundColor = resolvedCGColor(SemanticColors.arcBlockHover)
            layer.borderColor = resolvedCGColor(SemanticColors.lineAlpha40)
            layer.borderWidth = 1.5
            layer.shadowOpacity = 0
        } else {
            layer.backgroundColor = resolvedCGColor(SemanticColors.tileBarBg)
            layer.borderColor = resolvedCGColor(SemanticColors.lineAlpha45)
            layer.borderWidth = 1
            layer.shadowColor = resolvedCGColor(SemanticColors.miniCardShadowDefault)
            layer.shadowOpacity = 1
            layer.shadowRadius = 8
            layer.shadowOffset = NSSize(width: 0, height: -2)
        }
        titleLabel.textColor = SemanticColors.text
        repoWorktreeLabel.textColor = SemanticColors.muted
    }

    /// Stable pseudo-random brand color for a repo, picked from a fixed palette by a
    /// deterministic hash so the same project always gets the same color across launches.
    static func repoColor(for project: String) -> NSColor {
        let palette = [0xd97757, 0x10a37f, 0x8b7fd9, 0x4285f4, 0x6aa84f,
                       0xb07ad9, 0xe0a030, 0x4aa3a3, 0xd96f9a, 0x7a9bd9]
        var hash: UInt64 = 5381
        for byte in project.utf8 { hash = (hash &* 33) &+ UInt64(byte) }
        return NSColor(hex: palette[Int(hash % UInt64(palette.count))])
    }

    /// Colored git summary: green "+adds", red "−dels", then dim "↑ahead↓behind".
    /// Empty when there are no changes and no divergence (or stats not yet loaded).
    static func gitStatsAttributed(_ stats: WorktreeGitStats?) -> NSAttributedString {
        guard let stats, !stats.isEmpty else { return NSAttributedString() }
        let font = NSFont.monospacedDigitSystemFont(ofSize: Typography.secondaryPointSize, weight: .regular)
        let result = NSMutableAttributedString()
        func append(_ s: String, _ color: NSColor) {
            result.append(NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: color]))
        }
        if stats.added > 0 { append("+\(stats.added)", SemanticColors.running) }
        if stats.removed > 0 {
            if result.length > 0 { append(" ", SemanticColors.muted) }
            append("\u{2212}\(stats.removed)", SemanticColors.danger)
        }
        if stats.hasAheadBehind {
            if result.length > 0 { append("  ", SemanticColors.muted) }
            var ab = ""
            if let ahead = stats.ahead, ahead > 0 { ab += "\u{2191}\(ahead)" }
            if let behind = stats.behind, behind > 0 { ab += "\u{2193}\(behind)" }
            append(ab, SemanticColors.muted)
        }
        return result
    }

    // Test hook
    var repoBadgeTextForTesting: String { agentBadge.isHidden ? "" : agentBadge.labelText }
}

/// Small rounded pill showing an icon + name in a brand color. Used for the repo chip.
final class SailorBadgeView: NSView {
    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")

    var labelText: String { label.stringValue }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 4
        layer?.borderWidth = 1

        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.setContentHuggingPriority(.required, for: .horizontal)
        addSubview(icon)

        label.font = .systemFont(ofSize: 9.5, weight: .semibold)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setContentHuggingPriority(.required, for: .horizontal)
        label.setContentCompressionResistancePriority(.required, for: .horizontal)
        addSubview(label)

        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 9),
            icon.heightAnchor.constraint(equalToConstant: 9),

            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 3),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    func configure(text: String, color: NSColor, symbol: String) {
        label.stringValue = text
        label.textColor = color
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 8.5, weight: .semibold))
        icon.contentTintColor = color
        layer?.borderColor = color.withAlphaComponent(0.55).cgColor
        layer?.backgroundColor = color.withAlphaComponent(0.12).cgColor
    }
}
