import AppKit

/// An issue opened from the Issues panel, in the center overlay: who/what/when
/// above, the body rendered as Markdown below. Comments and editing stay on
/// GitHub, one click away.
final class IssueDetailView: NSView {
    private let issue: GitHubIssue
    private let preview = PreviewWebView()
    /// Start a new worktree on this issue; the button is shown only when set.
    var onStart: (() -> Void)? {
        didSet { startButton.isHidden = onStart == nil }
    }
    private lazy var startButton = NSButton(title: "▶ Start in new worktree", target: self,
                                            action: #selector(start))

    init(issue: GitHubIssue) {
        self.issue = issue
        super.init(frame: .zero)
        setup()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    /// The page body: the title as a heading, then the issue's own text.
    static func markdown(for issue: GitHubIssue) -> String {
        let body = issue.body?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return "# \(issue.title)\n\n" + (body.isEmpty ? "_No description._" : body)
    }

    private func setup() {
        let meta = NSTextField(labelWithString: "#\(issue.number) · opened by @\(issue.user.login) · "
            + IssueListSections.meta(for: issue))
        meta.font = AppFont.mono(size: 11)
        meta.textColor = SemanticColors.muted
        meta.lineBreakMode = .byTruncatingTail
        meta.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        meta.translatesAutoresizingMaskIntoConstraints = false

        let open = NSButton(title: "Open on GitHub", target: self, action: #selector(openOnGitHub))
        open.bezelStyle = .recessed
        open.font = AppFont.mono(size: 11)
        open.setAccessibilityIdentifier("issueDetail.openOnGitHub")
        open.translatesAutoresizingMaskIntoConstraints = false

        startButton.bezelStyle = .recessed
        startButton.font = AppFont.mono(size: 11)
        startButton.isHidden = onStart == nil
        startButton.setAccessibilityIdentifier("issueDetail.start")
        startButton.translatesAutoresizingMaskIntoConstraints = false

        preview.translatesAutoresizingMaskIntoConstraints = false

        addSubview(meta)
        addSubview(startButton)
        addSubview(open)
        addSubview(preview)
        NSLayoutConstraint.activate([
            meta.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            meta.centerYAnchor.constraint(equalTo: open.centerYAnchor),
            meta.trailingAnchor.constraint(lessThanOrEqualTo: startButton.leadingAnchor, constant: -12),
            startButton.centerYAnchor.constraint(equalTo: open.centerYAnchor),
            startButton.trailingAnchor.constraint(equalTo: open.leadingAnchor, constant: -8),

            open.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            open.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),

            preview.topAnchor.constraint(equalTo: open.bottomAnchor, constant: 8),
            preview.leadingAnchor.constraint(equalTo: leadingAnchor),
            preview.trailingAnchor.constraint(equalTo: trailingAnchor),
            preview.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Rendered once on screen, so the page picks up the real appearance.
        guard window != nil else { return }
        preview.render(markdown: Self.markdown(for: issue), baseDirectory: nil)
    }

    @objc private func start() {
        startButton.isEnabled = false
        onStart?()
    }

    @objc private func openOnGitHub() {
        guard let url = URL(string: issue.htmlURL) else { return }
        NSWorkspace.shared.open(url)
    }
}
