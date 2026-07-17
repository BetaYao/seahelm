# Auto Update Download Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Automatically download detected Seahelm updates and prompt the user to restart when ready.

**Architecture:** Add a small seam around update downloading so `UpdateCoordinator` can be tested without real network downloads. Route both polling and manual update discovery through one `beginUpdateFlow(release:)` method that records the pending release, shows the banner, and starts the download once per version.

**Tech Stack:** Swift 5.10, XCTest, AppKit, existing `UpdateChecker`, `UpdateManager`, and `UpdateBanner` classes.

---

## File Structure

- Modify: `Sources/App/UpdateCoordinator.swift` — add downloader protocol seam and automatic download orchestration.
- Modify: `Tests/UpdateCoordinatorTests.swift` — add fakes and tests for automatic download, duplicate suppression, manual checks, retry, and skip.

### Task 1: Add Test Seam And Auto Download Tests

**Files:**
- Modify: `Tests/UpdateCoordinatorTests.swift`
- Modify: `Sources/App/UpdateCoordinator.swift`

- [ ] **Step 1: Write failing tests**

Add tests that construct `UpdateCoordinator(config:updateChecker:updateManager:banner:)` with fake objects. Cover:

```swift
func testDidFindReleaseAutomaticallyStartsDownload()
func testDidFindSameReleaseDoesNotStartDuplicateDownload()
func testRetryDownloadsPendingReleaseAgain()
func testSkipClearsPendingReleaseAndPreventsDownload()
```

Expected assertions:

```swift
XCTAssertEqual(fakeUpdateManager.downloadedVersions, ["2.1.0"])
XCTAssertEqual(coordinator.pendingRelease?.version, "2.1.0")
XCTAssertEqual(fakeBanner.shownVersions, ["2.1.0"])
```

- [ ] **Step 2: Run focused tests to verify failure**

Run:

```bash
xcodebuild -project seahelm.xcodeproj -scheme seahelmTests -configuration Debug test -only-testing:seahelmTests/UpdateCoordinatorTests -skipPackagePluginValidation -skipMacroValidation
```

Expected: compile failure because `UpdateCoordinator` has no injectable initializer/protocol seam, or assertion failure because discovery does not download automatically.

- [ ] **Step 3: Add minimal implementation**

In `Sources/App/UpdateCoordinator.swift`:

- Introduce `UpdateChecking`, `UpdateDownloading`, and `UpdateBannerDisplaying` protocols.
- Conform `UpdateChecker`, `UpdateManager`, and `UpdateBanner` to those protocols.
- Add an injectable initializer that defaults to production objects.
- Add `private var downloadingVersion: String?`.
- Add `beginUpdateFlow(release:)` that sets `pendingRelease`, calls `banner.showNewVersion`, and calls `updateManager.download(release:)` unless that version is already downloading.
- Update `didFindRelease` and manual `checkForUpdates()` to call `beginUpdateFlow(release:)`.
- Clear `downloadingVersion` when state reaches `.readyToInstall`, `.failed`, or `.idle`.
- Keep `handleSkip(version:)` clearing `pendingRelease`; also clear `downloadingVersion` for that version.

- [ ] **Step 4: Run focused tests to verify pass**

Run the same `xcodebuild ... UpdateCoordinatorTests ...` command.

Expected: all `UpdateCoordinatorTests` pass.

### Task 2: Regression And Project Verification

**Files:**
- No additional source files expected.

- [ ] **Step 1: Run update-related tests**

Run:

```bash
xcodebuild -project seahelm.xcodeproj -scheme seahelmTests -configuration Debug test -only-testing:seahelmTests/UpdateCoordinatorTests -only-testing:seahelmTests/UpdateCheckerTests -skipPackagePluginValidation -skipMacroValidation
```

Expected: update coordinator and checker tests pass.

- [ ] **Step 2: Inspect diff**

Run:

```bash
git diff -- Sources/App/UpdateCoordinator.swift Tests/UpdateCoordinatorTests.swift docs/superpowers/specs/2026-07-17-auto-update-download-design.md docs/superpowers/plans/2026-07-17-auto-update-download.md
```

Expected: diff only contains automatic update download behavior and supporting docs/tests.
