import AppKit

/// Step 1: what Seahelm actually is.
///
/// The old wizard opened on "Choose your default agent", which asks a config
/// question before the user knows what they're configuring. This step teaches
/// the Ship ⊃ Project ⊃ Worktree ⊃ Sailor hierarchy the rest of the app's language
/// leans on, then names the three things Seahelm does for you.
final class OnboardingWelcomeStepView: NSView {
    private struct Tier {
        let symbol: String
        let term: String
        let gloss: String
    }

    private static let tiers = [
        Tier(symbol: "sailboat.fill", term: "Ship", gloss: "Seahelm"),
        Tier(symbol: "square.stack.3d.up.fill", term: "Project", gloss: "a repo"),
        Tier(symbol: "door.left.hand.closed", term: "Worktree", gloss: "a worktree"),
        Tier(symbol: "person.fill", term: "Sailor", gloss: "an agent"),
    ]

    private struct Promise {
        let symbol: String
        let title: String
        let body: String
    }

    private static let promises = [
        Promise(
            symbol: "rectangle.split.2x2.fill",
            title: "Run agents side by side",
            body: "Every worktree is its own git worktree and terminal, so parallel agents never trip over each other."
        ),
        Promise(
            symbol: "bell.badge.fill",
            title: "Know which one needs you",
            body: "Seahelm watches every sailor and tells you the moment one finishes, stalls, or asks a question."
        ),
        Promise(
            symbol: "arrow.clockwise.circle.fill",
            title: "Nothing dies when you quit",
            body: "Panes are backed by persistent zmx sessions — close the window, reopen, and the work is still running."
        ),
    ]

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func setup() {
        let chain = makeHierarchyCard()
        let promises = makePromiseStack()

        addSubview(chain)
        addSubview(promises)

        NSLayoutConstraint.activate([
            chain.topAnchor.constraint(equalTo: topAnchor),
            chain.leadingAnchor.constraint(equalTo: leadingAnchor),
            chain.trailingAnchor.constraint(equalTo: trailingAnchor),

            promises.topAnchor.constraint(equalTo: chain.bottomAnchor, constant: 26),
            promises.leadingAnchor.constraint(equalTo: leadingAnchor),
            promises.trailingAnchor.constraint(equalTo: trailingAnchor),
            promises.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor),
        ])
    }

    /// The nesting chain, read left to right: Ship › Project › Worktree › Sailor.
    private func makeHierarchyCard() -> NSView {
        let card = OnboardingPanel()
        card.showsSelectionGlow = false

        // Nodes hug their own labels ("Seahelm" is wider than "a repo"), so the
        // row is centered with fixed gaps rather than stretched edge to edge —
        // `.equalSpacing` across the full card width strands the first node.
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.distribution = .fill
        row.spacing = 22
        row.translatesAutoresizingMaskIntoConstraints = false

        for (index, tier) in Self.tiers.enumerated() {
            row.addArrangedSubview(makeTierNode(tier))
            if index < Self.tiers.count - 1 {
                let chevron = OnboardingStyle.monoLabel("›", size: 17, weight: .bold,
                                                        color: OnboardingStyle.textFaint)
                row.addArrangedSubview(chevron)
            }
        }

        let caption = OnboardingStyle.label(
            "Each one nests in the last. You steer the ship; the sailors do the work.",
            size: 12, color: OnboardingStyle.textFaint
        )

        card.addSubview(row)
        card.addSubview(caption)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: card.topAnchor, constant: 22),
            row.centerXAnchor.constraint(equalTo: card.centerXAnchor),
            row.leadingAnchor.constraint(greaterThanOrEqualTo: card.leadingAnchor, constant: 26),
            row.trailingAnchor.constraint(lessThanOrEqualTo: card.trailingAnchor, constant: -26),
            caption.topAnchor.constraint(equalTo: row.bottomAnchor, constant: 18),
            caption.centerXAnchor.constraint(equalTo: card.centerXAnchor),
            card.bottomAnchor.constraint(equalTo: caption.bottomAnchor, constant: 20),
        ])
        return card
    }

    private func makeTierNode(_ tier: Tier) -> NSView {
        let node = NSView()
        node.translatesAutoresizingMaskIntoConstraints = false

        let icon = OnboardingIconTile(symbol: tier.symbol, side: 38, pointSize: 16)
        let term = OnboardingStyle.label(tier.term, size: 13.5, weight: .semibold)
        let gloss = OnboardingStyle.monoLabel(tier.gloss, size: 11, color: OnboardingStyle.textFaint)

        for v in [icon, term, gloss] as [NSView] { node.addSubview(v) }
        // The bounds below only cap the node's width; without this pull it would
        // stretch to whatever the stack has spare.
        let hug = node.widthAnchor.constraint(equalToConstant: 0)
        hug.priority = .defaultLow
        hug.isActive = true
        NSLayoutConstraint.activate([
            icon.topAnchor.constraint(equalTo: node.topAnchor),
            icon.centerXAnchor.constraint(equalTo: node.centerXAnchor),
            term.topAnchor.constraint(equalTo: icon.bottomAnchor, constant: 8),
            term.centerXAnchor.constraint(equalTo: node.centerXAnchor),
            gloss.topAnchor.constraint(equalTo: term.bottomAnchor, constant: 1),
            gloss.centerXAnchor.constraint(equalTo: node.centerXAnchor),
            node.bottomAnchor.constraint(equalTo: gloss.bottomAnchor),
            node.leadingAnchor.constraint(lessThanOrEqualTo: term.leadingAnchor),
            node.leadingAnchor.constraint(lessThanOrEqualTo: gloss.leadingAnchor),
            node.trailingAnchor.constraint(greaterThanOrEqualTo: term.trailingAnchor),
            node.trailingAnchor.constraint(greaterThanOrEqualTo: gloss.trailingAnchor),
        ])
        return node
    }

    private func makePromiseStack() -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.spacing = 18
        stack.alignment = .leading
        stack.translatesAutoresizingMaskIntoConstraints = false

        for promise in Self.promises {
            let row = NSView()
            row.translatesAutoresizingMaskIntoConstraints = false

            let icon = OnboardingIconTile(symbol: promise.symbol, side: 30, pointSize: 13)
            let title = OnboardingStyle.label(promise.title, size: 13.5, weight: .semibold)
            let body = OnboardingStyle.wrappingLabel(promise.body, size: 12.5)

            for v in [icon, title, body] as [NSView] { row.addSubview(v) }
            NSLayoutConstraint.activate([
                icon.leadingAnchor.constraint(equalTo: row.leadingAnchor),
                icon.topAnchor.constraint(equalTo: row.topAnchor, constant: 1),
                title.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 14),
                title.topAnchor.constraint(equalTo: row.topAnchor),
                title.trailingAnchor.constraint(lessThanOrEqualTo: row.trailingAnchor),
                body.leadingAnchor.constraint(equalTo: title.leadingAnchor),
                body.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 3),
                body.trailingAnchor.constraint(equalTo: row.trailingAnchor),
                row.bottomAnchor.constraint(equalTo: body.bottomAnchor),
            ])
            stack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        return stack
    }
}
