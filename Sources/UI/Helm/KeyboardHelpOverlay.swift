import AppKit

/// `?` keyboard cheat-sheet — a two-column modal (NORMAL · HELM open) over the
/// dashboard. Bare-TUI styled. Click the scrim or press Esc to dismiss.
final class KeyboardHelpOverlay: NSView {

    // Bare-TUI palette (prototype THEME.A)
    private static let cardBg   = NSColor(srgbRed: 0x0e/255, green: 0x2d/255, blue: 0x37/255, alpha: 1)
    private static let border   = NSColor(srgbRed: 0x96/255, green: 0xd7/255, blue: 0xe1/255, alpha: 0.12)
    private static let scrim    = NSColor(srgbRed: 0x03/255, green: 0x10/255, blue: 0x15/255, alpha: 0.72)
    private static let radar    = NSColor(srgbRed: 0x1f/255, green: 0xc8/255, blue: 0xda/255, alpha: 1)
    private static let ink      = NSColor(srgbRed: 0xcf/255, green: 0xe0/255, blue: 0xe0/255, alpha: 1)
    private static let inkDim   = NSColor(srgbRed: 0x7f/255, green: 0xa0/255, blue: 0xa3/255, alpha: 1)
    private static let inkFaint = NSColor(srgbRed: 0x55/255, green: 0x71/255, blue: 0x70/255, alpha: 1)
    private static let keyBg    = NSColor(srgbRed: 0x78/255, green: 0xd2/255, blue: 0xe1/255, alpha: 0.045)

    private static let normalKeys: [(String, String)] = [
        ("⌘E", "总览 ⇄ worktree"),
        ("h j k l", "移动焦点"),
        ("1 – 9", "跳到 / 进入第 N 个 worktree"),
        ("⏎ / i", "进入终端"),
        ("f / c / m", "文件 / 改动 / First Mate 侧栏"),
        ("⌘1 / ⌘2 / ⌘3", "First Mate / 文件 / 改动"),
        ("⌃⇥ / ⌃⇧⇥", "下 / 上一个 worktree"),
        ("d", "删除聚焦 worktree"),
        ("n", "新建 worktree"),
        ("⌘esc", "INSERT → NORMAL"),
        ("?", "快捷键说明"),
    ]
    private static let helmKeys: [(String, String)] = [
        ("⌘D / ⌘⇧D", "水平 / 垂直分屏"),
        ("⌘⌥ ← → ↑ ↓", "移动分屏焦点"),
        ("⌘⌃ ← → ↑ ↓", "调整分屏比例"),
        ("/ @ #", "命令 / 仓库 / agent 补全"),
        ("↑ ↓ / ⏎", "补全菜单选择 / 确认"),
        ("esc", "命令框失焦 / 关闭"),
    ]

    var onDismiss: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    private func setup() {
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.backgroundColor = Self.scrim.cgColor
        let click = NSClickGestureRecognizer(target: self, action: #selector(scrimClicked))
        addGestureRecognizer(click)

        let card = NSView()
        card.wantsLayer = true
        card.layer?.backgroundColor = Self.cardBg.cgColor
        card.layer?.borderWidth = 1
        card.layer?.borderColor = Self.border.cgColor
        card.translatesAutoresizingMaskIntoConstraints = false
        addSubview(card)

        // Header
        let glyph = NSTextField(labelWithString: "⌨")
        glyph.font = AppFont.mono(size: 14, weight: .regular)
        glyph.textColor = Self.radar
        glyph.translatesAutoresizingMaskIntoConstraints = false
        let title = NSTextField(labelWithString: "KEYBOARD")
        title.font = AppFont.mono(size: 12, weight: .bold)
        title.textColor = Self.ink
        title.translatesAutoresizingMaskIntoConstraints = false
        let hint = NSTextField(labelWithString: "? 或 Esc 关闭")
        hint.font = AppFont.mono(size: 11, weight: .regular)
        hint.textColor = Self.inkFaint
        hint.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(glyph); card.addSubview(title); card.addSubview(hint)

        let left = column(header: "NORMAL", rows: Self.normalKeys)
        let right = column(header: "分屏 / 命令", rows: Self.helmKeys)
        card.addSubview(left); card.addSubview(right)

        NSLayoutConstraint.activate([
            card.centerXAnchor.constraint(equalTo: centerXAnchor),
            card.centerYAnchor.constraint(equalTo: centerYAnchor),
            card.widthAnchor.constraint(equalToConstant: 560),

            glyph.topAnchor.constraint(equalTo: card.topAnchor, constant: 14),
            glyph.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 18),
            title.centerYAnchor.constraint(equalTo: glyph.centerYAnchor),
            title.leadingAnchor.constraint(equalTo: glyph.trailingAnchor, constant: 9),
            hint.centerYAnchor.constraint(equalTo: glyph.centerYAnchor),
            hint.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -18),

            left.topAnchor.constraint(equalTo: glyph.bottomAnchor, constant: 14),
            left.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 18),
            left.widthAnchor.constraint(equalToConstant: 248),
            left.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -18),

            right.topAnchor.constraint(equalTo: left.topAnchor),
            right.leadingAnchor.constraint(equalTo: left.trailingAnchor, constant: 16),
            right.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -18),
        ])
    }

    private func column(header: String, rows: [(String, String)]) -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 9
        stack.translatesAutoresizingMaskIntoConstraints = false

        let head = NSTextField(labelWithString: header)
        head.font = AppFont.mono(size: 10.5, weight: .bold)
        head.textColor = Self.radar
        stack.addArrangedSubview(head)
        stack.setCustomSpacing(11, after: head)

        for (k, d) in rows {
            let row = NSStackView()
            row.orientation = .horizontal
            row.spacing = 10
            row.alignment = .centerY

            let key = NSTextField(labelWithString: k)
            key.font = AppFont.mono(size: 11, weight: .regular)
            key.textColor = Self.ink
            key.alignment = .center
            key.wantsLayer = true
            key.layer?.backgroundColor = Self.keyBg.cgColor
            key.layer?.cornerRadius = 4
            key.translatesAutoresizingMaskIntoConstraints = false
            key.widthAnchor.constraint(greaterThanOrEqualToConstant: 64).isActive = true
            // pad with edge insets via a container
            let keyWrap = NSView()
            keyWrap.translatesAutoresizingMaskIntoConstraints = false
            keyWrap.addSubview(key)
            NSLayoutConstraint.activate([
                key.topAnchor.constraint(equalTo: keyWrap.topAnchor, constant: 2),
                key.bottomAnchor.constraint(equalTo: keyWrap.bottomAnchor, constant: -2),
                key.leadingAnchor.constraint(equalTo: keyWrap.leadingAnchor, constant: 6),
                key.trailingAnchor.constraint(equalTo: keyWrap.trailingAnchor, constant: -6),
            ])

            let desc = NSTextField(labelWithString: d)
            desc.font = AppFont.mono(size: 11.5, weight: .regular)
            desc.textColor = Self.inkDim

            row.addArrangedSubview(keyWrap)
            row.addArrangedSubview(desc)
            stack.addArrangedSubview(row)
        }
        return stack
    }

    @objc private func scrimClicked() { onDismiss?() }
}
