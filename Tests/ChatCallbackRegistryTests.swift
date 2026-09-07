import XCTest
@testable import seahelm

final class ChatCallbackRegistryTests: XCTestCase {

    func testMintedTokenResolvesBackToItsAction() {
        let registry = ChatCallbackRegistry()
        let token = registry.mint(.command("/go #3"))
        XCTAssertEqual(registry.action(for: token), .command("/go #3"))
    }

    func testTokensAreDistinctAndShortEnoughForTelegram() {
        let registry = ChatCallbackRegistry()
        let tokens = (0..<500).map { registry.mint(.command("/order #\($0) hi")) }
        XCTAssertEqual(Set(tokens).count, tokens.count)
        // `callback_data` is capped at 64 bytes, and the token is all of it.
        XCTAssertTrue(tokens.allSatisfy { $0.utf8.count <= 64 })
    }

    func testUnknownTokenIsStaleRatherThanFatal() {
        let registry = ChatCallbackRegistry()
        XCTAssertNil(registry.action(for: "nope"))
    }

    /// A card that has been answered must not be answerable again — the option
    /// text would be typed into the pane twice.
    func testRetireDropsEveryButtonOnThatCard() {
        let registry = ChatCallbackRegistry()
        let first = registry.mint(.suggestionOption(orderId: "card-1", index: 0))
        let second = registry.mint(.suggestionOption(orderId: "card-1", index: 1))
        let dismiss = registry.mint(.dismissSuggestion(orderId: "card-1"))
        let other = registry.mint(.suggestionOption(orderId: "card-2", index: 0))
        let command = registry.mint(.command("/status"))

        registry.retire(orderId: "card-1")

        XCTAssertNil(registry.action(for: first))
        XCTAssertNil(registry.action(for: second))
        XCTAssertNil(registry.action(for: dismiss))
        XCTAssertEqual(registry.action(for: other), .suggestionOption(orderId: "card-2", index: 0))
        XCTAssertEqual(registry.action(for: command), .command("/status"))
    }

    func testOldestTokensAreEvictedPastCapacity() {
        let registry = ChatCallbackRegistry()
        let oldest = registry.mint(.command("/status"))
        for i in 0..<ChatCallbackRegistry.capacity {
            _ = registry.mint(.command("/order #\(i) hi"))
        }
        XCTAssertNil(registry.action(for: oldest))
    }

    /// Retiring must shrink the eviction queue too, or a long-lived session
    /// evicts live tokens to make room for ones it already dropped.
    func testRetireFreesCapacity() {
        let registry = ChatCallbackRegistry()
        let keeper = registry.mint(.command("/status"))
        for i in 0..<(ChatCallbackRegistry.capacity - 1) {
            _ = registry.mint(.suggestionOption(orderId: "card-\(i)", index: 0))
        }
        for i in 0..<(ChatCallbackRegistry.capacity - 1) {
            registry.retire(orderId: "card-\(i)")
        }
        for i in 0..<(ChatCallbackRegistry.capacity - 1) {
            _ = registry.mint(.command("/order #\(i) hi"))
        }
        XCTAssertEqual(registry.action(for: keeper), .command("/status"))
    }
}
