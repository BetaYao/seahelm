import AppKit

/// Step 2: theme cards + optional Ghostty font import.
final class OnboardingThemeStepView: NSView {
    private var selected: ThemeMode = .system
    private var ghosttySource: URL?

    private let cardsStack = NSStackView()
    private let importBanner = NSView()
    private let importTitle = NSTextField(labelWithString: "")
    private let importPath = NSTextField(labelWithString: "")
    private let importButton = OnboardingPrimaryButton(frame: .zero)
    private let hintLabel = OnboardingStyle.wrappingLabel(
        "More terminal options (fonts, cursor, colors) are in Settings → Terminal.",
        size: 12.5, color: OnboardingStyle.textFaint
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

        importBanner.wantsLayer = true
        importBanner.layer?.cornerRadius = 12
        importBanner.layer?.backgroundColor = OnboardingStyle.accentTint.cgColor
        importBanner.layer?.borderWidth = 1
        importBanner.layer?.borderColor = OnboardingStyle.accent.withAlphaComponent(0.25).cgColor
        importBanner.translatesAutoresizingMaskIntoConstraints = false

        importTitle.translatesAutoresizingMaskIntoConstraints = false
        importPath.font = AppFont.mono(size: 11.5)
        importPath.textColor = OnboardingStyle.textSecondary
        importPath.lineBreakMode = .byTruncatingMiddle
        importPath.translatesAutoresizingMaskIntoConstraints = false

        importButton.text = "Import"
        importButton.showsShortcut = false
        importButton.target = self
        importButton.action = #selector(importFonts)

        importBanner.addSubview(importTitle)
        importBanner.addSubview(importPath)
        importBanner.addSubview(importButton)

        addSubview(cardsStack)
        addSubview(importBanner)
        addSubview(hintLabel)

        NSLayoutConstraint.activate([
            cardsStack.topAnchor.constraint(equalTo: topAnchor),
            cardsStack.leadingAnchor.constraint(equalTo: leadingAnchor),
            cardsStack.trailingAnchor.constraint(equalTo: trailingAnchor),
            cardsStack.heightAnchor.constraint(equalToConstant: 190),

            importBanner.topAnchor.constraint(equalTo: cardsStack.bottomAnchor, constant: 22),
            importBanner.leadingAnchor.constraint(equalTo: leadingAnchor),
            importBanner.trailingAnchor.constraint(equalTo: trailingAnchor),

            importTitle.leadingAnchor.constraint(equalTo: importBanner.leadingAnchor, constant: 16),
            importTitle.topAnchor.constraint(equalTo: importBanner.topAnchor, constant: 14),
            importTitle.trailingAnchor.constraint(lessThanOrEqualTo: importButton.leadingAnchor, constant: -12),
            importPath.leadingAnchor.constraint(equalTo: importTitle.leadingAnchor),
            importPath.topAnchor.constraint(equalTo: importTitle.bottomAnchor, constant: 3),
            importPath.trailingAnchor.constraint(lessThanOrEqualTo: importButton.leadingAnchor, constant: -12),
            importBanner.bottomAnchor.constraint(equalTo: importPath.bottomAnchor, constant: 14),

            importButton.trailingAnchor.constraint(equalTo: importBanner.trailingAnchor, constant: -14),
            importButton.centerYAnchor.constraint(equalTo: importBanner.centerYAnchor),
            importButton.heightAnchor.constraint(equalToConstant: 32),
            importButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 84),

            hintLabel.topAnchor.constraint(equalTo: importBanner.bottomAnchor, constant: 14),
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
            let title = NSMutableAttributedString(string: "Ghostty config detected. ", attributes: [
                .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
                .foregroundColor: OnboardingStyle.textPrimary,
            ])
            title.append(NSAttributedString(string: "Import fonts?", attributes: [
                .font: NSFont.systemFont(ofSize: 13),
                .foregroundColor: OnboardingStyle.textSecondary,
            ]))
            importTitle.attributedStringValue = title
            importPath.stringValue = source.path
        } else {
            importBanner.isHidden = true
        }
    }

    @objc private func importFonts() {
        guard let source = ghosttySource else { return }
        let ok = GhosttyConfigImporter.importFonts(from: source)
        importButton.text = ok ? "Imported ✓" : "Import failed"
        importButton.isEnabled = !ok
    }
}

/// A theme choice card with a hand-drawn mini terminal preview.
private final class ThemePreviewCard: NSView {
    let mode: ThemeMode
    var onPick: ((ThemeMode) -> Void)?
    var isPicked = false {
        didSet { panel.isSelected = isPicked }
    }

    private let panel = OnboardingPanel()
    private let preview = MiniTerminalPreview()
    private let nameLabel: NSTextField
    private let subLabel: NSTextField

    init(mode: ThemeMode) {
        self.mode = mode
        let (name, sub, symbol): (String, String, String)
        switch mode {
        case .system: (name, sub, symbol) = ("System", "Match OS", "display")
        case .dark: (name, sub, symbol) = ("Dark", "Easy on the eyes", "moon")
        case .light: (name, sub, symbol) = ("Light", "Bright & crisp", "sun.max")
        }
        nameLabel = OnboardingStyle.label(name, size: 14, weight: .semibold)
        subLabel = OnboardingStyle.label(sub, size: 12, color: OnboardingStyle.textFaint)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        panel.showsCheckBadge = true
        panel.onClick = { [weak self] in
            guard let self else { return }
            self.onPick?(self.mode)
        }

        preview.mode = mode
        preview.translatesAutoresizingMaskIntoConstraints = false

        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .medium))
        icon.contentTintColor = OnboardingStyle.textSecondary
        icon.translatesAutoresizingMaskIntoConstraints = false

        addSubview(panel)
        panel.addSubview(preview)
        panel.addSubview(icon)
        panel.addSubview(nameLabel)
        panel.addSubview(subLabel)

        NSLayoutConstraint.activate([
            panel.topAnchor.constraint(equalTo: topAnchor),
            panel.leadingAnchor.constraint(equalTo: leadingAnchor),
            panel.trailingAnchor.constraint(equalTo: trailingAnchor),
            panel.bottomAnchor.constraint(equalTo: bottomAnchor),

            preview.topAnchor.constraint(equalTo: panel.topAnchor, constant: 12),
            preview.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 12),
            preview.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -12),
            preview.heightAnchor.constraint(equalToConstant: 118),

            icon.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 14),
            icon.centerYAnchor.constraint(equalTo: nameLabel.centerYAnchor),
            nameLabel.topAnchor.constraint(equalTo: preview.bottomAnchor, constant: 14),
            nameLabel.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 7),

            subLabel.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -14),
            subLabel.centerYAnchor.constraint(equalTo: nameLabel.centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
}

/// Draws a tiny fake terminal window: traffic lights, an accent prompt line
/// and dim output bars, in dark / light / half-and-half (system) flavors.
private final class MiniTerminalPreview: NSView {
    var mode: ThemeMode = .system { didSet { needsDisplay = true } }

    private let darkBG = NSColor(red: 0.09, green: 0.10, blue: 0.11, alpha: 1)
    private let lightBG = NSColor(red: 0.96, green: 0.96, blue: 0.97, alpha: 1)

    override func draw(_ dirtyRect: NSRect) {
        let radius: CGFloat = 8
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
            // Vertical split: dark left, light right.
            darkBG.setFill()
            bounds.fill()
            lightBG.setFill()
            NSRect(x: bounds.midX, y: bounds.minY, width: bounds.width / 2, height: bounds.height).fill()
            drawTerminal(dark: true, in: bounds)
        }

        NSColor.black.withAlphaComponent(0.1).setStroke()
        let border = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: radius, yRadius: radius)
        border.lineWidth = 1
        border.stroke()
    }

    private func drawTerminal(dark: Bool, in rect: NSRect) {
        let dim = dark ? NSColor.white.withAlphaComponent(0.25) : NSColor.black.withAlphaComponent(0.2)

        // Traffic lights.
        let dotColors: [NSColor] = [
            NSColor(red: 1.0, green: 0.37, blue: 0.34, alpha: 1),
            NSColor(red: 1.0, green: 0.75, blue: 0.18, alpha: 1),
            NSColor(red: 0.2, green: 0.8, blue: 0.35, alpha: 1),
        ]
        for (i, color) in dotColors.enumerated() {
            color.setFill()
            NSBezierPath(ovalIn: NSRect(
                x: rect.minX + 11, y: rect.maxY - 16, width: 6, height: 6
            ).offsetBy(dx: CGFloat(i) * 11, dy: 0)).fill()
        }

        // Prompt line: accent ❯ + command bar.
        OnboardingStyle.accent.setFill()
        NSRect(x: rect.minX + 11, y: rect.maxY - 36, width: 7, height: 4).fill(using: .sourceOver)
        (dark ? NSColor.white.withAlphaComponent(0.55) : NSColor.black.withAlphaComponent(0.5)).setFill()
        NSRect(x: rect.minX + 23, y: rect.maxY - 36, width: 52, height: 4).fill(using: .sourceOver)

        // Output bars.
        let widths: [CGFloat] = [82, 64, 94, 44]
        for (i, w) in widths.enumerated() {
            dim.setFill()
            NSRect(x: rect.minX + 11, y: rect.maxY - 50 - CGFloat(i) * 11, width: w, height: 4)
                .fill(using: .sourceOver)
        }

        // Status chip, island-style.
        OnboardingStyle.accent.withAlphaComponent(0.5).setFill()
        NSRect(x: rect.minX + 11, y: rect.minY + 9, width: 24, height: 5).fill(using: .sourceOver)
    }
}
