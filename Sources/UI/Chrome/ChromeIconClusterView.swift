import AppKit

/// Shared Theme · First Mate · Files · Issues icon strip used by both chrome headers.
final class ChromeIconClusterView: NSView {
    weak var delegate: ChromeHeaderDelegate?

    private let stack = NSStackView()
    private let themeButton = ChromeIconButton()
    private let firstMateButton = ChromeIconButton()
    private let filesButton = ChromeIconButton()
    private let issuesButton = ChromeIconButton()

    private var activePane: ChromeLeftPane?
    private var worktreeContextEnabled = true
    private var issuesAvailable = false

    /// GitHub's issue glyph is a dot in a ring.
    static let issuesSymbol = "smallcircle.filled.circle"

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

    /// When false, Files/Issues are dimmed and disabled; First Mate stays enabled.
    func setWorktreeContextEnabled(_ enabled: Bool) {
        worktreeContextEnabled = enabled
        applyWorktreeContext()
    }

    /// Issues is offered only for a worktree whose GitHub issues could be read;
    /// anywhere else it is hidden rather than dimmed, since nothing would bring
    /// it back to life.
    func setIssuesAvailable(_ available: Bool) {
        issuesAvailable = available
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
        configure(issuesButton, symbol: Self.issuesSymbol,
                  identifier: "chrome.icon.issues", label: "Issues",
                  action: #selector(issuesClicked))

        [themeButton, firstMateButton, filesButton, issuesButton].forEach {
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
        issuesButton.contentTintColor = activePane == .issues ? Theme.accent : Self.idleTint
        // Theme is never a pane; keep idle tint.
        themeButton.contentTintColor = Self.idleTint
    }

    private func applyWorktreeContext() {
        for button in [filesButton, issuesButton] {
            button.isEnabled = worktreeContextEnabled
            button.alphaValue = worktreeContextEnabled ? 1 : 0.3
        }
        issuesButton.isHidden = !issuesAvailable
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

    @objc private func issuesClicked() {
        delegate?.chromeDidSelectPane(.issues)
    }
}
