import AppKit

/// First Mate, pinned to the foot of the fleet column: a card of its own, not a
/// footer, tinted by what it needs from you — calm while it watches, green while
/// it works, amber when it is waiting on you. The second line says what is true
/// *now* (what it is doing, what waits on you, or what it last handled and
/// when), never an echo of what you said to it.
///
/// Clicking it opens First Mate over the terminal side; the badge answers its
/// cards, the clock shows its history, the `?` is the keyboard cheat-sheet.
final class FirstMateDockView: NSView {
    var onOpen: (() -> Void)?
    var onTogglePause: (() -> Void)?
    var onShowAllShortcuts: (() -> Void)?
    /// Settings ▸ First Mate, from the dock's context menu.
    var onShowSettings: (() -> Void)?
    /// The approvals badge: anchor view to show the waiting cards from.
    var onShowApprovals: ((NSView) -> Void)?
    /// The history button: anchor view to show the log from.
    var onShowHistory: ((NSView) -> Void)?

    private let card = NSView()
    private let mark = NSImageView()
    private let title = NSTextField(labelWithString: "First Mate")
    private let dot = NSView()
    private let spinner = SpinnerDotView(color: SemanticColors.running)
    private let activity = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")
    private let badge = NSButton()
    private let pauseButton = NSButton()
    private let historyButton = NSButton()
    private let helpButton = NSButton()
    private var clock: Timer?
    private var hovered = false
    private(set) var state = AutopilotCoordinator.State()

    /// How the card is tinted.
    enum Tone: Equatable { case quiet, watching, working, wantsYou }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    deinit { clock?.invalidate() }

    private func setup() {
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityIdentifier("overview.firstMateDock")
        setAccessibilityRole(.button)

        card.wantsLayer = true
        card.layer?.cornerRadius = 10
        card.layer?.borderWidth = 1
        card.translatesAutoresizingMaskIntoConstraints = false
        addSubview(card)

        mark.image = NSImage(systemSymbolName: "steeringwheel", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 15, weight: .semibold))
        title.font = AppFont.mono(size: 13, weight: .bold)
        title.textColor = SemanticColors.text
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 3.5
        dot.translatesAutoresizingMaskIntoConstraints = false
        activity.font = AppFont.mono(size: 11, weight: .medium)
        detail.font = AppFont.mono(size: 11)
        detail.textColor = SemanticColors.muted
        detail.lineBreakMode = .byTruncatingTail
        detail.maximumNumberOfLines = 1
        detail.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        badge.bezelStyle = .inline
        badge.target = self
        badge.action = #selector(badgeClicked)
        badge.toolTip = "Approve or decline what First Mate asked"
        badge.refusesFirstResponder = true
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
        let status = NSStackView(views: [dot, spinner, activity])
        status.spacing = 5
        status.alignment = .centerY
        let line1 = NSStackView(views: [mark, title, status, spacer, badge, historyButton, pauseButton, helpButton])
        line1.orientation = .horizontal
        line1.spacing = 7
        line1.alignment = .centerY
        let column = NSStackView(views: [line1, detail])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 5
        column.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(column)

        NSLayoutConstraint.activate([
            card.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            card.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            card.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            card.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
            column.topAnchor.constraint(equalTo: card.topAnchor, constant: 10),
            column.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 12),
            column.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -10),
            column.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -10),
            line1.widthAnchor.constraint(equalTo: column.widthAnchor),
            dot.widthAnchor.constraint(equalToConstant: 7),
            dot.heightAnchor.constraint(equalToConstant: 7),
        ])
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                       owner: self, userInfo: nil))
        // "12m ago" has to keep counting while nothing new happens.
        clock = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.apply(self.state)
        }
        apply(state)
    }

    func apply(_ state: AutopilotCoordinator.State) {
        self.state = state
        let (word, color) = Self.describe(state.activity)
        activity.stringValue = word
        activity.textColor = color
        let working = state.activity == .thinking
        spinner.isHidden = !working
        dot.isHidden = working
        dot.layer?.backgroundColor = color.cgColor
        let line = Self.detailLine(state, now: Date())
        detail.stringValue = line
        detail.textColor = Self.tone(state) == .wantsYou ? SemanticColors.attention : SemanticColors.muted
        badge.isHidden = state.pendingApprovals == 0
        badge.attributedTitle = NSAttributedString(string: " \(state.pendingApprovals) to approve ", attributes: [
            .font: AppFont.mono(size: 10, weight: .bold), .foregroundColor: SemanticColors.attention,
        ])
        pauseButton.isHidden = state.activity == .off
        let paused = state.activity == .paused
        pauseButton.image = NSImage(systemSymbolName: paused ? "play.fill" : "pause.fill",
                                    accessibilityDescription: paused ? "Resume" : "Pause")?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .regular))
        pauseButton.toolTip = paused ? "Resume First Mate" : "Pause First Mate"
        setAccessibilityLabel("First Mate, \(word). \(line)")
        refreshColors()
    }

    static func describe(_ activity: AutopilotCoordinator.State.Activity) -> (String, NSColor) {
        switch activity {
        case .off: return ("off", SemanticColors.subtle)
        case .starting: return ("starting", SemanticColors.subtle)
        case .idle: return ("watching", SemanticColors.accent)
        case .thinking: return ("working", SemanticColors.running)
        case .needsYou: return ("needs you", SemanticColors.attention)
        case .paused: return ("paused", SemanticColors.subtle)
        }
    }

    static func tone(_ state: AutopilotCoordinator.State) -> Tone {
        if state.activity == .needsYou || (state.pendingApprovals > 0 && state.activity != .off) { return .wantsYou }
        switch state.activity {
        case .off, .paused, .starting: return .quiet
        case .thinking: return .working
        case .idle, .needsYou: return .watching
        }
    }

    /// The second line: what is true now.
    static func detailLine(_ state: AutopilotCoordinator.State, now: Date) -> String {
        let queued = state.queued > 0 ? "\(state.queued) queued · " : ""
        switch state.activity {
        case .off: return "Off — click to set it up"
        case .starting: return "Starting its session…"
        case .paused: return queued.isEmpty ? "Paused — events wait until you resume" : "Paused · \(queued)waiting to resume"
        case .needsYou: return "Waiting for your answer in its terminal"
        case .thinking:
            let doing = state.doing.trimmingCharacters(in: .whitespacesAndNewlines)
            return queued + (doing.isEmpty ? "Working…" : doing)
        case .idle:
            if state.pendingApprovals > 0 {
                return "\(state.pendingApprovals) waiting for your approval"
            }
            if let at = state.latestAt, now.timeIntervalSince(at) < 6 * 3600, !state.latest.isEmpty {
                return queued + Self.ago(at, now: now) + " · " + state.latest
            }
            let projects = state.watching == 1 ? "1 project" : "\(state.watching) projects"
            return queued + "\(projects) · CI & merges"
        }
    }

    static func ago(_ date: Date, now: Date) -> String {
        let s = max(0, Int(now.timeIntervalSince(date)))
        if s < 60 { return "just now" }
        if s < 3600 { return "\(s / 60)m ago" }
        return "\(s / 3600)h ago"
    }

    var latestTextForTesting: String { detail.stringValue }
    var activityTextForTesting: String { activity.stringValue }

    /// Not a gesture recognizer: one on the dock would also fire for clicks on
    /// its buttons. A button handles its own mouseDown, so this only sees the rest.
    override func mouseDown(with event: NSEvent) { onOpen?() }

    override func mouseEntered(with event: NSEvent) { hovered = true; refreshColors() }
    override func mouseExited(with event: NSEvent) { hovered = false; refreshColors() }

    override func resetCursorRects() { addCursorRect(card.frame, cursor: .pointingHand) }

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
    @objc private func badgeClicked() { onShowApprovals?(badge) }
    @objc private func helpClicked() { onShowAllShortcuts?() }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshColors()
    }

    private func refreshColors() {
        let base: NSColor
        switch Self.tone(state) {
        case .quiet: base = SemanticColors.subtle
        case .watching: base = SemanticColors.accent
        case .working: base = SemanticColors.running
        case .wantsYou: base = SemanticColors.attention
        }
        effectiveAppearance.performAsCurrentDrawingAppearance {
            card.layer?.backgroundColor = base.withAlphaComponent(hovered ? 0.16 : 0.10).cgColor
            card.layer?.borderColor = base.withAlphaComponent(0.35).cgColor
            mark.contentTintColor = Self.tone(state) == .quiet ? SemanticColors.subtle : base
        }
    }
}
