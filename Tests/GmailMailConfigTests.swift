import XCTest
@testable import seahelm

final class GmailMailConfigTests: XCTestCase {
    func testDefaultConfigIsDisabledAndPersistsNoCredentials() throws {
        let config = GmailMailConfig()

        XCTAssertFalse(config.enabled)
        XCTAssertEqual(config.resolvedPollIntervalSeconds, 45)
        XCTAssertEqual(config.resolvedAllowedAttachmentBytes, 20 * 1_024 * 1_024)
        XCTAssertFalse(String(data: try JSONEncoder().encode(config), encoding: .utf8)!.contains("token"))
    }

    func testDerivesAndValidatesFixedInboundAlias() throws {
        let worktree = try makeDirectory()
        let config = GmailMailConfig(accountEmail: " Me@Example.com ", inboundAlias: "me+seahelm@example.com",
                                    projects: [.init(alias: "my-app", worktreePath: worktree.path)])

        XCTAssertEqual(config.accountEmail, "me@example.com")
        XCTAssertEqual(config.derivedInboundAlias, "me+seahelm@example.com")
        XCTAssertNil(config.validationError)
    }

    func testRejectsInvalidAliasDuplicateRuleAndUnknownDirectory() throws {
        let worktree = try makeDirectory()
        let wrongAlias = GmailMailConfig(accountEmail: "me@example.com", inboundAlias: "mail@example.com",
                                         projects: [.init(alias: "app", worktreePath: worktree.path)])
        XCTAssertNotNil(wrongAlias.validationError)

        let duplicate = GmailMailConfig(accountEmail: "me@example.com", inboundAlias: "me+seahelm@example.com",
                                        projects: [.init(alias: "app", worktreePath: worktree.path),
                                                   .init(alias: "APP", worktreePath: worktree.path)])
        XCTAssertEqual(duplicate.validationError, "Project aliases must be unique.")

        let missing = GmailMailConfig(accountEmail: "me@example.com", inboundAlias: "me+seahelm@example.com",
                                      projects: [.init(alias: "app", worktreePath: "/does/not/exist")])
        XCTAssertNotNil(missing.validationError)
    }

    func testClampsPollingIntervalAndAttachmentLimit() {
        let config = GmailMailConfig(pollIntervalSeconds: 1, allowedAttachmentBytes: -1)
        XCTAssertEqual(config.resolvedPollIntervalSeconds, 30)
        XCTAssertEqual(config.resolvedAllowedAttachmentBytes, 0)
    }

    func testLegacyConfigLeavesGmailMailNil() throws {
        let config = try JSONDecoder().decode(Config.self, from: "{}".data(using: .utf8)!)
        XCTAssertNil(config.gmailMail)
    }

    func testOAuthRequestUsesS256PKCEAndChecksCallbackState() throws {
        let request = GmailOAuthAuthorization.makeRequest(redirectURI: URL(string: "http://127.0.0.1:43123/callback")!)
        let items = Dictionary(uniqueKeysWithValues: URLComponents(url: request.url, resolvingAgainstBaseURL: false)!.queryItems!.map { ($0.name, $0.value ?? "") })

        XCTAssertEqual(items["client_id"], GmailOAuthAuthorization.clientID)
        XCTAssertEqual(items["code_challenge_method"], "S256")
        XCTAssertNotEqual(items["code_challenge"], request.codeVerifier)
        XCTAssertEqual(GmailOAuthAuthorization.authorizationCode(from: URL(string: "http://127.0.0.1/callback?code=abc&state=\(request.state)")!, expectedState: request.state), .success("abc"))
        XCTAssertEqual(GmailOAuthAuthorization.authorizationCode(from: URL(string: "http://127.0.0.1/callback?code=abc&state=wrong")!, expectedState: request.state), .failure(.stateMismatch))
    }

    func testInboundValidatorAcceptsOnlyBoundAccountAliasAndKnownProject() throws {
        let worktree = try makeDirectory()
        let config = GmailMailConfig(accountEmail: "me@example.com", inboundAlias: "me+seahelm@example.com",
                                     projects: [.init(alias: "app", worktreePath: worktree.path)])
        let message = GmailInboundMessage(id: "m1", threadId: "t1", receivedAt: Date(), headers: [
            "From": "Me <me@example.com>", "To": "me+seahelm@example.com", "Subject": "[seahelm:app] Hello"
        ])

        XCTAssertEqual(GmailInboundValidator.validate(message, config: config,
                                                       syncStartedAt: Date().addingTimeInterval(-1), processedIDs: []),
                       .accept(project: config.projects[0]))
    }

    func testProjectAliasAcceptsReplySubjectPrefix() {
        XCTAssertEqual(GmailInboundValidator.projectAlias(from: "Re: [seahelm:seahelm] Follow up"), "seahelm")
    }

    func testInboundValidatorRejectsPreEnableDuplicateAndAutomatedMail() throws {
        let worktree = try makeDirectory()
        let config = GmailMailConfig(accountEmail: "me@example.com", inboundAlias: "me+seahelm@example.com",
                                     projects: [.init(alias: "app", worktreePath: worktree.path)])
        let headers = ["From": "me@example.com", "To": "me+seahelm@example.com", "Subject": "[seahelm:app] Hi"]
        let old = GmailInboundMessage(id: "old", threadId: "t", receivedAt: .distantPast, headers: headers)
        XCTAssertEqual(GmailInboundValidator.validate(old, config: config, syncStartedAt: Date(), processedIDs: []), .reject(.preEnableMessage))

        let duplicate = GmailInboundMessage(id: "dup", threadId: "t", receivedAt: Date(), headers: headers)
        XCTAssertEqual(GmailInboundValidator.validate(duplicate, config: config, syncStartedAt: .distantPast, processedIDs: ["dup"]), .reject(.duplicateMessage))

        let automated = GmailInboundMessage(id: "auto", threadId: "t", receivedAt: Date(), headers: headers.merging(["Auto-Submitted": "auto-replied"]) { _, new in new })
        XCTAssertEqual(GmailInboundValidator.validate(automated, config: config, syncStartedAt: .distantPast, processedIDs: []), .reject(.autoReply))
    }

    func testStateStorePersistsBoundedIDsAndPrivacySafeAudit() throws {
        let directory = try makeDirectory()
        let store = GmailMailStateStore(fileURL: directory.appendingPathComponent("state.json"))
        var state = GmailMailState(syncStartedAt: Date(timeIntervalSince1970: 10))
        for index in 0...(GmailMailState.maxProcessedMessageIDs + 2) {
            state.record(messageID: "message-\(index)", threadID: "thread", code: .accepted)
        }
        try store.save(state)
        let loaded = try XCTUnwrap(store.load())
        XCTAssertEqual(loaded.processedMessageIDs.count, GmailMailState.maxProcessedMessageIDs)
        XCTAssertEqual(loaded.processedMessageIDs.first, "message-3")
        XCTAssertFalse(loaded.audit.last!.messageIDHash.contains("message"))
        XCTAssertFalse(loaded.audit.last!.threadIDHash.contains("thread"))
    }

    func testPollerUsesFakeAndAcceptsCurrentWindowMessageOnce() throws {
        let worktree = try makeDirectory()
        let config = GmailMailConfig(enabled: true, accountEmail: "me@example.com", inboundAlias: "me+seahelm@example.com",
                                     projects: [.init(alias: "app", worktreePath: worktree.path)])
        let message = GmailInboundMessage(id: "m", threadId: "t", receivedAt: Date().addingTimeInterval(1), headers: [
            "From": "me@example.com", "To": "me+seahelm@example.com", "Subject": "[seahelm:app] Hello"
        ])
        let fake = FakeGmailMailClient(result: .success(.init(messages: [message, message], latestHistoryId: "2")))
        let store = GmailMailStateStore(fileURL: try makeDirectory().appendingPathComponent("state.json"))
        let poller = GmailMailPoller(client: fake, stateStore: store)
        let accepted = expectation(description: "accepted once")
        accepted.expectedFulfillmentCount = 1
        poller.onAcceptedMessage = { _, _ in accepted.fulfill() }

        poller.start(config: config)
        wait(for: [accepted], timeout: 2)
        poller.stop()
    }

    func testAttachmentStoreUsesGeneratedPathsAndRejectsUnsafeTypes() throws {
        let root = try makeDirectory()
        let store = EmailAttachmentStore(root: root)
        let urls = try store.importAttachments([.init(filename: "../../bad.png", mimeType: "image/png", data: Data("x".utf8))],
                                               account: "me@example.com", threadID: "thread", messageID: "message", limit: 10)
        XCTAssertEqual(urls.count, 1)
        XCTAssertTrue(urls[0].path.hasPrefix(root.path))
        XCTAssertFalse(urls[0].lastPathComponent.contains("bad"))
        XCTAssertThrowsError(try store.importAttachments([.init(filename: "run.sh", mimeType: "application/x-sh", data: Data())],
                                                         account: "me@example.com", threadID: "thread", messageID: "two", limit: 10))
    }

    private func makeDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
}

private final class FakeGmailMailClient: GmailMailClient {
    let result: Result<GmailMailPoll, GmailMailClientError>
    init(result: Result<GmailMailPoll, GmailMailClientError>) { self.result = result }
    func poll(since: Date, historyID: String?, inboundAlias: String,
              completion: @escaping (Result<GmailMailPoll, GmailMailClientError>) -> Void) { completion(result) }
}
