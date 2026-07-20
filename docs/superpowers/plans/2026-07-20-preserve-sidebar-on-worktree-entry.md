# Preserve Sidebar State on Worktree Entry Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Keep the left sidebar in its current expanded or collapsed state whenever Seahelm enters a worktree's terminal mode.

**Architecture:** The unwanted behavior lives in the shared `.terminal` transition of `DashboardViewController`, so remove the state mutation there rather than adding per-entry flags. Add focused controller tests that load the real AppKit view hierarchy and assert both possible sidebar states survive the transition.

**Tech Stack:** Swift 5.10, AppKit, XCTest, XcodeGen/Xcodebuild

---

## File Structure

- Create `Tests/DashboardViewModeTests.swift` for view-mode/sidebar state regression tests.
- Modify `Sources/UI/Dashboard/DashboardViewController.swift` to stop collapsing the sidebar during the `.terminal` transition and update stale mode documentation.

### Task 1: Preserve Sidebar State During Terminal Entry

**Files:**
- Create: `Tests/DashboardViewModeTests.swift`
- Modify: `Sources/UI/Dashboard/DashboardViewController.swift:91-96,468-473,1524-1526`

- [ ] **Step 1: Write the failing regression tests**

Create `Tests/DashboardViewModeTests.swift`:

```swift
import XCTest
@testable import seahelm

final class DashboardViewModeTests: XCTestCase {
    func testEnteringTerminalKeepsExpandedSidebarExpanded() {
        let vc = DashboardViewController()
        vc.loadViewIfNeeded()
        XCTAssertTrue(vc.isLeftColumnCollapsedState)
        vc.toggleLeftColumnCollapse()
        XCTAssertFalse(vc.isLeftColumnCollapsedState)

        vc.setViewMode(.terminal)

        XCTAssertFalse(vc.isLeftColumnCollapsedState)
    }

    func testEnteringTerminalKeepsCollapsedSidebarCollapsed() {
        let vc = DashboardViewController()
        vc.loadViewIfNeeded()
        XCTAssertTrue(vc.isLeftColumnCollapsedState)

        vc.setViewMode(.terminal)

        XCTAssertTrue(vc.isLeftColumnCollapsedState)
    }
}
```

- [ ] **Step 2: Run the focused tests and verify the expanded-state test fails**

Run:

```bash
xcodebuild -project seahelm.xcodeproj -scheme seahelm -configuration Debug \
  -skipPackagePluginValidation -skipMacroValidation \
  -only-testing:seahelmTests/DashboardViewModeTests test
```

Expected: `testEnteringTerminalKeepsExpandedSidebarExpanded` fails because the current `.terminal` transition collapses an expanded sidebar. The collapsed-state test passes.

- [ ] **Step 3: Remove the terminal transition's sidebar mutation**

In `DashboardViewController.applyViewMode`, change the `.terminal` case from:

```swift
case .terminal:
    closeFirstMateSide()
    currentSide = .none
    overviewView.isHidden = true
    if !isLeftColumnCollapsed { _ = toggleLeftColumnCollapse() }
```

to:

```swift
case .terminal:
    closeFirstMateSide()
    currentSide = .none
    overviewView.isHidden = true
```

Update the `ViewMode.terminal` documentation to say that the terminal owns the keyboard while the left-column state is preserved. Update the worktree-row click documentation so mode 2 to mode 3 no longer claims the sidebar is hidden.

- [ ] **Step 4: Run the focused tests and verify both pass**

Run the same focused `xcodebuild ... -only-testing:seahelmTests/DashboardViewModeTests test` command.

Expected: both tests pass with zero failures.

- [ ] **Step 5: Run the full unit-test target**

Run:

```bash
xcodebuild -project seahelm.xcodeproj -scheme seahelm -configuration Debug \
  -skipPackagePluginValidation -skipMacroValidation \
  -only-testing:seahelmTests test
```

Expected: all unit tests pass with zero failures.

- [ ] **Step 6: Build the application**

Run:

```bash
xcodebuild -project seahelm.xcodeproj -scheme seahelm -configuration Debug \
  -skipPackagePluginValidation -skipMacroValidation build
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 7: Commit the behavior change**

```bash
git add Tests/DashboardViewModeTests.swift Sources/UI/Dashboard/DashboardViewController.swift
git commit -m "fix: preserve sidebar state when entering worktrees"
```
