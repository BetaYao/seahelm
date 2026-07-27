import AppKit

/// Step 3: appearance + optional Ghostty font import.
///
/// Picking a card re-themes the wizard itself (the whole window follows
/// `NSApp.appearance`), so the choice is previewed at full size rather than only
/// inside a 118pt thumbnail.
final class OnboardingThemeStepView: NSView {
    /// Fired when the user picks a mode, so the wizard can restyle its chrome.
    var onThemeChanged: ((ThemeMode) -> Void)?

    private var selected: ThemeMode = .system
    private var ghosttySource: URL?
    private var didImport = false

    private let cardsStack = NSStackView()
    private let importBanner = OnboardingPanel()
    private let importIcon = OnboardingIconTile(symbol: "textformat", side: 32, pointSize: 14)
    private let importTitle = NSTextField(labelWithString: "")
    private let importPath = NSTextField(labelWithString: "")
    private let importStatus = OnboardingStatusPill()
    private let importButton = OnboardingSecondaryButton(text: "Import fonts", symbol: "arrow.down.circle")
    private let hintLabel = OnboardingStyle.wrappingLabel(
        "Fonts, cursor style and terminal colors all live in Settings → Terminal. "
            + "Nothing here is permanent.",
        size: 12, color: OnboardingStyle.textFaint
    )

    private var cards: [ThemeMode: ThemePreviewCard] = [:]
    private var importBannerHeight: NSLayoutConstraint?

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
        cardsStack.spacing = 12
        cardsStack.distribution = .fillEqually
        cardsStack.translatesAutoresizingMaskIntoConstraints = false

        for mode in [ThemeMode.system, .dark, .light] {
            let card = ThemePreviewCard(mode: mode)
            card.onPick = { [weak self] picked in
                guard let self else { return }
                self.selected = picked
                ThemeMode.applyAppearance(picked)
                self.refreshCards()
                self.onThemeChanged?(picked)
            }
            cards[mode] = card
            cardsStack.addArrangedSubview(card)
        }

        importBanner.showsSelectionGlow = false
        importTitle.translatesAutoresizingMaskIntoConstraints = false
        importPath.font = AppFont.mono(size: 11)
        importPath.textColor = OnboardingStyle.textFaint
        importPath.lineBreakMode = .byTruncatingMiddle
        importPath.translatesAutoresizingMaskIntoConstraints = false
        importStatus.isHidden = true

        importButton.target = self
        importButton.action = #selector(importFonts)

        for v in [importIcon, importTitle, importPath, importStatus, importButton] as [NSView] {
            importBanner.addSubview(v)
        }

        addSubview(cardsStack)
        addSubview(importBanner)
        addSubview(hintLabel)

        NSLayoutConstraint.activate([
            cardsStack.topAnchor.constraint(equalTo: topAnchor),
            cardsStack.leadingAnchor.constraint(equalTo: leadingAnchor),
            cardsStack.trailingAnchor.constraint(equalTo: trailingAnchor),
            cardsStack.heightAnchor.constraint(equalToConstant: 196),

            importBanner.topAnchor.constraint(equalTo: cardsStack.bottomAnchor, constant: 22),
            importBanner.leadingAnchor.constraint(equalTo: leadingAnchor),
            importBanner.trailingAnchor.constraint(equalTo: trailingAnchor),

            importIcon.leadingAnchor.constraint(equalTo: importBanner.leadingAnchor, constant: 14),
            importIcon.centerYAnchor.constraint(equalTo: importBanner.centerYAnchor),

            importTitle.leadingAnchor.constraint(equalTo: importIcon.trailingAnchor, constant: 12),
            importTitle.topAnchor.constraint(equalTo: importBanner.topAnchor, constant: 13),
            importTitle.trailingAnchor.constraint(lessThanOrEqualTo: importStatus.leadingAnchor, constant: -10),
            importPath.leadingAnchor.constraint(equalTo: importTitle.leadingAnchor),
            importPath.topAnchor.constraint(equalTo: importTitle.bottomAnchor, constant: 2),
            importPath.trailingAnchor.constraint(lessThanOrEqualTo: importButton.leadingAnchor, constant: -12),
            importBanner.bottomAnchor.constraint(equalTo: importPath.bottomAnchor, constant: 13),

            importStatus.trailingAnchor.constraint(equalTo: importButton.leadingAnchor, constant: -10),
            importStatus.centerYAnchor.constraint(equalTo: importBanner.centerYAnchor),
            importButton.trailingAnchor.constraint(equalTo: importBanner.trailingAnchor, constant: -14),
            importButton.centerYAnchor.constraint(equalTo: importBanner.centerYAnchor),

            hintLabel.topAnchor.constraint(equalTo: importBanner.bottomAnchor, constant: 16),
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
        guard let source = ghosttySource else {
            // Collapse rather than hide: a hidden view still owns its height
            // constraints, which would leave a gap above the hint.
            importBanner.isHidden = true
            importBannerHeight = importBannerHeight ?? importBanner.heightAnchor.constraint(equalToConstant: 0)
            importBannerHeight?.isActive = true
            return
        }
        importBanner.isHidden = false
        importBannerHeight?.isActive = false

        let title = NSMutableAttributedString(string: "Ghostty config found. ", attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
            .foregroundColor: OnboardingStyle.textPrimary,
        ])
        title.append(NSAttributedString(string: "Reuse its font settings?", attributes: [
            .font: NSFont.systemFont(ofSize: 13),
            .foregroundColor: OnboardingStyle.textSecondary,
        ]))
        importTitle.attributedStringValue = title
        importPath.stringValue = source.path
    }

    @objc private func importFonts() {
        guard let source = ghosttySource, !didImport else { return }
        let ok = GhosttyConfigImporter.importFonts(from: source)
        didImport = ok
        importStatus.isHidden = false
        importStatus.state = ok ? .ok("Imported") : .failed("Couldn't read that config")
        importButton.isEnabled = !ok
    }
}

/// A theme choice card with a mini terminal preview drawn in that theme's colors.
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
        case .system: (name, sub, symbol) = ("System", "Follows macOS", "circle.lefthalf.filled")
        case .dark: (name, sub, symbol) = ("Dark", "The default", "moon.fill")
        case .light: (name, sub, symbol) = ("Light", "Bright rooms", "sun.max.fill")
        }
        nameLabel = OnboardingStyle.label(name, size: 13.5, weight: .semibold)
        subLabel = OnboardingStyle.label(sub, size: 11.5, color: OnboardingStyle.textFaint)
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
            .withSymbolConfiguration(.init(pointSize: 11, weight: .semibold))
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
            preview.heightAnchor.constraint(equalToConstant: 122),

            icon.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 13),
            icon.centerYAnchor.constraint(equalTo: nameLabel.centerYAnchor),
            nameLabel.topAnchor.constraint(equalTo: preview.bottomAnchor, constant: 14),
            nameLabel.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 7),

            subLabel.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -13),
            subLabel.centerYAnchor.constraint(equalTo: nameLabel.centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
}

/// A tiny fake Seahelm window: sidebar rail, prompt line, output, status island.
/// Colors come from `SemanticColors` resolved against the previewed appearance,
/// so the thumbnail is the app's real palette rather than an approximation.
private final class MiniTerminalPreview: NSView {
    var mode: ThemeMode = .system { didSet { needsDisplay = true } }

    private static let darkAppearance = NSAppearance(named: .darkAqua)!
    private static let lightAppearance = NSAppearance(named: .aqua)!

    override func draw(_ dirtyRect: NSRect) {
        let radius: CGFloat = 7
        NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).addClip()

        switch mode {
        case .dark:
            drawWindow(appearance: Self.darkAppearance, in: bounds)
        case .light:
            drawWindow(appearance: Self.lightAppearance, in: bounds)
        case .system:
            // Two half-width windows side by side. Clipping one full-width window
            // to its right half would hide all of that half's content, which just
            // read as an empty panel.
            let left = NSRect(x: bounds.minX, y: bounds.minY,
                              width: bounds.width / 2, height: bounds.height)
            let right = NSRect(x: bounds.midX, y: bounds.minY,
                               width: bounds.width / 2, height: bounds.height)
            drawWindow(appearance: Self.darkAppearance, in: left)
            drawWindow(appearance: Self.lightAppearance, in: right)
            // Hairline seam so the two halves read as a deliberate split.
            resolve(SemanticColors.lineAlpha40, in: Self.darkAppearance).setStroke()
            let seam = NSBezierPath()
            seam.move(to: NSPoint(x: bounds.midX, y: bounds.minY))
            seam.line(to: NSPoint(x: bounds.midX, y: bounds.maxY))
            seam.lineWidth = 1
            seam.stroke()
        }

        resolve(SemanticColors.lineAlpha22, in: Self.darkAppearance).setStroke()
        let border = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
                                  xRadius: radius, yRadius: radius)
        border.lineWidth = 1
        border.stroke()
    }

    /// Resolve a dynamic color against an explicit appearance — `NSColor.cgColor`
    /// otherwise picks up whatever `NSAppearance.current` happens to be.
    private func resolve(_ color: NSColor, in appearance: NSAppearance) -> NSColor {
        var out = color
        appearance.performAsCurrentDrawingAppearance {
            out = color.usingColorSpace(.sRGB) ?? color
        }
        return out
    }

    private func drawWindow(appearance: NSAppearance, in rect: NSRect) {
        let bg = resolve(SemanticColors.bg, in: appearance).withAlphaComponent(1)
        let panel = resolve(SemanticColors.panel, in: appearance).withAlphaComponent(1)
        let accent = resolve(SemanticColors.accent, in: appearance)
        let text = resolve(SemanticColors.text, in: appearance)
        let muted = resolve(SemanticColors.muted, in: appearance)

        bg.setFill()
        rect.fill()

        // Sidebar rail.
        panel.setFill()
        NSRect(x: rect.minX, y: rect.minY, width: 26, height: rect.height).fill()
        for i in 0..<3 {
            (i == 0 ? accent : muted.withAlphaComponent(0.45)).setFill()
            NSRect(x: rect.minX + 7, y: rect.maxY - 16 - CGFloat(i) * 12, width: 12, height: 4)
                .fill(using: .sourceOver)
        }

        let contentX = rect.minX + 36

        // Prompt line: accent ❯ then a command bar.
        accent.setFill()
        NSRect(x: contentX, y: rect.maxY - 20, width: 6, height: 4).fill(using: .sourceOver)
        text.withAlphaComponent(0.7).setFill()
        NSRect(x: contentX + 11, y: rect.maxY - 20, width: 46, height: 4).fill(using: .sourceOver)

        // Output bars.
        let widths: [CGFloat] = [72, 54, 84, 40]
        for (i, w) in widths.enumerated() {
            muted.withAlphaComponent(0.42).setFill()
            NSRect(x: contentX, y: rect.maxY - 34 - CGFloat(i) * 10,
                   width: min(w, rect.maxX - contentX - 10), height: 4).fill(using: .sourceOver)
        }

        // Status island pill along the bottom.
        panel.setFill()
        let island = NSRect(x: contentX, y: rect.minY + 9, width: 62, height: 12)
        NSBezierPath(roundedRect: island, xRadius: 6, yRadius: 6).fill()
        accent.setFill()
        NSBezierPath(ovalIn: NSRect(x: island.minX + 5, y: island.midY - 2.5, width: 5, height: 5)).fill()
        muted.withAlphaComponent(0.6).setFill()
        NSRect(x: island.minX + 14, y: island.midY - 1.5, width: 38, height: 3).fill(using: .sourceOver)
    }
}
