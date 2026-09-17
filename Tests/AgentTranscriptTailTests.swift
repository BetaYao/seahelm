import XCTest
@testable import seahelm

final class AgentTranscriptTailTests: XCTestCase {
    private var url: URL!
    private let longAgo = Date(timeIntervalSince1970: 0)

    override func setUp() {
        super.setUp()
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("transcript-\(UUID().uuidString).jsonl")
        FileManager.default.createFile(atPath: url.path, contents: nil)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: url)
        super.tearDown()
    }

    private func stamp(_ seconds: TimeInterval) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: Date(timeIntervalSince1970: seconds))
    }

    private func claude(_ blocks: [[String: Any]], at seconds: TimeInterval = 1000, sidechain: Bool = false) -> String {
        json(["type": "assistant", "isSidechain": sidechain, "timestamp": stamp(seconds),
              "message": ["role": "assistant", "content": blocks]])
    }

    private func json(_ obj: [String: Any]) -> String {
        String(data: try! JSONSerialization.data(withJSONObject: obj), encoding: .utf8)!
    }

    private func write(_ s: String) {
        let handle = try! FileHandle(forWritingTo: url)
        handle.seekToEndOfFile()
        handle.write(Data(s.utf8))
        handle.closeFile()
    }

    func testReadsClaudeProseBetweenToolCallsInOrder() {
        write([
            json(["type": "user", "timestamp": stamp(999), "message": ["role": "user", "content": "fix it"]]),
            claude([["type": "thinking", "thinking": "", "signature": "redacted"]]),
            claude([["type": "text", "text": "先看一下是怎么消失的。"]]),
            claude([["type": "tool_use", "name": "Bash", "input": [:]]]),
            json(["type": "user", "timestamp": stamp(1001), "message": ["role": "user", "content": [["type": "tool_result"]]]]),
            claude([["type": "text", "text": "找到了根源。"]]),
        ].joined(separator: "\n") + "\n")
        let tail = AgentTranscriptTail()
        XCTAssertEqual(tail.newProse(path: url.path, since: longAgo).map(\.text),
                       ["先看一下是怎么消失的。", "找到了根源。"])
    }

    func testOnlyWhatWasAppendedSinceTheLastRead() {
        let tail = AgentTranscriptTail()
        write(claude([["type": "text", "text": "one"]]) + "\n")
        XCTAssertEqual(tail.newProse(path: url.path, since: longAgo).map(\.text), ["one"])
        XCTAssertTrue(tail.newProse(path: url.path, since: longAgo).isEmpty)
        write(claude([["type": "text", "text": "two"]]) + "\n")
        XCTAssertEqual(tail.newProse(path: url.path, since: longAgo).map(\.text), ["two"])
    }

    /// The agent may be mid-write when a hook arrives.
    func testALineStillBeingWrittenWaitsForItsNewline() {
        let tail = AgentTranscriptTail()
        let line = claude([["type": "text", "text": "partial"]])
        write(String(line.prefix(20)))
        XCTAssertTrue(tail.newProse(path: url.path, since: longAgo).isEmpty)
        write(String(line.dropFirst(20)) + "\n")
        XCTAssertEqual(tail.newProse(path: url.path, since: longAgo).map(\.text), ["partial"])
    }

    func testFirstReadSkipsWhatTheTimelineAlreadyHas() {
        write([claude([["type": "text", "text": "old"]], at: 1000),
               claude([["type": "text", "text": "new"]], at: 2000)].joined(separator: "\n") + "\n")
        let tail = AgentTranscriptTail()
        XCTAssertEqual(tail.newProse(path: url.path, since: Date(timeIntervalSince1970: 1500)).map(\.text), ["new"])
    }

    func testFirstReadOfALongTranscriptStartsNearItsEnd() {
        let filler = claude([["type": "text", "text": String(repeating: "x", count: 500)]])
        write(Array(repeating: filler, count: 20).joined(separator: "\n") + "\n")
        write(claude([["type": "text", "text": "latest"]]) + "\n")
        let tail = AgentTranscriptTail(firstReadBytes: 1200)
        let texts = tail.newProse(path: url.path, since: longAgo).map(\.text)
        XCTAssertEqual(texts.last, "latest")
        XCTAssertLessThan(texts.count, 5, "not the whole session")
    }

    func testSubagentProseIsNotThePanes() {
        write(claude([["type": "text", "text": "subagent chatter"]], sidechain: true) + "\n")
        XCTAssertTrue(AgentTranscriptTail().newProse(path: url.path, since: longAgo).isEmpty)
    }

    func testSuggestionSentinelIsStrippedLikeTheStopHookDoes() {
        write(claude([["type": "text", "text": "Done.\n\n::seahelm-suggest:: push | open PR"]]) + "\n")
        XCTAssertEqual(AgentTranscriptTail().newProse(path: url.path, since: longAgo).map(\.text), ["Done."])
    }

    func testReadsCodexAssistantMessages() {
        write([
            json(["type": "response_item", "timestamp": stamp(1000),
                  "payload": ["type": "reasoning", "summary": []]]),
            json(["type": "response_item", "timestamp": stamp(1001),
                  "payload": ["type": "message", "role": "assistant",
                              "content": [["type": "output_text", "text": "已合并 PR"]]]]),
            json(["type": "response_item", "timestamp": stamp(1002),
                  "payload": ["type": "message", "role": "user",
                              "content": [["type": "input_text", "text": "merge it"]]]]),
        ].joined(separator: "\n") + "\n")
        XCTAssertEqual(AgentTranscriptTail().newProse(path: url.path, since: longAgo).map(\.text), ["已合并 PR"])
    }

    func testAReplacedShorterFileIsReadFromItsStart() {
        let tail = AgentTranscriptTail()
        write(Array(repeating: claude([["type": "text", "text": "a long first session"]]), count: 5)
            .joined(separator: "\n") + "\n")
        _ = tail.newProse(path: url.path, since: longAgo)
        try! Data((claude([["type": "text", "text": "fresh"]], at: 3000) + "\n").utf8).write(to: url)
        XCTAssertEqual(tail.newProse(path: url.path, since: Date(timeIntervalSince1970: 2000)).map(\.text), ["fresh"])
    }

    /// Claude Code shows some progress narration from thinking blocks; a redacted
    /// block is empty and must not become an empty row.
    func testVisibleThinkingIsKeptApartFromWhatIsSaid() {
        write([
            claude([["type": "thinking", "thinking": "", "signature": "redacted"]], at: 1000),
            claude([["type": "thinking", "thinking": "链路验证通了，接下来查时间戳格式。\n\n"]], at: 1001),
            claude([["type": "text", "text": "顺序对了。"]], at: 1002),
        ].joined(separator: "\n") + "\n")
        let entries = AgentTranscriptTail().newProse(path: url.path, since: longAgo)
        XCTAssertEqual(entries.map(\.kind), [.thinking, .text])
        XCTAssertEqual(entries.map(\.text), ["链路验证通了，接下来查时间戳格式。", "顺序对了。"])
    }

    func testCodexReasoningSummaryIsThinking() {
        write(json(["type": "response_item", "timestamp": stamp(1000),
                    "payload": ["type": "reasoning", "encrypted_content": "x",
                                "summary": [["type": "summary_text", "text": "**Checking the merge state**"]]]]) + "\n")
        let entries = AgentTranscriptTail().newProse(path: url.path, since: longAgo)
        XCTAssertEqual(entries.map(\.kind), [.thinking])
        XCTAssertEqual(entries.first?.text, "**Checking the merge state**")
    }

    func testMissingFileIsQuiet() {
        XCTAssertTrue(AgentTranscriptTail().newProse(path: "/nonexistent/x.jsonl", since: longAgo).isEmpty)
    }
}
