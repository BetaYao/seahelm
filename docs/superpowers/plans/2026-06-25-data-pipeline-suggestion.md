# Data Pipeline — Suggestion (Order merge + Stop-hook trigger) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make agent-authored suggestions a first-class part of the single Pending Orders queue (deleting the separate `SuggestionFeed`), and make suggestions reliable by reverse-triggering them from the Stop hook instead of relying on the agent voluntarily running `seahelm-suggest`.

**Architecture:** `.suggest` outcomes (from Plan A's `ingest`) become red-zone `PendingOrder`s carrying `options`; the Bridge panel renders option chips from the queue itself. Reliability comes from the local webhook server answering a Claude Code / Codex `Stop` hook with `{"decision":"block","reason":…}` (guarded by `stop_hook_active`), which forces the agent to call the existing `seahelm-suggest` shell tool before it truly stops.

**Tech Stack:** Swift 5.10, AppKit, XCTest. No new dependencies.

**Source spec:** `docs/superpowers/specs/2026-06-25-data-pipeline-design.md` (steps 5–6).

**Prerequisite:** `docs/superpowers/plans/2026-06-25-data-pipeline-core.md` (Plan A) must be complete — this plan assumes `ingest(NormalizedEvent)`, `IngestOutcome`, `FirstMateCoordinator.handle(_ outcome:)`, and `NormalizedEventKind.suggest(options:)` exist.

## Global Constraints

- Do not change serialization keys: `config.json` CodingKeys (use `decodeIfPresent` for any new field), WeCom/WeChat protocol fields, `SailorStatus` rawValue strings.
- Real domain type names: `SailorInfo`, `SailorStatus`, `FirstMateAction`, `PendingOrder`, `PendingOrdersQueue`, `FirstMateCoordinator`, `WebhookEvent`, `WebhookEventType`.
- Build headless: `xcodebuild -project seahelm.xcodeproj -scheme seahelm -configuration Debug -skipPackagePluginValidation -skipMacroValidation build`
- Targeted tests only: `-only-testing:seahelmTests/<Class>`. Never run `seahelmUITests`.
- New source/test files: run `xcodegen generate` before building.
- TDD throughout: failing test → fail → implement → pass → commit.
- The `seahelm-suggest` shell tool stays the suggestion intake channel (do NOT introduce an MCP server).

---

## File Structure

- `Sources/Core/FirstMate.swift` (modify) — add `options: [String]?` to `FirstMateAction`.
- `Sources/Core/PendingOrdersQueue.swift` (modify) — add `upsert(_:)` (replace-on-same-id) for suggest orders.
- `Sources/Core/FirstMateCoordinator.swift` (modify) — turn `.suggest` outcome into a red-zone order with options.
- `Sources/UI/SidePanel/BridgePanelViewController.swift` (modify) — derive suggestion chip rows from the queue; drop `SuggestionFeed`.
- `Sources/UI/SidePanel/WorktreeSidePanelViewController.swift` (modify) — drop `suggestionFeed`/`SuggestionItem`.
- `Sources/App/TabCoordinator.swift` (modify) — drop `SuggestionFeed` + `onSuggestions` wiring; change webhook server closure to return a Stop-hook response.
- `Sources/App/MainWindowController.swift` (modify) — `onSuggestionTapped` now resolves the order.
- `Sources/Status/WebhookStatusProvider.swift` (modify) — drop the `onSuggestions` special-case for `.suggest`.
- `Sources/Core/SuggestionFeed.swift` (delete).
- `Sources/Status/WebhookServer.swift` (modify) — `onEvent` returns an optional response body.
- `Sources/Core/StopHookResponder.swift` (create) — pure block-decision function.
- `Sources/Core/Config.swift` (modify) — `WebhookConfig.suggestOnStop`.
- `Sources/Core/CodexHooksSetup.swift` (modify) — un-discard stdout; update stale commands.

---

### Task 1: `.suggest` becomes a red-zone PendingOrder with options

**Files:**
- Modify: `Sources/Core/FirstMate.swift:15-37`
- Modify: `Sources/Core/PendingOrdersQueue.swift:19-24`
- Modify: `Sources/Core/FirstMateCoordinator.swift`
- Test: `Tests/SuggestOrderTests.swift`

**Interfaces:**
- Consumes: `IngestOutcome`, `NormalizedEventKind.suggest`, `FirstMateAction`, `PendingOrdersQueue`.
- Produces:
  - `FirstMateAction.options: [String]?` (default nil).
  - `PendingOrdersQueue.upsert(_ action: FirstMateAction)` — replaces an existing order with the same id.
  - `FirstMateCoordinator.handle(_ outcome:)` enqueues a suggest order when `outcome.event.kind == .suggest` with non-empty options.

- [ ] **Step 1: Write the failing test**

Create `Tests/SuggestOrderTests.swift`:

```swift
import XCTest
@testable import seahelm

final class SuggestOrderTests: XCTestCase {
    private func suggestOutcome(options: [String]) -> IngestOutcome {
        let info = SailorInfo(id: "t1", worktreePath: "/wt", agentType: .claudeCode,
                              project: "p", branch: "b", status: .idle, lastMessage: "",
                              commandLine: nil, roundDuration: 0, startedAt: nil, station: nil,
                              channel: nil, taskProgress: TaskProgress())
        return IngestOutcome(info: info, statusChanged: false, oldStatus: .idle, newStatus: .idle,
                             holdSeconds: 0, isCompletionSignal: false,
                             event: NormalizedEvent(terminalID: "t1", source: .hook("seahelm-suggest"),
                                                    kind: .suggest(options: options)))
    }

    func testSuggestOutcomeEnqueuesRedOrderWithOptions() {
        let queue = PendingOrdersQueue()
        let coord = FirstMateCoordinator(config: .default, queue: queue,
            notify: { _ in }, runInspection: { _ in }, hasOrders: { _ in true })
        coord.handle(suggestOutcome(options: ["run tests", "open PR"]))
        XCTAssertEqual(queue.all().count, 1)
        XCTAssertEqual(queue.all().first?.action.kind, .suggestNextOrder)
        XCTAssertEqual(queue.all().first?.action.zone, .red)
        XCTAssertEqual(queue.all().first?.action.options, ["run tests", "open PR"])
    }

    func testNewSuggestReplacesOldForSameWorktree() {
        let queue = PendingOrdersQueue()
        let coord = FirstMateCoordinator(config: .default, queue: queue,
            notify: { _ in }, runInspection: { _ in }, hasOrders: { _ in true })
        coord.handle(suggestOutcome(options: ["old"]))
        coord.handle(suggestOutcome(options: ["new1", "new2"]))
        XCTAssertEqual(queue.all().count, 1)
        XCTAssertEqual(queue.all().first?.action.options, ["new1", "new2"])
    }

    func testEmptyOptionsEnqueuesNothing() {
        let queue = PendingOrdersQueue()
        let coord = FirstMateCoordinator(config: .default, queue: queue,
            notify: { _ in }, runInspection: { _ in }, hasOrders: { _ in true })
        coord.handle(suggestOutcome(options: []))
        XCTAssertTrue(queue.all().isEmpty)
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `xcodegen generate && xcodebuild -project seahelm.xcodeproj -scheme seahelmTests -configuration Debug test -only-testing:seahelmTests/SuggestOrderTests`
Expected: FAIL — `FirstMateAction.options` / `upsert` undefined.

- [ ] **Step 3: Add `options` to `FirstMateAction`**

In `Sources/Core/FirstMate.swift`, change the `struct FirstMateAction` (lines 15-37) to add the field and init parameter:

```swift
struct FirstMateAction: Equatable {
    let kind: FirstMateActionKind
    let zone: FirstMateZone
    let worktreePath: String
    let branch: String
    let project: String
    let terminalID: String
    let message: String
    let payload: String?
    let options: [String]?

    init(kind: FirstMateActionKind, zone: FirstMateZone, worktreePath: String,
         branch: String, project: String, terminalID: String, message: String,
         payload: String? = nil, options: [String]? = nil) {
        self.kind = kind
        self.zone = zone
        self.worktreePath = worktreePath
        self.branch = branch
        self.project = project
        self.terminalID = terminalID
        self.message = message
        self.payload = payload
        self.options = options
    }
}
```

(The `options` default of nil keeps `FirstMate.evaluate`'s `make(...)` calls compiling unchanged.)

- [ ] **Step 4: Add `upsert` to `PendingOrdersQueue`**

In `Sources/Core/PendingOrdersQueue.swift`, after `enqueue` (line 24) add:

```swift
    /// Replace-on-same-id. Used for suggest orders where a newer suggestion supersedes the older.
    func upsert(_ action: FirstMateAction) {
        let id = Self.key(action)
        let order = PendingOrder(id: id, action: action)
        if let idx = orders.firstIndex(where: { $0.id == id }) {
            guard orders[idx] != order else { return }
            orders[idx] = order
        } else {
            orders.append(order)
        }
        onChange?()
    }
```

- [ ] **Step 5: Handle `.suggest` in `FirstMateCoordinator.handle(_ outcome:)`**

In `Sources/Core/FirstMateCoordinator.swift`, replace the `handle(_ outcome: IngestOutcome)` method (added in Plan A Task 4) with one that special-cases suggest before the high-frequency filter:

```swift
    func handle(_ outcome: IngestOutcome) {
        dispatchPrecondition(condition: .onQueue(.main))
        if case .suggest(let options) = outcome.event.kind {
            guard !options.isEmpty else { return }
            let info = outcome.info
            let action = FirstMateAction(kind: .suggestNextOrder, zone: .red,
                                         worktreePath: info.worktreePath, branch: info.branch,
                                         project: info.project, terminalID: info.id,
                                         message: "\(info.branch) suggestions", options: options)
            queue.upsert(action)
            return
        }
        guard outcome.statusChanged || outcome.isCompletionSignal else { return }
        let t = StatusTransition(
            worktreePath: outcome.info.worktreePath, branch: outcome.info.branch,
            project: outcome.info.project, terminalID: outcome.info.id,
            oldStatus: outcome.oldStatus, newStatus: outcome.newStatus,
            holdSeconds: outcome.holdSeconds, isCompletionSignal: outcome.isCompletionSignal)
        handle(t)
    }
```

(`queue` is the coordinator's existing private `PendingOrdersQueue` — see `FirstMateCoordinator.swift:8`. The dedup key `worktreePath#suggestNextOrder` gives one suggest order per worktree, and `upsert` overwrites it.)

- [ ] **Step 6: Run the test to verify it passes**

Run: `xcodebuild -project seahelm.xcodeproj -scheme seahelmTests -configuration Debug test -only-testing:seahelmTests/SuggestOrderTests`
Expected: PASS (3 tests).

- [ ] **Step 7: Build**

Run: `xcodebuild -project seahelm.xcodeproj -scheme seahelm -configuration Debug -skipPackagePluginValidation -skipMacroValidation build`
Expected: BUILD SUCCEEDED. (Existing tests that build `FirstMateAction` via the memberwise init still compile because `options` defaults to nil; any test comparing actions with `==` is unaffected since both sides have `options == nil`.)

- [ ] **Step 8: Commit**

```bash
git add Sources/Core/FirstMate.swift Sources/Core/PendingOrdersQueue.swift Sources/Core/FirstMateCoordinator.swift Tests/SuggestOrderTests.swift seahelm.xcodeproj/project.pbxproj
git commit -m "feat: suggest outcomes become red-zone pending orders with options"
```

---

### Task 2: Card-based Bridge panel; delete `SuggestionFeed`

The queue is the single source of truth and there is no separate Suggestions section. Every red-zone order renders as a **card** (`OrderCardView`): line 1 `● project · branch`, line 2 `lastMessage` (≤2 lines), then a numbered button row, plus a hover-reveal corner `✕`. A suggestion order's buttons are its `options`; a single-action order's button row is one `[1 Approve]`. Watch (green) becomes flat cards (`WatchCardView`): title + one line, no buttons. Keyboard: `j/k` move card focus, `1`–`9` pick the Nth option, `n` dismiss the focused card.

**Files:**
- Rewrite: `Sources/UI/SidePanel/BridgePanelViewController.swift` (drop the Suggestions section/table + `SuggestionCellView`; `OrderCellView` → `OrderCardView`; `WatchCellView` → `WatchCardView`; variable row height)
- Modify: `Sources/UI/SidePanel/WorktreeSidePanelViewController.swift:31-34,193`
- Modify: `Sources/App/MainWindowController.swift:388-392`
- Modify: `Sources/App/TabCoordinator.swift:39,406-416`
- Modify: `Sources/Status/WebhookStatusProvider.swift:12-14,47-59,113-116`
- Delete: `Sources/Core/SuggestionFeed.swift`
- Test: `Tests/BridgeCardModelTests.swift`

**Interfaces:**
- Consumes: `PendingOrdersQueue`, `PendingOrder`, `FirstMateAction.options`, `FirstMateActionKind`, `BridgeConfirmFlow`.
- Produces:
  - `BridgePanelViewController.onSuggestionTapped: ((PendingOrder, String) -> Void)?`
  - `BridgePanelViewController.onApprove: ((PendingOrder) -> Void)?` (unchanged)
  - Pure helpers: `BridgePanelViewController.buttonTitles(for order: PendingOrder) -> [String]` (options, or `["Approve"]` when `options == nil`); `BridgePanelViewController.cardHeight(for order: PendingOrder) -> CGFloat`.

- [ ] **Step 1: Write the failing test for the pure card helpers**

Create `Tests/BridgeCardModelTests.swift`:

```swift
import XCTest
@testable import seahelm

final class BridgeCardModelTests: XCTestCase {
    private func order(kind: FirstMateActionKind, options: [String]?) -> PendingOrder {
        let a = FirstMateAction(kind: kind, zone: .red, worktreePath: "/wt", branch: "b",
                                project: "p", terminalID: "t", message: "m", options: options)
        return PendingOrder(id: "id", action: a)
    }

    func testSuggestionButtonsAreItsOptions() {
        let o = order(kind: .suggestNextOrder, options: ["run tests", "open PR"])
        XCTAssertEqual(BridgePanelViewController.buttonTitles(for: o), ["run tests", "open PR"])
    }

    func testSingleActionButtonIsApprove() {
        let o = order(kind: .returnToPort, options: nil)
        XCTAssertEqual(BridgePanelViewController.buttonTitles(for: o), ["Approve"])
    }

    func testCardHeightGrowsWithMoreButtons() {
        let small = BridgePanelViewController.cardHeight(for: order(kind: .returnToPort, options: nil))
        let big = BridgePanelViewController.cardHeight(for: order(kind: .suggestNextOrder,
                                                                  options: ["a", "b", "c", "d", "e"]))
        XCTAssertGreaterThan(big, small)
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `xcodegen generate && xcodebuild -project seahelm.xcodeproj -scheme seahelmTests -configuration Debug test -only-testing:seahelmTests/BridgeCardModelTests`
Expected: FAIL — `buttonTitles(for:)` / `cardHeight(for:)` undefined.

- [ ] **Step 3: Add the pure helpers + dangerous-kind set**

In `Sources/UI/SidePanel/BridgePanelViewController.swift`, add to the class body:

```swift
    /// Kinds that require a two-step [!! Confirm] before executing.
    static let dangerousKinds: Set<FirstMateActionKind> = [.autoCommit, .returnToPort]

    static func buttonTitles(for order: PendingOrder) -> [String] {
        order.action.options ?? ["Approve"]
    }

    /// Card = header (20) + 2 message lines (32) + button row (28) + paddings (16),
    /// plus 28 per extra button row when options wrap (>3 buttons per row).
    static func cardHeight(for order: PendingOrder) -> CGFloat {
        let buttons = buttonTitles(for: order).count
        let rows = max(1, Int(ceil(Double(buttons) / 3.0)))
        return 20 + 32 + CGFloat(rows) * 28 + 16
    }
```

- [ ] **Step 4: Remove the Suggestions section and switch state to a single card list**

In `Sources/UI/SidePanel/BridgePanelViewController.swift`:

(a) Replace the `suggestionFeed` property + `onSuggestionTapped` (lines 15-18) with:

```swift
    var onSuggestionTapped: ((PendingOrder, String) -> Void)?
```

(b) Delete the `suggestionRows` field (line 26), and the suggest views (`suggestHeader`/`suggestTableView`/`suggestScrollView`, lines 40-42).

(c) Delete `setupSuggestSection()` (lines 159-186) and its call in `loadView()` (line 77).

(d) Delete `rebindSuggestions()` (lines 233-238) and `reloadSuggestions()` (lines 240-245).

(e) Set variable row height for the orders table — in `setupOrdersSection()` add `ordersTableView.usesAutomaticRowHeights = false` and implement the delegate:

```swift
    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        if tableView.tag == 1, row < pendingOrders.count {
            return Self.cardHeight(for: pendingOrders[row])
        }
        return tableView.tag == 1 ? 28 : 22
    }
```

(f) Simplify `reload()` (lines 247-252) — all red orders are cards in one table:

```swift
    private func reload() {
        pendingOrders = queue?.all() ?? []
        ordersHeader.stringValue = "Pending Orders · \(pendingOrders.count)"
        ordersTableView.reloadData()
    }
```

(g) In `numberOfRows` (lines 341-347), delete the `case 3` branch (suggest table is gone).

- [ ] **Step 5: Replace `OrderCellView` with `OrderCardView`**

In `Sources/UI/SidePanel/BridgePanelViewController.swift`, replace the entire `OrderCellView` class (lines 420-485) with `OrderCardView`. It renders the header, 2-line message, a numbered button row, and a hover `✕`; suggestion buttons fire `onOption(index)`, the lone Approve fires `onApprove`, and dangerous kinds flip to `[!! Confirm]` on first press:

```swift
private final class OrderCardView: NSTableCellView {
    private let titleLabel = NSTextField(labelWithString: "")
    private let messageLabel = NSTextField(labelWithString: "")
    private let buttonRow = NSStackView()
    private let dismissButton = NSButton()
    private var trackingArea: NSTrackingArea?

    private var onOption: ((Int) -> Void)?
    private var onDismiss: (() -> Void)?
    private var armedDangerousIndex: Int?

    override init(frame: NSRect) { super.init(frame: frame); setup() }
    required init?(coder: NSCoder) { fatalError() }

    private func setup() {
        titleLabel.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        messageLabel.font = NSFont.systemFont(ofSize: 11)
        messageLabel.textColor = Theme.textSecondary
        messageLabel.maximumNumberOfLines = 2
        messageLabel.lineBreakMode = .byTruncatingTail
        messageLabel.translatesAutoresizingMaskIntoConstraints = false

        buttonRow.orientation = .horizontal
        buttonRow.spacing = 6
        buttonRow.translatesAutoresizingMaskIntoConstraints = false

        dismissButton.title = "✕"
        dismissButton.isBordered = false
        dismissButton.contentTintColor = Theme.textSecondary
        dismissButton.target = self
        dismissButton.action = #selector(tappedDismiss)
        dismissButton.isHidden = true
        dismissButton.translatesAutoresizingMaskIntoConstraints = false

        addSubview(titleLabel); addSubview(messageLabel); addSubview(buttonRow); addSubview(dismissButton)
        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            titleLabel.trailingAnchor.constraint(equalTo: dismissButton.leadingAnchor, constant: -4),

            dismissButton.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            dismissButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            dismissButton.widthAnchor.constraint(equalToConstant: 18),

            messageLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 2),
            messageLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            messageLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),

            buttonRow.topAnchor.constraint(equalTo: messageLabel.bottomAnchor, constant: 6),
            buttonRow.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            buttonRow.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
        ])
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = trackingArea { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                               owner: self, userInfo: nil)
        addTrackingArea(t); trackingArea = t
    }
    override func mouseEntered(with event: NSEvent) { dismissButton.isHidden = false }
    override func mouseExited(with event: NSEvent) { dismissButton.isHidden = true }

    func configure(order: PendingOrder,
                   onOption: @escaping (Int) -> Void,
                   onDismiss: @escaping () -> Void) {
        self.onOption = onOption
        self.onDismiss = onDismiss
        self.armedDangerousIndex = nil
        titleLabel.stringValue = "● \(order.action.project) · \(order.action.branch)"
        titleLabel.textColor = Theme.textPrimary
        messageLabel.stringValue = order.action.message

        buttonRow.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let titles = BridgePanelViewController.buttonTitles(for: order)
        let dangerous = BridgePanelViewController.dangerousKinds.contains(order.action.kind)
        for (i, title) in titles.enumerated() {
            let b = NSButton(title: "\(i + 1) \(title)", target: self, action: #selector(tappedOption(_:)))
            b.bezelStyle = .rounded
            b.controlSize = .small
            b.tag = i
            b.toolTip = title
            if dangerous { b.contentTintColor = .systemOrange }
            buttonRow.addArrangedSubview(b)
        }
    }

    /// Press an option by index (mouse or number key). Returns true if the action fired
    /// (false means it only armed a dangerous confirm and needs a second press).
    @discardableResult
    func selectOption(_ index: Int, dangerous: Bool) -> Bool {
        if dangerous && armedDangerousIndex != index {
            armedDangerousIndex = index
            if let b = buttonRow.arrangedSubviews[safe: index] as? NSButton { b.title = "!! Confirm" }
            return false
        }
        onOption?(index)
        return true
    }

    @objc private func tappedOption(_ sender: NSButton) {
        let dangerous = sender.contentTintColor == .systemOrange
        selectOption(sender.tag, dangerous: dangerous)
    }
    @objc private func tappedDismiss() { onDismiss?() }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
```

- [ ] **Step 6: Wire the card in `viewFor` + route option taps**

In `Sources/UI/SidePanel/BridgePanelViewController.swift`, replace the `viewFor` delegate's `tag == 1` branch (lines 365-380) with card creation; delete the `tag == 3` branch entirely. The option handler decides approve vs send-command by whether the order has options:

```swift
        if tableView.tag == 1 {
            guard row < pendingOrders.count else { return nil }
            let order = pendingOrders[row]
            let id = NSUserInterfaceItemIdentifier("OrderCard")
            let card = (tableView.makeView(withIdentifier: id, owner: self) as? OrderCardView) ?? OrderCardView()
            card.identifier = id
            card.configure(order: order,
                           onOption: { [weak self] idx in self?.applyOption(order, index: idx) },
                           onDismiss: { [weak self] in self?.queue?.resolve(id: order.id) })
            return card
        }
```

Add the option dispatcher:

```swift
    private func applyOption(_ order: PendingOrder, index: Int) {
        if let options = order.action.options {
            guard index < options.count else { return }
            onSuggestionTapped?(order, options[index])   // sends command + resolves (MainWindowController)
        } else {
            onApprove?(order)
            queue?.resolve(id: order.id)
        }
    }
```

- [ ] **Step 7: Keyboard — number keys pick options, `n` dismisses**

In `Sources/UI/SidePanel/BridgePanelViewController.swift`, in `keyDown` (lines 262-287) replace the `\r` (Enter) handling and add digit handling. Keep `j/k` and `x` (clear watch). For the orders table:

```swift
        case "n":
            handleDismiss(in: activeTable)
        case "1", "2", "3", "4", "5", "6", "7", "8", "9":
            handleDigit(Int(key)! - 1, in: activeTable)
```

Add:

```swift
    private func handleDigit(_ index: Int, in tableView: NSTableView) {
        guard tableView.tag == 1 else { return }
        let row = tableView.selectedRow
        guard row >= 0, row < pendingOrders.count else { return }
        let order = pendingOrders[row]
        let dangerous = Self.dangerousKinds.contains(order.action.kind)
        if let card = tableView.view(atColumn: 0, row: row, makeIfNecessary: false) as? OrderCardView {
            card.selectOption(index, dangerous: dangerous)
        } else {
            applyOption(order, index: index)
        }
    }
```

Delete `handleEnter` (lines 298-314) and the private `approveOrder` helper (lines 400-416) — the card's button row replaces the old expand-on-Enter flow.

- [ ] **Step 8: Convert `WatchCellView` to a flat `WatchCardView`**

In `Sources/UI/SidePanel/BridgePanelViewController.swift`, rename `WatchCellView` → `WatchCardView` and update the watch `viewFor` branch (lines 381-394) to use the new name. Keep its existing single-line layout (icon + branch + message) — it already matches "flat card, no buttons". (Cosmetic only: optionally show `project · branch` by setting `branchLabel.stringValue = "\(item.project) · \(item.branch)"` if `WatchItem` carries `project`; otherwise leave `item.branch`.)

- [ ] **Step 9: Update `WorktreeSidePanelViewController`, `MainWindowController`, coordinator, provider; delete `SuggestionFeed`**

- `WorktreeSidePanelViewController.swift`: delete the `suggestionFeed` property + `didSet` (lines 31-32); change `onSuggestionTapped` (line 34) to `((PendingOrder, String) -> Void)?` and forward `bridgeVC?.onSuggestionTapped = onSuggestionTapped` where the other `bridgeVC?.on…` closures are set (grep `bridgeVC?.on`); delete `vc.suggestionFeed = suggestionFeed` (line 193).
- `MainWindowController.swift`: replace lines 388-392 with:

```swift
        dashboard.sidePanelVC.onSuggestionTapped = { [weak self] order, optionText in
            ShipLog.shared.sendCommand(to: order.action.terminalID, command: optionText)
            self?.tabCoordinator.pendingOrders.resolve(id: order.id)
        }
```

- `TabCoordinator.swift`: delete `let suggestionFeed = SuggestionFeed()` (line 39) and the `webhookProvider.onSuggestions = { … }` block (lines 406-416).
- `WebhookStatusProvider.swift`: delete the `onSuggestions` property (line 14), the `if event.event == .suggest { … }` block (lines 47-59), and the `onSuggestions?(worktreePath, [])` call (lines 113-116). Suggest now flows through `ShipLog.handleWebhookEvent → ingest` (already called at `TabCoordinator.swift:425`).
- Delete `Sources/Core/SuggestionFeed.swift`.
- Grep: `grep -rn "SuggestionFeed\|SuggestionItem\|onSuggestions\|SuggestionCellView\|OrderCellView" Sources Tests` — expect no matches.

- [ ] **Step 10: Run the card-model test + build**

Run: `xcodegen generate && xcodebuild -project seahelm.xcodeproj -scheme seahelmTests -configuration Debug test -only-testing:seahelmTests/BridgeCardModelTests`
Expected: PASS (3 tests).

Run: `xcodebuild -project seahelm.xcodeproj -scheme seahelm -configuration Debug -skipPackagePluginValidation -skipMacroValidation build`
Expected: BUILD SUCCEEDED (fix any leftover references the grep surfaced).

- [ ] **Step 11: Commit**

```bash
git add -A
git commit -m "feat: card-based Bridge panel (unified orders + suggestions), delete SuggestionFeed"
```

---

### Task 3: Stop-hook reverse-trigger for reliable suggestions

The local webhook server answers a `Stop` hook with `{"decision":"block","reason":…}` (once per turn, guarded by `stop_hook_active`) so the agent is forced to run `seahelm-suggest` before truly stopping. When blocking, we do NOT treat that Stop as completion (skip the normal ingest for it). Codex's command hook is fixed to forward stdout so its decision is read.

**Files:**
- Create: `Sources/Core/StopHookResponder.swift`
- Modify: `Sources/Status/WebhookServer.swift:8,11-14,106-138`
- Modify: `Sources/App/TabCoordinator.swift:423-425`
- Modify: `Sources/Core/Config.swift` (`WebhookConfig`)
- Modify: `Sources/Core/CodexHooksSetup.swift:15-17,111-145`
- Test: `Tests/StopHookResponderTests.swift`

**Interfaces:**
- Consumes: `WebhookEvent`, `WebhookEventType`, `WebhookConfig`.
- Produces:
  - `enum StopHookResponder { static func blockBody(for event: WebhookEvent, suggestOnStop: Bool) -> String? }`
  - `WebhookServer`'s `onEvent` becomes `(WebhookEvent) -> String?` (nil ⇒ 200 empty; non-nil ⇒ 200 with that JSON body).
  - `WebhookConfig.suggestOnStop: Bool` (default true).

- [ ] **Step 1: Write the failing test for `StopHookResponder`**

Create `Tests/StopHookResponderTests.swift`:

```swift
import XCTest
@testable import seahelm

final class StopHookResponderTests: XCTestCase {
    private func stop(active: Bool?) -> WebhookEvent {
        var data: [String: Any] = [:]
        if let active { data["stop_hook_active"] = active }
        return WebhookEvent(source: "claude-code", sessionId: "s", event: .agentStop,
                            cwd: "/wt", timestamp: nil, data: data.isEmpty ? nil : data)
    }

    func testFirstStopBlocks() {
        let body = StopHookResponder.blockBody(for: stop(active: false), suggestOnStop: true)
        XCTAssertNotNil(body)
        XCTAssertTrue(body!.contains("\"decision\":\"block\""))
        XCTAssertTrue(body!.contains("seahelm-suggest"))
    }

    func testSecondStopDoesNotBlock() {
        XCTAssertNil(StopHookResponder.blockBody(for: stop(active: true), suggestOnStop: true))
    }

    func testMissingFlagTreatedAsFirstStop() {
        XCTAssertNotNil(StopHookResponder.blockBody(for: stop(active: nil), suggestOnStop: true))
    }

    func testDisabledNeverBlocks() {
        XCTAssertNil(StopHookResponder.blockBody(for: stop(active: false), suggestOnStop: false))
    }

    func testNonStopEventNeverBlocks() {
        let e = WebhookEvent(source: "claude-code", sessionId: "s", event: .toolUseStart,
                             cwd: "/wt", timestamp: nil, data: nil)
        XCTAssertNil(StopHookResponder.blockBody(for: e, suggestOnStop: true))
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `xcodegen generate && xcodebuild -project seahelm.xcodeproj -scheme seahelmTests -configuration Debug test -only-testing:seahelmTests/StopHookResponderTests`
Expected: FAIL — `StopHookResponder` undefined.

- [ ] **Step 3: Implement `StopHookResponder`**

Create `Sources/Core/StopHookResponder.swift`:

```swift
import Foundation

/// Pure decision for the Stop hook reverse-trigger.
/// Returns a JSON body to force the agent to emit suggestions, or nil to let it stop.
/// The block reason tells the agent to call the existing `seahelm-suggest` shell tool.
enum StopHookResponder {
    static let reason = "Before ending this turn, call `seahelm-suggest 'option one' 'option two'` "
        + "with 2-5 short imperative next-step options for the user. "
        + "Do NOT print them as text — the user sees them as clickable buttons."

    static func blockBody(for event: WebhookEvent, suggestOnStop: Bool) -> String? {
        guard suggestOnStop else { return nil }
        guard event.event == .agentStop else { return nil }
        let active = event.data?["stop_hook_active"] as? Bool ?? false
        guard !active else { return nil }
        let escaped = reason.replacingOccurrences(of: "\"", with: "\\\"")
        return "{\"decision\":\"block\",\"reason\":\"\(escaped)\"}"
    }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `xcodebuild -project seahelm.xcodeproj -scheme seahelmTests -configuration Debug test -only-testing:seahelmTests/StopHookResponderTests`
Expected: PASS (5 tests).

- [ ] **Step 5: Add `suggestOnStop` to `WebhookConfig` (backward-compatible)**

In `Sources/Core/Config.swift`, replace the `WebhookConfig` struct with a version that decodes the new key via `decodeIfPresent`:

```swift
struct WebhookConfig: Codable {
    var enabled: Bool = true
    var port: UInt16 = 7070
    var suggestOnStop: Bool = true

    enum CodingKeys: String, CodingKey {
        case enabled, port
        case suggestOnStop = "suggest_on_stop"
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        port = try c.decodeIfPresent(UInt16.self, forKey: .port) ?? 7070
        suggestOnStop = try c.decodeIfPresent(Bool.self, forKey: .suggestOnStop) ?? true
    }
}
```

- [ ] **Step 6: Make `WebhookServer.onEvent` return an optional body**

In `Sources/Status/WebhookServer.swift`:
- Change the property and init (lines 8, 11-14):

```swift
    private let onEvent: (WebhookEvent) -> String?

    init(port: UInt16, onEvent: @escaping (WebhookEvent) -> String?) {
        self.port = port
        self.onEvent = onEvent
    }
```

- In `processHTTPRequest`, replace the success branch (lines 130-137):

```swift
        do {
            let event = try WebhookEvent.parse(from: body)
            let responseBody = onEvent(event) ?? ""
            sendResponse(connection: connection, statusCode: 200, body: responseBody)
        } catch {
            NSLog("[WebhookServer] Parse error: \(error)")
            sendResponse(connection: connection, statusCode: 400, body: "Bad Request")
        }
```

(`sendResponse` already sets `Content-Length` from the body, so a JSON body is delivered correctly.)

- [ ] **Step 7: Wire the decision into the server closure (and skip completion on block)**

In `Sources/App/TabCoordinator.swift`, replace the `WebhookServer(...)` closure (lines 423-425) with:

```swift
                    let server = WebhookServer(port: self.config.webhook.port) { [weak self] event in
                        guard let self else { return nil }
                        if let block = StopHookResponder.blockBody(
                            for: event, suggestOnStop: self.config.webhook.suggestOnStop) {
                            // Blocking Stop: agent will continue and call seahelm-suggest.
                            // Do NOT ingest this stop as completion (avoid premature idle).
                            return block
                        }
                        self.statusPublisher.webhookProvider.handleEvent(event)
                        ShipLog.shared.handleWebhookEvent(event)
                        return nil
                    }
```

- [ ] **Step 8: Fix the Codex command hook to forward stdout + update stale entries**

In `Sources/Core/CodexHooksSetup.swift`:
- Change `hookCommand` (lines 15-17) to stop discarding stdout:

```swift
    private static func hookCommand(port: UInt16) -> String {
        "/bin/sh -lc '/usr/bin/curl -fsS -X POST http://localhost:\(port)/webhook -H \"Content-Type: application/json\" --data-binary @- 2>/dev/null || true'"
    }
```

- In `ensureHooksJSON` (lines 124-130), update entries whose command no longer matches (so already-installed configs get the stdout fix), not only missing ones:

```swift
        let expected = config  // [[ "hooks": [[ "type": "command", "command": <new> ]] ]]
        for event in requiredEvents {
            let current = hooks[event] as? [[String: Any]]
            let currentCommand = (current?.first?["hooks"] as? [[String: Any]])?.first?["command"] as? String
            let expectedCommand = hookCommand(port: port)
            if current == nil || currentCommand != expectedCommand {
                hooks[event] = expected
                changed = true
                NSLog("[CodexHooksSetup] Installed/updated hook: \(event)")
            }
        }
```

- [ ] **Step 9: Build + full pipeline + Stop-hook tests**

Run: `xcodegen generate && xcodebuild -project seahelm.xcodeproj -scheme seahelm -configuration Debug -skipPackagePluginValidation -skipMacroValidation build`
Expected: BUILD SUCCEEDED.

Run: `xcodebuild -project seahelm.xcodeproj -scheme seahelmTests -configuration Debug test -only-testing:seahelmTests/StopHookResponderTests -only-testing:seahelmTests/SuggestOrderTests -only-testing:seahelmTests/BridgeSuggestionRowsTests`
Expected: PASS.

- [ ] **Step 10: Commit**

```bash
git add -A
git commit -m "feat: Stop-hook reverse-trigger for reliable suggestions (Claude + Codex)"
```

---

## Self-Review Notes

- **Spec coverage (steps 5–6):** Task 1 = `.suggest` → red-zone `PendingOrder` with options + dedup-by-worktree overwrite (spec "Order 同源" + dedup keys). Task 2 = card-based Bridge panel — every red order is an `OrderCardView` (title + ≤2-line message + numbered button row + hover ✕), one table, no separate Suggestions section; Watch becomes flat `WatchCardView`; delete `SuggestionFeed` (spec "Bridge 面板 UI:Pending Orders 卡片化"). Task 3 = Stop-hook reverse-trigger + `suggestOnStop` config + `stop_hook_active` loop guard + status-coupling fix (skip completion on block) + Codex command stdout fix (spec "suggestion 的两条进入路径" + landing step 6).
- **Type consistency:** `onSuggestionTapped` is `(PendingOrder, String)` across `BridgePanelViewController`, `WorktreeSidePanelViewController`, `MainWindowController`. `FirstMateAction.options` flows from coordinator → queue → Bridge helpers. `WebhookServer.onEvent` is `(WebhookEvent) -> String?` at both definition and the `TabCoordinator` call site.
- **Verification points for the implementer:** the exact forwarding block in `WorktreeSidePanelViewController` (Task 2 Step 9 — grep `bridgeVC?.on`); whether `WatchItem` carries `project` (Task 2 Step 8); whether any existing test constructs `WebhookServer` with the old `Void` closure (grep `WebhookServer(` in `Tests/` — `Tests/ShipLogWebhookPathTests.swift` exists and may need its closure return type updated); existing Bridge UI tests that referenced `OrderCellView`/`SuggestionCellView`/the suggest table (grep `OrderCell\|SuggestCell\|tag == 3` in `Tests/`).
- **Behavior change called out:** with `suggestOnStop` default true, every Claude Code / Codex turn now does one extra round-trip (agent pulled back to emit suggestions). Set `suggest_on_stop: false` in `config.json` to disable.
```
</content>
