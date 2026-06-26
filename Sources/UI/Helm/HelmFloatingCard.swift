import AppKit
import QuartzCore

/// Transient notification card that floats above the radar orb when a new order
/// or watch event arrives while the cockpit is closed. Mirrors the prototype's
/// floatOrder/floatWatch: a left-accent card with a countdown bar that auto-
/// dismisses; clicking it routes into the cockpit (orders) or acknowledges (watch).
final class HelmFloatingCard: NSView {

    // Bare-TUI palette (prototype THEME.A)
    private static let cardBg   = NSColor(srgbRed: 0x0e/255, green: 0x2d/255, blue: 0x37/255, alpha: 1)
    private static let border   = NSColor(srgbRed: 0x96/255, green: 0xd7/255, blue: 0xe1/255, alpha: 0.12)
    private static let ink      = NSColor(srgbRed: 0xcf/255, green: 0xe0/255, blue: 0xe0/255, alpha: 1)
    private static let inkFaint = NSColor(srgbRed: 0x55/255, green: 0x71/255, blue: 0x70/255, alpha: 1)

    var onClick: (() -> Void)?

    private let accentBar = NSView()
    private let barTrack = NSView()
    private let barFill = NSView()
    private var barWidth: NSLayoutConstraint!

    init(from: String, task: String, tag: String, tagColor: NSColor, body: String, hint: String) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.backgroundColor = Self.cardBg.cgColor
        layer?.borderWidth = 1
        layer?.borderColor = Self.border.cgColor

        // Left accent stripe.
        accentBar.wantsLayer = true
        accentBar.layer?.backgroundColor = tagColor.cgColor
        accentBar.translatesAutoresizingMaskIntoConstraints = false
        addSubview(accentBar)

        let fromLabel = NSTextField(labelWithString: from)
        fromLabel.font = AppFont.mono(size: 12, weight: .medium)
        fromLabel.textColor = Self.ink
        fromLabel.translatesAutoresizingMaskIntoConstraints = false

        let taskLabel = NSTextField(labelWithString: task)
        taskLabel.font = AppFont.mono(size: 11, weight: .regular)
        taskLabel.textColor = Self.inkFaint
        taskLabel.lineBreakMode = .byTruncatingTail
        taskLabel.translatesAutoresizingMaskIntoConstraints = false

        let tagLabel = NSTextField(labelWithString: tag)
        tagLabel.font = AppFont.mono(size: 10, weight: .bold)
        tagLabel.textColor = tagColor
        tagLabel.alignment = .right
        tagLabel.setContentHuggingPriority(.required, for: .horizontal)
        tagLabel.translatesAutoresizingMaskIntoConstraints = false

        let bodyLabel = NSTextField(wrappingLabelWithString: body)
        bodyLabel.font = AppFont.mono(size: 12, weight: .regular)
        bodyLabel.textColor = Self.ink
        bodyLabel.maximumNumberOfLines = 3
        bodyLabel.lineBreakMode = .byTruncatingTail
        bodyLabel.translatesAutoresizingMaskIntoConstraints = false

        let hintLabel = NSTextField(labelWithString: hint)
        hintLabel.font = AppFont.mono(size: 11, weight: .regular)
        hintLabel.textColor = Self.inkFaint
        hintLabel.translatesAutoresizingMaskIntoConstraints = false

        barTrack.wantsLayer = true
        barTrack.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.05).cgColor
        barTrack.translatesAutoresizingMaskIntoConstraints = false
        barFill.wantsLayer = true
        barFill.layer?.backgroundColor = tagColor.cgColor
        barFill.translatesAutoresizingMaskIntoConstraints = false
        barTrack.addSubview(barFill)

        addSubview(fromLabel); addSubview(taskLabel); addSubview(tagLabel)
        addSubview(bodyLabel); addSubview(hintLabel); addSubview(barTrack)

        barWidth = barFill.widthAnchor.constraint(equalTo: barTrack.widthAnchor)

        NSLayoutConstraint.activate([
            accentBar.leadingAnchor.constraint(equalTo: leadingAnchor),
            accentBar.topAnchor.constraint(equalTo: topAnchor),
            accentBar.bottomAnchor.constraint(equalTo: bottomAnchor),
            accentBar.widthAnchor.constraint(equalToConstant: 3),

            fromLabel.topAnchor.constraint(equalTo: topAnchor, constant: 11),
            fromLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            taskLabel.centerYAnchor.constraint(equalTo: fromLabel.centerYAnchor),
            taskLabel.leadingAnchor.constraint(equalTo: fromLabel.trailingAnchor, constant: 8),
            tagLabel.centerYAnchor.constraint(equalTo: fromLabel.centerYAnchor),
            tagLabel.leadingAnchor.constraint(greaterThanOrEqualTo: taskLabel.trailingAnchor, constant: 8),
            tagLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),

            bodyLabel.topAnchor.constraint(equalTo: fromLabel.bottomAnchor, constant: 7),
            bodyLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            bodyLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),

            hintLabel.topAnchor.constraint(equalTo: bodyLabel.bottomAnchor, constant: 8),
            hintLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            hintLabel.bottomAnchor.constraint(equalTo: barTrack.topAnchor, constant: -10),

            barTrack.leadingAnchor.constraint(equalTo: leadingAnchor),
            barTrack.trailingAnchor.constraint(equalTo: trailingAnchor),
            barTrack.bottomAnchor.constraint(equalTo: bottomAnchor),
            barTrack.heightAnchor.constraint(equalToConstant: 3),
            barFill.leadingAnchor.constraint(equalTo: barTrack.leadingAnchor),
            barFill.topAnchor.constraint(equalTo: barTrack.topAnchor),
            barFill.bottomAnchor.constraint(equalTo: barTrack.bottomAnchor),
            barWidth,
        ])

        let click = NSClickGestureRecognizer(target: self, action: #selector(clicked))
        addGestureRecognizer(click)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    /// Shrink the countdown bar from full to empty over `duration`.
    func startCountdown(duration: TimeInterval) {
        layoutSubtreeIfNeeded()
        barWidth.isActive = false
        barWidth = barFill.widthAnchor.constraint(equalToConstant: 0)
        barWidth.isActive = true
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = duration
            ctx.timingFunction = CAMediaTimingFunction(name: .linear)
            self.layoutSubtreeIfNeeded()
        }
    }

    @objc private func clicked() { onClick?() }
}
