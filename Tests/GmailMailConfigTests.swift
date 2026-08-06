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

    func testDerivesAndValidatesFixedInboundAlias() {
        let config = GmailMailConfig(accountEmail: " Me@Example.com ", inboundAlias: "me+seahelm@example.com")

        XCTAssertEqual(config.accountEmail, "me@example.com")
        XCTAssertEqual(config.derivedInboundAlias, "me+seahelm@example.com")
        XCTAssertNil(config.validationError)
    }

    /// The alias is the only recipient Seahelm answers on, so a config naming
    /// any other address has to be refused rather than silently listening wide.
    func testRejectsAnInboundAliasThatIsNotThePlusAddress() {
        let wrongAlias = GmailMailConfig(accountEmail: "me@example.com", inboundAlias: "mail@example.com")
        XCTAssertEqual(wrongAlias.validationError, "The inbound alias must be me+seahelm@example.com.")

        let notAnEmail = GmailMailConfig(accountEmail: "nonsense", inboundAlias: "nonsense")
        XCTAssertNotNil(notAnEmail.validationError)
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

    func testInboundValidatorAcceptsOnBoundAccountAndAlias() {
        let config = GmailMailConfig(accountEmail: "me@example.com", inboundAlias: "me+seahelm@example.com")
        let message = GmailInboundMessage(id: "m1", threadId: "t1", receivedAt: Date(), headers: [
            "From": "Me <me@example.com>", "To": "me+seahelm@example.com", "Subject": "Hello"
        ])

        XCTAssertEqual(GmailInboundValidator.validate(message, config: config,
                                                       syncStartedAt: Date().addingTimeInterval(-1), processedIDs: []),
                       .accept)
    }

    /// The recipient alias is the whole gate: any subject is valid, including
    /// none at all, and no project rule needs to exist.
    func testInboundValidatorIgnoresTheSubjectEntirely() {
        let config = GmailMailConfig(accountEmail: "me@example.com", inboundAlias: "me+seahelm@example.com")
        let started = Date().addingTimeInterval(-1)
        for subject in ["Re: 周报", "", "[seahelm:gone] stale tag"] {
            let message = GmailInboundMessage(id: "m-\(subject.count)", threadId: "t", receivedAt: Date(), headers: [
                "From": "me@example.com", "To": "me+seahelm@example.com", "Subject": subject
            ])
            XCTAssertEqual(GmailInboundValidator.validate(message, config: config, syncStartedAt: started, processedIDs: []),
                           .accept, "subject: \(subject)")
        }

        let noSubject = GmailInboundMessage(id: "m-none", threadId: "t", receivedAt: Date(), headers: [
            "From": "me@example.com", "To": "me+seahelm@example.com"
        ])
        XCTAssertEqual(GmailInboundValidator.validate(noSubject, config: config, syncStartedAt: started, processedIDs: []), .accept)
    }

    /// Every relay adds a `Received` header, so duplicate keys are the norm.
    /// Building the header map with `uniqueKeysWithValues` trapped, which took
    /// the whole app down on essentially any real mail.
    func testRepeatedHeadersDoNotTrap() {
        let message = GmailInboundMessage(id: "m", threadId: "t", receivedAt: Date(), headers: [
            "Received": "by 2002:a05 with SMTP id x1",
            "received": "from mail-yw1.google.com by mx.google.com",
            "To": "me+seahelm@example.com",
            "Delivered-To": "me@example.com",
            "delivered-to": "me+seahelm@example.com",
            "From": "me@example.com",
        ])
        // Both spellings survive, so a multi-hop Delivered-To still satisfies
        // the recipient gate that splits on commas.
        let config = GmailMailConfig(accountEmail: "me@example.com", inboundAlias: "me+seahelm@example.com")
        XCTAssertEqual(GmailInboundValidator.validate(message, config: config,
                                                      syncStartedAt: Date().addingTimeInterval(-1), processedIDs: []),
                       .accept)
        XCTAssertTrue(message.header("received")?.contains("mx.google.com") == true)
    }

    // MARK: - Sender whitelist

    private func outsideMessage(from sender: String, authenticated: Bool) -> GmailInboundMessage {
        var headers = ["From": sender, "To": "me+seahelm@example.com", "Subject": "hi"]
        if authenticated {
            headers["Authentication-Results"] = "mx.google.com; dkim=pass header.i=@work.example; spf=pass"
        }
        return GmailInboundMessage(id: "m-\(sender)-\(authenticated)", threadId: "t",
                                   receivedAt: Date(), headers: headers)
    }

    func testAcceptsAWhitelistedSenderThatGoogleVouchesFor() {
        let config = GmailMailConfig(accountEmail: "me@example.com", inboundAlias: "me+seahelm@example.com",
                                     allowedSenders: ["work@example.com"])
        XCTAssertEqual(GmailInboundValidator.validate(outsideMessage(from: "Work <work@example.com>", authenticated: true),
                                                      config: config, syncStartedAt: .distantPast, processedIDs: []),
                       .accept)
    }

    /// A `From` header is trivially forged and its contents are typed into a
    /// terminal, so a whitelisted address is worth nothing on its own.
    func testRejectsAWhitelistedSenderWithNoAuthenticationVerdict() {
        let config = GmailMailConfig(accountEmail: "me@example.com", inboundAlias: "me+seahelm@example.com",
                                     allowedSenders: ["work@example.com"])
        XCTAssertEqual(GmailInboundValidator.validate(outsideMessage(from: "work@example.com", authenticated: false),
                                                      config: config, syncStartedAt: .distantPast, processedIDs: []),
                       .reject(.unauthenticatedSender))
    }

    func testRejectsAnUnlistedSenderEvenWhenAuthenticated() {
        let config = GmailMailConfig(accountEmail: "me@example.com", inboundAlias: "me+seahelm@example.com",
                                     allowedSenders: ["work@example.com"])
        XCTAssertEqual(GmailInboundValidator.validate(outsideMessage(from: "stranger@example.com", authenticated: true),
                                                      config: config, syncStartedAt: .distantPast, processedIDs: []),
                       .reject(.invalidSender))
    }

    /// The account's own mail never leaves Google and carries no verdict, so the
    /// authentication requirement must not apply to it.
    func testAccountItselfNeedsNoAuthenticationHeader() {
        let config = GmailMailConfig(accountEmail: "me@example.com", inboundAlias: "me+seahelm@example.com")
        XCTAssertEqual(GmailInboundValidator.validate(outsideMessage(from: "me@example.com", authenticated: false),
                                                      config: config, syncStartedAt: .distantPast, processedIDs: []),
                       .accept)
    }

    /// A config written before the whitelist existed must still decode.
    func testDecodesConfigWithoutAllowedSenders() throws {
        let json = #"{"enabled":true,"accountEmail":"me@example.com","inboundAlias":"me+seahelm@example.com"}"#
        let decoded = try JSONDecoder().decode(GmailMailConfig.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.allowedSenders, [])
        XCTAssertEqual(decoded.pollIntervalSeconds, GmailMailConfig.defaultPollIntervalSeconds)
        XCTAssertNil(decoded.validationError)
    }

    func testInboundValidatorStillRejectsAForeignRecipient() {
        let config = GmailMailConfig(accountEmail: "me@example.com", inboundAlias: "me+seahelm@example.com")
        let message = GmailInboundMessage(id: "m1", threadId: "t1", receivedAt: Date(), headers: [
            "From": "me@example.com", "To": "me@example.com", "Subject": "Hello"
        ])
        XCTAssertEqual(GmailInboundValidator.validate(message, config: config,
                                                       syncStartedAt: Date().addingTimeInterval(-1), processedIDs: []),
                       .reject(.invalidRecipient))
    }

    func testInboundValidatorRejectsPreEnableDuplicateAndAutomatedMail() {
        let config = GmailMailConfig(accountEmail: "me@example.com", inboundAlias: "me+seahelm@example.com")
        let headers = ["From": "me@example.com", "To": "me+seahelm@example.com", "Subject": "Hi"]
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
        let config = GmailMailConfig(enabled: true, accountEmail: "me@example.com", inboundAlias: "me+seahelm@example.com")
        let message = GmailInboundMessage(id: "m", threadId: "t", receivedAt: Date().addingTimeInterval(1), headers: [
            "From": "me@example.com", "To": "me+seahelm@example.com", "Subject": "Hello"
        ])
        let fake = FakeGmailMailClient(result: .success(.init(messages: [message, message], latestHistoryId: "2")))
        let store = GmailMailStateStore(fileURL: try makeDirectory().appendingPathComponent("state.json"))
        let poller = GmailMailPoller(client: fake, stateStore: store)
        let accepted = expectation(description: "accepted once")
        accepted.expectedFulfillmentCount = 1
        poller.onAcceptedMessage = { _ in accepted.fulfill() }

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
