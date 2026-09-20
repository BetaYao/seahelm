import XCTest
@testable import seahelm

/// Per-pane forum topics: the rules that decide what a topic seahelm opened
/// itself means, and what survives a relaunch.
final class TelegramAutoTopicTests: XCTestCase {

    private let owner = TelegramUser(id: 42, isBot: false, firstName: "Matt", username: "matt_c")
    private var ownerConfig: TelegramConfig { TelegramConfig(allowedUsers: ["42"]) }

    private func topicMessage(_ text: String, thread: Int = 7) -> TelegramMessage {
        TelegramMessage(messageId: 1, date: 1_757_000_000,
                        chat: TelegramChat(id: -1_001_234_567_890, type: "supergroup",
                                           title: "Team", username: nil, isForum: true),
                        from: owner, senderChat: nil, text: text, caption: nil,
                        messageThreadId: thread, isTopicMessage: true)
    }

    // MARK: - The gate

    /// The point of the feature: a thread that is one pane's command line takes
    /// prose the way a private chat does.
    func testProseIsAnOrderInADedicatedTopic() {
        let cmd = TelegramChannel.command(in: topicMessage("ship it"), config: ownerConfig,
                                          botUsername: "seahelm_bot", dedicatedTopic: true)
        XCTAssertEqual(cmd?.body, "ship it")
    }

    /// And the rule it does not touch: an ordinary topic is still a shared
    /// room, where a stray line must not steer an agent.
    func testProseIsNotAnOrderInAnOrdinaryTopic() {
        XCTAssertNil(TelegramChannel.command(in: topicMessage("lunch?"), config: ownerConfig,
                                             botUsername: "seahelm_bot", dedicatedTopic: false))
    }

    /// A dedicated topic relaxes *where* an order may be given, never *who* may
    /// give one.
    func testDedicatedTopicStillObeysTheAllowlist() {
        let stranger = TelegramUser(id: 9, isBot: false, firstName: "X", username: nil)
        let message = TelegramMessage(messageId: 1, date: 1_757_000_000,
                                      chat: TelegramChat(id: -100, type: "supergroup", title: "T",
                                                         username: nil, isForum: true),
                                      from: stranger, senderChat: nil, text: "rm -rf /", caption: nil,
                                      messageThreadId: 7, isTopicMessage: true)
        XCTAssertNil(TelegramChannel.command(in: message, config: ownerConfig,
                                             botUsername: "seahelm_bot", dedicatedTopic: true))
    }

    // MARK: - Config

    func testTopicChatIdNeedsTheSwitchOn() {
        XCTAssertNil(TelegramConfig(topicChatId: "-100").resolvedTopicChatId)
        XCTAssertNil(TelegramConfig(autoTopics: true).resolvedTopicChatId)
        XCTAssertEqual(TelegramConfig(autoTopics: true, topicChatId: "-100").resolvedTopicChatId, "-100")
    }

    /// A topic is opened *in* a chat, so a configured address that names one
    /// itself is taken down to the group.
    func testTopicChatIdDropsAnyTopicOnIt() {
        XCTAssertEqual(TelegramConfig(autoTopics: true, topicChatId: "-100#42").resolvedTopicChatId, "-100")
    }

    // MARK: - Which group a pane's topic goes in

    private var mapped: TelegramConfig {
        TelegramConfig(autoTopics: true, topicChatId: "-100fallback",
                       topicChats: ["seahelm": "-100seahelm",
                                    "teamclaw": "-100teamclaw",
                                    "/Volumes/openbeta/workspace/saas-mono-worktrees/task/urgent": "-100urgent"])
    }

    func testProjectPicksItsGroup() {
        XCTAssertEqual(mapped.topicChatId(worktreePath: "/x/seahelm", project: "seahelm"), "-100seahelm")
        XCTAssertEqual(mapped.topicChatId(worktreePath: "/x/tc", project: "teamclaw"), "-100teamclaw")
    }

    /// A worktree important enough to name explicitly beats its repo.
    func testWorktreePathBeatsProject() {
        XCTAssertEqual(
            mapped.topicChatId(worktreePath: "/Volumes/openbeta/workspace/saas-mono-worktrees/task/urgent",
                               project: "saas-mono"),
            "-100urgent")
    }

    /// Written by hand, so half these tables will have a trailing slash.
    func testWorktreePathIgnoresATrailingSlash() {
        XCTAssertEqual(
            mapped.topicChatId(worktreePath: "/Volumes/openbeta/workspace/saas-mono-worktrees/task/urgent/",
                               project: "saas-mono"),
            "-100urgent")
    }

    func testUnmappedProjectFallsBack() {
        XCTAssertEqual(mapped.topicChatId(worktreePath: "/x/b", project: "banana"), "-100fallback")
    }

    /// A project name is a directory name; case should not decide where its
    /// threads land.
    func testProjectMatchIgnoresCase() {
        XCTAssertEqual(mapped.topicChatId(worktreePath: "/x/s", project: "Seahelm"), "-100seahelm")
    }

    /// No group for the repo and no fallback means no topic — not a topic in
    /// some other project's room.
    func testNoFallbackMeansNoTopic() {
        let cfg = TelegramConfig(autoTopics: true, topicChats: ["seahelm": "-100seahelm"])
        XCTAssertNil(cfg.topicChatId(worktreePath: "/x/b", project: "banana"))
        XCTAssertTrue(cfg.autoTopicsEnabled)
    }

    func testSwitchOffBeatsEveryMapping() {
        let cfg = TelegramConfig(autoTopics: false, topicChats: ["seahelm": "-100seahelm"])
        XCTAssertNil(cfg.topicChatId(worktreePath: "/x/s", project: "seahelm"))
        XCTAssertFalse(cfg.autoTopicsEnabled)
    }

    func testConfigDecodesTheMap() throws {
        let json = """
        {"auto_topics":true,"topic_chats":{"seahelm":"-1001","teamclaw":"-1002"}}
        """.data(using: .utf8)!
        let cfg = try JSONDecoder().decode(TelegramConfig.self, from: json)
        XCTAssertEqual(cfg.topicChatId(worktreePath: "/x", project: "teamclaw"), "-1002")
    }

    func testConfigDecodesTheNewKeys() throws {
        let json = """
        {"bot_token":"t","allowed_users":["42"],"auto_topics":true,"topic_chat_id":"-1001234567890"}
        """.data(using: .utf8)!
        let cfg = try JSONDecoder().decode(TelegramConfig.self, from: json)
        XCTAssertEqual(cfg.resolvedTopicChatId, "-1001234567890")
    }

    /// Every other setting still reads from a config written before topics
    /// existed.
    func testConfigWithoutTopicKeysStillDecodes() throws {
        let json = """
        {"bot_token":"t","allowed_users":["42"]}
        """.data(using: .utf8)!
        let cfg = try JSONDecoder().decode(TelegramConfig.self, from: json)
        XCTAssertNil(cfg.resolvedTopicChatId)
        XCTAssertEqual(cfg.allowedUsers, ["42"])
    }

    // MARK: - Names

    func testTopicNameIsTrimmedToTelegramsLimit() {
        let long = String(repeating: "x", count: 400)
        let name = TelegramBotAPI.trimTopicName(long)
        XCTAssertEqual(name.count, 128)
        XCTAssertTrue(name.hasSuffix("\u{2026}"))
    }

    /// A pane title is free-form user text and routinely spans lines; a topic
    /// name is one line.
    func testTopicNameFlattensWhitespace() {
        XCTAssertEqual(TelegramBotAPI.trimTopicName("fix the\n\n  flaky   test"), "fix the flaky test")
    }

    func testEmptyTopicNameFallsBackRatherThanFailing() {
        XCTAssertEqual(TelegramBotAPI.trimTopicName("   \n  "), "seahelm")
    }

    /// Colours group the thread list by repo, so they must not move between
    /// launches — which rules out `hashValue`, seeded per process.
    func testIconColourIsStableAndAllowed() {
        let first = TelegramBotAPI.topicIconColor(for: "seahelm")
        XCTAssertEqual(first, TelegramBotAPI.topicIconColor(for: "seahelm"))
        XCTAssertTrue(TelegramBotAPI.topicIconColors.contains(first))
        XCTAssertTrue(TelegramBotAPI.topicIconColors.contains(TelegramBotAPI.topicIconColor(for: "")))
    }

    // MARK: - The session store

    func testAutoTopicBindsAndIsFoundByPane() {
        let store = CommandSessionStore(url: nil, legacyMailURL: nil)
        let address = "-1001234567890#77"
        let key = CommandSession.key(surface: "telegram", id: address)
        store.bindAutoTopic(key, toPaneKey: "pane-a", paneId: "A",
                            worktreePath: "/tmp/a", topicName: "seahelm · review")

        let found = store.autoTopic(forPaneKey: "pane-a")
        XCTAssertEqual(found?.id, address)
        XCTAssertEqual(found?.topicName, "seahelm · review")
        XCTAssertEqual(store.autoTopicAddresses(), [address])
        XCTAssertNil(store.autoTopic(forPaneKey: "pane-b"))
    }

    /// A topic bound by hand is not ours: prose in it stays conversation, and
    /// it is not closed when the pane ends.
    func testManuallyBoundTopicIsNotAnAutoTopic() {
        let store = CommandSessionStore(url: nil, legacyMailURL: nil)
        let key = CommandSession.key(surface: "telegram", id: "-100#5")
        store.bind(key, toPaneKey: "pane-a", paneId: "A", worktreePath: "/tmp/a")
        XCTAssertNil(store.autoTopic(forPaneKey: "pane-a"))
        XCTAssertTrue(store.autoTopicAddresses().isEmpty)
    }

    /// A closed pane's topic stops being one we would route to or rename.
    func testClosingThePaneRetiresItsTopic() {
        let store = CommandSessionStore(url: nil, legacyMailURL: nil)
        let key = CommandSession.key(surface: "telegram", id: "-100#9")
        store.bindAutoTopic(key, toPaneKey: "pane-a", paneId: "A",
                            worktreePath: "/tmp/a", topicName: "n")

        let closed = store.close(paneId: "A")
        XCTAssertEqual(closed.count, 1)
        XCTAssertTrue(closed[0].autoTopic)
        XCTAssertNil(store.autoTopic(forPaneKey: "pane-a"))
        XCTAssertTrue(store.autoTopicAddresses().isEmpty)
    }

    func testTopicNameIsRecordedSoRenamesAreOnlySpentOnChanges() {
        let store = CommandSessionStore(url: nil, legacyMailURL: nil)
        let key = CommandSession.key(surface: "telegram", id: "-100#9")
        store.bindAutoTopic(key, toPaneKey: "pane-a", paneId: "A",
                            worktreePath: "/tmp/a", topicName: "old")
        store.noteTopicName("new", for: key)
        XCTAssertEqual(store.autoTopic(forPaneKey: "pane-a")?.topicName, "new")
    }

    /// A session file written before this feature has neither key.
    func testSessionDecodesWithoutTheNewFields() throws {
        let json = """
        {"key":"telegram:-100","boundPaneKey":"p","boundPaneId":"A","closed":false}
        """.data(using: .utf8)!
        let session = try JSONDecoder().decode(CommandSession.self, from: json)
        XCTAssertFalse(session.autoTopic)
        XCTAssertNil(session.topicName)
        XCTAssertEqual(session.boundPaneId, "A")
    }

    func testSessionRoundTripsTheNewFields() throws {
        let session = CommandSession(key: "telegram:-100#7", boundPaneKey: "p", boundPaneId: "A",
                                     autoTopic: true, topicName: "seahelm · review")
        let back = try JSONDecoder().decode(CommandSession.self,
                                            from: JSONEncoder().encode(session))
        XCTAssertEqual(back, session)
    }

    // MARK: - /home

    private var fleet: FleetIndex { CommandFixture.index }

    private func parseHome(_ line: String) -> Command? {
        guard case .success(let parsed) = CommandParser.parse(line, index: fleet) else { return nil }
        return parsed.command
    }

    func testBareHomeListsTheMapping() {
        XCTAssertEqual(parseHome("/home"), .home(nil, off: false))
    }

    /// A repo name is the recommended grain, so it wins the tie-break.
    func testHomeResolvesARepoByName() {
        guard case .home(.some(.repo(let repo)), false) = parseHome("/home @alpha") else {
            return XCTFail("expected a repo")
        }
        XCTAssertEqual(repo.name, "alpha")
        XCTAssertEqual(HomeTarget.repo(repo).configKey, "alpha")
    }

    /// Anything that is not a repo is tried as a worktree, and stored by path.
    func testHomeResolvesAWorktreeByBranch() {
        guard case .home(.some(.worktree(let wt)), false) = parseHome("/home @fix-y") else {
            return XCTFail("expected a worktree")
        }
        XCTAssertEqual(wt.path, "/repo/fix-y")
        XCTAssertEqual(HomeTarget.worktree(wt).configKey, "/repo/fix-y")
    }

    func testHomeOff() {
        guard case .home(.some(.repo), true) = parseHome("/home @alpha off") else {
            return XCTFail("expected off")
        }
    }

    func testHomeRejectsAStrayArgument() {
        XCTAssertNil(parseHome("/home @alpha sideways"))
    }

    func testHomeRejectsAnUnknownName() {
        XCTAssertNil(parseHome("/home @nope"))
    }

    /// The group is never typed — it is where the line came from.
    func testChatIdComesFromTheSurface() {
        XCTAssertEqual(CommandExecutor.chatId(of: CommandSurface(sessionKey: "telegram:-100#46")), "-100")
        XCTAssertEqual(CommandExecutor.chatId(of: CommandSurface(sessionKey: "telegram:-100")), "-100")
        XCTAssertNil(CommandExecutor.chatId(of: .desktop))
        XCTAssertNil(CommandExecutor.chatId(of: CommandSurface(sessionKey: "mail:abc")))
    }

    func testHomeListingNamesWhatIsUnset() {
        XCTAssertTrue(CommandFormatter.topicHomes([:]).contains("/home @repo"))
        let rows = CommandFormatter.topicHomes(["seahelm": "-1001", "teamclaw": "-1002"])
        XCTAssertTrue(rows.contains("seahelm"))
        XCTAssertTrue(rows.contains("-1002"))
    }

    /// A creator has no `can_manage_topics` flag and may manage them anyway.
    func testCreatorMayManageTopicsWithoutTheFlag() {
        XCTAssertTrue(TelegramChatMember(status: "creator", canManageTopics: nil).mayManageTopics)
        XCTAssertTrue(TelegramChatMember(status: "administrator", canManageTopics: true).mayManageTopics)
        XCTAssertFalse(TelegramChatMember(status: "administrator", canManageTopics: false).mayManageTopics)
        XCTAssertFalse(TelegramChatMember(status: "member", canManageTopics: nil).mayManageTopics)
    }
}
