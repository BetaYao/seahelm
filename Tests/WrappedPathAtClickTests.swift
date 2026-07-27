import XCTest
@testable import seahelm

/// Covers the pure halves of the pane's right-click path detection: which viewport
/// rows get read for a click, and which logical line of a multi-row read is the one
/// touching that click. Together these are what let a soft-wrapped path resolve —
/// a single-row read truncates it and it stops matching a file on disk.
final class WrappedPathAtClickTests: XCTestCase {

    // MARK: - wrapSearchPlan

    func testClickedRowIsTriedFirst() {
        let plan = GhosttyNSView.wrapSearchPlan(row: 10, rowCount: 40, span: 3)
        XCTAssertEqual(plan.first?.range, 10...10)
        XCTAssertEqual(plan.first?.pick, .only)
    }

    func testSearchesDownwardThenUpward() {
        let plan = GhosttyNSView.wrapSearchPlan(row: 10, rowCount: 40, span: 3)
        XCTAssertEqual(plan.count, 3)
        // A token that began on the clicked row wraps downward.
        XCTAssertEqual(plan[1].range, 10...13)
        XCTAssertEqual(plan[1].pick, .first)
        // A click that landed on a continuation row has to look up.
        XCTAssertEqual(plan[2].range, 7...10)
        XCTAssertEqual(plan[2].pick, .last)
    }

    func testSpanIsClampedToTheGrid() {
        let atTop = GhosttyNSView.wrapSearchPlan(row: 1, rowCount: 40, span: 3)
        XCTAssertEqual(atTop.map(\.range), [1...1, 1...4, 0...1])

        let atBottom = GhosttyNSView.wrapSearchPlan(row: 38, rowCount: 40, span: 3)
        XCTAssertEqual(atBottom.map(\.range), [38...38, 38...39, 35...38])
    }

    func testFirstRowHasNoUpwardRead() {
        let plan = GhosttyNSView.wrapSearchPlan(row: 0, rowCount: 40, span: 3)
        XCTAssertEqual(plan.map(\.range), [0...0, 0...3])
    }

    func testLastRowHasNoDownwardRead() {
        let plan = GhosttyNSView.wrapSearchPlan(row: 39, rowCount: 40, span: 3)
        XCTAssertEqual(plan.map(\.range), [39...39, 36...39])
    }

    func testSingleRowGridOnlyReadsItself() {
        XCTAssertEqual(GhosttyNSView.wrapSearchPlan(row: 0, rowCount: 1, span: 3).map(\.range), [0...0])
    }

    func testOutOfRangeRowsYieldNoPlan() {
        XCTAssertTrue(GhosttyNSView.wrapSearchPlan(row: -1, rowCount: 40, span: 3).isEmpty)
        XCTAssertTrue(GhosttyNSView.wrapSearchPlan(row: 40, rowCount: 40, span: 3).isEmpty)
        XCTAssertTrue(GhosttyNSView.wrapSearchPlan(row: 0, rowCount: 0, span: 3).isEmpty)
    }

    // MARK: - logicalLine

    func testOnlyReturnsTheWholeRead() {
        XCTAssertEqual(GhosttyNSView.logicalLine(from: "a/b.txt", pick: .only), "a/b.txt")
    }

    /// Ghostty joins soft-wrapped rows, so the wrapped path arrives as one piece and
    /// hard line breaks are the only `\n`. Reading downward, the clicked row's line is first.
    func testFirstTakesTheLineTheClickStarted() {
        let read = "services/supabase/migrations/20260727_sessions_source_read_path.sql\nnext line\nanother"
        XCTAssertEqual(
            GhosttyNSView.logicalLine(from: read, pick: .first),
            "services/supabase/migrations/20260727_sessions_source_read_path.sql"
        )
    }

    /// Reading upward, the line reaching the clicked row is the last one.
    func testLastTakesTheLineReachingTheClick() {
        let read = "earlier output\nmore output\n/Volumes/openbeta/workspace/a/very/long/path.sql"
        XCTAssertEqual(
            GhosttyNSView.logicalLine(from: read, pick: .last),
            "/Volumes/openbeta/workspace/a/very/long/path.sql"
        )
    }

    func testNoHardBreakMeansTheWholeReadIsOneLogicalLine() {
        let read = "one/wrapped/token/that/spans/rows.sql"
        XCTAssertEqual(GhosttyNSView.logicalLine(from: read, pick: .first), read)
        XCTAssertEqual(GhosttyNSView.logicalLine(from: read, pick: .last), read)
    }

    func testEmptyReadIsHandled() {
        XCTAssertEqual(GhosttyNSView.logicalLine(from: "", pick: .first), "")
        XCTAssertEqual(GhosttyNSView.logicalLine(from: "", pick: .last), "")
    }

    /// A trailing hard break must not make the "last" line swallow the previous one.
    func testTrailingNewlineYieldsAnEmptyLastLine() {
        XCTAssertEqual(GhosttyNSView.logicalLine(from: "path.sql\n", pick: .last), "")
    }

    // MARK: - End-to-end shape

    /// The truncated half of a wrapped path must not resolve, while the joined form does.
    /// This is the actual failure: `filePathAtClick` used to see only the truncated half.
    func testTruncatedHalfDoesNotResolveButJoinedFormDoes() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("wrapped-path-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let name = "20260727000000_sessions_source_read_path.sql"
        try "-- migration".write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)

        let bases: [String?] = [dir.path]
        // What a single-row read produced: the tail wrapped onto the next row.
        let truncated = String(name.dropLast("th.sql".count))
        XCTAssertNil(GhosttyNSView.resolveSelectedPath(raw: truncated, bases: bases))
        // What the multi-row read produces once ghostty rejoins the rows.
        XCTAssertEqual(
            GhosttyNSView.resolveSelectedPath(raw: name, bases: bases)?.lastPathComponent,
            name
        )
    }
}
