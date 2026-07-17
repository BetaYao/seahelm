import XCTest
@testable import seahelm

/// Exercises the real on-disk store. Each test uses a unique account id and
/// clears it afterwards, so it only ever touches its own key in the file.
final class WeChatSessionStoreTests: XCTestCase {
    private var accountId = ""

    override func setUp() {
        super.setUp()
        accountId = "test-\(UUID().uuidString)"
    }

    override func tearDown() {
        WeChatSessionStore.clear(accountId: accountId)
        waitForStoreWrites()
        super.tearDown()
    }

    /// Saves are debounced ~1s; give the store time to land them.
    private func waitForStoreWrites() {
        let done = expectation(description: "store settled")
        DispatchQueue.global().asyncAfter(deadline: .now() + 1.6) { done.fulfill() }
        wait(for: [done], timeout: 3)
    }

    func testLoadReturnsEmptyForUnknownAccount() {
        XCTAssertEqual(WeChatSessionStore.load(accountId: accountId), .empty)
    }

    func testSaveThenLoadRoundTrips() {
        let state = WeChatSessionState(
            syncBuf: "cursor-abc",
            contextTokens: ["user-1": "ctx-1", "user-2": "ctx-2"]
        )
        WeChatSessionStore.save(state, accountId: accountId)
        waitForStoreWrites()

        XCTAssertEqual(WeChatSessionStore.load(accountId: accountId), state)
    }

    func testLatestSaveWins() {
        WeChatSessionStore.save(
            WeChatSessionState(syncBuf: "old", contextTokens: [:]),
            accountId: accountId
        )
        WeChatSessionStore.save(
            WeChatSessionState(syncBuf: "new", contextTokens: ["u": "t"]),
            accountId: accountId
        )
        waitForStoreWrites()

        XCTAssertEqual(WeChatSessionStore.load(accountId: accountId).syncBuf, "new")
        XCTAssertEqual(WeChatSessionStore.load(accountId: accountId).contextTokens, ["u": "t"])
    }

    func testClearRemovesState() {
        WeChatSessionStore.save(
            WeChatSessionState(syncBuf: "cursor", contextTokens: ["u": "t"]),
            accountId: accountId
        )
        waitForStoreWrites()
        XCTAssertEqual(WeChatSessionStore.load(accountId: accountId).syncBuf, "cursor")

        WeChatSessionStore.clear(accountId: accountId)
        waitForStoreWrites()
        XCTAssertEqual(WeChatSessionStore.load(accountId: accountId), .empty)
    }

    /// Accounts must not read or clobber each other's cursor.
    func testAccountsAreIsolated() {
        let other = "test-\(UUID().uuidString)"
        defer { WeChatSessionStore.clear(accountId: other) }

        WeChatSessionStore.save(
            WeChatSessionState(syncBuf: "mine", contextTokens: [:]),
            accountId: accountId
        )
        WeChatSessionStore.save(
            WeChatSessionState(syncBuf: "theirs", contextTokens: [:]),
            accountId: other
        )
        waitForStoreWrites()

        XCTAssertEqual(WeChatSessionStore.load(accountId: accountId).syncBuf, "mine")
        XCTAssertEqual(WeChatSessionStore.load(accountId: other).syncBuf, "theirs")

        WeChatSessionStore.clear(accountId: other)
        waitForStoreWrites()
        XCTAssertEqual(WeChatSessionStore.load(accountId: accountId).syncBuf, "mine")
    }
}
