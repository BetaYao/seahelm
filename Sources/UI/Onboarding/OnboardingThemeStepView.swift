import AppKit

/// Step 2: theme cards + optional Ghostty font import.
final class OnboardingThemeStepView: NSView {
    private var selected: ThemeMode = .system
    private var ghosttySource: URL?

    private let cardsStack = NSStackView()
    private let importBanner = OnboardingPanel()
    private let importLabel = NSTextField(wrappingLabelWithString: "")
    private let importButton = NSButton(title: "Import", target: nil, action: nil)
    private let hintLabel = OnboardingStyle.wrappingLabel(
        "More terminal options (fonts, cursor, colors) are in Settings → Terminal.",
        size: 11, color: OnboardingStyle.textFaint
    )

    private var cards: [ThemeMode: ThemePreviewCard] = [:]

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func configure(config: Config) {
        selected = ThemeMode(rawValue: config.themeMode) ?? .system
        ghosttySource = GhosttyConfigImporter.detectSourceURL()
        refreshCards()
        refreshImportBanner()
        ThemeMode.applyAppearance(selected)
    }

    func selectedThemeMode() -> ThemeMode { selected }

    private func setup() {
        cardsStack.orientation = .horizontal
        cardsStack.spacing = 14
        cardsStack.distribution = .fillEqually
        cardsStack.translatesAutoresizingMaskIntoConstraints = false

        for mode in [ThemeMode.system, .dark, .light] {
            let card = ThemePreviewCard(mode: mode)
            card.onPick = { [weak self] picked in
                guard let self else { return }
                self.selected = picked
                ThemeMode.applyAppearance(picked)
                self.refreshCards()
            }
            cards[mode] = card
            cardsStack.addArrangedSubview(card)
        }

        importLabel.font = AppFont.mono(size: 12)
        importLabel.textColor = OnboardingStyle.textPrimary
        importLabel.translatesAutoresizingMaskIntoConstraints = false

        importButton.bezelStyle = .rounded
        importButton.target = self
        importButton.action = #selector(importFonts)
        importButton.translatesAutoresizingMaskIntoConstraints = false

        importBanner.addSubview(importLabel)
        importBanner.addSubview(importButton)

        addSubview(cardsStack)
        addSubview(importBanner)
        addSubview(hintLabel)

        NSLayoutConstraint.activate([
            cardsStack.topAnchor.constraint(equalTo: topAnchor),
            cardsStack.leadingAnchor.constraint(equalTo: leadingAnchor),
            cardsStack.trailingAnchor.constraint(equalTo: trailingAnchor),
            cardsStack.heightAnchor.constraint(equalToConstant: 170),

            importBanner.topAnchor.constraint(equalTo: cardsStack.bottomAnchor, constant: 20),
            importBanner.leadingAnchor.constraint(equalTo: leadingAnchor),
            importBanner.trailingAnchor.constraint(equalTo: trailingAnchor),

            importLabel.leadingAnchor.constraint(equalTo: importBanner.leadingAnchor, constant: 14),
            importLabel.topAnchor.constraint(equalTo: importBanner.topAnchor, constant: 14),
            importLabel.trailingAnchor.constraint(lessThanOrEqualTo: importButton.leadingAnchor, constant: -12),
            importBanner.bottomAnchor.constraint(equalTo: importLabel.bottomAnchor, constant: 14),

            importButton.trailingAnchor.constraint(equalTo: importBanner.trailingAnchor, constant: -14),
            importButton.centerYAnchor.constraint(equalTo: importBanner.centerYAnchor),

            hintLabel.topAnchor.constraint(equalTo: importBanner.bottomAnchor, constant: 12),
            hintLabel.leadingAnchor.constraint(equalTo: leadingAnchor),
            hintLabel.trailingAnchor.constraint(equalTo: trailingAnchor),
            hintLabel.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor),
        ])
    }

    private func refreshCards() {
        for (mode, card) in cards {
            card.isPicked = mode == selected
        }
    }

    private func refreshImportBanner() {
        if let source = ghosttySource {
            importBanner.isHidden = false
            importLabel.stringValue = "Ghostty config detected — import fonts?\n\(source.path)"
        } else {
            importBanner.isHidden = true
        }
    }

    @objc private func importFonts() {
        guard let source = ghosttySource else { return }
        let ok = GhosttyConfigImporter.importFonts(from: source)
        importButton.title = ok ? "Imported ✓" : "Import failed"
        importButton.isEnabled = !ok
    }
}

/// A theme choice card with a hand-drawn mini terminal preview.
private final class ThemePreviewCard: NSView {
    let mode: ThemeMode
    var onPick: ((ThemeMode) -> Void)?
    var isPicked = false {
        didSet {
            panel.isSelected = isPicked
            check.isHidden = !isPicked
        }
    }

    private let panel = OnboardingPanel()
    private let preview = MiniTerminalPreview()
    private let nameLabel: NSTextField
    private let subLabel: NSTextField
    private let check: NSTextField

    init(mode: ThemeMode) {
        self.mode = mode
        let (name, sub): (String, String)
        switch mode {
        case .system: (name, sub) = ("System", "match the OS")
        case .dark: (name, sub) = ("Dark", "easy on the eyes")
        case .light: (name, sub) = ("Light", "bright & crisp")
        }
        nameLabel = OnboardingStyle.label(name, size: 13, weight: .semibold)
        subLabel = OnboardingStyle.label(sub, size: 10.5, color: OnboardingStyle.textFaint)
        check = OnboardingStyle.label("✓", size: 12, weight: .bold, color: OnboardingStyle.accent)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        panel.onClick = { [weak self] in
            guard let self else { return }
            self.onPick?(self.mode)
        }

        preview.mode = mode
        preview.translatesAutoresizingMaskIntoConstraints = false
        check.isHidden = true

        addSubview(panel)
        panel.addSubview(preview)
        panel.addSubview(nameLabel)
        panel.addSubview(subLabel)
        panel.addSubview(check)

        NSLayoutConstraint.activate([
            panel.topAnchor.constraint(equalTo: topAnchor),
            panel.leadingAnchor.constraint(equalTo: leadingAnchor),
            panel.trailingAnchor.constraint(equalTo: trailingAnchor),
            panel.bottomAnchor.constraint(equalTo: bottomAnchor),

            preview.topAnchor.constraint(equalTo: panel.topAnchor, constant: 10),
            preview.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 10),
            preview.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -10),
            preview.heightAnchor.constraint(equalToConstant: 104),

            nameLabel.topAnchor.constraint(equalTo: preview.bottomAnchor, constant: 10),
            nameLabel.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 12),
            subLabel.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 1),
            subLabel.leadingAnchor.constraint(equalTo: nameLabel.leadingAnchor),

            check.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -12),
            check.centerYAnchor.constraint(equalTo: nameLabel.centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
}

/// Draws a tiny fake terminal window: traffic lights, a cyan prompt line and
/// dim output bars, in dark / light / half-and-half (system) flavors.
private final class MiniTerminalPreview: NSView {
    var mode: ThemeMode = .system { didSet { needsDisplay = true } }

    private let darkBG = NSColor(red: 0.05, green: 0.08, blue: 0.09, alpha: 1)
    private let lightBG = NSColor(red: 0.95, green: 0.96, blue: 0.96, alpha: 1)

    override func draw(_ dirtyRect: NSRect) {
        let radius: CGFloat = 7
        let clip = NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius)
        clip.addClip()

        switch mode {
        case .dark:
            darkBG.setFill()
            bounds.fill()
            drawTerminal(dark: true, in: bounds)
        case .light:
            lightBG.setFill()
            bounds.fill()
            drawTerminal(dark: false, in: bounds)
        case .system:
            // Diagonal split: dark upper-left, light lower-right.
            darkBG.setFill()
            bounds.fill()
            let split = NSBezierPath()
            split.move(to: NSPoint(x: bounds.maxX, y: bounds.maxY))
            split.line(to: NSPoint(x: bounds.maxX, y: bounds.minY))
            split.line(to: NSPoint(x: bounds.minX, y: bounds.minY))
            split.close()
            lightBG.setFill()
            split.fill()
            drawTerminal(dark: true, in: bounds)
        }

        NSColor.white.withAlphaComponent(0.08).setStroke()
        let border = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: radius, yRadius: radius)
        border.lineWidth = 1
        border.stroke()
    }

    private func drawTerminal(dark: Bool, in rect: NSRect) {
        let dim = dark ? NSColor.white.withAlphaComponent(0.25) : NSColor.black.withAlphaComponent(0.25)

        // Traffic lights.
        let dotColors: [NSColor] = [
            NSColor(red: 1.0, green: 0.37, blue: 0.34, alpha: 1),
            NSColor(red: 1.0, green: 0.75, blue: 0.18, alpha: 1),
            NSColor(red: 0.2, green: 0.8, blue: 0.35, alpha: 1),
        ]
        for (i, color) in dotColors.enumerated() {
            color.setFill()
            NSBezierPath(ovalIn: NSRect(
                x: rect.minX + 10 + CGFloat(i) * 11, y: rect.maxY - 15, width: 6, height: 6
            )).fill()
        }

        // Prompt line: cyan ❯ + command bar.
        OnboardingStyle.accent.setFill()
        NSRect(x: rect.minX + 10, y: rect.maxY - 34, width: 7, height: 4).fill(using: .sourceOver)
        (dark ? NSColor.white.withAlphaComponent(0.6) : NSColor.black.withAlphaComponent(0.55)).setFill()
        NSRect(x: rect.minX + 22, y: rect.maxY - 34, width: 52, height: 4).fill(using: .sourceOver)

        // Output bars.
        let widths: [CGFloat] = [80, 64, 92, 40]
        for (i, w) in widths.enumerated() {
            dim.setFill()
            NSRect(x: rect.minX + 10, y: rect.maxY - 48 - CGFloat(i) * 11, width: w, height: 4)
                .fill(using: .sourceOver)
        }

        // Status chip, island-style.
        OnboardingStyle.accent.withAlphaComponent(0.5).setFill()
        NSRect(x: rect.minX + 10, y: rect.minY + 8, width: 24, height: 5).fill(using: .sourceOver)
    }
}
