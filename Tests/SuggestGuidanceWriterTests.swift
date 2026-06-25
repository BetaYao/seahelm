import XCTest
@testable import seahelm

final class SuggestGuidanceWriterTests: XCTestCase {
    private func tempFile() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("guidance-\(UUID().uuidString).md")
    }

    func testInsertsIntoNewFile() throws {
        let url = tempFile(); defer { try? FileManager.default.removeItem(at: url) }
        SuggestGuidanceWriter.upsert(into: url)
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(text.contains("<!-- seahelm:suggest:start -->"))
        XCTAssertTrue(text.contains("seahelm-suggest"))
        XCTAssertTrue(text.contains("<!-- seahelm:suggest:end -->"))
    }

    func testPreservesUserContentAndIsIdempotent() throws {
        let url = tempFile(); defer { try? FileManager.default.removeItem(at: url) }
        try "# My Project\n\nHello.\n".write(to: url, atomically: true, encoding: .utf8)

        SuggestGuidanceWriter.upsert(into: url)
        SuggestGuidanceWriter.upsert(into: url) // second run must not duplicate

        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(text.contains("# My Project"))
        XCTAssertTrue(text.contains("Hello."))
        let starts = text.components(separatedBy: "<!-- seahelm:suggest:start -->").count - 1
        XCTAssertEqual(starts, 1) // exactly one managed block
    }
}
