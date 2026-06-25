# Keyboard Navigation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let users operate amux's three high-frequency workflows (layout switch + card focus, new worktree, delete worktree) entirely from the keyboard, via a three-state focus model (T=Terminal / D=Dashboard Nav / M=Modal).

**Architecture:** Introduce a `DashboardFocusController` that owns the D-state Tab ring (focused index, snapshot/restore). Wire window-level shortcuts in `AmuxWindow.performKeyEquivalent` (`Cmd+1..4`, `Cmd+E`). Grid layout auto-enters D; focus layouts enter D on `Cmd+E`. Return/Esc exit D and restore terminal first responder. Delete (`Cmd+Backspace`) in D routes to the existing `TerminalCoordinator.confirmAndDeleteWorktree`. The new-branch dialog gets a small key-view-loop fix.

**Tech Stack:** Swift 5.10, AppKit, Ghostty C API, existing `DashboardViewController` / `TerminalCoordinator` / `AmuxWindow` infrastructure.

**Spec:** `docs/superpowers/specs/2026-04-11-keyboard-navigation-design.md`

---

## File Map

| File | Change |
|---|---|
| `Sources/UI/Dashboard/DashboardFocusController.swift` | **Create** — pure Swift class encapsulating D-state: focused target, Tab ring, snapshot |
| `Sources/UI/Dashboard/DashboardViewController.swift` | **Modify** — track `lastFocusLayout`, override `acceptsFirstResponder`/`keyDown`, drive D-state lifecycle, implement visual updates |
| `Sources/UI/Dashboard/MiniCardView.swift` | **Modify** — add `isKeyboardFocused: Bool` with cyan border/glow |
| `Sources/UI/Dashboard/StackedCardContainerView.swift` | **Modify** — add `isKeyboardFocused: Bool` with cyan border/glow (distinct from existing `isSelected`) |
| `Sources/UI/Dashboard/FocusPanelView.swift` | **Modify** — add `isKeyboardFocused: Bool` with cyan border/glow on the big panel |
| `Sources/App/MainWindowController.swift` | **Modify** — in `AmuxWindow.performKeyEquivalent`, add `Cmd+1..4` layout switch and `Cmd+E` toggle |
| `Sources/UI/Dialog/NewBranchDialog.swift` | **Modify** — set `initialFirstResponder`, add `createButton.keyEquivalent = "\r"`, call `recalculateKeyViewLoop()` |
| `Tests/DashboardFocusControllerTests.swift` | **Create** — unit tests for Tab ring + snapshot |

---

## Task 1: Track "last-used focus layout" in DashboardViewController

**Goal:** When Grid drill-in via `Return` needs to know which focus layout to use, this value provides it. Default is `.leftRight`.

**Files:**
- Modify: `Sources/UI/Dashboard/DashboardViewController.swift`

- [ ] **Step 1: Add the stored property next to `currentLayout`**

Find the line (around line 93):

```swift
var currentLayout: DashboardLayout = .leftRight
```

Add immediately below:

```swift
/// The most recently used non-grid focus layout. Grid's Return drill-in uses this as the target.
/// Seeded to .leftRight so first-launch behavior is predictable.
private(set) var lastFocusLayout: DashboardLayout = .leftRight
```

- [ ] **Step 2: Update `setLayout(_:)` to record focus layouts**

Find the method (around line 283):

```swift
func setLayout(_ layout: DashboardLayout) {
    guard layout != currentLayout else { return }
    detachTerminals()
    resetSidebarConstraints()
    isSidebarCollapsed = false
    currentLayout = layout
    showLayout(layout)
    rebuildCurrentLayout()
}
```

Replace with:

```swift
func setLayout(_ layout: DashboardLayout) {
    guard layout != currentLayout else { return }
    detachTerminals()
    resetSidebarConstraints()
    isSidebarCollapsed = false
    // Remember the focus layout we are LEAVING, so grid Return can restore it.
    if currentLayout != .grid {
        lastFocusLayout = currentLayout
    }
    currentLayout = layout
    showLayout(layout)
    rebuildCurrentLayout()
}
```

- [ ] **Step 3: Build to confirm no compile errors**

Run: `xcodebuild -project amux.xcodeproj -scheme amux -configuration Debug build`
Expected: BUILD SUCCEEDED

- [ ] **Step 4: Commit**

```bash
git add Sources/UI/Dashboard/DashboardViewController.swift
git commit -m "feat(dashboard): track lastFocusLayout for grid Return drill-in"
```

---

## Task 2: Create `DashboardFocusController` (pure class, testable)

**Goal:** Encapsulate D-state logic in a pure Swift class that can be unit-tested without AppKit. It owns: the Tab ring, the focused index, next/prev navigation, and the snapshot struct.

**Files:**
- Create: `Sources/UI/Dashboard/DashboardFocusController.swift`
- Create: `Tests/DashboardFocusControllerTests.swift`

- [ ] **Step 1: Write the failing tests first**

Create `Tests/DashboardFocusControllerTests.swift`:

```swift
import XCTest
@testable import amux

final class DashboardFocusControllerTests: XCTestCase {

    // MARK: - Grid ring

    func testGridRingNextWrapsAround() {
        let ctrl = DashboardFocusController()
        ctrl.enterGrid(cardIds: ["a", "b", "c"], initialId: "a")
        XCTAssertEqual(ctrl.focusedTarget, .card("a"))
        ctrl.next()
        XCTAssertEqual(ctrl.focusedTarget, .card("b"))
        ctrl.next()
        XCTAssertEqual(ctrl.focusedTarget, .card("c"))
        ctrl.next()
        XCTAssertEqual(ctrl.focusedTarget, .card("a"))
    }

    func testGridRingPrevWrapsAround() {
        let ctrl = DashboardFocusController()
        ctrl.enterGrid(cardIds: ["a", "b", "c"], initialId: "a")
        ctrl.prev()
        XCTAssertEqual(ctrl.focusedTarget, .card("c"))
        ctrl.prev()
        XCTAssertEqual(ctrl.focusedTarget, .card("b"))
    }

    func testGridInitialFallsBackToFirstWhenInitialNotFound() {
        let ctrl = DashboardFocusController()
        ctrl.enterGrid(cardIds: ["a", "b", "c"], initialId: "zzz")
        XCTAssertEqual(ctrl.focusedTarget, .card("a"))
    }

    func testGridInitialHandlesEmptyRing() {
        let ctrl = DashboardFocusController()
        ctrl.enterGrid(cardIds: [], initialId: nil)
        XCTAssertEqual(ctrl.focusedTarget, .none)
    }

    // MARK: - Focus-layout ring

    func testFocusLayoutRingStartsAtBigPanel() {
        let ctrl = DashboardFocusController()
        ctrl.enterFocusLayout(cardIds: ["a", "b"])
        XCTAssertEqual(ctrl.focusedTarget, .bigPanel)
    }

    func testFocusLayoutRingCyclesPanelThenCards() {
        let ctrl = DashboardFocusController()
        ctrl.enterFocusLayout(cardIds: ["a", "b"])
        ctrl.next() // first card
        XCTAssertEqual(ctrl.focusedTarget, .card("a"))
        ctrl.next()
        XCTAssertEqual(ctrl.focusedTarget, .card("b"))
        ctrl.next() // back to big panel
        XCTAssertEqual(ctrl.focusedTarget, .bigPanel)
    }

    func testFocusLayoutPrevFromBigPanelGoesToLastCard() {
        let ctrl = DashboardFocusController()
        ctrl.enterFocusLayout(cardIds: ["a", "b"])
        ctrl.prev()
        XCTAssertEqual(ctrl.focusedTarget, .card("b"))
    }

    // MARK: - Delete shifts focus

    func testDeleteShiftsFocusToNextCardInGrid() {
        let ctrl = DashboardFocusController()
        ctrl.enterGrid(cardIds: ["a", "b", "c"], initialId: "b")
        ctrl.removeCurrentCard()
        // After removing "b", ring is ["a", "c"] and focus advances to "c"
        XCTAssertEqual(ctrl.focusedTarget, .card("c"))
    }

    func testDeleteLastCardWrapsToFirstInGrid() {
        let ctrl = DashboardFocusController()
        ctrl.enterGrid(cardIds: ["a", "b", "c"], initialId: "c")
        ctrl.removeCurrentCard()
        XCTAssertEqual(ctrl.focusedTarget, .card("a"))
    }

    func testDeleteOnlyCardBecomesNone() {
        let ctrl = DashboardFocusController()
        ctrl.enterGrid(cardIds: ["a"], initialId: "a")
        ctrl.removeCurrentCard()
        XCTAssertEqual(ctrl.focusedTarget, .none)
    }

    func testDeleteInFocusLayoutFallsBackToBigPanelIfNoCardsLeft() {
        let ctrl = DashboardFocusController()
        ctrl.enterFocusLayout(cardIds: ["a"])
        ctrl.next() // focus card "a"
        ctrl.removeCurrentCard()
        XCTAssertEqual(ctrl.focusedTarget, .bigPanel)
    }
}
```

- [ ] **Step 2: Run tests — expect compile failure**

Run: `xcodebuild -project amux.xcodeproj -scheme amuxTests -configuration Debug test -only-testing:amuxTests/DashboardFocusControllerTests`
Expected: FAIL with "cannot find 'DashboardFocusController' in scope"

- [ ] **Step 3: Create the implementation**

Create `Sources/UI/Dashboard/DashboardFocusController.swift`:

```swift
import AppKit

/// Encapsulates the "Dashboard Navigation" (D-state) focus ring.
///
/// Pure value logic — no AppKit view references. Consumed by `DashboardViewController`
/// which translates `focusedTarget` into first-responder and visual updates.
final class DashboardFocusController {

    enum Target: Equatable {
        case none
        case bigPanel          // only meaningful in focus layouts
        case card(String)      // worktree path (agent id)
    }

    enum Mode {
        case idle              // not in D state
        case grid              // grid layout: ring = cards only
        case focusLayout       // leftRight/topSmall/topLarge: ring = [bigPanel, cards...]
    }

    private(set) var mode: Mode = .idle
    private(set) var focusedTarget: Target = .none
    private(set) var cardIds: [String] = []

    /// Snapshot of state before entering D, used by Esc to restore.
    struct Snapshot {
        let firstResponder: NSResponder?
        let focusedWorktreePath: String?
        let layout: DashboardLayout
    }
    private(set) var snapshot: Snapshot?

    // MARK: - Entry

    func enterGrid(cardIds: [String], initialId: String?) {
        mode = .grid
        self.cardIds = cardIds
        if let initial = initialId, cardIds.contains(initial) {
            focusedTarget = .card(initial)
        } else if let first = cardIds.first {
            focusedTarget = .card(first)
        } else {
            focusedTarget = .none
        }
    }

    func enterFocusLayout(cardIds: [String]) {
        mode = .focusLayout
        self.cardIds = cardIds
        focusedTarget = .bigPanel
    }

    func exit() {
        mode = .idle
        focusedTarget = .none
        cardIds = []
        snapshot = nil
    }

    func captureSnapshot(_ snapshot: Snapshot) {
        self.snapshot = snapshot
    }

    // MARK: - Navigation

    func next() {
        switch mode {
        case .idle:
            return
        case .grid:
            guard !cardIds.isEmpty else { focusedTarget = .none; return }
            if case .card(let id) = focusedTarget, let idx = cardIds.firstIndex(of: id) {
                focusedTarget = .card(cardIds[(idx + 1) % cardIds.count])
            } else {
                focusedTarget = .card(cardIds[0])
            }
        case .focusLayout:
            // ring: [bigPanel, card0, card1, ...]
            switch focusedTarget {
            case .bigPanel:
                focusedTarget = cardIds.first.map { .card($0) } ?? .bigPanel
            case .card(let id):
                if let idx = cardIds.firstIndex(of: id) {
                    if idx + 1 < cardIds.count {
                        focusedTarget = .card(cardIds[idx + 1])
                    } else {
                        focusedTarget = .bigPanel
                    }
                } else {
                    focusedTarget = .bigPanel
                }
            case .none:
                focusedTarget = .bigPanel
            }
        }
    }

    func prev() {
        switch mode {
        case .idle:
            return
        case .grid:
            guard !cardIds.isEmpty else { focusedTarget = .none; return }
            if case .card(let id) = focusedTarget, let idx = cardIds.firstIndex(of: id) {
                let prevIdx = (idx - 1 + cardIds.count) % cardIds.count
                focusedTarget = .card(cardIds[prevIdx])
            } else {
                focusedTarget = .card(cardIds[cardIds.count - 1])
            }
        case .focusLayout:
            switch focusedTarget {
            case .bigPanel:
                focusedTarget = cardIds.last.map { .card($0) } ?? .bigPanel
            case .card(let id):
                if let idx = cardIds.firstIndex(of: id) {
                    if idx == 0 {
                        focusedTarget = .bigPanel
                    } else {
                        focusedTarget = .card(cardIds[idx - 1])
                    }
                } else {
                    focusedTarget = .bigPanel
                }
            case .none:
                focusedTarget = .bigPanel
            }
        }
    }

    // MARK: - Mutation

    /// Remove the currently focused card from the ring and advance focus.
    /// No-op if the focused target is not a card.
    func removeCurrentCard() {
        guard case .card(let id) = focusedTarget,
              let idx = cardIds.firstIndex(of: id) else { return }
        cardIds.remove(at: idx)
        if cardIds.isEmpty {
            focusedTarget = (mode == .focusLayout) ? .bigPanel : .none
            return
        }
        let nextIdx = idx % cardIds.count
        focusedTarget = .card(cardIds[nextIdx])
    }

    /// Replace the card list while preserving focus if possible.
    /// Called when the underlying agent list changes while D is active.
    func refreshCards(_ ids: [String]) {
        cardIds = ids
        if case .card(let id) = focusedTarget, !ids.contains(id) {
            focusedTarget = (mode == .focusLayout) ? .bigPanel : (ids.first.map { .card($0) } ?? .none)
        }
    }
}
```

- [ ] **Step 4: Add the new file to the Xcode project**

The project uses XcodeGen. Run:

```bash
xcodegen generate
```

Expected: project regenerated, new file picked up automatically from `Sources/` and `Tests/` glob patterns.

- [ ] **Step 5: Run tests — expect PASS**

Run: `xcodebuild -project amux.xcodeproj -scheme amuxTests -configuration Debug test -only-testing:amuxTests/DashboardFocusControllerTests`
Expected: 11 tests PASS.

- [ ] **Step 6: Commit**

```bash
git add Sources/UI/Dashboard/DashboardFocusController.swift Tests/DashboardFocusControllerTests.swift amux.xcodeproj/project.pbxproj
git commit -m "feat(dashboard): add DashboardFocusController for D-state navigation"
```

---

## Task 3: Add `isKeyboardFocused` visual state to card and panel views

**Goal:** Give `MiniCardView`, `StackedCardContainerView`, and `FocusPanelView` a distinct keyboard-focus visual (2px cyan border + glow), orthogonal to any existing `isSelected` mouse state.

**Files:**
- Modify: `Sources/UI/Dashboard/MiniCardView.swift`
- Modify: `Sources/UI/Dashboard/StackedCardContainerView.swift`
- Modify: `Sources/UI/Dashboard/FocusPanelView.swift`

- [ ] **Step 1: Add `isKeyboardFocused` to `MiniCardView`**

Open `Sources/UI/Dashboard/MiniCardView.swift`. Near the existing `isSelected` property (line 12), add:

```swift
var isKeyboardFocused: Bool = false { didSet { updateAppearance() } }
```

Then find `updateAppearance()` (referenced near line 295). Inside it, after the existing `isSelected` handling, add a keyboard-focus overlay — take the cyan accent from `SemanticColors`:

```swift
// Keyboard-focus ring overrides the normal selection ring.
if isKeyboardFocused {
    layer?.borderColor = SemanticColors.brandCyan.cgColor
    layer?.borderWidth = 2
    layer?.shadowColor = SemanticColors.brandCyan.cgColor
    layer?.shadowOpacity = 0.6
    layer?.shadowRadius = 8
    layer?.shadowOffset = .zero
    layer?.masksToBounds = false
}
```

If `SemanticColors.brandCyan` does not exist in the codebase, use the existing brand accent color (grep for `cyan`, `brand`, or `accent` in `SemanticColors.swift`). The key is: distinct from `isSelected`'s color.

- [ ] **Step 2: Same treatment for `StackedCardContainerView`**

Open `Sources/UI/Dashboard/StackedCardContainerView.swift`. Add:

```swift
var isKeyboardFocused: Bool = false { didSet { updateKeyboardFocusAppearance() } }

private func updateKeyboardFocusAppearance() {
    wantsLayer = true
    if isKeyboardFocused {
        layer?.borderColor = SemanticColors.brandCyan.cgColor
        layer?.borderWidth = 2
        layer?.shadowColor = SemanticColors.brandCyan.cgColor
        layer?.shadowOpacity = 0.6
        layer?.shadowRadius = 8
        layer?.shadowOffset = .zero
        layer?.masksToBounds = false
    } else {
        layer?.borderColor = nil
        layer?.borderWidth = 0
        layer?.shadowOpacity = 0
    }
}
```

- [ ] **Step 3: Same treatment for `FocusPanelView`**

Open `Sources/UI/Dashboard/FocusPanelView.swift`. Add the same `isKeyboardFocused` property and `updateKeyboardFocusAppearance()` method. The big panel is larger, so consider a slightly thicker border (3px) for visibility.

- [ ] **Step 4: Build**

Run: `xcodebuild -project amux.xcodeproj -scheme amux -configuration Debug build`
Expected: BUILD SUCCEEDED

- [ ] **Step 5: Commit**

```bash
git add Sources/UI/Dashboard/MiniCardView.swift Sources/UI/Dashboard/StackedCardContainerView.swift Sources/UI/Dashboard/FocusPanelView.swift
git commit -m "feat(dashboard): add isKeyboardFocused visual state"
```

---

## Task 4: Wire `DashboardViewController` to own the focus controller and handle D-state keys

**Goal:** `DashboardViewController` owns a `DashboardFocusController`, becomes first responder in D state, handles Tab/Shift+Tab/Return/Esc/Cmd+Backspace, and drives visual updates + terminal-promotion side effects.

**Files:**
- Modify: `Sources/UI/Dashboard/DashboardViewController.swift`

- [ ] **Step 1: Add the controller property and `acceptsFirstResponder` override**

Near the other properties (around line 93 where `currentLayout` lives), add:

```swift
let focusController = DashboardFocusController()
private var isInDState: Bool { focusController.mode != .idle }
```

Add the override (find an appropriate spot, e.g. just after `override func viewDidLoad()`):

```swift
override var acceptsFirstResponder: Bool {
    // Accept first responder only while D-state is active. When idle,
    // let the terminal keep first responder so Tab/keys flow to the PTY.
    isInDState
}
```

- [ ] **Step 2: Add D-state entry/exit helpers**

Add a new extension or section at the bottom of the file:

```swift
// MARK: - D-State (Dashboard Navigation) Lifecycle

extension DashboardViewController {

    /// Called by MainWindowController/AmuxWindow when user presses Cmd+E in a focus layout,
    /// or automatically when setLayout(.grid) is invoked.
    func enterDashboardNavigation() {
        guard !isInDState else { return }

        // Snapshot current state for Esc restore.
        let snapshot = DashboardFocusController.Snapshot(
            firstResponder: view.window?.firstResponder,
            focusedWorktreePath: agents.first(where: { $0.id == selectedAgentId })?.worktreePath,
            layout: currentLayout
        )
        focusController.captureSnapshot(snapshot)

        let cardIds = agents.map { $0.id }
        if currentLayout == .grid {
            let initial = snapshot.focusedWorktreePath
                .flatMap { path in agents.first(where: { $0.worktreePath == path })?.id }
                ?? selectedAgentId
            focusController.enterGrid(cardIds: cardIds, initialId: initial)
        } else {
            focusController.enterFocusLayout(cardIds: cardIds)
        }

        view.window?.makeFirstResponder(self)
        applyKeyboardFocusVisuals()
        applyDimOverlayIfNeeded()
    }

    /// Exits D-state and returns first responder to an appropriate terminal surface.
    /// - Parameter restoreSnapshot: if true, restores the pre-D first responder (Esc behavior).
    ///                              If false, uses the newly focused worktree (Return behavior).
    func exitDashboardNavigation(restoreSnapshot: Bool) {
        guard isInDState else { return }

        let snapshot = focusController.snapshot
        focusController.exit()

        clearKeyboardFocusVisuals()
        clearDimOverlay()

        if restoreSnapshot, let snap = snapshot, let responder = snap.firstResponder {
            view.window?.makeFirstResponder(responder)
        } else {
            // Hand first responder to the currently active split leaf of the selected agent.
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if let termView = self.activeSplitContainer?.focusedLeafView {
                    self.view.window?.makeFirstResponder(termView)
                }
            }
        }
    }
}
```

Note: `focusedLeafView` may not exist by that exact name — grep for how existing code fetches the active leaf terminal view from `SplitContainerView` and use the same API. If there is no convenient accessor, add a small helper on `SplitContainerView` that returns `tree?.focusedLeafView` or equivalent.

- [ ] **Step 3: Implement `applyKeyboardFocusVisuals()`, `clearKeyboardFocusVisuals()`, `applyDimOverlayIfNeeded()`, `clearDimOverlay()`**

Add to the same extension:

```swift
private func applyKeyboardFocusVisuals() {
    // Clear all first
    clearKeyboardFocusVisuals()

    switch focusController.focusedTarget {
    case .none:
        return
    case .bigPanel:
        if let refs = focusLayoutRefs(for: currentLayout) {
            refs.focusPanel.isKeyboardFocused = true
        }
    case .card(let agentId):
        if currentLayout == .grid {
            gridCards.first(where: { $0.agentId == agentId })?.isKeyboardFocused = true
        } else if let refs = focusLayoutRefs(for: currentLayout) {
            // mini cards in the sidebar — find by agent id
            refs.miniCards
                .flatMap { $0.cards }
                .first(where: { $0.agentId == agentId })?
                .isKeyboardFocused = true
        }
    }
}

private func clearKeyboardFocusVisuals() {
    for card in gridCards { card.isKeyboardFocused = false }
    if let refs = focusLayoutRefs(for: currentLayout) {
        refs.focusPanel.isKeyboardFocused = false
        refs.miniCards.flatMap { $0.cards }.forEach { $0.isKeyboardFocused = false }
    }
}

private func applyDimOverlayIfNeeded() {
    // Grid: no global dim (grid is inherently browsing).
    guard currentLayout != .grid else { return }
    guard let refs = focusLayoutRefs(for: currentLayout) else { return }
    // Show a 5% white dim overlay on the big panel and all mini cards.
    refs.focusPanel.showDimOverlay(opacity: 0.05)
    refs.miniCards.flatMap { $0.cards }.forEach { $0.showDimOverlay(opacity: 0.05) }
}

private func clearDimOverlay() {
    if let refs = focusLayoutRefs(for: currentLayout) {
        refs.focusPanel.hideDimOverlay()
        refs.miniCards.flatMap { $0.cards }.forEach { $0.hideDimOverlay() }
    }
}
```

**Note on `showDimOverlay` / `hideDimOverlay`:** these helpers likely don't exist yet. Add minimal versions to `MiniCardView`, `StackedCardContainerView`, and `FocusPanelView` — a single `CALayer` added as a sublayer with `backgroundColor = NSColor.white.withAlphaComponent(opacity).cgColor`, removed on hide. Match the existing card rounded-corner mask if there is one.

**Note on `refs.miniCards[...].cards`:** grep for the exact structure of `StackedMiniCardContainerView` to see how to enumerate the cards inside. If `cards` is not the property name, use whatever the existing code uses (e.g. `miniCardViews`).

- [ ] **Step 4: Implement `keyDown` handler**

Add the following override inside the main `DashboardViewController` class body:

```swift
override func keyDown(with event: NSEvent) {
    guard isInDState else {
        super.keyDown(with: event)
        return
    }

    let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

    switch event.keyCode {
    case 48: // Tab
        if flags.contains(.shift) {
            focusController.prev()
        } else {
            focusController.next()
        }
        applyKeyboardFocusVisuals()
        scrollFocusedIntoView()
        return
    case 36: // Return
        handleReturnInDState()
        return
    case 53: // Escape
        exitDashboardNavigation(restoreSnapshot: true)
        return
    case 51, 117: // Backspace (51) or Forward Delete (117)
        if flags.contains(.command) || event.keyCode == 117 {
            handleDeleteInDState()
            return
        }
    default:
        break
    }

    super.keyDown(with: event)
}
```

- [ ] **Step 5: Implement `handleReturnInDState()` and `handleDeleteInDState()` and `scrollFocusedIntoView()`**

Add to the same extension:

```swift
private func handleReturnInDState() {
    switch focusController.focusedTarget {
    case .none:
        exitDashboardNavigation(restoreSnapshot: true)
    case .bigPanel:
        // In focus layouts only — exit D, keep current main, first responder to big panel.
        exitDashboardNavigation(restoreSnapshot: false)
    case .card(let agentId):
        guard let agent = agents.first(where: { $0.id == agentId }) else {
            exitDashboardNavigation(restoreSnapshot: true)
            return
        }
        if currentLayout == .grid {
            // Drill in: switch to last-used focus layout, promote card, exit D.
            setLayout(lastFocusLayout)
            selectAgent(byWorktreePath: agent.worktreePath)
            exitDashboardNavigation(restoreSnapshot: false)
        } else {
            // Focus layout: promote card to main, stay in this layout, exit D.
            selectAgent(byWorktreePath: agent.worktreePath)
            exitDashboardNavigation(restoreSnapshot: false)
        }
    }
}

private func handleDeleteInDState() {
    guard case .card(let agentId) = focusController.focusedTarget,
          let agent = agents.first(where: { $0.id == agentId }),
          let info = agent.worktreeInfo else { return }

    // Route through the existing confirmation + deletion flow on TerminalCoordinator.
    // (terminalCoordinator reference: obtain via window controller or existing delegate.)
    guard let mwc = view.window?.windowController as? MainWindowController else { return }
    mwc.terminalCoordinator.confirmAndDeleteWorktree(info, window: view.window)

    // Optimistically advance focus; the delegate callback will refresh the ring when
    // the agent list updates.
    focusController.removeCurrentCard()
    applyKeyboardFocusVisuals()
}

private func scrollFocusedIntoView() {
    guard case .card(let agentId) = focusController.focusedTarget else { return }
    if currentLayout == .grid {
        if let card = gridCards.first(where: { $0.agentId == agentId }) {
            card.scrollToVisible(card.bounds)
        }
    } else if let refs = focusLayoutRefs(for: currentLayout) {
        if let card = refs.miniCards.flatMap({ $0.cards }).first(where: { $0.agentId == agentId }) {
            card.scrollToVisible(card.bounds)
        }
    }
}
```

**Note on `agent.worktreeInfo`:** check `AgentDisplayInfo` or equivalent for how to get a `WorktreeInfo` from an agent. If it's not a direct property, build it from the agent's fields — the delete coordinator needs `.path`, `.branch`, `.isMainWorktree`.

- [ ] **Step 6: Hook agent-list updates to refresh the ring**

Find where `agents` is reassigned in `DashboardViewController` (grep for `self.agents =`). After each reassignment, if `isInDState`, call:

```swift
if isInDState {
    focusController.refreshCards(agents.map { $0.id })
    applyKeyboardFocusVisuals()
}
```

- [ ] **Step 7: Build**

Run: `xcodebuild -project amux.xcodeproj -scheme amux -configuration Debug build`
Expected: BUILD SUCCEEDED. If you see errors about missing properties (e.g. `cards`, `focusedLeafView`, `worktreeInfo`), grep the codebase for the correct names and fix.

- [ ] **Step 8: Commit**

```bash
git add Sources/UI/Dashboard/DashboardViewController.swift Sources/UI/Dashboard/MiniCardView.swift Sources/UI/Dashboard/StackedCardContainerView.swift Sources/UI/Dashboard/FocusPanelView.swift
git commit -m "feat(dashboard): handle D-state key events and focus lifecycle"
```

---

## Task 5: Wire window-level shortcuts in `AmuxWindow`

**Goal:** Add `Cmd+1..4` (layout switch) and `Cmd+E` (enter D-state) to `AmuxWindow.performKeyEquivalent`.

**Files:**
- Modify: `Sources/App/MainWindowController.swift`

- [ ] **Step 1: Add the new handlers**

Find `AmuxWindow.performKeyEquivalent` (around line 479). Just before the final `return super.performKeyEquivalent(with: event)` line (~543), insert:

```swift
// Cmd+1..4: switch dashboard layout.
if flags == .command, let chars = event.charactersIgnoringModifiers {
    let layoutMap: [String: DashboardLayout] = [
        "1": .grid,
        "2": .leftRight,
        "3": .topSmall,
        "4": .topLarge
    ]
    if let target = layoutMap[chars], let dashVC = mwc.tabCoordinator.dashboardVC {
        // If we are currently in D-state, exit it before switching layouts
        // (the target layout will either re-enter D for grid or go straight to T).
        if dashVC.isInDStateForWindow {
            dashVC.exitDashboardNavigation(restoreSnapshot: true)
        }
        dashVC.setLayout(target)
        if target == .grid {
            dashVC.enterDashboardNavigation()
        }
        return true
    }
}

// Cmd+E: toggle D-state in focus layouts. No-op in grid (already in D).
if flags == .command && event.charactersIgnoringModifiers == "e" {
    if let dashVC = mwc.tabCoordinator.dashboardVC {
        if dashVC.currentLayout == .grid {
            return true  // swallow, no-op
        }
        if dashVC.isInDStateForWindow {
            dashVC.exitDashboardNavigation(restoreSnapshot: true)
        } else {
            dashVC.enterDashboardNavigation()
        }
        return true
    }
}
```

- [ ] **Step 2: Expose `isInDStateForWindow` on DashboardViewController**

In `DashboardViewController.swift`, add near the existing D-state helpers:

```swift
/// Public read-only accessor for window-level shortcut handlers.
var isInDStateForWindow: Bool { isInDState }
```

- [ ] **Step 3: Build**

Run: `xcodebuild -project amux.xcodeproj -scheme amux -configuration Debug build`
Expected: BUILD SUCCEEDED

- [ ] **Step 4: Manual smoke test**

Launch amux. Verify:
1. `Cmd+1` switches to Grid and Tab starts cycling cards with visible cyan focus ring.
2. `Cmd+2` switches to Left-Right; focus returns to terminal.
3. `Cmd+E` while in Left-Right dims the big panel and mini cards; Tab moves focus between them.
4. `Esc` in D-state restores terminal focus.
5. `Cmd+E` in Grid is a no-op.

- [ ] **Step 5: Commit**

```bash
git add Sources/App/MainWindowController.swift Sources/UI/Dashboard/DashboardViewController.swift
git commit -m "feat(window): add Cmd+1..4 layout switch and Cmd+E to enter D-state"
```

---

## Task 6: Grid-mode auto-enter D on dashboard load

**Goal:** The first time the user opens a project tab in Grid layout (e.g. via app launch or `Cmd+0`), automatically enter D-state so Tab immediately cycles cards.

**Files:**
- Modify: `Sources/UI/Dashboard/DashboardViewController.swift`

- [ ] **Step 1: Auto-enter D on grid layout build**

Find the code path where the grid layout is built and shown — look at `showLayout(_:)` (around line 380) and the `viewDidAppear` if one exists. After the grid is rendered with cards, if `currentLayout == .grid` and not already in D, call `enterDashboardNavigation()`.

Safest place: at the end of `setLayout(_:)` when `layout == .grid`:

```swift
func setLayout(_ layout: DashboardLayout) {
    guard layout != currentLayout else { return }
    detachTerminals()
    resetSidebarConstraints()
    isSidebarCollapsed = false
    if currentLayout != .grid {
        lastFocusLayout = currentLayout
    }
    currentLayout = layout
    showLayout(layout)
    rebuildCurrentLayout()
    if layout == .grid {
        // Auto-enter D-state so Tab cycles cards immediately.
        DispatchQueue.main.async { [weak self] in
            self?.enterDashboardNavigation()
        }
    }
}
```

Also: in `viewDidAppear` (create it if absent):

```swift
override func viewDidAppear() {
    super.viewDidAppear()
    if currentLayout == .grid && !isInDState {
        enterDashboardNavigation()
    }
}
```

- [ ] **Step 2: Build**

Run: `xcodebuild -project amux.xcodeproj -scheme amux -configuration Debug build`
Expected: BUILD SUCCEEDED

- [ ] **Step 3: Manual smoke test**

Launch amux in Grid layout. Without any click, press Tab — expect the focus ring to move between cards. Press Return on a card — expect layout to switch to `lastFocusLayout` with the right card promoted.

- [ ] **Step 4: Commit**

```bash
git add Sources/UI/Dashboard/DashboardViewController.swift
git commit -m "feat(dashboard): auto-enter D-state when showing grid layout"
```

---

## Task 7: Fix `NewBranchDialog` keyboard navigation

**Goal:** Make the new-branch dialog fully keyboard-navigable: auto-focus the branch-name field, Tab moves through fields + dropdowns, Return triggers Create, Esc cancels.

**Files:**
- Modify: `Sources/UI/Dialog/NewBranchDialog.swift`

- [ ] **Step 1: Add `keyEquivalent = "\r"` to the Create button**

Find `setupButtons()` at line 317. After `createButton.action = #selector(createClicked)` but before the `createLoadingIndicator` block, add:

```swift
createButton.keyEquivalent = "\r"   // Return triggers Create
```

The `cancelButton.keyEquivalent = "\u{1b}"` is already in place at line 340.

- [ ] **Step 2: Set `initialFirstResponder` and recalculate the key view loop**

Find `viewDidAppear()` — if it doesn't exist in `NewBranchDialog`, add it:

```swift
override func viewDidAppear() {
    super.viewDidAppear()
    view.window?.initialFirstResponder = branchField
    view.window?.makeFirstResponder(branchField)
    view.window?.recalculateKeyViewLoop()
}
```

If `viewDidAppear` already exists, merge these three lines into it.

- [ ] **Step 3: Verify no parent refuses first responder**

Grep the file for `refusesFirstResponder` and `acceptsFirstResponder`. If any container returns `false`, remove or gate it so that `NSPopUpButton`s can be reached by Tab.

- [ ] **Step 4: Build**

Run: `xcodebuild -project amux.xcodeproj -scheme amux -configuration Debug build`
Expected: BUILD SUCCEEDED

- [ ] **Step 5: Manual smoke test**

1. Press `Cmd+N` to open dialog.
2. Cursor should auto-focus the branch name field — start typing immediately.
3. Press `Tab` — focus moves to Base branch dropdown (or Repo dropdown, depending on layout order).
4. Press `Space` or `↓` on the dropdown — options expand.
5. Arrow keys navigate options; `Return` selects.
6. `Tab` through remaining fields.
7. `Return` anywhere outside an expanded dropdown — triggers Create.
8. `Esc` — cancels.

- [ ] **Step 6: Commit**

```bash
git add Sources/UI/Dialog/NewBranchDialog.swift
git commit -m "fix(dialog): enable keyboard navigation in NewBranchDialog"
```

---

## Task 8: End-to-end regression pass

**Goal:** Confirm no existing shortcuts broke, no terminal input regressions, and all three target workflows are reachable from keyboard only.

- [ ] **Step 1: Run the full test suite**

Run: `xcodebuild -project amux.xcodeproj -scheme amuxTests -configuration Debug test`
Expected: all tests PASS (including the new `DashboardFocusControllerTests`).

- [ ] **Step 2: Manual regression checklist**

Unplug mouse / keep hands on keyboard only.

**Terminal T-state regressions (no behavior change expected):**
- [ ] `Cmd+D` / `Cmd+Shift+D` — splits work
- [ ] `Cmd+Option+Arrow` — moves focus between splits
- [ ] `Cmd+Ctrl+Arrow` — resizes splits
- [ ] `Cmd+W` — closes current split/tab
- [ ] Tab inside terminal — still sends `\t` to shell (type `echo "a"` + Tab — should autocomplete)
- [ ] `Cmd+B` — toggles sidebar
- [ ] `Cmd+P` — opens Quick Switcher, arrow + Return + Esc still work

**New keyboard workflows:**
- [ ] Workflow 1: `Cmd+1` → Tab / Shift+Tab cycles cards in grid → Return drills into Left-Right with correct card promoted.
- [ ] Workflow 2: `Cmd+2` / `Cmd+3` / `Cmd+4` switch layouts; in any of them `Cmd+E` enters D, Tab moves between big panel and mini cards, Return on a mini card promotes it, Esc cancels cleanly and restores the original terminal focus.
- [ ] Workflow 3: `Cmd+N` → type branch name → Tab to dropdown → select → Return — creates worktree.
- [ ] Workflow 4: `Cmd+E` (in focus layout) → Tab to a mini card → `Cmd+Backspace` → existing confirmation dialog appears → `Return` on Delete → worktree removed and focus advances to the next card.
- [ ] Visual sanity: dim overlay visible only in D-state in focus layouts, never in Grid, never in T; cyan focus ring follows Tab.

**Spec compliance:**
- [ ] Re-read `docs/superpowers/specs/2026-04-11-keyboard-navigation-design.md` §1–§4 and tick off each key binding against the running app.

- [ ] **Step 3: If any regression found, fix and re-run this task.**

- [ ] **Step 4: Final commit (docs / CLAUDE.md updates if needed)**

If any shortcut was renamed or any contract changed during implementation, update `CLAUDE.md`'s "Window key handling" section accordingly.

```bash
git add CLAUDE.md
git commit -m "docs: update key handling notes for keyboard navigation"
```

---

## Self-Review Notes

**Spec coverage check (against `docs/superpowers/specs/2026-04-11-keyboard-navigation-design.md`):**

- §Core Concept (three-state model): implemented via `DashboardFocusController.mode` + `DashboardViewController.isInDState`. ✓
- §1 Key bindings: `Cmd+1..4` (Task 5), `Cmd+E` (Task 5), Tab/Shift+Tab/Return/Esc/Cmd+Backspace (Task 4), delete routing (Task 4). ✓
- §2 Grid mode: auto-enter D (Task 6), Tab ring (Task 2 + 4), initial focus on most-recent worktree (Task 4, via snapshot's `focusedWorktreePath`), Return drill-in to `lastFocusLayout` (Task 1 + 4), delete + focus shift (Task 4). ✓
- §3 Focus layouts: `Cmd+E` entry (Task 5), Tab ring starting at big panel (Task 2 + 4), Return semantics per target (Task 4), Esc snapshot restore (Task 4), dim overlay (Task 4), big panel not deletable (implicit — delete handler guards on `.card` target). ✓
- §4 NewBranchDialog: Task 7. ✓
- §5 Implementation sketch: Tasks 1–5 map directly. ✓
- §6 Testing: unit tests in Task 2, manual checklist in Task 8. ✓

**Placeholder scan:** no TBDs, no "add appropriate X", no "write tests for the above". Every code step has full code. Grep-based notes ("check for correct API name") are acknowledged research steps, not placeholders — they instruct the engineer to verify against the live codebase because the exact member names on `SplitContainerView` / `AgentDisplayInfo` / `StackedMiniCardContainerView` couldn't be fully confirmed from a quick audit and should be pinned down at implementation time.

**Type consistency check:** `DashboardFocusController.Target`, `Mode`, `Snapshot`, `enterGrid`, `enterFocusLayout`, `exit`, `captureSnapshot`, `next`, `prev`, `removeCurrentCard`, `refreshCards` are the same names in Tasks 2, 4, 5. `isKeyboardFocused`, `showDimOverlay`, `hideDimOverlay` are consistent across Tasks 3 and 4. `isInDState` (private) + `isInDStateForWindow` (public) are correctly distinguished in Tasks 4 and 5.
