import AppKit

/// First Mate, at the foot of the fleet column, drawn as a section rule:
///
///     ─── ⎈ First Mate · watching ───
///
/// A hairline with its name set into it, so it reads as part of the column's
/// structure rather than as one more row — and only the status word carries
/// colour (accent while it watches, green while it works, amber when it wants
/// you). A second line appears only when it is waiting on you, and is the way
/// to answer it. Everything else — what it is doing, what it last handled — is
/// the tooltip; history, pause and the `?` cheat-sheet show on hover.
///
/// It still has to look clickable: a `›` at the end of the rule says it opens
/// something, and on hover the row lifts like a fleet row does. Clicking it
/// opens First Mate over the terminal side.
final class FirstMateDockView: NSView {
    var onOpen: (() -> Void)?
    var onTogglePause: (() -> Void)?
    var onShowAllShortcuts: (() -> Void)?
    /// Settings ▸ First Mate, from the dock's context menu.
    var onShowSettings: (() -> Void)?
    /// The waiting-on-you line: anchor view to show the cards from.
    var onShowApprovals: ((NSView) -> Void)?
    /// The history button: anchor view to show the log from.
    var onShowHistory: ((NSView) -> Void)?

    private let leftRule = NSView()
    private let rightRule = NSView()
    private let mark = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private let spinner = SpinnerDotView(color: SemanticColors.running)
    private let attention = NSButton()
    private let pauseButton = NSButton()
    private let historyButton = NSButton()
    private let helpButton = NSButton()
    private let tools = NSStackView()
    private let chevron = NSImageView()
    private let hoverFill = NSView()
    private var clock: Timer?
    private var hovered = false {
        didSet {
            tools.isHidden = !hovered
            apply(state)
        }
    }
    private(set) var state = AutopilotCoordinator.State()

    /// What the status word's colour says.
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

        for rule in [leftRule, rightRule] {
            rule.wantsLayer = true
            rule.translatesAutoresizingMaskIntoConstraints = false
            rule.heightAnchor.constraint(equalToConstant: 1).isActive = true
        }
        leftRule.widthAnchor.constraint(equalToConstant: 14).isActive = true
        rightRule.setContentHuggingPriority(.defaultLow, for: .horizontal)

        mark.image = NSImage(systemSymbolName: "steeringwheel", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .medium))
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow + 1, for: .horizontal)

        attention.isBordered = false
        attention.alignment = .left
        attention.target = self
        attention.action = #selector(attentionClicked)
        attention.refusesFirstResponder = true
        attention.isHidden = true

        for (button, symbol, tip, action) in [
            (historyButton, "clock.arrow.circlepath", "What First Mate has done", #selector(historyClicked)),
            (pauseButton, "pause.fill", "Pause First Mate", #selector(pauseClicked)),
            (helpButton, "questionmark.circle", "Keyboard shortcuts (?)", #selector(helpClicked)),
        ] {
            button.isBordered = false
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)?
                .withSymbolConfiguration(.init(pointSize: 10, weight: .regular))
            button.contentTintColor = SemanticColors.subtle
            button.toolTip = tip
            button.target = self
            button.action = action
            button.refusesFirstResponder = true
            tools.addArrangedSubview(button)
        }
        tools.spacing = 6
        tools.isHidden = true
        chevron.image = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: "Open First Mate")?
            .withSymbolConfiguration(.init(pointSize: 10, weight: .semibold))
        hoverFill.wantsLayer = true
        hoverFill.layer?.cornerRadius = 8
        hoverFill.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hoverFill)

        let line1 = NSStackView(views: [leftRule, mark, spinner, label, rightRule, tools, chevron])
        line1.orientation = .horizontal
        line1.spacing = 6
        line1.alignment = .centerY
        let column = NSStackView(views: [line1, attention])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 4
        column.translatesAutoresizingMaskIntoConstraints = false
        addSubview(column)

        NSLayoutConstraint.activate([
            hoverFill.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            hoverFill.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            hoverFill.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            hoverFill.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
            column.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            column.leadingAnchor.constraint(equalTo: leadingAnchor),
            column.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            column.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
            line1.widthAnchor.constraint(equalTo: column.widthAnchor),
        ])
        attention.leadingAnchor.constraint(equalTo: mark.leadingAnchor).isActive = true
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                       owner: self, userInfo: nil))
        // "12m ago" in the tooltip keeps counting while nothing new happens.
        clock = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.apply(self.state)
        }
        apply(state)
    }

    func apply(_ state: AutopilotCoordinator.State) {
        self.state = state
        let (word, color) = Self.describe(state.activity)
        let text = NSMutableAttributedString(string: "First Mate", attributes: [
            .font: AppFont.mono(size: 11, weight: .semibold),
            .foregroundColor: hovered ? SemanticColors.text : SemanticColors.muted,
        ])
        text.append(NSAttributedString(string: " · ", attributes: [
            .font: AppFont.mono(size: 11), .foregroundColor: SemanticColors.subtle,
        ]))
        text.append(NSAttributedString(string: word, attributes: [
            .font: AppFont.mono(size: 11, weight: .medium), .foregroundColor: color,
        ]))
        label.attributedStringValue = text
        spinner.isHidden = state.activity != .thinking
        mark.contentTintColor = Self.tone(state) == .quiet ? SemanticColors.subtle : color

        let line = Self.detailLine(state, now: Date())
        let wantsYou = Self.tone(state) == .wantsYou
        attention.isHidden = !wantsYou
        attention.attributedTitle = NSAttributedString(string: line, attributes: [
            .font: AppFont.mono(size: 11), .foregroundColor: SemanticColors.attention,
        ])
        toolTip = "First Mate — \(word)  (⌘J)\n\(line)"

        pauseButton.isHidden = state.activity == .off
        let paused = state.activity == .paused
        pauseButton.image = NSImage(systemSymbolName: paused ? "play.fill" : "pause.fill",
                                    accessibilityDescription: paused ? "Resume" : "Pause")?
            .withSymbolConfiguration(.init(pointSize: 10, weight: .regular))
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

    /// What is true now: the tooltip always, the second line when it wants you.
    static func detailLine(_ state: AutopilotCoordinator.State, now: Date) -> String {
        let queued = state.queued > 0 ? "\(state.queued) queued · " : ""
        switch state.activity {
        case .off: return "Off — click to set it up"
        case .starting: return "Starting its session…"
        case .paused: return queued.isEmpty ? "Paused — events wait until you resume" : "Paused · \(queued)waiting to resume"
        case .needsYou: return "Waiting for your answer in its terminal"
        case .thinking:
            if state.pendingApprovals > 0 { return "\(state.pendingApprovals) waiting for your approval" }
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

    var latestTextForTesting: String { attention.isHidden ? "" : attention.title }
    var activityTextForTesting: String { label.stringValue }

    /// Not a gesture recognizer: one on the dock would also fire for clicks on
    /// its buttons. A button handles its own mouseDown, so this only sees the rest.
    override func mouseDown(with event: NSEvent) { onOpen?() }

    override func mouseEntered(with event: NSEvent) { hovered = true; refreshColors() }
    override func mouseExited(with event: NSEvent) { hovered = false; refreshColors() }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        let settings = NSMenuItem(title: "First Mate Settings…", action: #selector(settingsClicked), keyEquivalent: "")
        settings.target = self
        menu.addItem(settings)
        return menu
    }

    /// The amber line: approvals open their cards; anything else opens First Mate.
    @objc private func attentionClicked() {
        if state.pendingApprovals > 0 { onShowApprovals?(attention) } else { onOpen?() }
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
            let rule = (Self.tone(state) == .wantsYou ? SemanticColors.attention : SemanticColors.line)
                .withAlphaComponent(hovered ? 0.45 : 0.22).cgColor
            leftRule.layer?.backgroundColor = rule
            rightRule.layer?.backgroundColor = rule
            // The fleet rows' own hover fill, so it lifts the way a row does.
            hoverFill.layer?.backgroundColor = hovered
                ? (effectiveAppearance.isDark ? NSColor.white.withAlphaComponent(0.06)
                                              : NSColor.black.withAlphaComponent(0.05)).cgColor
                : NSColor.clear.cgColor
            chevron.contentTintColor = hovered ? SemanticColors.text : SemanticColors.subtle
        }
    }
}
