import XCTest
@testable import seahelm

final class ShareLinkStoreTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testAMintedTokenOpensItsPaneOnly() {
        let store = ShareLinkStore(fileURL: nil)
        let (link, token) = store.mint(paneSessionKey: "k1", label: "a", lifetime: .day, now: now)
        XCTAssertEqual(store.check(token: token, paneSessionKey: "k1", now: now), .valid(id: link.id, recipient: nil))
        XCTAssertEqual(store.check(token: token, paneSessionKey: "k2", now: now), .invalid)
        XCTAssertEqual(store.check(token: "nope", paneSessionKey: "k1", now: now), .invalid)
        XCTAssertEqual(store.check(token: "", paneSessionKey: "k1", now: now), .invalid)
    }

    func testEachLinkHasItsOwnToken() {
        let store = ShareLinkStore(fileURL: nil)
        let a = store.mint(paneSessionKey: "k1", label: "", lifetime: .day, now: now)
        let b = store.mint(paneSessionKey: "k1", label: "", lifetime: .day, now: now)
        XCTAssertNotEqual(a.token, b.token)
        XCTAssertNotEqual(a.link.id, b.link.id)
    }

    func testALinkExpires() {
        let store = ShareLinkStore(fileURL: nil)
        let (link, token) = store.mint(paneSessionKey: "k1", label: "", lifetime: .hour, now: now)
        XCTAssertTrue(store.isLive(id: link.id, now: now.addingTimeInterval(3599)))
        XCTAssertFalse(store.isLive(id: link.id, now: now.addingTimeInterval(3601)))
        XCTAssertEqual(store.check(token: token, paneSessionKey: "k1", now: now.addingTimeInterval(3601)), .expired)
    }

    func testNeverDoesNotExpire() {
        let store = ShareLinkStore(fileURL: nil)
        let (link, _) = store.mint(paneSessionKey: "k1", label: "", lifetime: .never, now: now)
        XCTAssertNil(link.expiresAt)
        XCTAssertTrue(store.isLive(id: link.id, now: now.addingTimeInterval(10 * 365 * 86_400)))
    }

    /// The new lifetime counts from when it was chosen, not from creation.
    func testChangingTheLifetimeRestartsTheClock() {
        let store = ShareLinkStore(fileURL: nil)
        let (link, token) = store.mint(paneSessionKey: "k1", label: "", lifetime: .hour, now: now)
        let later = now.addingTimeInterval(3000)
        let updated = store.setLifetime(id: link.id, .hour, now: later)
        XCTAssertEqual(updated?.expiresAt, later.addingTimeInterval(3600))
        XCTAssertEqual(store.check(token: token, paneSessionKey: "k1", now: now.addingTimeInterval(4000)),
                       .valid(id: link.id, recipient: nil))
    }

    func testRevokingOneLeavesTheOthers() {
        let store = ShareLinkStore(fileURL: nil)
        let a = store.mint(paneSessionKey: "k1", label: "", lifetime: .day, now: now)
        let b = store.mint(paneSessionKey: "k1", label: "", lifetime: .day, now: now)
        store.revoke(id: a.link.id)
        XCTAssertEqual(store.check(token: a.token, paneSessionKey: "k1", now: now), .invalid)
        XCTAssertEqual(store.check(token: b.token, paneSessionKey: "k1", now: now), .valid(id: b.link.id, recipient: nil))
    }

    func testRevokeAllForOnePane() {
        let store = ShareLinkStore(fileURL: nil)
        _ = store.mint(paneSessionKey: "k1", label: "", lifetime: .day, now: now)
        _ = store.mint(paneSessionKey: "k1", label: "", lifetime: .day, now: now)
        let other = store.mint(paneSessionKey: "k2", label: "", lifetime: .day, now: now)
        store.revokeAll(paneSessionKey: "k1")
        XCTAssertEqual(store.active(now: now).map(\.id), [other.link.id])
        store.revokeAll()
        XCTAssertTrue(store.active(now: now).isEmpty)
    }

    func testActiveDropsExpiredLinks() {
        let store = ShareLinkStore(fileURL: nil)
        _ = store.mint(paneSessionKey: "k1", label: "", lifetime: .hour, now: now)
        let kept = store.mint(paneSessionKey: "k1", label: "", lifetime: .week, now: now)
        XCTAssertEqual(store.active(now: now.addingTimeInterval(7200)).map(\.id), [kept.link.id])
    }

    func testChangesAreAnnounced() {
        let store = ShareLinkStore(fileURL: nil)
        var count = 0
        store.onChange = { count += 1 }
        let (link, _) = store.mint(paneSessionKey: "k1", label: "", lifetime: .day, now: now)
        store.setLifetime(id: link.id, .week, now: now)
        store.revoke(id: link.id)
        XCTAssertEqual(count, 3)
    }

    /// Survives a restart, and the file holds no token — a copy of it is not a
    /// set of keys to the panes.
    func testPersistsWithoutTheToken() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("share-links.json")
        let (link, token) = ShareLinkStore(fileURL: url)
            .mint(paneSessionKey: "k1", label: "pane", lifetime: .day, now: now)
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(text.contains(token))
        let reloaded = ShareLinkStore(fileURL: url)
        XCTAssertEqual(reloaded.check(token: token, paneSessionKey: "k1", now: now), .valid(id: link.id, recipient: nil))
        let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o600)
    }

    func testARecipientIsKeptAndCanBeSetLater() {
        let store = ShareLinkStore(fileURL: nil)
        let now = Date()
        let (link, token) = store.mint(paneSessionKey: "k1", label: "", lifetime: .day, now: now)
        XCTAssertNil(store.recipient(id: link.id))
        store.setRecipient(id: link.id, "  Wang\nMeng ")
        XCTAssertEqual(store.check(token: token, paneSessionKey: "k1", now: now),
                       .valid(id: link.id, recipient: "Wang Meng"))
        store.setRecipient(id: link.id, "   ")
        XCTAssertNil(store.recipient(id: link.id), "a blank name opens the link again")
    }

    /// The name stands inside `[from …]`, so it cannot close the bracket early.
    func testSenderNamesAreOneShortLineWithoutBrackets() {
        XCTAssertEqual(ShareLinkStore.senderName("[Matt] ok"), "Matt ok")
        XCTAssertEqual(ShareLinkStore.senderName(String(repeating: "a", count: 99))?.count, 40)
        XCTAssertNil(ShareLinkStore.senderName("\n\t"))
        XCTAssertNil(ShareLinkStore.senderName(nil))
    }
}
