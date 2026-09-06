import XCTest
@testable import seahelm

final class CommandSessionStoreTests: XCTestCase {
    private var dir: URL!

    override func setUp() {
        super.setUp()
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("seahelm-sessions-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
        super.tearDown()
    }

    func testBindPersistsAcrossInstances() {
        let url = dir.appendingPathComponent("sessions.json")
        CommandSessionStore(url: url, legacyMailURL: nil)
            .bind("telegram:1", toPaneKey: "k7", paneId: "b", worktreePath: "/w", commander: "1")
        let reloaded = CommandSessionStore(url: url, legacyMailURL: nil).session(for: "telegram:1")
        XCTAssertEqual(reloaded.boundPaneKey, "k7")
        XCTAssertEqual(reloaded.boundPaneId, "b")
        XCTAssertEqual(reloaded.commander, "1")
        XCTAssertEqual(reloaded.surface, "telegram")
        XCTAssertEqual(reloaded.id, "1")
    }

    func testCloseMarksEveryConversationOnThePane() {
        let store = CommandSessionStore(url: nil, legacyMailURL: nil)
        store.bind("telegram:1", toPaneKey: "k7", paneId: "b", worktreePath: "/w")
        store.bind("mail:t1", toPaneKey: "k7", paneId: "b", worktreePath: "/w", commander: "a@b.c")
        store.bind("mail:t2", toPaneKey: "k3", paneId: "a", worktreePath: "/w")
        XCTAssertEqual(store.sessions(boundToPaneKey: "k7").count, 2)

        let closed = store.close(paneId: "b")
        XCTAssertEqual(Set(closed.map(\.key)), ["telegram:1", "mail:t1"])
        XCTAssertTrue(store.sessions(boundToPaneKey: "k7").isEmpty)
        XCTAssertEqual(store.sessions(boundToPaneKey: "k3").count, 1)
        XCTAssertTrue(store.close(paneId: "b").isEmpty, "closing twice reports nothing")
    }

    func testRebindingReopensAClosedSession() {
        let store = CommandSessionStore(url: nil, legacyMailURL: nil)
        store.bind("mail:t1", toPaneKey: "k7", paneId: "b", worktreePath: "/w")
        store.close(paneId: "b")
        store.bind("mail:t1", toPaneKey: "k3", paneId: "a", worktreePath: "/w")
        XCTAssertFalse(store.session(for: "mail:t1").closed)
    }

    func testPendingIsTakenOnceAndExpires() {
        let store = CommandSessionStore(url: nil, legacyMailURL: nil)
        let live = PendingAction(line: ParsedLine(.yes), summary: "x", expiresAt: Date().addingTimeInterval(60))
        store.setPending(live, for: "s")
        XCTAssertEqual(store.takePending(for: "s"), live)
        XCTAssertNil(store.takePending(for: "s"))

        store.setPending(PendingAction(line: ParsedLine(.yes), summary: "x", expiresAt: Date().addingTimeInterval(-1)), for: "s")
        XCTAssertNil(store.takePending(for: "s"))
    }

    /// The mail bindings written by the store this one replaced come across
    /// as `mail:<thread>` sessions, once.
    func testImportsLegacyMailConversations() throws {
        let legacy = dir.appendingPathComponent("gmail-mail-conversations.json")
        try """
        {"thread-1": {"gmailThreadID": "thread-1", "paneSessionKey": "seahelm-repo-main", "paneID": "st1",
                      "projectAlias": "", "worktreePath": "/w/main", "closed": false, "commander": "me@x.y"},
         "thread-2": {"gmailThreadID": "thread-2", "paneSessionKey": "", "paneID": "st2",
                      "projectAlias": "", "worktreePath": "", "closed": true}}
        """.data(using: .utf8)!.write(to: legacy)

        let url = dir.appendingPathComponent("sessions.json")
        let store = CommandSessionStore(url: url, legacyMailURL: legacy)
        let one = store.session(for: "mail:thread-1")
        XCTAssertEqual(one.boundPaneKey, "seahelm-repo-main")
        XCTAssertEqual(one.boundPaneId, "st1")
        XCTAssertEqual(one.commander, "me@x.y")
        XCTAssertEqual(one.boundWorktreePath, "/w/main")
        let two = store.session(for: "mail:thread-2")
        XCTAssertEqual(two.boundPaneKey, "local:st2")
        XCTAssertTrue(two.closed)

        // Once written, the new file wins even if the legacy one changes.
        try Data("{}".utf8).write(to: legacy)
        XCTAssertEqual(CommandSessionStore(url: url, legacyMailURL: legacy).session(for: "mail:thread-1").commander, "me@x.y")
    }
}

final class PaneHandleRegistryTests: XCTestCase {
    private var url: URL!

    override func setUp() {
        super.setUp()
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("seahelm-handles-\(UUID().uuidString).json")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: url)
        super.tearDown()
    }

    func testHandlesAreMintedInOrderAndStable() {
        let registry = PaneHandleRegistry(url: url)
        XCTAssertEqual(registry.handle(for: "seahelm-a-main"), 1)
        XCTAssertEqual(registry.handle(for: "seahelm-b-main"), 2)
        XCTAssertEqual(registry.handle(for: "seahelm-a-main"), 1)
        XCTAssertEqual(registry.key(for: 2), "seahelm-b-main")
        XCTAssertNil(registry.existingHandle(for: "never"))
    }

    /// The whole point: `#2` next week is the pane `#2` was today.
    func testHandlesSurviveARelaunchAndAreNeverReused() {
        let first = PaneHandleRegistry(url: url)
        _ = first.handle(for: "one")
        _ = first.handle(for: "two")

        let second = PaneHandleRegistry(url: url)
        XCTAssertEqual(second.existingHandle(for: "two"), 2)
        XCTAssertEqual(second.handle(for: "three"), 3, "a fresh key gets a fresh number, even after a relaunch")
    }

    func testLocalPanesKeyByStationId() {
        XCTAssertEqual(PaneHandleRegistry.key(sessionKey: "", paneId: "st9"), "local:st9")
        XCTAssertEqual(PaneHandleRegistry.key(sessionKey: "seahelm-x", paneId: "st9"), "seahelm-x")
    }
}
