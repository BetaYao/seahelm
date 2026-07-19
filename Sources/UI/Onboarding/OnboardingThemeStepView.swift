import AppKit

/// Step 2: theme cards + optional Ghostty font import.
final class OnboardingThemeStepView: NSView {
    private var selected: ThemeMode = .system
    private var ghosttySource: URL?

    private let cardsStack = NSStackView()
    private let importBanner = NSView()
    private let importLabel = NSTextField(wrappingLabelWithString: "")
    private let importButton = NSButton(title: "Import", target: nil, action: nil)
    private let hintLabel = NSTextField(wrappingLabelWithString: "More terminal options (fonts, cursor, colors) are in Settings → Terminal.")

    private var cardButtons: [ThemeMode: NSButton] = [:]

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
            let btn = makeThemeCard(mode)
            cardButtons[mode] = btn
            cardsStack.addArrangedSubview(btn)
        }

        importBanner.wantsLayer = true
        importBanner.layer?.cornerRadius = 10
        importBanner.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        importBanner.translatesAutoresizingMaskIntoConstraints = false

        importLabel.font = .systemFont(ofSize: 13)
        importLabel.translatesAutoresizingMaskIntoConstraints = false

        importButton.bezelStyle = .rounded
        importButton.target = self
        importButton.action = #selector(importFonts)
        importButton.translatesAutoresizingMaskIntoConstraints = false

        importBanner.addSubview(importLabel)
        importBanner.addSubview(importButton)

        hintLabel.font = .systemFont(ofSize: 11)
        hintLabel.textColor = .secondaryLabelColor
        hintLabel.translatesAutoresizingMaskIntoConstraints = false

        addSubview(cardsStack)
        addSubview(importBanner)
        addSubview(hintLabel)

        NSLayoutConstraint.activate([
            cardsStack.topAnchor.constraint(equalTo: topAnchor),
            cardsStack.leadingAnchor.constraint(equalTo: leadingAnchor),
            cardsStack.trailingAnchor.constraint(equalTo: trailingAnchor),
            cardsStack.heightAnchor.constraint(equalToConstant: 140),

            importBanner.topAnchor.constraint(equalTo: cardsStack.bottomAnchor, constant: 20),
            importBanner.leadingAnchor.constraint(equalTo: leadingAnchor),
            importBanner.trailingAnchor.constraint(equalTo: trailingAnchor),
            importBanner.heightAnchor.constraint(greaterThanOrEqualToConstant: 56),

            importLabel.leadingAnchor.constraint(equalTo: importBanner.leadingAnchor, constant: 14),
            importLabel.centerYAnchor.constraint(equalTo: importBanner.centerYAnchor),
            importLabel.trailingAnchor.constraint(lessThanOrEqualTo: importButton.leadingAnchor, constant: -12),

            importButton.trailingAnchor.constraint(equalTo: importBanner.trailingAnchor, constant: -14),
            importButton.centerYAnchor.constraint(equalTo: importBanner.centerYAnchor),

            hintLabel.topAnchor.constraint(equalTo: importBanner.bottomAnchor, constant: 12),
            hintLabel.leadingAnchor.constraint(equalTo: leadingAnchor),
            hintLabel.trailingAnchor.constraint(equalTo: trailingAnchor),
            hintLabel.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor),
        ])
    }

    private func makeThemeCard(_ mode: ThemeMode) -> NSButton {
        let title: String
        let subtitle: String
        switch mode {
        case .system: title = "System"; subtitle = "Match OS"
        case .dark: title = "Dark"; subtitle = "Easy on the eyes"
        case .light: title = "Light"; subtitle = "Bright & crisp"
        }
        let btn = NSButton(title: "\(title)\n\(subtitle)", target: self, action: #selector(themePicked(_:)))
        btn.bezelStyle = .regularSquare
        btn.setButtonType(.momentaryPushIn)
        btn.identifier = NSUserInterfaceItemIdentifier(mode.rawValue)
        btn.wantsLayer = true
        btn.layer?.cornerRadius = 10
        btn.font = .systemFont(ofSize: 13, weight: .semibold)
        return btn
    }

    private func refreshCards() {
        for (mode, btn) in cardButtons {
            btn.layer?.borderWidth = mode == selected ? 2 : 1
            btn.layer?.borderColor = (mode == selected
                ? NSColor.controlAccentColor
                : NSColor.separatorColor).cgColor
        }
    }

    private func refreshImportBanner() {
        if let source = ghosttySource {
            importBanner.isHidden = false
            importLabel.stringValue = "Ghostty config detected. Import fonts?\n\(source.path)"
        } else {
            importBanner.isHidden = true
        }
    }

    @objc private func themePicked(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue,
              let mode = ThemeMode(rawValue: id) else { return }
        selected = mode
        ThemeMode.applyAppearance(mode)
        refreshCards()
    }

    @objc private func importFonts() {
        guard let source = ghosttySource else { return }
        let ok = GhosttyConfigImporter.importFonts(from: source)
        importButton.title = ok ? "Imported ✓" : "Import failed"
        importButton.isEnabled = !ok
    }
}
