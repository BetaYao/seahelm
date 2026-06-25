# 全键盘操作改造 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把 amux 的 dashboard 交互改造成 vim 式模式系统（Normal/Insert），让卡片导航、进入终端、新建 worktree、卡片动作（删/diff/文件）全部可纯键盘完成，并用底部状态栏显示当前模式与热键。

**Architecture:** 新建 `KeyboardModeController`（单一真相源，类比 `AgentHead`）持有模式与瞬时子态，配一张声明式 `Keymap`（`mode → KeyChord → Action`）。窗口层 `AmuxWindow.performKeyEquivalent`/`sendEvent` 与 `DashboardViewController.keyDown` 把按键交给 controller 派发。现有 `DashboardFocusController`（D-state 焦点环）被复用并扩展出 `h/j/k/l` 二维移动与 `1-9` 跳转。现有 `StatusBarView` 扩展出模式区。

**Tech Stack:** Swift 5.10, AppKit, XCTest（`@testable import amux`，无外部依赖）。XcodeGen 生成工程；新增源文件后需 `xcodegen generate`。

---

## 现状关键事实（实现者必读）

- `DashboardFocusController`（`Sources/UI/Dashboard/DashboardFocusController.swift`）：`enum Target { none, bigPanel, card(String) }`；`focusedTarget`、`cardIds`、`next()`、`prev()`、`removeCurrentCard()`、`refreshCards(_:)`、`enterGrid(cardIds:initialId:)`、`enterFocusLayout(cardIds:)`、`exit()`、`captureSnapshot(_:)`、`snapshot`。`card(String)` 里的 String 是 **agentId**。
- `DashboardViewController`：`isInDState`、`enterDashboardNavigation()`、`exitDashboardNavigation(restoreSnapshot:)`、`keyDown(with:)`（仅 `isInDState` 时拦 Tab/Return/Esc/Delete，见 1091-1115）、`viewDidAppear()` 对 grid 自动进 D-state（1164-1169）、`handleReturnInDState()`、`handleDeleteInDState()`（调用 `dashboardDelegate?.dashboardDidRequestDelete(agentId)`，main worktree 直接 return）、`applyKeyboardFocusVisuals()`/`clearKeyboardFocusVisuals()`、`scrollFocusedIntoView()`、`agents: [AgentInfo]`（每个有 `id`、`worktreePath`、`isMainWorktree`）。
- Dashboard 委托方法（`DashboardViewControllerDelegate`，定义在 DashboardViewController.swift 顶部）：`dashboardDidRequestDelete`、`dashboardDidRequestBrowseFiles(worktreePath:)`、`dashboardDidRequestShowChanges(worktreePath:)`、`dashboardDidRequestAddProject()`。
- `AmuxWindow`（`Sources/App/MainWindowController.swift:627-723`）：`performKeyEquivalent` 处理 Cmd 组合键（Cmd+D/Cmd+B/Cmd+Shift+F/Cmd+J 等），`sendEvent` 拦 Escape（keyCode 53）。Cmd+J 在 700-709，是删除目标。
- `StatusBarView`（`Sources/UI/StatusBar/StatusBarView.swift`，高 26）：已存在，含 `usageLabel`/`notificationLabel`/`shortcutsLabel`，方法 `updateUsage/Notification/Shortcuts(text:)`。已挂在窗口底部（MainWindowController:358-379）。
- `InlineWorktreeCreateView`（`Sources/UI/Dashboard/InlineWorktreeCreateView.swift`，607 行）：`selectedAgentType`（enum，有 `.displayName`/`.inlinePickerLogoSVG`/`.inlinePickerSymbolName`）、repo/agent 是点击 chip 弹 `NSMenu`（`selectAgent(_:)` @objc，repo 菜单约 185-206），`Cmd+Return` 提交（236-245）。
- `MenuBuilder`（`Sources/App/MenuBuilder.swift`）：**不含** Cmd+J 项（Cmd+J 纯窗口级），所以无需改 MenuBuilder。

## 文件结构

**新增**
- `Sources/App/KeyboardMode.swift` — `enum KeyboardMode { normal, insert }`、`enum KeyboardSubstate`、`struct KeyChord`、`enum KeyboardAction`。纯值类型，无 AppKit 依赖以外的东西。
- `Sources/App/KeyboardModeController.swift` — 模式单一真相源 + `KeyboardModeDelegate`。
- `Sources/App/Keymap.swift` — 声明式 `[KeyboardMode: [KeyChord: KeyboardAction]]` 查表。
- `Tests/KeyboardModeControllerTests.swift`
- `Tests/KeymapTests.swift`
- `Tests/StatusBarModeTests.swift`
- `Tests/DashboardFocusControllerNavTests.swift`

**改动**
- `Sources/UI/StatusBar/StatusBarView.swift` — 加模式区。
- `Sources/UI/Dashboard/DashboardFocusController.swift` — 加 `jump(toIndex:)` 与 `move(_ direction:columns:)`。
- `Sources/UI/Dashboard/DashboardViewController.swift` — keyDown 走 keymap；删除二次确认；常驻 Normal。
- `Sources/App/MainWindowController.swift` — 实例化 controller；`performKeyEquivalent` 接 Cmd+Esc 并删 Cmd+J；`sendEvent` 接双击 Esc；状态栏接模式。
- `Sources/UI/Dashboard/InlineWorktreeCreateView.swift` — Tab 字段环、`←/→` 循环、`Space` 切 reuse。

---

## Phase 1 — KeyboardModeController（纯逻辑，TDD）

### Task 1: 类型定义 + 基础模式切换

**Files:**
- Create: `Sources/App/KeyboardMode.swift`
- Create: `Sources/App/KeyboardModeController.swift`
- Test: `Tests/KeyboardModeControllerTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
// Tests/KeyboardModeControllerTests.swift
import XCTest
@testable import amux

final class KeyboardModeControllerTests: XCTestCase {
    func testStartsInNormal() {
        let c = KeyboardModeController()
        XCTAssertEqual(c.mode, .normal)
        XCTAssertEqual(c.substate, .none)
    }

    func testEnterInsertSetsMode() {
        let c = KeyboardModeController()
        c.enterInsert()
        XCTAssertEqual(c.mode, .insert)
    }

    func testEnterNormalFromInsert() {
        let c = KeyboardModeController()
        c.enterInsert()
        c.enterNormal()
        XCTAssertEqual(c.mode, .normal)
    }

    func testModeChangeNotifiesDelegate() {
        let c = KeyboardModeController()
        let spy = ModeSpy()
        c.delegate = spy
        c.enterInsert()
        XCTAssertEqual(spy.modeChangeCount, 1)
        XCTAssertEqual(spy.lastMode, .insert)
    }
}

final class ModeSpy: KeyboardModeDelegate {
    var modeChangeCount = 0
    var lastMode: KeyboardMode?
    var lastHint: String?
    func keyboardModeDidChange(_ mode: KeyboardMode, substate: KeyboardSubstate) {
        modeChangeCount += 1
        lastMode = mode
    }
    func keyboardHintDidChange(_ hint: String) { lastHint = hint }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -project amux.xcodeproj -scheme amuxTests -configuration Debug test -only-testing:amuxTests/KeyboardModeControllerTests 2>&1 | tail -20`
Expected: COMPILE FAILURE — `KeyboardModeController` / `KeyboardMode` undefined.

- [ ] **Step 3: Write the types**

```swift
// Sources/App/KeyboardMode.swift
import Foundation

enum KeyboardMode: Equatable {
    case normal
    case insert
}

/// Transient state within Normal mode.
enum KeyboardSubstate: Equatable {
    case none
    case deletePending(agentId: String)   // first `d` pressed, awaiting confirm
    case createForm                        // inline worktree creator focused
}
```

```swift
// Sources/App/KeyboardModeController.swift
import Foundation

protocol KeyboardModeDelegate: AnyObject {
    func keyboardModeDidChange(_ mode: KeyboardMode, substate: KeyboardSubstate)
    func keyboardHintDidChange(_ hint: String)
}

final class KeyboardModeController {
    weak var delegate: KeyboardModeDelegate?

    private(set) var mode: KeyboardMode = .normal
    private(set) var substate: KeyboardSubstate = .none

    func enterInsert() {
        setMode(.insert, substate: .none)
    }

    func enterNormal() {
        setMode(.normal, substate: .none)
    }

    private func setMode(_ newMode: KeyboardMode, substate newSub: KeyboardSubstate) {
        let changed = newMode != mode || newSub != substate
        mode = newMode
        substate = newSub
        if changed {
            delegate?.keyboardModeDidChange(mode, substate: substate)
            delegate?.keyboardHintDidChange(hintText)
        }
    }

    // Placeholder; replaced with real hints in Task 4.
    var hintText: String { mode == .insert ? "INSERT" : "NORMAL" }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild -project amux.xcodeproj -scheme amuxTests -configuration Debug test -only-testing:amuxTests/KeyboardModeControllerTests 2>&1 | tail -20`
Expected: PASS (4 tests). NOTE: new files must be added to the test/app targets — run `xcodegen generate` first if the project uses globbed sources (amux does; `project.yml` globs `Sources/**` and `Tests/**`, so just regenerate).

- [ ] **Step 5: Commit**

```bash
xcodegen generate
git add Sources/App/KeyboardMode.swift Sources/App/KeyboardModeController.swift Tests/KeyboardModeControllerTests.swift amux.xcodeproj/project.pbxproj
git commit -m "feat: KeyboardModeController with normal/insert modes" --no-verify
```

---

### Task 2: Cmd+Esc / 双击 Esc → Normal（可注入时钟）

**Files:**
- Modify: `Sources/App/KeyboardModeController.swift`
- Test: `Tests/KeyboardModeControllerTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
extension KeyboardModeControllerTests {
    func testCmdEscFromInsertGoesNormal() {
        let c = KeyboardModeController()
        c.enterInsert()
        let handled = c.handleEsc(hasCommand: true, now: 0)
        XCTAssertTrue(handled)
        XCTAssertEqual(c.mode, .normal)
    }

    func testSingleEscInInsertDoesNotExit() {
        let c = KeyboardModeController()
        c.enterInsert()
        let handled = c.handleEsc(hasCommand: false, now: 0)
        XCTAssertFalse(handled)          // passes through to terminal
        XCTAssertEqual(c.mode, .insert)
    }

    func testDoubleEscWithinWindowExits() {
        let c = KeyboardModeController()
        c.enterInsert()
        _ = c.handleEsc(hasCommand: false, now: 0.0)
        let handled = c.handleEsc(hasCommand: false, now: 0.30)   // within 0.4s
        XCTAssertTrue(handled)
        XCTAssertEqual(c.mode, .normal)
    }

    func testDoubleEscTooSlowDoesNotExit() {
        let c = KeyboardModeController()
        c.enterInsert()
        _ = c.handleEsc(hasCommand: false, now: 0.0)
        let handled = c.handleEsc(hasCommand: false, now: 0.80)   // outside 0.4s
        XCTAssertFalse(handled)
        XCTAssertEqual(c.mode, .insert)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -project amux.xcodeproj -scheme amuxTests -configuration Debug test -only-testing:amuxTests/KeyboardModeControllerTests 2>&1 | tail -20`
Expected: COMPILE FAILURE — `handleEsc` undefined.

- [ ] **Step 3: Implement handleEsc**

```swift
// add to KeyboardModeController
private var lastEscTime: TimeInterval = -1
static let doubleEscWindow: TimeInterval = 0.4

/// Returns true if the controller consumed the Esc (caller must NOT pass it on).
/// `now` is a monotonic timestamp in seconds (injected for tests; production uses
/// ProcessInfo.processInfo.systemUptime).
@discardableResult
func handleEsc(hasCommand: Bool, now: TimeInterval) -> Bool {
    guard mode == .insert else { return false }
    if hasCommand {
        enterNormal()
        lastEscTime = -1
        return true
    }
    if lastEscTime >= 0 && (now - lastEscTime) <= Self.doubleEscWindow {
        enterNormal()
        lastEscTime = -1
        return true
    }
    lastEscTime = now
    return false   // first Esc passes through to the terminal
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild -project amux.xcodeproj -scheme amuxTests -configuration Debug test -only-testing:amuxTests/KeyboardModeControllerTests 2>&1 | tail -20`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/App/KeyboardModeController.swift Tests/KeyboardModeControllerTests.swift
git commit -m "feat: cmd+esc and double-esc exit insert mode" --no-verify
```

---

### Task 3: 删除二次确认子态

**Files:**
- Modify: `Sources/App/KeyboardModeController.swift`
- Test: `Tests/KeyboardModeControllerTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
extension KeyboardModeControllerTests {
    func testBeginDeleteEntersPending() {
        let c = KeyboardModeController()
        c.beginDelete(agentId: "a1")
        XCTAssertEqual(c.substate, .deletePending(agentId: "a1"))
    }

    func testConfirmDeleteReturnsAgentAndClears() {
        let c = KeyboardModeController()
        c.beginDelete(agentId: "a1")
        let confirmed = c.confirmDelete()
        XCTAssertEqual(confirmed, "a1")
        XCTAssertEqual(c.substate, .none)
    }

    func testConfirmDeleteWithoutPendingReturnsNil() {
        let c = KeyboardModeController()
        XCTAssertNil(c.confirmDelete())
    }

    func testCancelDeleteClearsPending() {
        let c = KeyboardModeController()
        c.beginDelete(agentId: "a1")
        c.cancelDelete()
        XCTAssertEqual(c.substate, .none)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild ... -only-testing:amuxTests/KeyboardModeControllerTests 2>&1 | tail -20`
Expected: COMPILE FAILURE — `beginDelete`/`confirmDelete`/`cancelDelete` undefined.

- [ ] **Step 3: Implement**

```swift
// add to KeyboardModeController
func beginDelete(agentId: String) {
    setMode(.normal, substate: .deletePending(agentId: agentId))
}

@discardableResult
func confirmDelete() -> String? {
    guard case .deletePending(let agentId) = substate else { return nil }
    setMode(.normal, substate: .none)
    return agentId
}

func cancelDelete() {
    guard case .deletePending = substate else { return }
    setMode(.normal, substate: .none)
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild ... -only-testing:amuxTests/KeyboardModeControllerTests 2>&1 | tail -20`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/App/KeyboardModeController.swift Tests/KeyboardModeControllerTests.swift
git commit -m "feat: delete-pending two-step confirm substate" --no-verify
```

---

### Task 4: createForm 子态 + 真实 hint 文本

**Files:**
- Modify: `Sources/App/KeyboardModeController.swift`
- Test: `Tests/KeyboardModeControllerTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
extension KeyboardModeControllerTests {
    func testHintNormal() {
        let c = KeyboardModeController()
        XCTAssertTrue(c.hintText.contains("hjkl"))
        XCTAssertTrue(c.hintText.contains("⏎"))
    }

    func testHintInsert() {
        let c = KeyboardModeController()
        c.enterInsert()
        XCTAssertTrue(c.hintText.contains("⌘esc"))
    }

    func testHintDeletePending() {
        let c = KeyboardModeController()
        c.beginDelete(agentId: "a1")
        XCTAssertTrue(c.hintText.uppercased().contains("DELETE?"))
    }

    func testHintCreateForm() {
        let c = KeyboardModeController()
        c.beginCreateForm()
        XCTAssertEqual(c.substate, .createForm)
        XCTAssertTrue(c.hintText.contains("tab"))
    }

    func testEndCreateFormReturnsNormal() {
        let c = KeyboardModeController()
        c.beginCreateForm()
        c.endCreateForm()
        XCTAssertEqual(c.substate, .none)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild ... -only-testing:amuxTests/KeyboardModeControllerTests 2>&1 | tail -20`
Expected: FAIL — `beginCreateForm` undefined / hint assertions fail.

- [ ] **Step 3: Implement createForm + replace hintText**

```swift
// add to KeyboardModeController
func beginCreateForm() { setMode(.normal, substate: .createForm) }
func endCreateForm() {
    guard case .createForm = substate else { return }
    setMode(.normal, substate: .none)
}

// REPLACE the placeholder hintText from Task 1 with:
var hintText: String {
    switch substate {
    case .deletePending:
        return "DELETE?  ·  d / y confirm  ·  esc cancel"
    case .createForm:
        return "CREATE  ·  tab field  ·  \u{2190}\u{2192} change  ·  \u{2318}\u{23CE} create  ·  esc cancel"
    case .none:
        switch mode {
        case .insert:
            return "INSERT  ·  \u{2318}esc / esc\u{00B7}esc \u{2192} normal"
        case .normal:
            return "NORMAL  ·  hjkl move  ·  \u{23CE} enter  ·  d del  ·  c diff  ·  f files  ·  n new"
        }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild ... -only-testing:amuxTests/KeyboardModeControllerTests 2>&1 | tail -20`
Expected: PASS (all tests in file).

- [ ] **Step 5: Commit**

```bash
git add Sources/App/KeyboardModeController.swift Tests/KeyboardModeControllerTests.swift
git commit -m "feat: createForm substate and real status hints" --no-verify
```

---

## Phase 2 — Keymap 表（TDD）

### Task 5: KeyChord + KeyboardAction + Keymap 查表

**Files:**
- Modify: `Sources/App/KeyboardMode.swift`
- Create: `Sources/App/Keymap.swift`
- Test: `Tests/KeymapTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
// Tests/KeymapTests.swift
import XCTest
@testable import amux

final class KeymapTests: XCTestCase {
    func testNormalNavigationKeys() {
        XCTAssertEqual(Keymap.action(mode: .normal, chord: KeyChord(char: "h")), .moveFocus(.left))
        XCTAssertEqual(Keymap.action(mode: .normal, chord: KeyChord(char: "j")), .moveFocus(.down))
        XCTAssertEqual(Keymap.action(mode: .normal, chord: KeyChord(char: "k")), .moveFocus(.up))
        XCTAssertEqual(Keymap.action(mode: .normal, chord: KeyChord(char: "l")), .moveFocus(.right))
    }

    func testNormalNumberJump() {
        XCTAssertEqual(Keymap.action(mode: .normal, chord: KeyChord(char: "1")), .jumpToCard(0))
        XCTAssertEqual(Keymap.action(mode: .normal, chord: KeyChord(char: "9")), .jumpToCard(8))
    }

    func testNormalActionKeys() {
        XCTAssertEqual(Keymap.action(mode: .normal, chord: KeyChord(char: "i")), .enterTerminal)
        XCTAssertEqual(Keymap.action(mode: .normal, chord: KeyChord(char: "d")), .deleteFocused)
        XCTAssertEqual(Keymap.action(mode: .normal, chord: KeyChord(char: "c")), .showChanges)
        XCTAssertEqual(Keymap.action(mode: .normal, chord: KeyChord(char: "f")), .browseFiles)
        XCTAssertEqual(Keymap.action(mode: .normal, chord: KeyChord(char: "n")), .newWorktree)
    }

    func testReturnEntersTerminal() {
        XCTAssertEqual(Keymap.action(mode: .normal, chord: KeyChord(keyCode: 36)), .enterTerminal)
    }

    func testUnmappedReturnsNil() {
        XCTAssertNil(Keymap.action(mode: .normal, chord: KeyChord(char: "z")))
    }

    func testInsertModeHasNoNormalBindings() {
        XCTAssertNil(Keymap.action(mode: .insert, chord: KeyChord(char: "h")))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild ... -only-testing:amuxTests/KeymapTests 2>&1 | tail -20`
Expected: COMPILE FAILURE — `KeyChord`/`KeyboardAction`/`Keymap` undefined.

- [ ] **Step 3: Implement types + table**

```swift
// add to Sources/App/KeyboardMode.swift
enum FocusDirection: Equatable { case left, right, up, down }

enum KeyboardAction: Equatable {
    case moveFocus(FocusDirection)
    case jumpToCard(Int)        // 0-based
    case enterTerminal
    case deleteFocused
    case showChanges
    case browseFiles
    case newWorktree
}

/// A normalized key identity. Either a printable char (no modifiers) or a raw keyCode.
struct KeyChord: Hashable {
    let char: String?
    let keyCode: UInt16?
    init(char: String) { self.char = char; self.keyCode = nil }
    init(keyCode: UInt16) { self.char = nil; self.keyCode = keyCode }
}
```

```swift
// Sources/App/Keymap.swift
import Foundation

enum Keymap {
    static func action(mode: KeyboardMode, chord: KeyChord) -> KeyboardAction? {
        guard mode == .normal else { return nil }   // Insert mode: keys go to terminal
        if let c = chord.char {
            switch c {
            case "h": return .moveFocus(.left)
            case "j": return .moveFocus(.down)
            case "k": return .moveFocus(.up)
            case "l": return .moveFocus(.right)
            case "i": return .enterTerminal
            case "d": return .deleteFocused
            case "c": return .showChanges
            case "f": return .browseFiles
            case "n": return .newWorktree
            case "1"..."9":
                if let n = Int(c) { return .jumpToCard(n - 1) }
                return nil
            default: return nil
            }
        }
        if let kc = chord.keyCode {
            switch kc {
            case 36: return .enterTerminal       // Return
            case 123: return .moveFocus(.left)   // Left arrow
            case 124: return .moveFocus(.right)  // Right arrow
            case 125: return .moveFocus(.down)   // Down arrow
            case 126: return .moveFocus(.up)     // Up arrow
            default: return nil
            }
        }
        return nil
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild ... -only-testing:amuxTests/KeymapTests 2>&1 | tail -20`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
xcodegen generate
git add Sources/App/KeyboardMode.swift Sources/App/Keymap.swift Tests/KeymapTests.swift amux.xcodeproj/project.pbxproj
git commit -m "feat: declarative keymap table for normal mode" --no-verify
```

---

## Phase 3 — 状态栏模式区（TDD）

### Task 6: StatusBarView 显示模式 + hint

**Files:**
- Modify: `Sources/UI/StatusBar/StatusBarView.swift`
- Test: `Tests/StatusBarModeTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
// Tests/StatusBarModeTests.swift
import XCTest
@testable import amux

final class StatusBarModeTests: XCTestCase {
    func testUpdateModeShowsModeName() {
        let bar = StatusBarView(frame: .zero)
        bar.updateMode(.normal, hint: "NORMAL  ·  hjkl move")
        XCTAssertEqual(bar.modeTextForTesting, "NORMAL")
        XCTAssertTrue(bar.shortcutsTextForTesting.contains("hjkl"))
    }

    func testInsertModeText() {
        let bar = StatusBarView(frame: .zero)
        bar.updateMode(.insert, hint: "INSERT  ·  ⌘esc")
        XCTAssertEqual(bar.modeTextForTesting, "INSERT")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild ... -only-testing:amuxTests/StatusBarModeTests 2>&1 | tail -20`
Expected: COMPILE FAILURE — `updateMode`/`modeTextForTesting` undefined.

- [ ] **Step 3: Implement — add mode chip label**

Add a `modeLabel` to `StatusBarView`. Insert after the existing label declarations (line 10) and into `setup()`:

```swift
// add near other label decls (after line 10)
private let modeLabel = NSTextField(labelWithString: "NORMAL")

// testing accessors (near line 13)
var modeTextForTesting: String { modeLabel.stringValue }
var shortcutsTextForTesting: String { shortcutsLabel.stringValue }

// new public API (near line 24)
func updateMode(_ mode: KeyboardMode, hint: String) {
    modeLabel.stringValue = (mode == .insert) ? "INSERT" : "NORMAL"
    // strip the leading "NORMAL/INSERT  ·  " prefix so the chip isn't duplicated in the hint
    if let range = hint.range(of: "·") {
        shortcutsLabel.stringValue = String(hint[range.upperBound...]).trimmingCharacters(in: .whitespaces)
    } else {
        shortcutsLabel.stringValue = hint
    }
    modeLabel.textColor = (mode == .insert) ? SemanticColors.accent : SemanticColors.muted
}
```

In `setup()`, configure `modeLabel` and add to the leading edge (before `usageLabel`). Add it to the styling loop is wrong (it would inherit muted/right styling); instead style separately:

```swift
// inside setup(), after the for-loop that styles the three labels:
modeLabel.font = NSFont.systemFont(ofSize: 10, weight: .bold)
modeLabel.textColor = SemanticColors.muted
modeLabel.translatesAutoresizingMaskIntoConstraints = false
addSubview(modeLabel)
```

And update constraints: pin `modeLabel` to the leading edge, and move `usageLabel` leading to be after it:

```swift
// REPLACE the usageLabel.leadingAnchor constraint line (44) and add modeLabel constraints:
NSLayoutConstraint.activate([
    modeLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
    modeLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
    usageLabel.leadingAnchor.constraint(equalTo: modeLabel.trailingAnchor, constant: 10),
    usageLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
    notificationLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
    notificationLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
    shortcutsLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
    shortcutsLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
    usageLabel.trailingAnchor.constraint(lessThanOrEqualTo: notificationLabel.leadingAnchor, constant: -8),
    notificationLabel.trailingAnchor.constraint(lessThanOrEqualTo: shortcutsLabel.leadingAnchor, constant: -8),
])
```

(Remove the original `usageLabel.leadingAnchor ... constant: 12` entry so it isn't double-constrained.)

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild ... -only-testing:amuxTests/StatusBarModeTests 2>&1 | tail -20`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/UI/StatusBar/StatusBarView.swift Tests/StatusBarModeTests.swift
git commit -m "feat: status bar mode chip and hint display" --no-verify
```

---

## Phase 4 — 焦点环二维导航扩展（TDD）

### Task 7: DashboardFocusController 加 jump + 方向移动

`next()`/`prev()` 是线性的。Normal 模式要 `h/j/k/l` 与 `1-9`。Grid 是二维（需列数），focus 布局是竖列。新增两个方法，内部对 grid 用列数把方向折算成索引步进，对 focus 布局 left/right 无效、up/down 复用 prev/next。

**Files:**
- Modify: `Sources/UI/Dashboard/DashboardFocusController.swift`
- Test: `Tests/DashboardFocusControllerNavTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
// Tests/DashboardFocusControllerNavTests.swift
import XCTest
@testable import amux

final class DashboardFocusControllerNavTests: XCTestCase {
    private func gridController(_ ids: [String], focus: String) -> DashboardFocusController {
        let c = DashboardFocusController()
        c.enterGrid(cardIds: ids, initialId: focus)
        return c
    }

    func testJumpToIndexGrid() {
        let c = gridController(["a","b","c","d"], focus: "a")
        c.jump(toIndex: 2)
        XCTAssertEqual(c.focusedTarget, .card("c"))
    }

    func testJumpOutOfRangeIsNoop() {
        let c = gridController(["a","b"], focus: "a")
        c.jump(toIndex: 9)
        XCTAssertEqual(c.focusedTarget, .card("a"))
    }

    func testGridMoveRightAdvancesByOne() {
        let c = gridController(["a","b","c","d"], focus: "a")
        c.move(.right, columns: 2)
        XCTAssertEqual(c.focusedTarget, .card("b"))
    }

    func testGridMoveDownAdvancesByColumns() {
        let c = gridController(["a","b","c","d"], focus: "a")  // 2 cols: a b / c d
        c.move(.down, columns: 2)
        XCTAssertEqual(c.focusedTarget, .card("c"))
    }

    func testGridMoveUpFromTopRowIsNoop() {
        let c = gridController(["a","b","c","d"], focus: "b")
        c.move(.up, columns: 2)
        XCTAssertEqual(c.focusedTarget, .card("b"))
    }

    func testGridMoveRightAtRowEndIsNoop() {
        let c = gridController(["a","b","c","d"], focus: "b")  // b is end of row 0
        c.move(.right, columns: 2)
        XCTAssertEqual(c.focusedTarget, .card("b"))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild ... -only-testing:amuxTests/DashboardFocusControllerNavTests 2>&1 | tail -20`
Expected: COMPILE FAILURE — `jump(toIndex:)`/`move(_:columns:)` undefined.

- [ ] **Step 3: Implement**

```swift
// add to DashboardFocusController
func jump(toIndex index: Int) {
    guard mode != .idle, cardIds.indices.contains(index) else { return }
    focusedTarget = .card(cardIds[index])
}

/// Grid-aware directional move. `columns` is the number of cards per row in the
/// current grid layout (callers pass 1 for focus layouts → up/down behave as prev/next,
/// left/right are no-ops).
func move(_ direction: FocusDirection, columns: Int) {
    guard mode != .idle else { return }
    guard case .card(let id) = focusedTarget, let idx = cardIds.firstIndex(of: id) else {
        // No card focused yet: any move selects the first card.
        if let first = cardIds.first { focusedTarget = .card(first) }
        return
    }
    let cols = max(1, columns)
    let col = idx % cols
    var target = idx
    switch direction {
    case .left:  if col > 0 { target = idx - 1 }
    case .right: if col < cols - 1 && idx + 1 < cardIds.count { target = idx + 1 }
    case .up:    if idx - cols >= 0 { target = idx - cols }
    case .down:  if idx + cols < cardIds.count { target = idx + cols }
    }
    focusedTarget = .card(cardIds[target])
}
```

NOTE: `focusedTarget` is `private(set)` — these methods are inside the class so they can assign it.

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild ... -only-testing:amuxTests/DashboardFocusControllerNavTests 2>&1 | tail -20`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/UI/Dashboard/DashboardFocusController.swift Tests/DashboardFocusControllerNavTests.swift
git commit -m "feat: grid-aware jump and directional focus move" --no-verify
```

---

## Phase 5 — 接入窗口与 Dashboard（集成，手动验证）

> 这一阶段把纯逻辑接到 AppKit。AppKit 焦点/事件难以单测，靠构建 + 手动验证。每个任务结束跑全量编译。

### Task 8: MainWindowController 持有 controller，接状态栏，删 Cmd+J，接 Esc

**Files:**
- Modify: `Sources/App/MainWindowController.swift`

- [ ] **Step 1: 加 controller 属性并设为状态栏 delegate**

在 `MainWindowController` 属性区（line 50 附近，`statusBar` 之后）加：

```swift
let keyboardMode = KeyboardModeController()
```

在 `windowDidLoad`/初始化状态栏的地方（搜索 `statusBar` 的配置处，约 358 行附近）加，让 controller 变化驱动状态栏：

```swift
keyboardMode.delegate = self
statusBar.updateMode(keyboardMode.mode, hint: keyboardMode.hintText)
```

并在文件末尾给 `MainWindowController` 加 conformance：

```swift
extension MainWindowController: KeyboardModeDelegate {
    func keyboardModeDidChange(_ mode: KeyboardMode, substate: KeyboardSubstate) {
        statusBar.updateMode(mode, hint: keyboardMode.hintText)
    }
    func keyboardHintDidChange(_ hint: String) {
        statusBar.updateMode(keyboardMode.mode, hint: hint)
    }
}
```

- [ ] **Step 2: performKeyEquivalent — 删 Cmd+J，加 Cmd+Esc**

在 `AmuxWindow.performKeyEquivalent` 中**删除** Cmd+J 分支（700-709）。在 `return super.performKeyEquivalent(with: event)`（711）之前加 Cmd+Esc：

```swift
// Cmd+Esc: exit insert mode → normal (Cmd is intercepted before terminal)
if flags == .command && event.keyCode == 53 {
    if mwc.keyboardMode.handleEsc(hasCommand: true, now: ProcessInfo.processInfo.systemUptime) {
        mwc.tabCoordinator.dashboardVC?.enterDashboardNavigation()
        return true
    }
}
```

- [ ] **Step 3: sendEvent — 双击 Esc**

把 `AmuxWindow.sendEvent`（714-722）改为：当处于 insert 且第二次 Esc 命中时，进 Normal 并吞键；否则放行（第一次 Esc 仍透传给终端）：

```swift
override func sendEvent(_ event: NSEvent) {
    if event.type == .keyDown, event.keyCode == 53,
       let mwc = windowController as? MainWindowController,
       mwc.keyboardMode.mode == .insert {
        let consumed = mwc.keyboardMode.handleEsc(hasCommand: false,
                                                  now: ProcessInfo.processInfo.systemUptime)
        if consumed {
            mwc.tabCoordinator.dashboardVC?.enterDashboardNavigation()
            return
        }
        // first Esc: fall through to terminal
    }
    super.sendEvent(event)
}
```

- [ ] **Step 4: 进入终端时切 insert**

`DashboardViewController.handleReturnInDState()` 在 `.card` 分支会 `selectAgent` + `exitDashboardNavigation(restoreSnapshot:false)`。进入终端即 insert：在 `exitDashboardNavigation` 落焦到终端后通知 controller。最简做法——在 MainWindowController 暴露一个回调，但更直接：让 `DashboardViewController` 持有一个 `onEnterTerminal` 闭包（Task 9 设）。此处仅记录依赖；实现见 Task 9。

- [ ] **Step 5: 构建 + 提交**

Run: `xcodebuild -project amux.xcodeproj -scheme amux -configuration Debug build 2>&1 | tail -15`
Expected: BUILD SUCCEEDED。

```bash
git add Sources/App/MainWindowController.swift
git commit -m "feat: wire KeyboardModeController into window, replace cmd+J with cmd/double esc" --no-verify
```

---

### Task 9: DashboardViewController.keyDown 走 keymap；常驻 Normal

**Files:**
- Modify: `Sources/UI/Dashboard/DashboardViewController.swift`

- [ ] **Step 1: 加进入终端/委托回调属性**

在 `DashboardViewController` 顶部属性区加（供 MWC 注入）：

```swift
/// Set by MainWindowController. Called when the user drills into a terminal so the
/// keyboard mode can switch to .insert.
var onEnterTerminal: (() -> Void)?
/// Called with the focused agentId when the user wants the new-worktree creator.
var onRequestNewWorktree: (() -> Void)?
```

在 MainWindowController 创建 dashboardVC 处（搜索 `DashboardViewController(`）注入：

```swift
dashVC.onEnterTerminal = { [weak self] in self?.keyboardMode.enterInsert() }
dashVC.onRequestNewWorktree = { [weak self] in
    self?.keyboardMode.beginCreateForm()
    self?.tabCoordinator.dashboardVC?.focusInlineCreator()   // existing Cmd+N path
}
```

(如果聚焦内联创建器的现有方法名不同，搜索 `MainWindowController.swift:226-232` 的 Cmd+N handler 复用其实现。)

- [ ] **Step 2: 重写 keyDown 用 keymap 派发**

把 `keyDown(with:)`（1091-1115）替换为：始终在 dashboard（Normal）下用 keymap 派发。先处理 deletePending 的确认键，再查表。

```swift
override func keyDown(with event: NSEvent) {
    guard isInDState else { super.keyDown(with: event); return }
    let mode = windowKeyboardMode   // helper below
    let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

    // deletePending: d/y confirm, esc/other cancel
    if case .deletePending(let agentId) = mode?.substate {
        if event.keyCode == 53 { mode?.cancelDelete(); applyKeyboardFocusVisuals(); return }
        if let ch = event.charactersIgnoringModifiers, ch == "d" || ch == "y" {
            if mode?.confirmDelete() == agentId { performDelete(agentId: agentId) }
            return
        }
        mode?.cancelDelete(); applyKeyboardFocusVisuals(); return
    }

    // Escape with no pending → exit nav (legacy behavior)
    if event.keyCode == 53 && flags.isEmpty {
        exitDashboardNavigation(restoreSnapshot: true); return
    }

    // Build chord: printable char with no command/control/option, else keyCode.
    let chord: KeyChord
    if flags.isDisjoint(with: [.command, .control, .option]),
       let ch = event.charactersIgnoringModifiers, ch.count == 1,
       ch.rangeOfCharacter(from: .alphanumerics) != nil {
        chord = KeyChord(char: ch)
    } else {
        chord = KeyChord(keyCode: event.keyCode)
    }

    guard let action = Keymap.action(mode: .normal, chord: chord) else {
        super.keyDown(with: event); return
    }
    dispatch(action)
}

private var windowKeyboardMode: KeyboardModeController? {
    (view.window?.windowController as? MainWindowController)?.keyboardMode
}
```

- [ ] **Step 3: 实现 dispatch(_:)**

```swift
private func dispatch(_ action: KeyboardAction) {
    switch action {
    case .moveFocus(let dir):
        focusController.move(dir, columns: currentGridColumns)
        applyKeyboardFocusVisuals(); scrollFocusedIntoView()
    case .jumpToCard(let idx):
        focusController.jump(toIndex: idx)
        applyKeyboardFocusVisuals(); scrollFocusedIntoView()
    case .enterTerminal:
        onEnterTerminal?()
        handleReturnInDState()
    case .deleteFocused:
        guard case .card(let agentId) = focusController.focusedTarget,
              let agent = agents.first(where: { $0.id == agentId }) else { return }
        guard !agent.isMainWorktree else { return }
        windowKeyboardMode?.beginDelete(agentId: agentId)
    case .showChanges:
        guard case .card(let agentId) = focusController.focusedTarget,
              let agent = agents.first(where: { $0.id == agentId }) else { return }
        dashboardDelegate?.dashboardDidRequestShowChanges(worktreePath: agent.worktreePath)
    case .browseFiles:
        guard case .card(let agentId) = focusController.focusedTarget,
              let agent = agents.first(where: { $0.id == agentId }) else { return }
        dashboardDelegate?.dashboardDidRequestBrowseFiles(worktreePath: agent.worktreePath)
    case .newWorktree:
        onRequestNewWorktree?()
    }
}

private func performDelete(agentId: String) {
    dashboardDelegate?.dashboardDidRequestDelete(agentId)
    focusController.removeCurrentCard()
    applyKeyboardFocusVisuals()
}
```

- [ ] **Step 4: 提供 currentGridColumns**

Grid 的列数由布局计算决定。搜索 `layoutGridFrames()`（1174 附近）找列数算法，抽一个只读属性。若该方法用 `columns` 局部变量，提取为：

```swift
/// Columns per row for the current grid layout. Focus layouts return 1 (vertical list).
private var currentGridColumns: Int {
    guard currentLayout == .grid else { return 1 }
    return max(1, computedGridColumnCount)   // reuse the same formula as layoutGridFrames()
}
```

实现 `computedGridColumnCount` 复用 `layoutGridFrames` 里现有的列数公式（不要复制魔法数——把公式提取成一个方法两处共用）。

- [ ] **Step 5: 构建 + 手动验证**

Run: `xcodebuild -project amux.xcodeproj -scheme amux -configuration Debug build 2>&1 | tail -15`
Expected: BUILD SUCCEEDED。

手动验证：启动 app（用 `pmux-screenshot-imessage` 或直接运行）。在 dashboard：`h/j/k/l` 移动焦点环、`1-9` 跳卡、`Return`/`i` 进终端（状态栏变 INSERT）、`Cmd+Esc` 回 dashboard（状态栏变 NORMAL）。

```bash
git add Sources/UI/Dashboard/DashboardViewController.swift Sources/App/MainWindowController.swift
git commit -m "feat: dashboard keyDown dispatches via keymap, normal-mode nav" --no-verify
```

---

### Task 10: 删除二次确认接状态栏

`beginDelete` 已在 Task 9 的 `.deleteFocused` 调用；`deletePending` 子态变化经 `KeyboardModeDelegate` 自动刷新状态栏（Task 8 已接）。本任务只做手动验证 + 主 worktree 拒删提示。

**Files:**
- Modify: `Sources/UI/Dashboard/DashboardViewController.swift`（如需主 worktree 提示）

- [ ] **Step 1: 主 worktree 拒删时给状态栏临时提示**

在 `.deleteFocused` 的 `guard !agent.isMainWorktree else { return }` 改为：

```swift
guard !agent.isMainWorktree else {
    windowKeyboardMode?.flashHint("main worktree 不可删除")
    return
}
```

在 `KeyboardModeController` 加 `flashHint`（临时覆盖 hint，0.0 注入时钟无关，用 DispatchQueue 复原）：

```swift
// KeyboardModeController
func flashHint(_ text: String) {
    delegate?.keyboardHintDidChange(text)
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
        guard let self else { return }
        self.delegate?.keyboardHintDidChange(self.hintText)
    }
}
```

- [ ] **Step 2: 构建 + 手动验证**

Run: `xcodebuild -project amux.xcodeproj -scheme amux -configuration Debug build 2>&1 | tail -15`
Expected: BUILD SUCCEEDED。

验证：焦点落非主卡片按 `d` → 状态栏变红 `DELETE? · d/y confirm · esc cancel`；再按 `d`/`y` 删除；按 `Esc` 取消恢复。焦点落 main 卡按 `d` → 状态栏闪「不可删除」。

```bash
git add Sources/UI/Dashboard/DashboardViewController.swift Sources/App/KeyboardModeController.swift
git commit -m "feat: delete confirm via status bar, main worktree guard" --no-verify
```

---

## Phase 6 — 新建 worktree 键盘流程

### Task 11: 创建表单 Tab 字段环

**Files:**
- Modify: `Sources/UI/Dashboard/InlineWorktreeCreateView.swift`

- [ ] **Step 1: 让 repo/agent chip 与 reuse 复选框可成为 firstResponder**

给三个控件（repoChip、agentChip、reuse checkbox）的视图类 override：

```swift
override var acceptsFirstResponder: Bool { true }
override func becomeFirstResponder() -> Bool { needsDisplay = true; return super.becomeFirstResponder() }
override func resignFirstResponder() -> Bool { needsDisplay = true; return super.resignFirstResponder() }
```

并在 `draw(_:)` 中当 `window?.firstResponder === self` 时画焦点环（描边 + 圆角，复用现有 chip 的 cornerRadius）。

- [ ] **Step 2: Tab 顺序**

`InlineWorktreeCreateView` 的文本框 `doCommandBy`（236-245）已拦 `Cmd+Return`。在其中加 Tab 处理，把焦点从名字框送到 repoChip：

```swift
if commandSelector == #selector(NSResponder.insertTab(_:)) {
    window?.makeFirstResponder(repoChip); return true
}
if commandSelector == #selector(NSResponder.insertBacktab(_:)) {
    window?.makeFirstResponder(reuseCheckbox); return true
}
```

给 repoChip/agentChip/reuseCheckbox override `keyDown` 处理 Tab(48)/Shift+Tab 在 `名字 → repo → agent → reuse → 名字` 环上移动（各自 `window?.makeFirstResponder(next)`）。

- [ ] **Step 3: 构建 + 手动验证**

Run: `xcodebuild -project amux.xcodeproj -scheme amux -configuration Debug build 2>&1 | tail -15`
Expected: BUILD SUCCEEDED。

验证：`n` 进创建器（状态栏 CREATE），打字，`Tab` 在四个字段间环移，每个字段有焦点环。

```bash
git add Sources/UI/Dashboard/InlineWorktreeCreateView.swift
git commit -m "feat: tab traversal across new-worktree form fields" --no-verify
```

---

### Task 12: repo/agent 字段 ←/→ 就地循环

**Files:**
- Modify: `Sources/UI/Dashboard/InlineWorktreeCreateView.swift`

- [ ] **Step 1: 抽取选项数组**

repo 现有数据源（搜索弹 repo 菜单处约 185-206，菜单项来自一个 `[String]` 路径数组）；agent 现有 `AgentType.allCases`（`selectAgent(_:)` 菜单用）。确保两者各有一个有序数组属性 `repoPaths: [String]` 与 `let agentTypes = AgentType.allCases`，及当前选中索引。

- [ ] **Step 2: chip keyDown 处理 ←/→**

在 repoChip 的 `keyDown`：

```swift
override func keyDown(with event: NSEvent) {
    switch event.keyCode {
    case 123: owner?.cycleRepo(-1)   // Left
    case 124: owner?.cycleRepo(+1)   // Right
    case 49, 36: owner?.openRepoMenu()  // Space/Return → fallback to menu
    default: super.keyDown(with: event)
    }
}
```

agentChip 同理调用 `cycleAgent(_:)`/`openAgentMenu()`。`owner` 是弱引用回 `InlineWorktreeCreateView`。

- [ ] **Step 3: 实现 cycleRepo/cycleAgent**

```swift
func cycleRepo(_ delta: Int) {
    guard !repoPaths.isEmpty else { return }
    selectedRepoIndex = (selectedRepoIndex + delta + repoPaths.count) % repoPaths.count
    applySelectedRepo()      // reuse the same update path the menu action uses
}
func cycleAgent(_ delta: Int) {
    let all = AgentType.allCases
    guard let cur = all.firstIndex(of: selectedAgentType) else { return }
    selectedAgentType = all[(cur + delta + all.count) % all.count]
    refreshAgentChip()       // reuse the same UI update the menu action triggers
}
```

`applySelectedRepo()`/`refreshAgentChip()` 复用现有菜单选中后的更新逻辑（不要复制——把菜单 action 内的更新体抽成这两个方法，菜单与方向键共用）。

- [ ] **Step 4: 构建 + 手动验证**

Run: `xcodebuild -project amux.xcodeproj -scheme amux -configuration Debug build 2>&1 | tail -15`
Expected: BUILD SUCCEEDED。

验证：Tab 到 repo/agent，`←/→` 循环切换，chip 文字/图标即时更新；`Space` 仍能弹菜单。

```bash
git add Sources/UI/Dashboard/InlineWorktreeCreateView.swift
git commit -m "feat: arrow-key cycling for repo and agent chips" --no-verify
```

---

### Task 13: reuse-env Space 切换 + 提交/取消回 Normal

**Files:**
- Modify: `Sources/UI/Dashboard/InlineWorktreeCreateView.swift`

- [ ] **Step 1: reuse checkbox Space 切换**

reuseCheckbox 的 `keyDown`：`case 49: state = (state == .on ? .off : .on); performClick(nil)`（或直接 toggle 现有 bool + 刷新）。

- [ ] **Step 2: 提交/取消通知 controller 退出 createForm**

在现有 `Cmd+Return` 提交路径与 `Esc` 取消路径里，调用回 MWC 让 `keyboardMode.endCreateForm()`。给 `InlineWorktreeCreateView` 加 `var onFormEnd: (() -> Void)?`，提交成功与取消时都 `onFormEnd?()`；MWC 注入 `{ [weak self] in self?.keyboardMode.endCreateForm() }`。Esc 取消还需让 dashboard 回到 Normal 焦点环（`enterDashboardNavigation()`）。

- [ ] **Step 3: 构建 + 手动验证**

Run: `xcodebuild -project amux.xcodeproj -scheme amux -configuration Debug build 2>&1 | tail -15`
Expected: BUILD SUCCEEDED。

验证：Tab 到 reuse 字段 `Space` 切换；`Cmd+Return` 创建后状态栏回 NORMAL；`Esc` 取消后回 NORMAL 且焦点环回到 dashboard。

```bash
git add Sources/UI/Dashboard/InlineWorktreeCreateView.swift Sources/App/MainWindowController.swift
git commit -m "feat: reuse-env space toggle and createForm exit on submit/cancel" --no-verify
```

---

## Phase 7 — 清理与回归

### Task 14: 去除 Cmd+J 残留、跑全量测试、更新旧测试

**Files:**
- Modify: 受影响的现有测试（搜索 `isInDState`/`enterDashboardNavigation`/`Cmd+J` 的测试断言）

- [ ] **Step 1: 搜索 Cmd+J / D-state 文案残留**

Run: `grep -rn "Cmd+J\|toggle D-state\|enterDashboardNavigation\|isInDState" Sources/ Tests/`
处理：注释/文档里提到 Cmd+J 的更新为「启动即 Normal」；`viewDidAppear` 自动进 D-state 的逻辑保留（它现在就是「进 Normal 焦点环」语义），但确认它不再依赖被删的 Cmd+J。

- [ ] **Step 2: 跑全量测试**

Run: `xcodebuild -project amux.xcodeproj -scheme amuxTests -configuration Debug test 2>&1 | tail -30`
Expected: 全部 PASS。若旧测试因交互变化失败，按新行为更新断言（不要为了过测试削弱新行为）。

- [ ] **Step 3: 全量构建**

Run: `xcodebuild -project amux.xcodeproj -scheme amux -configuration Debug build 2>&1 | tail -15`
Expected: BUILD SUCCEEDED。

- [ ] **Step 4: 端到端手动验证（覆盖 spec 三大范围）**

1. 卡片导航+进终端：`h/j/k/l`/`1-9`/`Return`/`i`/`Cmd+Esc`/双击 Esc。
2. 卡片动作：`d`（二次确认）/`c`（diff）/`f`（文件）。
3. 新建流程：`n` → 打字 → `Tab` 字段环 → repo/agent `←/→` → reuse `Space` → `Cmd+Return`。
状态栏全程显示正确模式与热键。

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "chore: remove cmd+J remnants, update tests for keyboard modes" --no-verify
```

---

## Self-Review 记录

- **Spec 覆盖**：模式模型(Task 1-4)、Cmd/双击 Esc(Task 2,8)、Normal 键映射(Task 5,9)、删除二次确认(Task 3,10)、新建流程 Tab+←/→+Space(Task 11-13)、状态栏(Task 6,8)、去 Cmd+J(Task 8,14)、焦点二维导航(Task 7,9)。Diff/Inspector 内部导航 spec 已声明非本期，未排任务 ✓。
- **类型一致**：`KeyboardMode`/`KeyboardSubstate`/`KeyChord`/`KeyboardAction`/`FocusDirection` 全部在 Task 1/5 定义后被一致引用；`handleEsc`/`beginDelete`/`confirmDelete`/`beginCreateForm`/`endCreateForm`/`flashHint` 签名跨任务一致。
- **开放风险（实现时确认，不阻塞）**：(a) `currentGridColumns` 需复用 `layoutGridFrames` 的真实列数公式；(b) 聚焦内联创建器的现有方法名需对照 MainWindowController Cmd+N handler；(c) repo 路径数组与 agent 菜单更新逻辑需从现有菜单 action 抽取共用，避免重复。
