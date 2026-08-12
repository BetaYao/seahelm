import AppKit
import UserNotifications

/// Step 5: what the wizard actually did, and the three keys to know.
///
/// The install report is the point of this step — before, hooks were written to
/// `~/.claude`, `~/.codex` and `~/.local/bin` with no acknowledgement at all, so
/// a partial failure surfaced days later as "status detection doesn't work".
final class OnboardingReadyStepView: NSView {
    private struct Shortcut {
        let keys: String
        let what: String
    }

    private static let shortcuts = [
        Shortcut(keys: "⌘P", what: "Jump to any worktree, project or command"),
        Shortcut(keys: "⌘D", what: "Split the current pane"),
        Shortcut(keys: "Space", what: "Leader key — opens the which-key menu"),
    ]

    private let summaryStack = NSStackView()
    private let installStack = NSStackView()
    private let installHeader = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// Render the outcome of the run. `installSteps` is empty when the user got
    /// here without hooks being installed (webhook disabled, no agents).
    func configure(config: Config, installSteps: [OnboardingHookInstaller.InstallStep]) {
        summaryStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        installStack.arrangedSubviews.forEach { $0.removeFromSuperview() }

        let agent = SailorType(rawValue: config.defaultAgent)?.displayName ?? config.defaultAgent
        let theme = (ThemeMode(rawValue: config.themeMode) ?? .system).rawValue.capitalized
        summaryStack.addArrangedSubview(makeSummaryChip(label: "Default agent", value: agent))
        summaryStack.addArrangedSubview(makeSummaryChip(label: "Appearance", value: theme))
        summaryStack.addArrangedSubview(
            makeSummaryChip(label: "Yolo", value: config.agentYolo ? "On" : "Off")
        )

        let failed = installSteps.filter { !$0.ok }
        installHeader.attributedStringValue = makeInstallHeader(
            total: installSteps.count, failedCount: failed.count
        )
        // Only failures are itemized. A green wall of "installed ✓" is noise; a
        // short list of what didn't land is the thing worth reading.
        for step in failed {
            installStack.addArrangedSubview(makeInstallRow(step))
        }
        installStack.isHidden = failed.isEmpty
    }

    private func setup() {
        summaryStack.orientation = .horizontal
        summaryStack.spacing = 10
        summaryStack.distribution = .fillEqually
        summaryStack.translatesAutoresizingMaskIntoConstraints = false

        installHeader.translatesAutoresizingMaskIntoConstraints = false
        installStack.orientation = .vertical
        installStack.spacing = 6
        installStack.alignment = .leading
        installStack.translatesAutoresizingMaskIntoConstraints = false

        let shortcutsCard = makeShortcutsCard()

        addSubview(summaryStack)
        addSubview(installHeader)
        addSubview(installStack)
        addSubview(shortcutsCard)

        NSLayoutConstraint.activate([
            summaryStack.topAnchor.constraint(equalTo: topAnchor),
            summaryStack.leadingAnchor.constraint(equalTo: leadingAnchor),
            summaryStack.trailingAnchor.constraint(equalTo: trailingAnchor),

            installHeader.topAnchor.constraint(equalTo: summaryStack.bottomAnchor, constant: 20),
            installHeader.leadingAnchor.constraint(equalTo: leadingAnchor),
            installHeader.trailingAnchor.constraint(equalTo: trailingAnchor),

            installStack.topAnchor.constraint(equalTo: installHeader.bottomAnchor, constant: 8),
            installStack.leadingAnchor.constraint(equalTo: leadingAnchor),
            installStack.trailingAnchor.constraint(equalTo: trailingAnchor),

            shortcutsCard.topAnchor.constraint(equalTo: installStack.bottomAnchor, constant: 22),
            shortcutsCard.leadingAnchor.constraint(equalTo: leadingAnchor),
            shortcutsCard.trailingAnchor.constraint(equalTo: trailingAnchor),
            shortcutsCard.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor),
        ])
    }

    private func makeSummaryChip(label: String, value: String) -> NSView {
        let panel = OnboardingPanel()
        panel.showsSelectionGlow = false
        let caption = OnboardingStyle.monoLabel(label.uppercased(), size: 10,
                                                color: OnboardingStyle.textFaint)
        let valueLabel = OnboardingStyle.label(value, size: 14, weight: .semibold)
        valueLabel.lineBreakMode = .byTruncatingTail

        panel.addSubview(caption)
        panel.addSubview(valueLabel)
        NSLayoutConstraint.activate([
            panel.heightAnchor.constraint(equalToConstant: 58),
            caption.topAnchor.constraint(equalTo: panel.topAnchor, constant: 12),
            caption.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 14),
            valueLabel.leadingAnchor.constraint(equalTo: caption.leadingAnchor),
            valueLabel.trailingAnchor.constraint(lessThanOrEqualTo: panel.trailingAnchor, constant: -12),
            valueLabel.topAnchor.constraint(equalTo: caption.bottomAnchor, constant: 3),
        ])
        return panel
    }

    private func makeInstallHeader(total: Int, failedCount: Int) -> NSAttributedString {
        let header = NSMutableAttributedString()
        let (dot, color, text): (String, NSColor, String)
        if total == 0 {
            (dot, color, text) = ("○", OnboardingStyle.textFaint,
                                  "No agent integrations were installed.")
        } else if failedCount == 0 {
            (dot, color, text) = ("●", OnboardingStyle.ok,
                                  "Installed \(total) integration\(total == 1 ? "" : "s") — "
                                      + "your agents now report status back to Seahelm.")
        } else {
            (dot, color, text) = ("●", OnboardingStyle.warn,
                                  "\(failedCount) of \(total) couldn't be written. "
                                      + "Seahelm still runs; those agents just won't report status.")
        }
        header.append(NSAttributedString(string: "\(dot) ", attributes: [
            .font: NSFont.systemFont(ofSize: 9, weight: .bold),
            .foregroundColor: color,
        ]))
        header.append(NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 12.5, weight: .medium),
            .foregroundColor: OnboardingStyle.textSecondary,
        ]))
        return header
    }

    private func makeInstallRow(_ step: OnboardingHookInstaller.InstallStep) -> NSView {
        let row = NSTextField(labelWithString: "")
        row.translatesAutoresizingMaskIntoConstraints = false
        let text = NSMutableAttributedString(string: "✗  \(step.name)  ", attributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium),
            .foregroundColor: SemanticColors.danger,
        ])
        text.append(NSAttributedString(string: step.detail, attributes: [
            .font: AppFont.mono(size: 11),
            .foregroundColor: OnboardingStyle.textFaint,
        ]))
        row.attributedStringValue = text
        return row
    }

    private func makeShortcutsCard() -> NSView {
        let card = OnboardingPanel()
        card.showsSelectionGlow = false

        let heading = OnboardingStyle.label("Three keys worth remembering", size: 13, weight: .semibold)
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.spacing = 10
        stack.alignment = .leading
        stack.translatesAutoresizingMaskIntoConstraints = false

        for shortcut in Self.shortcuts {
            let row = NSView()
            row.translatesAutoresizingMaskIntoConstraints = false
            let cap = KeycapView(text: shortcut.keys)
            let what = OnboardingStyle.label(shortcut.what, size: 12.5,
                                             color: OnboardingStyle.textSecondary)
            row.addSubview(cap)
            row.addSubview(what)
            NSLayoutConstraint.activate([
                cap.leadingAnchor.constraint(equalTo: row.leadingAnchor),
                cap.centerYAnchor.constraint(equalTo: row.centerYAnchor),
                // Fixed column so the descriptions line up and the caps don't
                // stretch to fill the row.
                cap.widthAnchor.constraint(equalToConstant: 64),
                what.leadingAnchor.constraint(equalTo: cap.trailingAnchor, constant: 14),
                what.centerYAnchor.constraint(equalTo: row.centerYAnchor),
                what.trailingAnchor.constraint(lessThanOrEqualTo: row.trailingAnchor),
                row.topAnchor.constraint(equalTo: cap.topAnchor),
                row.bottomAnchor.constraint(equalTo: cap.bottomAnchor),
            ])
            stack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }

        card.addSubview(heading)
        card.addSubview(stack)
        NSLayoutConstraint.activate([
            heading.topAnchor.constraint(equalTo: card.topAnchor, constant: 16),
            heading.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 18),
            stack.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: 12),
            stack.leadingAnchor.constraint(equalTo: heading.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -18),
            card.bottomAnchor.constraint(equalTo: stack.bottomAnchor, constant: 18),
        ])
        return card
    }
}

/// A key cap: bordered mono chip.
private final class KeycapView: NSView, OnboardingThemeReactive {
    private let label: NSTextField

    init(text: String) {
        label = OnboardingStyle.monoLabel(text, size: 11.5, weight: .medium,
                                          color: OnboardingStyle.textPrimary)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 5
        layer?.borderWidth = 1
        translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 24),
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            widthAnchor.constraint(greaterThanOrEqualTo: label.widthAnchor, constant: 14),
        ])
        applyTheme()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyTheme()
    }

    func applyTheme() {
        layer?.backgroundColor = resolvedCGColor(SemanticColors.panel2)
        layer?.borderColor = resolvedCGColor(SemanticColors.lineAlpha22)
        label.textColor = OnboardingStyle.textPrimary
    }
}
