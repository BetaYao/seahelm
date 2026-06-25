import XCTest
@testable import seahelm

/// Mock ExternalChannel for testing
final class MockExternalChannel: ExternalChannel {
    let channelId: String
    let channelType: ExternalChannelType = .wecom
    var gatewayState: GatewayState = .disconnected
    var onMessage: ((InboundMessage) -> Void)?
    var sentMessages: [OutboundMessage] = []
    var connectCalled = false
    var disconnectCalled = false

    init(channelId: String = "mock-ch") {
        self.channelId = channelId
    }

    func send(_ message: OutboundMessage) {
        sentMessages.append(message)
    }

    func connect() { connectCalled = true }
    func disconnect() { disconnectCalled = true }
}

final class ShipLogExternalTests: XCTestCase {

    override func setUp() {
        super.setUp()
        ShipLog.shared.unregisterAllExternalChannels()
        // Clean up any agents from other tests
        for agent in ShipLog.shared.allAgents() {
            ShipLog.shared.unregister(terminalID: agent.id)
        }
    }

    override func tearDown() {
        ShipLog.shared.unregisterAllExternalChannels()
        for agent in ShipLog.shared.allAgents() {
            ShipLog.shared.unregister(terminalID: agent.id)
        }
        super.tearDown()
    }

    private func makeMessage(content: String, channelId: String = "mock-ch") -> InboundMessage {
        InboundMessage(
            channelId: channelId, senderId: "u1", senderName: "Test",
            chatId: nil, chatType: .direct, content: content,
            messageId: "m1", timestamp: Date(), replyTo: nil, metadata: nil
        )
    }

    // MARK: - Channel Registration

    func testRegisterExternalChannel() {
        let ch = MockExternalChannel()
        ShipLog.shared.registerChannel(ch)
        XCTAssertNotNil(ch.onMessage, "onMessage callback should be wired up")
    }

    func testUnregisterExternalChannel() {
        let ch = MockExternalChannel()
        ShipLog.shared.registerChannel(ch)
        ShipLog.shared.unregisterChannel("mock-ch")
        XCTAssertTrue(ch.disconnectCalled)
    }

    // MARK: - Command Handling

    func testHelpCommand() {
        let ch = MockExternalChannel()
        ShipLog.shared.registerChannel(ch)
        ShipLog.shared.handleInbound(makeMessage(content: "/help"))

        XCTAssertEqual(ch.sentMessages.count, 1)
        XCTAssertTrue(ch.sentMessages[0].content.contains("/idea"))
        XCTAssertTrue(ch.sentMessages[0].content.contains("/status"))
    }

    func testStatusCommandNoAgents() {
        let ch = MockExternalChannel()
        ShipLog.shared.registerChannel(ch)
        ShipLog.shared.handleInbound(makeMessage(content: "/status"))

        XCTAssertEqual(ch.sentMessages.count, 1)
        XCTAssertTrue(ch.sentMessages[0].content.contains("No agent"))
    }

    func testListCommandNoAgents() {
        let ch = MockExternalChannel()
        ShipLog.shared.registerChannel(ch)
        ShipLog.shared.handleInbound(makeMessage(content: "/list"))

        XCTAssertEqual(ch.sentMessages.count, 1)
        XCTAssertTrue(ch.sentMessages[0].content.contains("No agent"))
    }

    func testIdeaCommand() {
        let ch = MockExternalChannel()
        ShipLog.shared.registerChannel(ch)
        ShipLog.shared.handleInbound(makeMessage(content: "/idea 做一个暗色模式"))

        XCTAssertEqual(ch.sentMessages.count, 1)
        XCTAssertTrue(ch.sentMessages[0].content.contains("做一个暗色模式"))
    }

    func testNonCommandShowsHelp() {
        let ch = MockExternalChannel()
        ShipLog.shared.registerChannel(ch)
        ShipLog.shared.handleInbound(makeMessage(content: "hello"))

        XCTAssertEqual(ch.sentMessages.count, 1)
        XCTAssertTrue(ch.sentMessages[0].content.contains("/help"))
    }

    func testUnknownCommandShowsHelp() {
        let ch = MockExternalChannel()
        ShipLog.shared.registerChannel(ch)
        ShipLog.shared.handleInbound(makeMessage(content: "/foobar"))

        XCTAssertEqual(ch.sentMessages.count, 1)
        XCTAssertTrue(ch.sentMessages[0].content.contains("/help"))
    }

    // MARK: - Broadcast

    func testBroadcastSendsToAllChannels() {
        let ch1 = MockExternalChannel(channelId: "ch-1")
        let ch2 = MockExternalChannel(channelId: "ch-2")
        ShipLog.shared.registerChannel(ch1)
        ShipLog.shared.registerChannel(ch2)

        ShipLog.shared.broadcast("test alert")

        XCTAssertEqual(ch1.sentMessages.count, 1)
        XCTAssertEqual(ch1.sentMessages[0].content, "test alert")
        XCTAssertEqual(ch2.sentMessages.count, 1)
        XCTAssertEqual(ch2.sentMessages[0].content, "test alert")
    }
}
