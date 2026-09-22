import XCTest
@testable import seahelm

/// The rule both `ClaudeHooksSetup` and `CodexHooksSetup` install through. Each
/// installer keeps its own tests for its file format; these pin the merge itself.
final class HookEventMergeTests: XCTestCase {

    private let ours: [String: Any] = ["type": "command", "command": "/x/seahelm-hook codex"]
    private let theirs: [String: Any] = ["type": "command", "command": "other-tool-hook"]

    private func commands(_ groups: [[String: Any]]) -> [String] {
        groups.flatMap { ($0["hooks"] as? [[String: Any]]) ?? [] }
            .compactMap { $0["command"] as? String }
    }

    // MARK: - Installing

    func testEmptyEventGetsOurs() throws {
        let merged = try XCTUnwrap(HookEventMerge.merging(event: [], entry: ours))
        XCTAssertEqual(commands(merged), ["/x/seahelm-hook codex"])
    }

    func testForeignEventGetsOursAppended() throws {
        let groups: [[String: Any]] = [["hooks": [theirs]]]
        let merged = try XCTUnwrap(HookEventMerge.merging(event: groups, entry: ours))
        XCTAssertEqual(commands(merged), ["other-tool-hook", "/x/seahelm-hook codex"])
    }

    /// Launch runs this every start, so a settled event must report no change —
    /// otherwise we rewrite the user's config forever, appending as we go.
    func testSettledEventReportsNoChange() {
        let groups: [[String: Any]] = [["hooks": [theirs]], ["hooks": [ours]]]
        XCTAssertNil(HookEventMerge.merging(event: groups, entry: ours))
    }

    // MARK: - Migrating our own

    func testStaleEntryOfOursIsMigratedInPlaceNotDuplicated() throws {
        let stale: [String: Any] = ["type": "http", "url": "http://127.0.0.1:8765/webhook"]
        let groups: [[String: Any]] = [["hooks": [stale]]]
        let merged = try XCTUnwrap(HookEventMerge.merging(event: groups, entry: ours))
        XCTAssertEqual(commands(merged), ["/x/seahelm-hook codex"])
        XCTAssertEqual(merged.count, 1, "migration must not add a second group")
    }

    func testDuplicatesOfOursCollapse() throws {
        let stale: [String: Any] = ["type": "command", "command": "/x/seahelm-hook"]
        let groups: [[String: Any]] = [["hooks": [stale]], ["hooks": [ours]]]
        let merged = try XCTUnwrap(HookEventMerge.merging(event: groups, entry: ours))
        XCTAssertEqual(commands(merged), ["/x/seahelm-hook codex"])
    }

    /// Our entry can sit in a group the user put a matcher on; rewriting the
    /// entry must not drop the rest of the group.
    func testGroupMatcherSurvivesAMigration() throws {
        let stale: [String: Any] = ["type": "command", "command": "/x/seahelm-hook"]
        let groups: [[String: Any]] = [["matcher": "Edit", "hooks": [stale]]]
        let merged = try XCTUnwrap(HookEventMerge.merging(event: groups, entry: ours))
        XCTAssertEqual(merged.first?["matcher"] as? String, "Edit")
    }

    // MARK: - Leaving foreign entries alone

    func testGroupWeCannotReadIsLeftIntact() throws {
        let opaque: [String: Any] = ["hooks": "not-a-list"]
        let merged = try XCTUnwrap(HookEventMerge.merging(event: [opaque], entry: ours))
        XCTAssertEqual(merged.count, 2)
        XCTAssertEqual(merged.first?["hooks"] as? String, "not-a-list")
    }

    func testForeignEntryInTheSameGroupAsOursSurvives() throws {
        let stale: [String: Any] = ["type": "command", "command": "/x/seahelm-hook"]
        let groups: [[String: Any]] = [["hooks": [theirs, stale]]]
        let merged = try XCTUnwrap(HookEventMerge.merging(event: groups, entry: ours))
        XCTAssertEqual(commands(merged), ["other-tool-hook", "/x/seahelm-hook codex"])
    }

    // MARK: - Retiring

    func testRemovingTakesOnlyOurs() throws {
        let groups: [[String: Any]] = [["hooks": [theirs, ours]]]
        let remaining = try XCTUnwrap(HookEventMerge.removing(event: groups))
        XCTAssertEqual(commands(remaining), ["other-tool-hook"])
    }

    func testRemovingEmptiesAnEventThatWasOnlyOurs() throws {
        let remaining = try XCTUnwrap(HookEventMerge.removing(event: [["hooks": [ours]]]))
        XCTAssertTrue(remaining.isEmpty, "caller drops the key on empty")
    }

    func testRemovingReportsNothingWhenNoneOfItIsOurs() {
        XCTAssertNil(HookEventMerge.removing(event: [["hooks": [theirs]]]))
    }
}
