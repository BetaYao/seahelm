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

    /// The one instruction that reaches Codex, opencode, Cursor and Pi: they all
    /// read AGENTS.md, and `pane move` is the only path that does not depend on
    /// seahelm inferring the move from a cwd it may never see in time.
    func testWritesTheWorktreeMoveInstruction() throws {
        let url = tempFile(); defer { try? FileManager.default.removeItem(at: url) }
        SuggestGuidanceWriter.upsert(into: url)
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(text.contains("<!-- seahelm:worktree:start -->"))
        XCTAssertTrue(text.contains("seahelm pane move"))
        XCTAssertTrue(text.contains("$SEAHELM_PANE_ID"))
        XCTAssertTrue(text.contains("<!-- seahelm:worktree:end -->"))
    }

    /// Two managed blocks, each replaced in place — a second run must not stack
    /// either of them, and must not disturb the other.
    func testBothBlocksAreIdempotent() throws {
        let url = tempFile(); defer { try? FileManager.default.removeItem(at: url) }
        try "# Project\n".write(to: url, atomically: true, encoding: .utf8)
        SuggestGuidanceWriter.upsert(into: url)
        SuggestGuidanceWriter.upsert(into: url)
        SuggestGuidanceWriter.upsert(into: url)

        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertEqual(text.components(separatedBy: "<!-- seahelm:suggest:start -->").count - 1, 1)
        XCTAssertEqual(text.components(separatedBy: "<!-- seahelm:worktree:start -->").count - 1, 1)
        XCTAssertTrue(text.contains("# Project"))
    }

    /// A file that already carries the older single-block form gains the new one
    /// without losing or duplicating what is there.
    func testExistingSuggestOnlyFileGainsTheWorktreeBlock() throws {
        let url = tempFile(); defer { try? FileManager.default.removeItem(at: url) }
        let legacy = "# Project\n\n" + SuggestGuidanceWriter.managedBlock() + "\n"
        try legacy.write(to: url, atomically: true, encoding: .utf8)

        SuggestGuidanceWriter.upsert(into: url)

        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertEqual(text.components(separatedBy: "<!-- seahelm:suggest:start -->").count - 1, 1)
        XCTAssertTrue(text.contains("seahelm pane move"))
        XCTAssertTrue(text.contains("# Project"))
    }
}
