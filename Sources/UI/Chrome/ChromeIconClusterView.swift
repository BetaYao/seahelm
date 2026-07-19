import AppKit

/// Shared Theme · First Mate · Files · Changes icon strip used by both chrome headers.
final class ChromeIconClusterView: NSView {
    weak var delegate: ChromeHeaderDelegate?

    private let stack = NSStackView()
    private let themeButton = ChromeIconButton()
    private let firstMateButton = ChromeIconButton()
    private let filesButton = ChromeIconButton()
    private let changesButton = ChromeIconButton()

    private var activePane: ChromeLeftPane?
    private var worktreeContextEnabled = true

    private static let idleTint = NSColor(hex: 0x888888)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    // MARK: - Public API

    func setActivePane(_ pane: ChromeLeftPane?) {
        activePane = pane
        applyActiveTint()
    }

    /// When false, Files/Changes are dimmed and disabled; First Mate stays enabled.
    func setWorktreeContextEnabled(_ enabled: Bool) {
        worktreeContextEnabled = enabled
        applyWorktreeContext()
    }

    // MARK: - Setup

    private func setup() {
        translatesAutoresizingMaskIntoConstraints = false

        stack.orientation = .horizontal
        stack.spacing = 2
        stack.alignment = .centerY
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        configure(themeButton, symbol: "circle.lefthalf.filled",
                  identifier: "chrome.icon.theme", label: "Theme",
                  action: #selector(themeClicked))
        configure(firstMateButton, symbol: "sailboat",
                  identifier: "chrome.icon.firstMate", label: "First Mate",
                  action: #selector(firstMateClicked))
        configure(filesButton, symbol: "folder",
                  identifier: "chrome.icon.files", label: "Files",
                  action: #selector(filesClicked))
        configure(changesButton, symbol: "plusminus",
                  identifier: "chrome.icon.changes", label: "Changes",
                  action: #selector(changesClicked))

        [themeButton, firstMateButton, filesButton, changesButton].forEach {
            stack.addArrangedSubview($0)
        }

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        applyActiveTint()
        applyWorktreeContext()
    }

    private func configure(_ button: ChromeIconButton, symbol: String,
                           identifier: String, label: String, action: Selector) {
        let config = NSImage.SymbolConfiguration(pointSize: 12, weight: .medium)
        if let image = NSImage(systemSymbolName: symbol, accessibilityDescription: label) {
            button.image = image.withSymbolConfiguration(config)
        }
        button.bezelStyle = .recessed
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.contentTintColor = Self.idleTint
        button.target = self
        button.action = action
        button.translatesAutoresizingMaskIntoConstraints = false
        button.setAccessibilityIdentifier(identifier)
        button.setAccessibilityLabel(label)
        button.wantsLayer = true
        button.layer?.cornerRadius = 7
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: 26),
            button.heightAnchor.constraint(equalToConstant: 26),
        ])
    }

    private func applyActiveTint() {
        firstMateButton.contentTintColor = activePane == .firstMate ? Theme.accent : Self.idleTint
        filesButton.contentTintColor = activePane == .files ? Theme.accent : Self.idleTint
        changesButton.contentTintColor = activePane == .changes ? Theme.accent : Self.idleTint
        // Theme is never a pane; keep idle tint.
        themeButton.contentTintColor = Self.idleTint
    }

    private func applyWorktreeContext() {
        for button in [filesButton, changesButton] {
            button.isEnabled = worktreeContextEnabled
            button.alphaValue = worktreeContextEnabled ? 1 : 0.3
        }
        firstMateButton.isEnabled = true
        firstMateButton.alphaValue = 1
        themeButton.isEnabled = true
        themeButton.alphaValue = 1
    }

    // MARK: - Actions

    @objc private func themeClicked() {
        delegate?.chromeDidToggleTheme()
    }

    @objc private func firstMateClicked() {
        delegate?.chromeDidSelectPane(.firstMate)
    }

    @objc private func filesClicked() {
        delegate?.chromeDidSelectPane(.files)
    }

    @objc private func changesClicked() {
        delegate?.chromeDidSelectPane(.changes)
    }
}
