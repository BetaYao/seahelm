import XCTest
@testable import seahelm

final class TelegramPacketBookTests: XCTestCase {
    func testInFlightDuplicatesJoinOnePacket() {
        let book = TelegramPacketBook()
        var first: String?
        var second: String?
        XCTAssertEqual(book.begin(key: "chat|card", completion: { first = $0 }), .send)
        XCTAssertEqual(book.begin(key: "chat|card", completion: { second = $0 }), .joined)

        book.finish(key: "chat|card", messageID: "42")

        XCTAssertEqual(first, "42")
        XCTAssertEqual(second, "42")
    }

    func testDeliveredPacketIsNotSentAgain() {
        let book = TelegramPacketBook()
        XCTAssertEqual(book.begin(key: "chat|card", completion: nil), .send)
        book.finish(key: "chat|card", messageID: "42")

        XCTAssertEqual(book.begin(key: "chat|card", completion: nil), .delivered("42"))
    }

    func testFailedPacketMayTryAgain() {
        let book = TelegramPacketBook()
        XCTAssertEqual(book.begin(key: "chat|card", completion: nil), .send)
        book.finish(key: "chat|card", messageID: nil)

        XCTAssertEqual(book.begin(key: "chat|card", completion: nil), .send)
    }
}
