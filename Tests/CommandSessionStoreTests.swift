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

    /// Unbound default chat hears every pane; after `/go` it only hears that pane.
    func testTelegramNotifyRoutingRespectsGoBinding() {
        let store = CommandSessionStore(url: nil, legacyMailURL: nil)
        let me = "42"
        // Unbound: fleet listener gets every event.
        XCTAssertEqual(Set(store.telegramChatsToNotify(paneKey: "k16", worktreePath: nil, fleetListenerChatIds: [me])), [me])
        XCTAssertEqual(Set(store.telegramChatsToNotify(paneKey: "k9", worktreePath: nil, fleetListenerChatIds: [me])), [me])

        store.bind("telegram:\(me)", toPaneKey: "k16", paneId: "p16", worktreePath: "/w")
        // Bound to #16: only #16 events.
        XCTAssertEqual(Set(store.telegramChatsToNotify(paneKey: "k16", worktreePath: nil, fleetListenerChatIds: [me])), [me])
        XCTAssertTrue(store.telegramChatsToNotify(paneKey: "k9", worktreePath: nil, fleetListenerChatIds: [me]).isEmpty)

        // A group bound to the same pane still hears it; the personal chat does too.
        store.bind("telegram:group99", toPaneKey: "k16", paneId: "p16", worktreePath: "/w")
        XCTAssertEqual(Set(store.telegramChatsToNotify(paneKey: "k16", worktreePath: nil, fleetListenerChatIds: [me])),
                       Set([me, "group99"]))
    }

    /// The desk looking at a pane must not silence the chat that ordered it.
    ///
    /// When the pane is on screen and frontmost the banner is suppressed, and
    /// with it the fleet-wide listeners — `fleetListenerChatIds` arrives empty.
    /// A chat bound with `/go` still hears its pane: it sent the order from a
    /// phone that is not looking at this screen, and its answer used to be lost
    /// entirely, delivered only to the terminal the sender happened to be
    /// sitting in front of.
    func testBoundChatHearsItsPaneWithNoFleetListeners() {
        let store = CommandSessionStore(url: nil, legacyMailURL: nil)
        store.bind("telegram:42", toPaneKey: "k12", paneId: "p12", worktreePath: "/w")
        XCTAssertEqual(store.telegramChatsToNotify(paneKey: "k12", worktreePath: nil, fleetListenerChatIds: []), ["42"])
        // Another pane's event still says nothing while the fleet is silenced.
        XCTAssertTrue(store.telegramChatsToNotify(paneKey: "k9", worktreePath: nil, fleetListenerChatIds: []).isEmpty)
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

    // MARK: - One address per room

    /// The duplicate that shipped twice: three bindings on one pane, all in the
    /// same group, and every notice arriving three times. Deduping lives in the
    /// store because the first fix patched one call site and missed two.
    func testNotifyGivesOneAddressPerChat() {
        let store = CommandSessionStore(url: nil, legacyMailURL: nil)
        store.bind(CommandSession.key(surface: "telegram", id: "-100"),
                   toPaneKey: "p", paneId: "A", worktreePath: "/w")
        store.bind(CommandSession.key(surface: "telegram", id: "-100#46"),
                   toPaneKey: "p", paneId: "A", worktreePath: "/w")
        store.bindAutoTopic(CommandSession.key(surface: "telegram", id: "-100#102"),
                            toWorktreePath: "/w", paneKey: "p", paneId: "A", topicName: "n")

        XCTAssertEqual(store.telegramChatsToNotify(paneKey: "p", worktreePath: "/w", fleetListenerChatIds: []),
                       ["-100#102"])
        XCTAssertEqual(store.telegramChats(boundToPaneKey: "p"), ["-100#102"])
    }

    /// A fleet listener naming the same group is the same room too.
    func testFleetListenerDoesNotDoubleUpOnABoundGroup() {
        let store = CommandSessionStore(url: nil, legacyMailURL: nil)
        store.bindAutoTopic(CommandSession.key(surface: "telegram", id: "-100#7"),
                            toWorktreePath: "/w", paneKey: "p", paneId: "A", topicName: "n")
        XCTAssertEqual(store.telegramChatsToNotify(paneKey: "p", worktreePath: "/w", fleetListenerChatIds: ["-100"]),
                       ["-100#7"])
    }

    // MARK: - Letting go of a binding

    func testCloseByKeyClosesOnceAndReportsWhoDidIt() {
        let store = CommandSessionStore(url: nil, legacyMailURL: nil)
        store.bind("telegram:1", toPaneKey: "k7", paneId: "b", worktreePath: "/w")
        XCTAssertEqual(store.close(key: "telegram:1")?.key, "telegram:1")
        // The second caller is told it was not theirs to clean up — otherwise a
        // topic could be deleted twice over.
        XCTAssertNil(store.close(key: "telegram:1"))
        XCTAssertNil(store.close(key: "telegram:absent"))
    }

    /// The sweep's whole job: a binding whose worktree is gone.
    func testStaleBindingIsOneWhoseWorktreeIsGone() {
        let store = CommandSessionStore(url: nil, legacyMailURL: nil)
        store.bind("telegram:1", toPaneKey: "k7", paneId: "dead", worktreePath: "/gone")
        store.bind("telegram:2", toPaneKey: "k8", paneId: "live", worktreePath: "/here")
        let stale = StaleChatBindings.stale(in: store.allSessions(),
                                            worktreeExists: { $0 == "/here" },
                                            paneIsLive: { _ in false })
        XCTAssertEqual(stale.map(\.key), ["telegram:1"])
    }

    /// A pane that followed its agent out of a worktree being deleted moved,
    /// it did not end — and the conversation goes with the pane.
    func testALiveBoundPaneKeepsItsBinding() {
        let store = CommandSessionStore(url: nil, legacyMailURL: nil)
        store.bind("telegram:1", toPaneKey: "k7", paneId: "moved", worktreePath: "/gone")
        XCTAssertTrue(StaleChatBindings.stale(in: store.allSessions(),
                                              worktreeExists: { _ in false },
                                              paneIsLive: { $0 == "moved" }).isEmpty)
    }

    /// Never on a missing pane alone: that is also what a pane looks like
    /// before the app has finished restoring it.
    func testAMissingPaneAloneIsNotStale() {
        let store = CommandSessionStore(url: nil, legacyMailURL: nil)
        store.bind("telegram:1", toPaneKey: "k7", paneId: "unregistered", worktreePath: "/here")
        XCTAssertTrue(StaleChatBindings.stale(in: store.allSessions(),
                                              worktreeExists: { _ in true },
                                              paneIsLive: { _ in false }).isEmpty)
    }

    /// An already-closed binding has been let go of once; sweeping it again
    /// would send a second goodbye to the same room.
    func testAClosedBindingIsNotSweptAgain() {
        let store = CommandSessionStore(url: nil, legacyMailURL: nil)
        store.bind("telegram:1", toPaneKey: "k7", paneId: "dead", worktreePath: "/gone")
        store.close(paneId: "dead")
        XCTAssertTrue(StaleChatBindings.stale(in: store.allSessions(),
                                              worktreeExists: { _ in false },
                                              paneIsLive: { _ in false }).isEmpty)
    }

    /// A chat bound to no worktree — `/go` never given, or given to a pane
    /// since gone — has nothing to check against and is left alone.
    func testABindingWithNoWorktreeIsLeftAlone() {
        let store = CommandSessionStore(url: nil, legacyMailURL: nil)
        store.save(CommandSession(key: "telegram:1"))
        XCTAssertTrue(StaleChatBindings.stale(in: store.allSessions(),
                                              worktreeExists: { _ in false },
                                              paneIsLive: { _ in false }).isEmpty)
    }

    /// Another chat is another conversation and still hears it.
    func testADifferentChatIsStillNotified() {
        let store = CommandSessionStore(url: nil, legacyMailURL: nil)
        store.bind(CommandSession.key(surface: "telegram", id: "-100#4"),
                   toPaneKey: "p", paneId: "A", worktreePath: "/w")
        store.bind(CommandSession.key(surface: "telegram", id: "42"),
                   toPaneKey: "p", paneId: "A", worktreePath: "/w")
        XCTAssertEqual(store.telegramChatsToNotify(paneKey: "p", worktreePath: nil, fleetListenerChatIds: []).sorted(),
                       ["-100#4", "42"])
    }
}
