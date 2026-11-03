import AppKit

/// First Mate, pinned to the foot of the fleet column where the shortcut strip
/// used to be: what it is doing, the last thing it did, and how many approvals
/// wait on you. Clicking it opens First Mate over the terminal side; the `?`
/// in its corner is the keyboard cheat-sheet the strip used to advertise.
final class FirstMateDockView: NSView {
    var onOpen: (() -> Void)?
    var onTogglePause: (() -> Void)?
    var onShowAllShortcuts: (() -> Void)?
    /// Settings ▸ First Mate, from the dock's context menu.
    var onShowSettings: (() -> Void)?
    /// The history button: anchor view to show the log from.
    var onShowHistory: ((NSView) -> Void)?

    private let rule = NSView()
    private let mark = NSImageView()
    private let title = NSTextField(labelWithString: "First Mate")
    private let activity = NSTextField(labelWithString: "")
    private let latest = NSTextField(labelWithString: "")
    private let badge = NSTextField(labelWithString: "")
    private let pauseButton = NSButton()
    private let historyButton = NSButton()
    private let helpButton = NSButton()
    private(set) var state = AutopilotCoordinator.State()

    private static let topLine = NSColor(name: nil) { appearance in
        appearance.isDark
            ? NSColor(srgbRed: 150/255, green: 215/255, blue: 225/255, alpha: 0.10)
            : NSColor(srgbRed: 0x1f/255, green: 0x23/255, blue: 0x2b/255, alpha: 0.10)
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    private func setup() {
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityIdentifier("overview.firstMateDock")
        setAccessibilityRole(.button)

        rule.wantsLayer = true
        rule.translatesAutoresizingMaskIntoConstraints = false
        addSubview(rule)

        mark.image = NSImage(systemSymbolName: "steeringwheel", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .medium))
        title.font = AppFont.mono(size: 12, weight: .semibold)
        title.textColor = SemanticColors.text
        activity.font = AppFont.mono(size: 11)
        latest.font = AppFont.mono(size: 11)
        latest.textColor = SemanticColors.muted
        latest.lineBreakMode = .byTruncatingTail
        latest.maximumNumberOfLines = 1
        latest.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        badge.font = AppFont.mono(size: 10, weight: .semibold)
        badge.textColor = SemanticColors.attention
        badge.isHidden = true

        for (button, symbol, tip, action) in [
            (historyButton, "clock.arrow.circlepath", "What First Mate has done", #selector(historyClicked)),
            (pauseButton, "pause.fill", "Pause First Mate", #selector(pauseClicked)),
            (helpButton, "questionmark.circle", "Keyboard shortcuts (?)", #selector(helpClicked)),
        ] {
            button.isBordered = false
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)?
                .withSymbolConfiguration(.init(pointSize: 11, weight: .regular))
            button.contentTintColor = SemanticColors.subtle
            button.toolTip = tip
            button.target = self
            button.action = action
            button.refusesFirstResponder = true
        }

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let line1 = NSStackView(views: [mark, title, activity, spacer, badge, historyButton, pauseButton, helpButton])
        line1.orientation = .horizontal
        line1.spacing = 6
        line1.alignment = .centerY
        let column = NSStackView(views: [line1, latest])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 3
        column.translatesAutoresizingMaskIntoConstraints = false
        addSubview(column)

        NSLayoutConstraint.activate([
            rule.topAnchor.constraint(equalTo: topAnchor),
            rule.leadingAnchor.constraint(equalTo: leadingAnchor),
            rule.trailingAnchor.constraint(equalTo: trailingAnchor),
            rule.heightAnchor.constraint(equalToConstant: 1),
            column.topAnchor.constraint(equalTo: topAnchor, constant: 9),
            column.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 15),
            column.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            column.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -9),
            line1.widthAnchor.constraint(equalTo: column.widthAnchor),
        ])
        apply(state)
        refreshColors()
    }

    func apply(_ state: AutopilotCoordinator.State) {
        self.state = state
        let (word, color) = Self.describe(state.activity)
        activity.stringValue = word
        activity.textColor = color
        mark.contentTintColor = state.activity == .off || state.activity == .paused
            ? SemanticColors.subtle : SemanticColors.accent
        var second = state.latest
        if state.activity == .off { second = "Off — click to set up" }
        if state.queued > 0 { second = "\(state.queued) queued · " + second }
        latest.stringValue = second
        badge.isHidden = state.pendingApprovals == 0
        badge.stringValue = "\(state.pendingApprovals) to approve"
        pauseButton.isHidden = state.activity == .off
        let paused = state.activity == .paused
        pauseButton.image = NSImage(systemSymbolName: paused ? "play.fill" : "pause.fill",
                                    accessibilityDescription: paused ? "Resume" : "Pause")?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .regular))
        pauseButton.toolTip = paused ? "Resume First Mate" : "Pause First Mate"
        setAccessibilityLabel("First Mate, \(word). \(second)")
    }

    static func describe(_ activity: AutopilotCoordinator.State.Activity) -> (String, NSColor) {
        switch activity {
        case .off: return ("off", SemanticColors.subtle)
        case .starting: return ("starting…", SemanticColors.subtle)
        case .idle: return ("idle", SemanticColors.idle)
        case .thinking: return ("thinking…", SemanticColors.running)
        case .needsYou: return ("needs you", SemanticColors.attention)
        case .paused: return ("paused", SemanticColors.subtle)
        }
    }

    var latestTextForTesting: String { latest.stringValue }
    var activityTextForTesting: String { activity.stringValue }

    /// Not a gesture recognizer: one on the dock would also fire for clicks on
    /// its buttons. A button handles its own mouseDown, so this only sees the rest.
    override func mouseDown(with event: NSEvent) { onOpen?() }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        let settings = NSMenuItem(title: "First Mate Settings…", action: #selector(settingsClicked), keyEquivalent: "")
        settings.target = self
        menu.addItem(settings)
        return menu
    }

    @objc private func settingsClicked() { onShowSettings?() }
    @objc private func pauseClicked() { onTogglePause?() }
    @objc private func historyClicked() { onShowHistory?(historyButton) }
    @objc private func helpClicked() { onShowAllShortcuts?() }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshColors()
    }

    private func refreshColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            rule.layer?.backgroundColor = Self.topLine.cgColor
        }
    }
}
