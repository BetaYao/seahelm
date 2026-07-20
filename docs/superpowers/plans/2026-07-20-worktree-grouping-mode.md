# Worktree Grouping Mode Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a persistent First Mate header menu that groups worktrees by repository, status, or last activity time.

**Architecture:** Put grouping and preference decoding in a pure model. `DashboardOverviewView` translates `SailorDisplayInfo` values into grouping items, renders the resulting sections with its existing stack/row views, and continues deriving keyboard order from `orderedRows`.

**Tech Stack:** Swift 5.10, AppKit, XCTest, UserDefaults, XcodeGen

---

## Preparation

The approved spec is on a local `main` that is behind `origin/main`. Start from the latest remote code in an isolated worktree:

```bash
git fetch origin
git worktree add ../seahelm-worktree-grouping -b feat/worktree-grouping origin/main
cd ../seahelm-worktree-grouping
git cherry-pick 1e38dcd
```

If `GhosttyKit.xcframework` is absent, run `scripts/setup.sh` with Zig 0.15.2 available. Never commit Ghostty build artifacts.

## File Structure

- Create `Sources/UI/Dashboard/WorktreeGrouping.swift` for pure grouping values, algorithms, and preference persistence.
- Create `Tests/WorktreeGroupingTests.swift` for group order, time boundaries, stable sorting, and persistence.
- Modify `Sources/UI/Dashboard/DashboardViewController.swift` for `lastActivityAt`, the header menu, model-driven rendering, and focus notification.
- Modify `Sources/App/TabCoordinator.swift` to pass the authoritative activity date.
- Modify `Tests/DashboardViewControllerClickTests.swift` to update its `SailorDisplayInfo` fixture.
- Create `Tests/DashboardOverviewGroupingTests.swift` for AppKit menu, persistence, row order, and selection coverage.

### Task 1: Pure Grouping And Preference Model

**Files:**
- Create: `Tests/WorktreeGroupingTests.swift`
- Create: `Sources/UI/Dashboard/WorktreeGrouping.swift`

- [ ] **Step 1: Write failing repository and status tests**

Create `Tests/WorktreeGroupingTests.swift`:

```swift
import XCTest
@testable import seahelm

final class WorktreeGroupingTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 2_000_000)

    private func item(_ path: String, repo: String, status: SailorStatus = .idle,
                      activity: Date? = nil, main: Bool = false,
                      created: Date = .distantPast) -> WorktreeGroupingItem {
        WorktreeGroupingItem(id: path, path: path, repository: repo, status: status,
                             lastActivityAt: activity, isMainWorktree: main,
                             creationDate: created)
    }

    func testRepositoryGroupingKeepsCurrentOrdering() {
        let old = Date(timeIntervalSince1970: 10)
        let new = Date(timeIntervalSince1970: 20)
        let groups = WorktreeGrouping.groups([
            item("/b/new", repo: "beta", created: new),
            item("/a/linked", repo: "alpha", created: old),
            item("/b/main", repo: "beta", main: true, created: new),
            item("/b/old", repo: "beta", created: old),
        ], mode: .repository, now: now)
        XCTAssertEqual(groups.map(\.title), ["beta", "alpha"])
        XCTAssertEqual(groups[0].items.map(\.path), ["/b/main", "/b/old", "/b/new"])
    }

    func testRepositoryUsesPathAsCreationTimeTieBreaker() {
        let groups = WorktreeGrouping.groups([
            item("/repo/z", repo: "repo"), item("/repo/a", repo: "repo"),
        ], mode: .repository, now: now)
        XCTAssertEqual(groups[0].items.map(\.path), ["/repo/a", "/repo/z"])
    }

    func testStatusGroupingUsesApprovedOrderAndRecency() {
        let groups = WorktreeGrouping.groups([
            item("/idle", repo: "r", status: .idle, activity: now.addingTimeInterval(-5)),
            item("/run-old", repo: "r", status: .running, activity: now.addingTimeInterval(-30)),
            item("/wait", repo: "r", status: .waiting, activity: now),
            item("/run-new", repo: "r", status: .running, activity: now.addingTimeInterval(-10)),
            item("/error", repo: "r", status: .error, activity: now),
            item("/exited", repo: "r", status: .exited, activity: now),
        ], mode: .status, now: now)
        XCTAssertEqual(groups.map(\.title), ["Needs input", "Running", "Idle", "Error", "Dormant"])
        XCTAssertEqual(groups[1].items.map(\.path), ["/run-new", "/run-old"])
    }
}
```

- [ ] **Step 2: Run RED**

```bash
xcodebuild -project seahelm.xcodeproj -scheme seahelmTests -configuration Debug test \
  -only-testing:seahelmTests/WorktreeGroupingTests \
  -skipPackagePluginValidation -skipMacroValidation
```

Expected: compilation fails because the grouping types do not exist.

- [ ] **Step 3: Implement repository/status grouping**

Create `Sources/UI/Dashboard/WorktreeGrouping.swift` with these exact module-level types:

```swift
import Foundation

enum WorktreeGroupingMode: String, CaseIterable { case repository, status, activityTime }
enum WorktreeActivityBucket: String, CaseIterable {
    case recentHour, today, recentSevenDays, earlier, noActivity
}
enum WorktreeGroupID: Hashable {
    case repository(String), status(SailorStatus), activity(WorktreeActivityBucket)
}
struct WorktreeGroupingItem: Equatable {
    let id: String
    let path: String
    let repository: String
    let status: SailorStatus
    let lastActivityAt: Date?
    let isMainWorktree: Bool
    let creationDate: Date
}
struct WorktreeGroup: Equatable {
    let id: WorktreeGroupID
    let title: String
    let status: SailorStatus?
    let items: [WorktreeGroupingItem]
}
```

Implement `WorktreeGrouping.groups(_:mode:now:calendar:)`. Repository mode records keys in first-seen order, converts an empty name to `Unknown repository`, and sorts main first, creation date ascending, then path. Status mode iterates `[.waiting, .running, .idle, .error, .exited, .unknown]`, uses titles `Needs input`, `Running`, `Idle`, `Error`, `Dormant`, `Unknown`, and sorts activity descending with path as the final tie-breaker. Return `[]` temporarily for activity mode.

- [ ] **Step 4: Run GREEN**

Run the Step 2 command. Expected: three tests pass.

- [ ] **Step 5: Add failing time and preference tests**

Append:

```swift
func testActivityBucketsHonorExactBoundaries() {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    let now = ISO8601DateFormatter().date(from: "2026-07-20T12:00:00Z")!
    let groups = WorktreeGrouping.groups([
        item("/future", repo: "r", activity: now.addingTimeInterval(60)),
        item("/hour", repo: "r", activity: now.addingTimeInterval(-3_599)),
        item("/today", repo: "r", activity: now.addingTimeInterval(-3_600)),
        item("/week", repo: "r", activity: now.addingTimeInterval(-6 * 86_400)),
        item("/earlier", repo: "r", activity: now.addingTimeInterval(-7 * 86_400)),
        item("/none", repo: "r", activity: nil),
    ], mode: .activityTime, now: now, calendar: calendar)
    XCTAssertEqual(groups.map(\.title),
                   ["Recent hour", "Today", "Recent 7 days", "Earlier", "No activity"])
    XCTAssertEqual(groups[0].items.map(\.path), ["/future", "/hour"])
}

func testPreferenceRoundTripsAndInvalidValueFallsBack() {
    let suite = "WorktreeGroupingTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let preference = WorktreeGroupingPreference(defaults: defaults)
    preference.save(.activityTime)
    XCTAssertEqual(preference.load(), .activityTime)
    defaults.set("broken", forKey: WorktreeGroupingPreference.key)
    XCTAssertEqual(preference.load(), .repository)
}
```

- [ ] **Step 6: Run RED, then implement activity buckets and persistence**

Run Step 2; expect the activity assertion and missing preference type to fail. Then add:

```swift
struct WorktreeGroupingPreference {
    static let key = "seahelm.dashboard.worktreeGroupingMode"
    let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    func load() -> WorktreeGroupingMode {
        guard let raw = defaults.string(forKey: Self.key),
              let mode = WorktreeGroupingMode(rawValue: raw) else { return .repository }
        return mode
    }
    func save(_ mode: WorktreeGroupingMode) { defaults.set(mode.rawValue, forKey: Self.key) }
}
```

Bucket by clamped age: `< 3_600` is Recent hour; otherwise same calendar day is Today; otherwise `< 7 * 86_400` is Recent 7 days; known older dates are Earlier; nil is No activity. Iterate buckets in that order and sort every bucket by activity descending, then path.

- [ ] **Step 7: Run GREEN and commit**

Run Step 2; expect all tests to pass.

```bash
git add Sources/UI/Dashboard/WorktreeGrouping.swift Tests/WorktreeGroupingTests.swift
git commit -m "feat: model worktree grouping modes"
```

### Task 2: Carry Raw Activity Dates Into Grouping

**Files:**
- Modify: `Sources/UI/Dashboard/DashboardViewController.swift:15-55`
- Modify: `Sources/UI/Dashboard/WorktreeGrouping.swift`
- Modify: `Sources/App/TabCoordinator.swift:335-385`
- Modify: `Tests/DashboardViewControllerClickTests.swift:30-65`
- Create: `Tests/DashboardOverviewGroupingTests.swift`

- [ ] **Step 1: Write a failing adapter test**

Create `Tests/DashboardOverviewGroupingTests.swift` with a `makeSailor` helper based on `DashboardViewControllerClickTests`, and add:

```swift
func testGroupingItemUsesHighestStatusAndRawActivityDate() {
    let activity = Date(timeIntervalSince1970: 1234)
    let sailor = makeSailor(id: "agent", path: "/repo/feature", project: "repo",
                            statuses: [.running, .error], lastActivityAt: activity)
    let item = sailor.groupingItem(creationDate: Date(timeIntervalSince1970: 10))
    XCTAssertEqual(item.status, .error)
    XCTAssertEqual(item.lastActivityAt, activity)
    XCTAssertEqual(item.repository, "repo")
}
```

The helper supplies the latest `currentPaneTitle` and `currentPaneRunTime` initializer fields from `origin/main`.

- [ ] **Step 2: Run RED**

```bash
xcodebuild -project seahelm.xcodeproj -scheme seahelmTests -configuration Debug test \
  -only-testing:seahelmTests/DashboardOverviewGroupingTests \
  -skipPackagePluginValidation -skipMacroValidation
```

Expected: compilation fails because `lastActivityAt` and `groupingItem` are missing.

- [ ] **Step 3: Add the field, adapter, and producer value**

Add `let lastActivityAt: Date?` beside `lastActivityAge` in `SailorDisplayInfo`. In `WorktreeGrouping.swift`, add:

```swift
extension SailorDisplayInfo {
    func groupingItem(creationDate: Date) -> WorktreeGroupingItem {
        WorktreeGroupingItem(id: id, path: worktreePath, repository: project,
            status: SailorStatus.highestPriority(paneStatuses),
            lastActivityAt: lastActivityAt, isMainWorktree: isMainWorktree,
            creationDate: creationDate)
    }
}
```

In `TabCoordinator`, pass the existing `lastActivity` local as `lastActivityAt: lastActivity`. Add `lastActivityAt: nil` to `DashboardViewControllerClickTests` and the supplied date to the new fixture.

- [ ] **Step 4: Run GREEN and commit**

```bash
xcodebuild -project seahelm.xcodeproj -scheme seahelmTests -configuration Debug test \
  -only-testing:seahelmTests/DashboardOverviewGroupingTests \
  -only-testing:seahelmTests/DashboardViewControllerClickTests \
  -skipPackagePluginValidation -skipMacroValidation
git add Sources/UI/Dashboard/DashboardViewController.swift Sources/UI/Dashboard/WorktreeGrouping.swift \
  Sources/App/TabCoordinator.swift Tests/DashboardViewControllerClickTests.swift \
  Tests/DashboardOverviewGroupingTests.swift
git commit -m "refactor: expose worktree activity dates to dashboard"
```

Expected: both test classes pass before committing.

### Task 3: Add The Header Menu And Model-Driven Rendering

**Files:**
- Modify: `Sources/UI/Dashboard/DashboardViewController.swift:1595-2225`
- Modify: `Tests/DashboardOverviewGroupingTests.swift`

- [ ] **Step 1: Write failing AppKit tests**

Use an isolated `UserDefaults` suite and injected fixed clock:

```swift
func testMenuLoadsAllModesAndChecksStoredMode() {
    let context = makeView(storedMode: .status)
    defer { context.defaults.removePersistentDomain(forName: context.suite) }
    XCTAssertEqual(context.view.groupingMenuTitlesForTesting,
                   ["Group by Repository", "Group by Status", "Group by Time"])
    XCTAssertEqual(context.view.checkedGroupingModeForTesting, .status)
}

func testChoosingStatusPersistsRegroupsAndKeepsSelection() {
    let context = makeView(storedMode: .repository)
    defer { context.defaults.removePersistentDomain(forName: context.suite) }
    let view = context.view
    view.selectedId = "run"
    view.update([
        makeSailor(id: "idle", path: "/a/idle", project: "a", statuses: [.idle]),
        makeSailor(id: "run", path: "/b/run", project: "b", statuses: [.running]),
        makeSailor(id: "wait", path: "/a/wait", project: "a", statuses: [.waiting]),
    ])
    view.selectGroupingModeForTesting(.status)
    XCTAssertEqual(view.renderedGroupTitlesForTesting, ["Needs input", "Running", "Idle"])
    XCTAssertEqual(view.orderedRows.map(\.id), ["wait", "run", "idle"])
    XCTAssertEqual(context.defaults.string(forKey: WorktreeGroupingPreference.key), "status")
    XCTAssertEqual(view.selectedRowIDForTesting, "run")
}

func testInvalidStoredModeStartsInRepositoryMode() {
    let context = makeView(rawStoredMode: "broken")
    defer { context.defaults.removePersistentDomain(forName: context.suite) }
    XCTAssertEqual(context.view.groupingModeForTesting, .repository)
}
```

- [ ] **Step 2: Run RED**

Run the Task 2 focused command. Expected: compilation fails because the injectable initializer and testing accessors are missing.

- [ ] **Step 3: Add the button, native menu, and preference injection**

In `DashboardOverviewView`:

- Store `latestSailors`, an injected `() -> Date`, `WorktreeGroupingPreference`, and its loaded mode.
- Keep `override init(frame:)` and `required init?(coder:)` on standard defaults; add an internal `init(frame:defaults:now:)` for tests.
- Create an unbordered `NSButton` using `rectangle.3.group`, falling back to `☷`.
- Add a flexible spacer and the button after `headerSub`; constrain the header row to both 15-point horizontal insets.
- Build a native `NSMenu` with `Group by Repository`, `Group by Status`, and `Group by Time`; store each raw mode in `representedObject`, check only the active item, and assign no key equivalents.
- On selection, save the mode, update checks plus tooltip/accessibility text, render `latestSailors`, reveal the selected row, and call a new `onGroupingChanged` closure.

- [ ] **Step 4: Replace inline repo grouping with the pure model**

In the renderer, build and group items exactly once:

```swift
let sailorsByPath = Dictionary(uniqueKeysWithValues: sailors.map { ($0.worktreePath, $0) })
let items = sailors.map { $0.groupingItem(creationDate: Self.creationDate($0.worktreePath)) }
let groups = WorktreeGrouping.groups(items, mode: groupingMode, now: now())
```

For each model group, render a header and existing `RowView`, then append `(id, path)` to `orderedRows`. Repository/time headers use neutral `inkDim`; status headers reuse `groupMeta` glyph/color/label. Track row views by ID so only a mode-triggered render calls `scrollToVisible` for the selected row. Expose internal read-only testing accessors used above.

- [ ] **Step 5: Re-anchor keyboard focus after regrouping**

During `DashboardViewController` setup, add:

```swift
overviewView.onGroupingChanged = { [weak self] in self?.syncOverviewFocusCounts() }
```

This reuses the controller's existing ID/path anchor instead of introducing another focus model.

- [ ] **Step 6: Run GREEN and commit**

```bash
xcodebuild -project seahelm.xcodeproj -scheme seahelmTests -configuration Debug test \
  -only-testing:seahelmTests/WorktreeGroupingTests \
  -only-testing:seahelmTests/DashboardOverviewGroupingTests \
  -only-testing:seahelmTests/OverviewFocusModelTests \
  -skipPackagePluginValidation -skipMacroValidation
git add Sources/UI/Dashboard/DashboardViewController.swift Tests/DashboardOverviewGroupingTests.swift
git commit -m "feat: switch First Mate worktree grouping"
```

Expected: all three focused test classes pass before committing.

### Task 4: Regression And Visual Verification

**Files:**
- Modify only `seahelm.xcodeproj/project.pbxproj` if XcodeGen registers new files.

- [ ] **Step 1: Regenerate and inspect project membership**

```bash
xcodegen generate
git status --short
```

Expected: successful generation. Keep a project-file change only when it registers the new source/test files.

- [ ] **Step 2: Run the full unit suite and build**

```bash
xcodebuild -project seahelm.xcodeproj -scheme seahelmTests -configuration Debug test \
  -skipPackagePluginValidation -skipMacroValidation
xcodebuild -project seahelm.xcodeproj -scheme seahelm -configuration Debug build \
  -skipPackagePluginValidation -skipMacroValidation
```

Expected: `** TEST SUCCEEDED **` and `** BUILD SUCCEEDED **`. If Ghostty linking fails, preserve the exact output and report the infrastructure blocker without claiming success.

- [ ] **Step 3: Verify the UI manually**

Launch the debug app and confirm the right-aligned icon, native menu checkmark, unchanged repository order, approved status/time ordering, selected-row visibility across switches, restart persistence, and readable light/dark appearances.

- [ ] **Step 4: Inspect and finish the diff**

```bash
git diff --check
git status --short
git diff --stat origin/main...HEAD
```

If XcodeGen changed only project membership:

```bash
git add seahelm.xcodeproj/project.pbxproj
git commit -m "chore: register worktree grouping sources"
```

Expected: no Ghostty artifacts, build outputs, or `.superpowers/brainstorm` files are tracked.
