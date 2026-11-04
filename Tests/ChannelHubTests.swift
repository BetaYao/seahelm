import XCTest
@testable import seahelm

/// Mock ExternalChannel for testing
final class MockExternalChannel: ExternalChannel {
    let channelId: String
    let channelType: ExternalChannelType = .telegram
    var gatewayState: GatewayState = .disconnected
    var onMessage: ((InboundMessage) -> Void)?
    var onCallback: ((InboundCallback) -> Void)?
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

final class ChannelHubTests: XCTestCase {

    override func setUp() {
        super.setUp()
        ChannelHub.shared.unregisterAllExternalChannels()
        // Clean up any agents from other tests
        for agent in Fleet.shared.allPanes() {
            Fleet.shared.unregister(terminalID: agent.id)
        }
    }

    override func tearDown() {
        ChannelHub.shared.unregisterAllExternalChannels()
        for agent in Fleet.shared.allPanes() {
            Fleet.shared.unregister(terminalID: agent.id)
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
        ChannelHub.shared.registerChannel(ch)
        XCTAssertNotNil(ch.onMessage, "onMessage callback should be wired up")
    }

    func testUnregisterExternalChannel() {
        let ch = MockExternalChannel()
        ChannelHub.shared.registerChannel(ch)
        ChannelHub.shared.unregisterChannel("mock-ch")
        XCTAssertTrue(ch.disconnectCalled)
    }

    // MARK: - Command Handling







    // MARK: - Broadcast

    func testBroadcastSendsToAllChannels() {
        let ch1 = MockExternalChannel(channelId: "ch-1")
        let ch2 = MockExternalChannel(channelId: "ch-2")
        ChannelHub.shared.registerChannel(ch1)
        ChannelHub.shared.registerChannel(ch2)

        ChannelHub.shared.broadcast("test alert")

        XCTAssertEqual(ch1.sentMessages.count, 1)
        XCTAssertEqual(ch1.sentMessages[0].content, "test alert")
        XCTAssertEqual(ch2.sentMessages.count, 1)
        XCTAssertEqual(ch2.sentMessages[0].content, "test alert")
    }
}
