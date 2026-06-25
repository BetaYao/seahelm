// Sources/UI/Dashboard/StackedMiniCardContainerView.swift
import AppKit

protocol MiniCardReorderDelegate: AnyObject {
    func miniCardReorderBegan(_ card: StackedMiniCardContainerView)
    func miniCardReorderEnded(_ card: StackedMiniCardContainerView)
}

final class StackedMiniCardContainerView: NSView {
    override var acceptsFirstResponder: Bool { false }

    let miniCardView = MiniCardView()
    private(set) var ghostViews: [NSView] = []

    /// The container owns click handling. miniCardView.delegate must remain nil.
    weak var delegate: AgentCardDelegate?
    /// Delegate for drag-to-reorder in sidebar. Set by DashboardViewController.
    weak var reorderDelegate: MiniCardReorderDelegate?

    var agentId: String { miniCardView.agentId }

    var isSelected: Bool {
        get { miniCardView.isSelected }
        set { miniCardView.isSelected = newValue }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    private func setup() {
        wantsLayer = true
        layer?.masksToBounds = false

        // Disable MiniCardView's own click handler to prevent double-firing.
        // Remove its gesture recognizers and use the container's instead.
        miniCardView.gestureRecognizers.forEach { miniCardView.removeGestureRecognizer($0) }
        miniCardView.translatesAutoresizingMaskIntoConstraints = true
        addSubview(miniCardView)

        let click = NSClickGestureRecognizer(target: self, action: #selector(handleClick))
        addGestureRecognizer(click)

        let press = NSPressGestureRecognizer(target: self, action: #selector(handleLongPress(_:)))
        press.minimumPressDuration = 0.3
        press.allowableMovement = 4
        addGestureRecognizer(press)
    }

    // MARK: - Drag-to-Reorder

    private var dragStartLocation: NSPoint = .zero
    /// Placeholder that holds space in the stack while the card floats freely.
    private var dragPlaceholder: NSView?
    /// The index we started dragging from.
    private var dragOriginIndex: Int = 0
    /// Current insertion target index (in the placeholder-augmented arranged subviews).
    private var dragCurrentIndex: Int = 0

    @objc private func handleLongPress(_ gesture: NSPressGestureRecognizer) {
        guard let stack = superview as? NSStackView else { return }
        let isVertical = stack.orientation == .vertical

        switch gesture.state {
        case .began:
            dragStartLocation = gesture.location(in: stack)

            // Remember origin index
            dragOriginIndex = stack.arrangedSubviews.firstIndex(of: self) ?? 0
            dragCurrentIndex = dragOriginIndex

            // Insert an invisible placeholder at our position to hold space
            let ph = NSView(frame: frame)
            ph.translatesAutoresizingMaskIntoConstraints = false
            if isVertical {
                ph.heightAnchor.constraint(equalToConstant: frame.height).isActive = true
            } else {
                ph.widthAnchor.constraint(equalToConstant: frame.width).isActive = true
            }
            dragPlaceholder = ph

            // Remove self from arranged (stop Auto Layout managing us) but keep as subview
            stack.removeArrangedSubview(self)
            stack.insertArrangedSubview(ph, at: dragOriginIndex)
            translatesAutoresizingMaskIntoConstraints = true
            // Re-add as plain subview on top so it renders above siblings
            stack.addSubview(self)

            // Visual lift
            layer?.zPosition = 100
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.15
                ctx.allowsImplicitAnimation = true
                self.alphaValue = 0.85
                self.layer?.shadowOpacity = 0.5
                self.layer?.shadowRadius = 12
                self.layer?.shadowOffset = CGSize(width: 0, height: -4)
                self.layer?.shadowColor = NSColor.black.cgColor
            }
            reorderDelegate?.miniCardReorderBegan(self)

        case .changed:
            guard let ph = dragPlaceholder else { return }
            let current = gesture.location(in: stack)
            let delta = isVertical ? (current.y - dragStartLocation.y) : (current.x - dragStartLocation.x)

            // Move the card freely (frame-based, no Auto Layout)
            var newOrigin = frame.origin
            if isVertical {
                newOrigin.y += delta
            } else {
                newOrigin.x += delta
            }
            frame.origin = newOrigin
            dragStartLocation = current

            // Determine target index from the card's center vs. arranged subviews.
            // FlippedStackView has y=0 at top, increasing downward. Horizontal stacks
            // go left-to-right. In both cases midY/midX increases with index.
            // Find the first sibling whose midpoint is PAST the card's center.
            let center = isVertical ? frame.midY : frame.midX
            let arranged = stack.arrangedSubviews // includes placeholder, not self
            var targetIndex = arranged.count
            for (i, sibling) in arranged.enumerated() {
                guard sibling !== self else { continue }
                let siblingMid = isVertical ? sibling.frame.midY : sibling.frame.midX
                if siblingMid > center {
                    targetIndex = i
                    break
                }
            }

            // Move placeholder to target if changed
            if targetIndex != dragCurrentIndex {
                dragCurrentIndex = targetIndex
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.2
                    ctx.allowsImplicitAnimation = true
                    stack.removeArrangedSubview(ph)
                    stack.insertArrangedSubview(ph, at: min(targetIndex, stack.arrangedSubviews.count))
                    stack.layoutSubtreeIfNeeded()
                }
            }

        case .ended, .cancelled:
            guard let ph = dragPlaceholder else { return }

            // Replace placeholder with self in the stack
            let finalIndex = stack.arrangedSubviews.firstIndex(of: ph) ?? dragCurrentIndex
            stack.removeArrangedSubview(ph)
            ph.removeFromSuperview()
            dragPlaceholder = nil

            // Re-insert self as arranged subview
            stack.insertArrangedSubview(self, at: min(finalIndex, stack.arrangedSubviews.count))
            translatesAutoresizingMaskIntoConstraints = false

            // Animate settle
            layer?.zPosition = 0
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.2
                ctx.allowsImplicitAnimation = true
                self.alphaValue = 1.0
                self.layer?.shadowOpacity = 0
                self.layer?.shadowRadius = 0
                stack.layoutSubtreeIfNeeded()
            }
            reorderDelegate?.miniCardReorderEnded(self)

        default:
            break
        }
    }

    // MARK: - Configure

    func configure(paneCount: Int) {
        let needed = min(max(paneCount - 1, 0), 2)

        while ghostViews.count > needed {
            ghostViews.removeLast().removeFromSuperview()
        }

        while ghostViews.count < needed {
            let ghost = MiniGhostCardView()
            ghost.ghostIndex = ghostViews.count
            ghost.wantsLayer = true
            addSubview(ghost, positioned: .below, relativeTo: miniCardView)
            ghostViews.append(ghost)
        }
    }

    // MARK: - Layout

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        super.resizeSubviews(withOldSize: oldSize)
        layoutChildren()
    }

    func layoutChildren() {
        let w = bounds.width
        let h = bounds.height
        let ghostOffset: CGFloat = 3
        let maxOffset = CGFloat(ghostViews.count) * ghostOffset
        let cardW = w - maxOffset
        let cardH = h - maxOffset

        miniCardView.frame = NSRect(x: 0, y: maxOffset, width: cardW, height: cardH)

        for (i, ghost) in ghostViews.enumerated() {
            let offset = CGFloat(i + 1) * ghostOffset
            ghost.frame = NSRect(x: offset, y: maxOffset - offset, width: cardW, height: cardH)
        }
    }

    // MARK: - Hit testing

    override func hitTest(_ point: NSPoint) -> NSView? {
        // point is in superview coordinates; convert to local before checking miniCardView.frame
        let localPoint = convert(point, from: superview)
        guard miniCardView.frame.contains(localPoint) else { return nil }
        return super.hitTest(point)
    }

    // MARK: - Click

    @objc private func handleClick() {
        delegate?.agentCardClicked(agentId: miniCardView.agentId)
    }

    // MARK: - Context menu

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        let deleteItem = NSMenuItem(title: "Delete Worktree", action: #selector(deleteWorktreeAction), keyEquivalent: "")
        deleteItem.target = self
        menu.addItem(deleteItem)
        menu.addItem(NSMenuItem.separator())
        let closeRepoItem = NSMenuItem(title: "Close Repo", action: #selector(closeRepoAction), keyEquivalent: "")
        closeRepoItem.target = self
        menu.addItem(closeRepoItem)
        return menu
    }

    @objc private func deleteWorktreeAction() {
        delegate?.agentCardDidRequestDelete(agentId: miniCardView.agentId)
    }

    @objc private func closeRepoAction() {
        delegate?.agentCardDidRequestCloseRepo(agentId: miniCardView.agentId)
    }

    // MARK: - Appearance

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        ghostViews.forEach { $0.needsDisplay = true }
    }
}

// MARK: - MiniGhostCardView

private final class MiniGhostCardView: NSView {
    var ghostIndex: Int = 0

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.cornerRadius = 4
        layer?.masksToBounds = true
        let bg = ghostIndex == 0 ? SemanticColors.tileGhost1Bg : SemanticColors.tileGhost2Bg
        layer?.backgroundColor = resolvedCGColor(bg)
        layer?.borderColor = resolvedCGColor(SemanticColors.tileGhostBorder)
        layer?.borderWidth = 1
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}
