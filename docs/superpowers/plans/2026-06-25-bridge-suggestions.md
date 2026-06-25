# Bridge Suggestions (v1) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let an agent report suggested next steps via a small shell command (`seahelm-suggest`) that POSTs to seahelm's existing webhook, and render those suggestions as clickable buttons in the Bridge panel that send the chosen text back to the agent — with no raw XML in the terminal.

**Architecture:** A new webhook event type `suggest` carries an `options` array. `WebhookStatusProvider` delivers it via an `onSuggestions(worktreePath, options)` callback (no status/session mutation). `TabCoordinator` resolves the agent and updates a new `SuggestionFeed` (a sibling of the existing `WatchFeed`). `BridgePanelViewController` renders a third "Suggestions" section; tapping a chip calls `AgentHead.sendCommand` and clears the feed. A `SeahelmSuggestInstaller` installs the `seahelm-suggest` script at app launch (mirroring `ClaudeStatuslineBridgeInstaller`); `WorktreeCreator` writes a managed instruction block into each new worktree's `CLAUDE.md`/`AGENTS.md`.

**Tech Stack:** Swift 5.10, AppKit (not SwiftUI), XCTest with `@testable import seahelm`, POSIX `/bin/sh` + `curl` for the helper script.

## Global Constraints

- Swift 5.10, macOS 14.0+ (Sonoma), AppKit. No SwiftUI, no Combine for UI updates.
- Tests: XCTest, `@testable import seahelm`, files under `Tests/`, no external test dependencies.
- Build (headless): `xcodebuild -project seahelm.xcodeproj -scheme seahelm -configuration Debug -skipPackagePluginValidation -skipMacroValidation build`
- Run a single test class: `xcodebuild -project seahelm.xcodeproj -scheme seahelmTests -configuration Debug test -only-testing:seahelmTests/<ClassName> -skipPackagePluginValidation -skipMacroValidation`
- Pure logic types have no IO and no singletons; side effects go through injected closures/callbacks.
- All UI and feed objects (`SuggestionFeed`, `BridgePanelViewController`) are main-thread only, matching `WatchFeed`.
- The `Sources/` glob in `project.yml` already covers new files under `Sources/Core`, `Sources/Status`, `Sources/Git` — no `xcodegen` re-run needed unless a test file must be added to the test target glob (the `Tests/` glob already covers new test files).
- Webhook generic payload shape (enforced by `WebhookEvent.parseGeneric`): top-level `source`, `session_id`, `event`, `cwd` are required strings; event-specific data lives under top-level `data`.

---

### Task 1: Add the `suggest` webhook event type

**Files:**
- Modify: `Sources/Status/WebhookEvent.swift:3-38` (add enum case + status mapping)
- Test: `Tests/WebhookSuggestEventTests.swift`

**Interfaces:**
- Consumes: existing `WebhookEvent.parse(from:)`, `WebhookEventType`.
- Produces: `WebhookEventType.suggest` (rawValue `"suggest"`); a parsed `WebhookEvent` whose `data["options"]` is `[String]`.

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import seahelm

final class WebhookSuggestEventTests: XCTestCase {
    func testParsesSuggestEventWithOptions() throws {
        let json = """
        {"source":"seahelm-suggest","session_id":"s1","event":"suggest",
         "cwd":"/repo/feat-x","data":{"options":["run tests","open PR"]}}
        """
        let event = try WebhookEvent.parse(from: Data(json.utf8))
        XCTAssertEqual(event.event, .suggest)
        XCTAssertEqual(event.cwd, "/repo/feat-x")
        XCTAssertEqual(event.data?["options"] as? [String], ["run tests", "open PR"])
    }

    func testSuggestStatusIsUnknown() {
        XCTAssertEqual(WebhookEventType.suggest.agentStatus(data: nil), .unknown)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -project seahelm.xcodeproj -scheme seahelmTests -configuration Debug test -only-testing:seahelmTests/WebhookSuggestEventTests -skipPackagePluginValidation -skipMacroValidation`
Expected: FAIL — `'suggest'` is not a member of `WebhookEventType`.

- [ ] **Step 3: Add the enum case and status mapping**

In `Sources/Status/WebhookEvent.swift`, add the case to the enum (after line 16, `case cwdChanged`):

```swift
    case suggest = "suggest"
```

In the `agentStatus(data:)` switch, add a branch so it stays exhaustive (suggestions never change status; this value is never used because the provider early-returns for `.suggest`):

```swift
        case .suggest:
            return .unknown
```

(No `fromClaudeCode` mapping is needed — `suggest` only arrives via the generic payload path from our own script.)

- [ ] **Step 4: Run test to verify it passes**

Run: same as Step 2.
Expected: PASS (2 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/Status/WebhookEvent.swift Tests/WebhookSuggestEventTests.swift
git commit -m "feat: add 'suggest' webhook event type"
```

---

### Task 2: Deliver suggestions from WebhookStatusProvider

**Files:**
- Modify: `Sources/Status/WebhookStatusProvider.swift:7-17` (add callback), `:43-97` (handle suggest + clear on userPrompt)
- Test: `Tests/WebhookStatusProviderSuggestTests.swift`

**Interfaces:**
- Consumes: `WebhookEventType.suggest` (Task 1), existing `handleEvent(_:)`, `updateWorktrees(_:)`, `matchWorktree`.
- Produces: `var onSuggestions: ((_ worktreePath: String, _ options: [String]) -> Void)?` on `WebhookStatusProvider`. Fired (on the main queue) with the parsed options for a `suggest` event whose `cwd` matches a known worktree, and fired with `[]` for a `userPrompt` event (a new round clears stale suggestions). A `suggest` event does NOT create or mutate any `SessionState` and does NOT change agent status.

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import seahelm

final class WebhookStatusProviderSuggestTests: XCTestCase {
    private func makeEvent(_ type: WebhookEventType, cwd: String, data: [String: Any]?) -> WebhookEvent {
        WebhookEvent(source: "seahelm-suggest", sessionId: "s1", event: type,
                     cwd: cwd, timestamp: nil, data: data)
    }

    func testSuggestFiresCallbackWithOptions() {
        let provider = WebhookStatusProvider()
        provider.updateWorktrees(["/repo/feat-x"])
        let exp = expectation(description: "onSuggestions")
        var received: (String, [String])?
        provider.onSuggestions = { path, options in received = (path, options); exp.fulfill() }

        provider.handleEvent(makeEvent(.suggest, cwd: "/repo/feat-x", data: ["options": ["a", "b"]]))

        wait(for: [exp], timeout: 1.0)
        XCTAssertEqual(received?.0, "/repo/feat-x")
        XCTAssertEqual(received?.1, ["a", "b"])
        // suggest must not create a session / change status
        XCTAssertEqual(provider.status(for: "/repo/feat-x"), .unknown)
    }

    func testSuggestUnknownWorktreeIsIgnored() {
        let provider = WebhookStatusProvider()
        provider.updateWorktrees(["/repo/feat-x"])
        var fired = false
        provider.onSuggestions = { _, _ in fired = true }
        provider.handleEvent(makeEvent(.suggest, cwd: "/somewhere/else", data: ["options": ["a"]]))
        // give the (non-)dispatch a chance to run
        let pause = expectation(description: "pause"); DispatchQueue.main.async { pause.fulfill() }
        wait(for: [pause], timeout: 1.0)
        XCTAssertFalse(fired)
    }

    func testUserPromptClearsSuggestions() {
        let provider = WebhookStatusProvider()
        provider.updateWorktrees(["/repo/feat-x"])
        let exp = expectation(description: "cleared")
        var received: [String]?
        provider.onSuggestions = { _, options in received = options; exp.fulfill() }
        provider.handleEvent(makeEvent(.userPrompt, cwd: "/repo/feat-x", data: ["prompt": "go"]))
        wait(for: [exp], timeout: 1.0)
        XCTAssertEqual(received, [])
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -project seahelm.xcodeproj -scheme seahelmTests -configuration Debug test -only-testing:seahelmTests/WebhookStatusProviderSuggestTests -skipPackagePluginValidation -skipMacroValidation`
Expected: FAIL — `onSuggestions` is not a member.

- [ ] **Step 3: Add the callback and handling**

In `Sources/Status/WebhookStatusProvider.swift`, add the property next to the other callbacks (after line 17):

```swift
    /// Called when a `suggest` event arrives (with parsed options) or when a
    /// new round begins (with `[]` to clear). Fired on the main queue.
    var onSuggestions: ((_ worktreePath: String, _ options: [String]) -> Void)?
```

Inside `handleEvent(_:)`, immediately after `let canonCwd = canonicalize(event.cwd)` (line 45), add the suggest short-circuit:

```swift
            // Suggestions: deliver options out-of-band; never touch sessions/status.
            if event.event == .suggest {
                guard let worktreePath = matchWorktree(canonCwd) else { return }
                let options = (event.data?["options"] as? [String]) ?? []
                DispatchQueue.main.async { [weak self] in
                    self?.onSuggestions?(worktreePath, options)
                }
                return
            }
```

Then, after the existing `guard let worktreePath = matchWorktree(canonCwd) else { ... }` block (the one ending at line 97), add the clear-on-new-round hook:

```swift
            // A new user prompt starts a fresh round — clear any stale suggestions.
            if event.event == .userPrompt {
                DispatchQueue.main.async { [weak self] in
                    self?.onSuggestions?(worktreePath, [])
                }
            }
```

- [ ] **Step 4: Run test to verify it passes**

Run: same as Step 2.
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/Status/WebhookStatusProvider.swift Tests/WebhookStatusProviderSuggestTests.swift
git commit -m "feat: WebhookStatusProvider delivers suggest options via onSuggestions"
```

---

### Task 3: SuggestionFeed model

**Files:**
- Create: `Sources/Core/SuggestionFeed.swift`
- Test: `Tests/SuggestionFeedTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `struct SuggestionItem: Equatable, Identifiable { let id: String; let worktreePath: String; let branch: String; let terminalID: String; let options: [String]; let seq: Int }`
  - `final class SuggestionFeed` with:
    - `var onChange: (() -> Void)?`
    - `func set(worktreePath: String, branch: String, terminalID: String, options: [String])` — upsert by `worktreePath`; empty `options` removes the entry; fires `onChange` only when the stored options actually change.
    - `func all() -> [SuggestionItem]` — newest-first (highest `seq` first).
    - `func clear(worktreePath: String)` — remove the entry for a worktree; fires `onChange` if something was removed.

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
@testable import seahelm

final class SuggestionFeedTests: XCTestCase {
    func testSetAddsItemAndFiresChange() {
        let feed = SuggestionFeed()
        var changes = 0
        feed.onChange = { changes += 1 }
        feed.set(worktreePath: "/w", branch: "feat-x", terminalID: "t1", options: ["a", "b"])
        XCTAssertEqual(feed.all().count, 1)
        XCTAssertEqual(feed.all().first?.options, ["a", "b"])
        XCTAssertEqual(feed.all().first?.terminalID, "t1")
        XCTAssertEqual(changes, 1)
    }

    func testSetSameOptionsDoesNotFireChange() {
        let feed = SuggestionFeed()
        feed.set(worktreePath: "/w", branch: "b", terminalID: "t", options: ["a"])
        var changes = 0
        feed.onChange = { changes += 1 }
        feed.set(worktreePath: "/w", branch: "b", terminalID: "t", options: ["a"])
        XCTAssertEqual(changes, 0)
    }

    func testEmptyOptionsRemoves() {
        let feed = SuggestionFeed()
        feed.set(worktreePath: "/w", branch: "b", terminalID: "t", options: ["a"])
        feed.set(worktreePath: "/w", branch: "b", terminalID: "t", options: [])
        XCTAssertTrue(feed.all().isEmpty)
    }

    func testClearRemovesAndFires() {
        let feed = SuggestionFeed()
        feed.set(worktreePath: "/w", branch: "b", terminalID: "t", options: ["a"])
        var changes = 0
        feed.onChange = { changes += 1 }
        feed.clear(worktreePath: "/w")
        XCTAssertTrue(feed.all().isEmpty)
        XCTAssertEqual(changes, 1)
    }

    func testAllIsNewestFirst() {
        let feed = SuggestionFeed()
        feed.set(worktreePath: "/w1", branch: "b1", terminalID: "t1", options: ["a"])
        feed.set(worktreePath: "/w2", branch: "b2", terminalID: "t2", options: ["b"])
        XCTAssertEqual(feed.all().map { $0.worktreePath }, ["/w2", "/w1"])
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild -project seahelm.xcodeproj -scheme seahelmTests -configuration Debug test -only-testing:seahelmTests/SuggestionFeedTests -skipPackagePluginValidation -skipMacroValidation`
Expected: FAIL — `SuggestionFeed` not found.

- [ ] **Step 3: Write the implementation**

```swift
import Foundation

struct SuggestionItem: Equatable, Identifiable {
    let id: String          // == worktreePath
    let worktreePath: String
    let branch: String
    let terminalID: String
    let options: [String]
    /// Monotonically increasing; higher = newer.
    let seq: Int
}

/// Per-agent live suggestion chips, newest-first. Main-thread only.
/// Mirrors WatchFeed's shape so the Bridge panel can observe it the same way.
final class SuggestionFeed {
    private var items: [SuggestionItem] = []
    private var counter = 0
    var onChange: (() -> Void)?

    func set(worktreePath: String, branch: String, terminalID: String, options: [String]) {
        if options.isEmpty {
            clear(worktreePath: worktreePath)
            return
        }
        if let existing = items.first(where: { $0.id == worktreePath }), existing.options == options {
            return // no change
        }
        counter += 1
        let item = SuggestionItem(id: worktreePath, worktreePath: worktreePath, branch: branch,
                                  terminalID: terminalID, options: options, seq: counter)
        if let idx = items.firstIndex(where: { $0.id == worktreePath }) {
            items[idx] = item
        } else {
            items.append(item)
        }
        onChange?()
    }

    func all() -> [SuggestionItem] {
        items.sorted { $0.seq > $1.seq }
    }

    func clear(worktreePath: String) {
        let before = items.count
        items.removeAll { $0.id == worktreePath }
        if items.count != before { onChange?() }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: same as Step 2.
Expected: PASS (5 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/Core/SuggestionFeed.swift Tests/SuggestionFeedTests.swift
git commit -m "feat: SuggestionFeed store mirroring WatchFeed"
```

---

### Task 4: `seahelm-suggest` script installer

**Files:**
- Create: `Sources/Core/SeahelmSuggestInstaller.swift`
- Test: `Tests/SeahelmSuggestInstallerTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `enum SeahelmSuggestInstaller` with:
    - `static func scriptContents(port: UInt16) -> String` — the full `/bin/sh` script text (pure, testable).
    - `@discardableResult static func ensureInstalled(binDirectory: URL, port: UInt16) -> Bool` — writes the script to `binDirectory/seahelm-suggest`, `chmod 0755`, creating the dir; returns true if written/updated. Idempotent: skips rewrite if the existing file already contains the current version marker.
    - `@discardableResult static func ensureInstalled(port: UInt16) -> Bool` — convenience using `~/.local/bin`.

**Note on the script:** it takes each CLI arg as one option string and POSTs `{"source":"seahelm-suggest","session_id":"cli","event":"suggest","cwd":"$PWD","data":{"options":[...]}}` to `http://127.0.0.1:<port>/webhook`. Options are JSON-escaped with `sed` (backslash then double-quote). Port is overridable via `SEAHELM_WEBHOOK_PORT`. The script always exits 0 so it never blocks the agent. A version marker comment lets the installer detect stale copies.

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
@testable import seahelm

final class SeahelmSuggestInstallerTests: XCTestCase {
    func testScriptContainsPortMarkerAndEndpoint() {
        let script = SeahelmSuggestInstaller.scriptContents(port: 7070)
        XCTAssertTrue(script.contains("seahelm-suggest v1"))          // version marker
        XCTAssertTrue(script.contains("SEAHELM_WEBHOOK_PORT:-7070"))   // default port w/ override
        XCTAssertTrue(script.contains("/webhook"))
        XCTAssertTrue(script.contains("\"event\":\"suggest\""))
        XCTAssertTrue(script.hasPrefix("#!/bin/sh"))
    }

    func testInstallWritesExecutableScript() throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("seahelm-suggest-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }

        let wrote = SeahelmSuggestInstaller.ensureInstalled(binDirectory: tmp, port: 7070)
        XCTAssertTrue(wrote)

        let scriptPath = tmp.appendingPathComponent("seahelm-suggest").path
        XCTAssertTrue(FileManager.default.fileExists(atPath: scriptPath))
        let attrs = try FileManager.default.attributesOfItem(atPath: scriptPath)
        let perms = (attrs[.posixPermissions] as? NSNumber)?.intValue ?? 0
        XCTAssertEqual(perms & 0o111, 0o111) // executable bits set

        // Idempotent: second run with same version does not rewrite.
        let wroteAgain = SeahelmSuggestInstaller.ensureInstalled(binDirectory: tmp, port: 7070)
        XCTAssertFalse(wroteAgain)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild -project seahelm.xcodeproj -scheme seahelmTests -configuration Debug test -only-testing:seahelmTests/SeahelmSuggestInstallerTests -skipPackagePluginValidation -skipMacroValidation`
Expected: FAIL — `SeahelmSuggestInstaller` not found.

- [ ] **Step 3: Write the implementation**

```swift
import Foundation

enum SeahelmSuggestInstaller {
    private static let versionMarker = "# seahelm-suggest v1"

    static func scriptContents(port: UInt16) -> String {
        return """
        #!/bin/sh
        \(versionMarker) — managed by seahelm. Do not edit; it is overwritten on launch.
        # Usage: seahelm-suggest "option one" "option two" ...
        # Reports suggested next steps to seahelm; shows as one tool-call line, never raw XML.
        set -u
        port="${SEAHELM_WEBHOOK_PORT:-\(port)}"

        esc() { printf '%s' "$1" | sed 's/\\\\/\\\\\\\\/g; s/"/\\\\"/g'; }

        opts=""
        for arg in "$@"; do
          item="\\"$(esc "$arg")\\""
          if [ -z "$opts" ]; then opts="$item"; else opts="$opts,$item"; fi
        done

        cwd="$(esc "$PWD")"
        body="{\\"source\\":\\"seahelm-suggest\\",\\"session_id\\":\\"cli\\",\\"event\\":\\"suggest\\",\\"cwd\\":\\"$cwd\\",\\"data\\":{\\"options\\":[$opts]}}"

        curl -s -m 2 -X POST "http://127.0.0.1:$port/webhook" \\
          -H "Content-Type: application/json" \\
          -d "$body" >/dev/null 2>&1 || true
        exit 0
        """
    }

    @discardableResult
    static func ensureInstalled(port: UInt16 = 7070) -> Bool {
        let bin = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin")
        return ensureInstalled(binDirectory: bin, port: port)
    }

    @discardableResult
    static func ensureInstalled(binDirectory: URL, port: UInt16) -> Bool {
        let scriptURL = binDirectory.appendingPathComponent("seahelm-suggest")
        let desired = scriptContents(port: port)

        // Skip if an up-to-date copy already exists.
        if let existing = try? String(contentsOf: scriptURL, encoding: .utf8),
           existing.contains(versionMarker), existing == desired {
            return false
        }

        do {
            try FileManager.default.createDirectory(at: binDirectory, withIntermediateDirectories: true)
            try desired.write(to: scriptURL, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
            return true
        } catch {
            NSLog("[SeahelmSuggestInstaller] Failed to install: \(error)")
            return false
        }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: same as Step 2.
Expected: PASS (2 tests).

- [ ] **Step 5: Manually sanity-check the generated script runs**

Run:
```bash
swift -e 'print("noop")' >/dev/null 2>&1 || true   # placeholder; real check below
```
Then, after a Debug build that includes the new file, the script is exercised end-to-end in Task 7's smoke test. For now just confirm shell syntax by writing the rendered script to a temp file and running `sh -n`:
```bash
cat > /tmp/seahelm-suggest-check.sh <<'EOF'
#!/bin/sh
# (paste the rendered scriptContents(port:7070) here only if hand-verifying)
EOF
sh -n /tmp/seahelm-suggest-check.sh && echo "syntax OK"
```
Expected: `syntax OK` (optional manual check; the unit tests are the gate).

- [ ] **Step 6: Commit**

```bash
git add Sources/Core/SeahelmSuggestInstaller.swift Tests/SeahelmSuggestInstallerTests.swift
git commit -m "feat: install seahelm-suggest helper script at launch"
```

---

### Task 5: Inject the suggest guidance into new worktrees

**Files:**
- Create: `Sources/Git/SuggestGuidanceWriter.swift`
- Modify: `Sources/Git/WorktreeCreator.swift:97-104` (call the writer after the worktree is created)
- Test: `Tests/SuggestGuidanceWriterTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `enum SuggestGuidanceWriter` with:
    - `static func managedBlock() -> String` — the marker-delimited instruction block (pure).
    - `static func upsert(into fileURL: URL)` — inserts the block if absent, replaces it in place if present (idempotent), preserving all surrounding content. Creates the file if missing.
    - `static func writeForWorktree(_ worktreePath: String)` — upserts into both `CLAUDE.md` and `AGENTS.md` at the worktree root.

**Note:** markers are `<!-- seahelm:suggest:start -->` and `<!-- seahelm:suggest:end -->`. Each agent reads only its own file, so writing both is safe.

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
@testable import seahelm

final class SuggestGuidanceWriterTests: XCTestCase {
    private func tempFile() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("guidance-\(UUID().uuidString).md")
    }

    func testInsertsIntoNewFile() throws {
        let url = tempFile(); defer { try? FileManager.default.removeItem(at: url) }
        SuggestGuidanceWriter.upsert(into: url)
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(text.contains("<!-- seahelm:suggest:start -->"))
        XCTAssertTrue(text.contains("seahelm-suggest"))
        XCTAssertTrue(text.contains("<!-- seahelm:suggest:end -->"))
    }

    func testPreservesUserContentAndIsIdempotent() throws {
        let url = tempFile(); defer { try? FileManager.default.removeItem(at: url) }
        try "# My Project\n\nHello.\n".write(to: url, atomically: true, encoding: .utf8)

        SuggestGuidanceWriter.upsert(into: url)
        SuggestGuidanceWriter.upsert(into: url) // second run must not duplicate

        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(text.contains("# My Project"))
        XCTAssertTrue(text.contains("Hello."))
        let starts = text.components(separatedBy: "<!-- seahelm:suggest:start -->").count - 1
        XCTAssertEqual(starts, 1) // exactly one managed block
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild -project seahelm.xcodeproj -scheme seahelmTests -configuration Debug test -only-testing:seahelmTests/SuggestGuidanceWriterTests -skipPackagePluginValidation -skipMacroValidation`
Expected: FAIL — `SuggestGuidanceWriter` not found.

- [ ] **Step 3: Write the implementation**

```swift
import Foundation

enum SuggestGuidanceWriter {
    private static let startMarker = "<!-- seahelm:suggest:start -->"
    private static let endMarker = "<!-- seahelm:suggest:end -->"

    static func managedBlock() -> String {
        return """
        \(startMarker)
        ## Quick options for the user (seahelm)

        When you finish a turn and can anticipate the user's likely next steps, run:

            seahelm-suggest 'first option' 'second option'

        Each option is a short imperative phrase (max ~5 options). Do NOT print options
        as text in your reply — the user sees them as clickable buttons in seahelm.
        \(endMarker)
        """
    }

    static func upsert(into fileURL: URL) {
        let block = managedBlock()
        let existing = (try? String(contentsOf: fileURL, encoding: .utf8)) ?? ""

        let updated: String
        if let startRange = existing.range(of: startMarker),
           let endRange = existing.range(of: endMarker),
           startRange.lowerBound < endRange.lowerBound {
            // Replace the existing managed block in place.
            updated = existing.replacingCharacters(in: startRange.lowerBound..<endRange.upperBound, with: block)
        } else if existing.isEmpty {
            updated = block + "\n"
        } else {
            let separator = existing.hasSuffix("\n") ? "\n" : "\n\n"
            updated = existing + separator + block + "\n"
        }

        try? updated.write(to: fileURL, atomically: true, encoding: .utf8)
    }

    static func writeForWorktree(_ worktreePath: String) {
        let root = URL(fileURLWithPath: worktreePath)
        for name in ["CLAUDE.md", "AGENTS.md"] {
            upsert(into: root.appendingPathComponent(name))
        }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: same as Step 2.
Expected: PASS (2 tests).

- [ ] **Step 5: Call the writer from WorktreeCreator**

In `Sources/Git/WorktreeCreator.swift`, inside `createWorktree`, just before `return WorktreeInfo(...)` (line 98), add:

```swift
        SuggestGuidanceWriter.writeForWorktree(worktreePath)
```

- [ ] **Step 6: Build to confirm it compiles**

Run: `xcodebuild -project seahelm.xcodeproj -scheme seahelm -configuration Debug -skipPackagePluginValidation -skipMacroValidation build`
Expected: BUILD SUCCEEDED.

- [ ] **Step 7: Commit**

```bash
git add Sources/Git/SuggestGuidanceWriter.swift Sources/Git/WorktreeCreator.swift Tests/SuggestGuidanceWriterTests.swift
git commit -m "feat: inject seahelm-suggest guidance into new worktrees"
```

---

### Task 6: Wire delivery (provider → feed) and install at launch

**Files:**
- Modify: `Sources/App/TabCoordinator.swift:38-39` (own the feed), `:401-418` (wire `onSuggestions`)
- Modify: `Sources/App/AppDelegate.swift:27-29` (install the script)

**Interfaces:**
- Consumes: `SuggestionFeed` (Task 3), `WebhookStatusProvider.onSuggestions` (Task 2), `SeahelmSuggestInstaller` (Task 4), `AgentHead.shared.agent(forWorktree:)` (existing → `AgentInfo` with `id`, `branch`).
- Produces: `TabCoordinator.suggestionFeed: SuggestionFeed` (public, consumed by Task 7).

- [ ] **Step 1: Add the feed property**

In `Sources/App/TabCoordinator.swift`, next to the other First Mate stores (after line 39, `let watchFeed = WatchFeed()`):

```swift
    let suggestionFeed = SuggestionFeed()
```

- [ ] **Step 2: Wire the provider callback**

In `Sources/App/TabCoordinator.swift`, next to the existing `self.statusPublisher.webhookProvider.onNewWorktreeDetected = ...` wiring (around line 403), add:

```swift
                    self.statusPublisher.webhookProvider.onSuggestions = { [weak self] worktreePath, options in
                        guard let self else { return }
                        let agent = AgentHead.shared.agent(forWorktree: worktreePath)
                        self.suggestionFeed.set(
                            worktreePath: worktreePath,
                            branch: agent?.branch ?? "",
                            terminalID: agent?.id ?? "",
                            options: options
                        )
                    }
```

(The callback already arrives on the main queue from `WebhookStatusProvider`, so `suggestionFeed` is touched on main.)

- [ ] **Step 3: Install the script at launch**

In `Sources/App/AppDelegate.swift`, next to the existing setup calls (after line 29, `CodexHooksSetup.ensureHooksConfigured(...)`):

```swift
            SeahelmSuggestInstaller.ensureInstalled(port: config.webhook.port)
```

- [ ] **Step 4: Build**

Run: `xcodebuild -project seahelm.xcodeproj -scheme seahelm -configuration Debug -skipPackagePluginValidation -skipMacroValidation build`
Expected: BUILD SUCCEEDED.

- [ ] **Step 5: Commit**

```bash
git add Sources/App/TabCoordinator.swift Sources/App/AppDelegate.swift
git commit -m "feat: wire suggest delivery to SuggestionFeed and install helper at launch"
```

---

### Task 7: Suggestions section in the Bridge panel

**Files:**
- Modify: `Sources/UI/SidePanel/BridgePanelViewController.swift` (add a third section + chip cell + tap handling)
- Modify: `Sources/App/MainWindowController.swift:402-409` (inject feed + tap handler)

**Interfaces:**
- Consumes: `SuggestionFeed`/`SuggestionItem` (Task 3), `TabCoordinator.suggestionFeed` (Task 6), `AgentHead.shared.sendCommand(to:command:)` (existing).
- Produces: `BridgePanelViewController.suggestionFeed: SuggestionFeed?`, `BridgePanelViewController.onSuggestionTapped: ((SuggestionItem, String) -> Void)?`.

**Note:** Each `SuggestionItem` holds N options for one agent. Render one row per `(item, option)` pair so each chip is independently clickable. The section hides (zero rows) when the feed is empty.

- [ ] **Step 1: Add feed property, tap handler, flattened rows, and section views**

In `BridgePanelViewController`, add near the other injected feeds (after line 14, `var onApprove`):

```swift
    var suggestionFeed: SuggestionFeed? {
        didSet { rebindSuggestions() }
    }
    var onSuggestionTapped: ((SuggestionItem, String) -> Void)?
```

Add private state next to `watchItems` (after line 20):

```swift
    /// Flattened (item, option) pairs, one per rendered chip row.
    private var suggestionRows: [(item: SuggestionItem, option: String)] = []
```

Add the section views next to the watch views (after line 32):

```swift
    private let suggestHeader = NSTextField(labelWithString: "Suggestions")
    private let suggestTableView = NSTableView()
    private let suggestScrollView = NSScrollView()
```

In `loadView()`, after `setupWatchSection()` (line 66), add:

```swift
        setupSuggestSection()
```

Add the setup method (mirroring `setupWatchSection`, tag = 3, after the `setupWatchSection()` method, before `makeSectionContainer`):

```swift
    private func setupSuggestSection() {
        suggestHeader.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        suggestHeader.textColor = Theme.textSecondary
        suggestHeader.translatesAutoresizingMaskIntoConstraints = false

        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("SuggestCol"))
        col.title = ""
        suggestTableView.addTableColumn(col)
        suggestTableView.headerView = nil
        suggestTableView.rowHeight = 26
        suggestTableView.dataSource = self
        suggestTableView.delegate = self
        suggestTableView.tag = 3
        suggestTableView.setAccessibilityIdentifier("bridge.suggestTable")
        suggestTableView.allowsEmptySelection = true
        suggestTableView.backgroundColor = .clear

        suggestScrollView.documentView = suggestTableView
        suggestScrollView.drawsBackground = false
        suggestScrollView.hasVerticalScroller = true
        suggestScrollView.autohidesScrollers = true
        suggestScrollView.translatesAutoresizingMaskIntoConstraints = false
        suggestTableView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle

        addFullWidthArranged(makeDivider())
        let section = makeSectionContainer(header: suggestHeader, scroll: suggestScrollView, minHeight: 60)
        addFullWidthArranged(section)
    }
```

- [ ] **Step 2: Add binding + reload for suggestions**

Add next to `rebindWatch()` (after line 191):

```swift
    private func rebindSuggestions() {
        suggestionFeed?.onChange = { [weak self] in
            DispatchQueue.main.async { self?.reloadSuggestions() }
        }
        if isViewLoaded { reloadSuggestions() }
    }

    private func reloadSuggestions() {
        let items = suggestionFeed?.all() ?? []
        suggestionRows = items.flatMap { item in item.options.map { (item, $0) } }
        suggestHeader.stringValue = suggestionRows.isEmpty ? "Suggestions" : "Suggestions · \(suggestionRows.count)"
        suggestTableView.reloadData()
    }
```

- [ ] **Step 3: Extend the data source/delegate for tag 3**

In `numberOfRows(in:)` (line 287-289), replace the body so tag 3 is handled:

```swift
    func numberOfRows(in tableView: NSTableView) -> Int {
        switch tableView.tag {
        case 1: return pendingOrders.count
        case 3: return suggestionRows.count
        default: return watchItems.count
        }
    }
```

In `tableView(_:viewFor:row:)`, add a branch for tag 3 at the top of the method (before the `if tableView.tag == 1` block at line 292):

```swift
        if tableView.tag == 3 {
            guard row < suggestionRows.count else { return nil }
            let pair = suggestionRows[row]
            let id = NSUserInterfaceItemIdentifier("SuggestCell")
            let cell: SuggestionCellView
            if let reused = tableView.makeView(withIdentifier: id, owner: self) as? SuggestionCellView {
                cell = reused
            } else {
                cell = SuggestionCellView()
                cell.identifier = id
            }
            cell.configure(branch: pair.item.branch, option: pair.option,
                           onTap: { [weak self] in self?.onSuggestionTapped?(pair.item, pair.option) })
            return cell
        }
```

- [ ] **Step 4: Add the SuggestionCellView**

After `WatchCellView` (end of file, after line 465), add:

```swift
// MARK: - SuggestionCellView

private final class SuggestionCellView: NSTableCellView {
    private let branchLabel = NSTextField(labelWithString: "")
    private let button = NSButton()
    private var onTap: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        setup()
    }
    required init?(coder: NSCoder) { fatalError() }

    private func setup() {
        branchLabel.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .medium)
        branchLabel.textColor = Theme.textSecondary
        branchLabel.lineBreakMode = .byTruncatingTail
        branchLabel.translatesAutoresizingMaskIntoConstraints = false

        button.bezelStyle = .rounded
        button.controlSize = .small
        button.font = NSFont.systemFont(ofSize: 11)
        button.lineBreakMode = .byTruncatingTail
        button.target = self
        button.action = #selector(tapped)
        button.translatesAutoresizingMaskIntoConstraints = false

        addSubview(branchLabel)
        addSubview(button)

        NSLayoutConstraint.activate([
            branchLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            branchLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            branchLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 90),

            button.leadingAnchor.constraint(equalTo: branchLabel.trailingAnchor, constant: 6),
            button.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -6),
            button.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    func configure(branch: String, option: String, onTap: @escaping () -> Void) {
        self.onTap = onTap
        branchLabel.stringValue = branch
        button.title = option
        button.toolTip = option
    }

    @objc private func tapped() { onTap?() }
}
```

- [ ] **Step 5: Inject the feed and tap handler from MainWindowController**

In `Sources/App/MainWindowController.swift`, next to the existing side-panel wiring (after line 403, `dashboard.sidePanelVC.watchFeed = tabCoordinator.watchFeed`), add:

```swift
        dashboard.sidePanelVC.suggestionFeed = tabCoordinator.suggestionFeed
        dashboard.sidePanelVC.onSuggestionTapped = { [weak self] item, optionText in
            AgentHead.shared.sendCommand(to: item.terminalID, command: optionText)
            self?.tabCoordinator.suggestionFeed.clear(worktreePath: item.worktreePath)
        }
```

- [ ] **Step 6: Build**

Run: `xcodebuild -project seahelm.xcodeproj -scheme seahelm -configuration Debug -skipPackagePluginValidation -skipMacroValidation build`
Expected: BUILD SUCCEEDED.

- [ ] **Step 7: Manual smoke test**

1. Launch seahelm; open a worktree with a running agent.
2. In that worktree's terminal, run: `seahelm-suggest 'run tests' 'open PR'`
   (confirm `~/.local/bin` is on PATH; the run shows one clean line, no raw XML).
3. Two buttons labeled `run tests` / `open PR` appear in the Bridge "Suggestions" section, tagged with the branch.
4. Click `run tests` → the agent's terminal receives `run tests` as input; the chips clear.
5. Send any new prompt to the agent → the Suggestions section clears automatically.

- [ ] **Step 8: Commit**

```bash
git add Sources/UI/SidePanel/BridgePanelViewController.swift Sources/App/MainWindowController.swift
git commit -m "feat: Bridge Suggestions section with clickable agent chips"
```

---

## Self-Review

**Spec coverage:**
- Agent reports next steps without raw XML → Task 4 (`seahelm-suggest`) + Task 5 (guidance tells the model to use it, not print). ✓
- Receive out-of-band + store per agent → Task 1 (event) + Task 2 (delivery) + Task 3 (`SuggestionFeed`). ✓ (Refinement vs spec: suggestions live in a dedicated `SuggestionFeed` that mirrors `WatchFeed`, instead of an `AgentInfo.options` field. This fits the Bridge's existing feed-injection architecture — the panel already observes `WatchFeed`/`PendingOrdersQueue` the same way — and avoids threading options through the 2s status poll. Functionally equivalent; better-bounded.)
- Render clickable buttons; click sends + clears → Task 7 (`SuggestionCellView`, `onSuggestionTapped`). ✓
- Auto-clear on new round → Task 2 (`userPrompt` → fire `[]`) + `SuggestionFeed.clear`. ✓
- Works for seahelm- and user-launched agents → Task 5 writes worktree `CLAUDE.md`/`AGENTS.md` (read on every launch regardless of who starts the agent); Task 4 installs the script globally on PATH. ✓
- Codex best-effort → Task 5 writes `AGENTS.md` too; script is agent-agnostic shell. ✓

**Placeholder scan:** None. Task 4 Step 5 is an optional manual shell-syntax check clearly marked as non-gating (unit tests are the gate); all code steps carry full code.

**Type consistency:** `SuggestionItem`/`SuggestionFeed.set(worktreePath:branch:terminalID:options:)`/`all()`/`clear(worktreePath:)` are used identically in Tasks 3, 6, 7. `WebhookStatusProvider.onSuggestions: (String, [String]) -> Void` matches between Task 2 (definition) and Task 6 (use). `onSuggestionTapped: (SuggestionItem, String) -> Void` matches between Task 7's definition and MainWindowController use. `SeahelmSuggestInstaller.ensureInstalled(port:)` and `scriptContents(port:)` match Tasks 4 and 6. `SuggestGuidanceWriter.writeForWorktree(_:)`/`upsert(into:)`/`managedBlock()` match Task 5 internally and the `WorktreeCreator` call site.

**Scope check:** Single subsystem (agent self-report → Bridge buttons). The LLM observer (C) is explicitly out of scope per the spec and not referenced by any task. Suitable for one implementation pass.
