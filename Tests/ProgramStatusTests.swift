import XCTest
@testable import seahelm

/// OSC 7501 records (`ProgramStatusStore`) and how the live root record takes
/// part in status arbitration. Spec rules are cited as rev 0.4 sections.
final class ProgramStatusTests: XCTestCase {
    private typealias R = ProgramStatusReport

    // MARK: - Records

    /// "Each report replaces its record entirely": a key not re-sent is gone.
    func testReportReplacesWholeRecord() {
        var store = ProgramStatusStore()
        store.apply(R(state: .blocked, kind: .permission, app: "claude-code", msg: "approve Bash"))
        store.apply(R(state: .working, app: "claude-code"))
        XCTAssertEqual(store.root?.state, .working)
        XCTAssertNil(store.root?.report.kind)
        XCTAssertEqual(store.root?.report.msg, "")
    }

    func testClearWithIdRemovesThatSubtreeOnly() {
        var store = ProgramStatusStore()
        store.apply(R(state: .working, app: "deploy"))
        store.apply(R(state: .working, id: "us-east"))
        store.apply(R(state: .working, id: "us-east/db"))
        store.apply(R(state: .working, id: "us-eastern"))
        store.apply(R(state: .clear, id: "us-east"))
        XCTAssertEqual(Set(store.records.keys), ["", "us-eastern"])
    }

    func testClearWithoutIdRemovesEverything() {
        var store = ProgramStatusStore()
        store.apply(R(state: .working))
        store.apply(R(state: .done, id: "a"))
        XCTAssertTrue(store.apply(R(state: .clear)))
        XCTAssertTrue(store.records.isEmpty)
        XCTAssertFalse(store.apply(R(state: .clear)), "clearing nothing is not a change")
    }

    /// `app` comes from the nearest ancestor that has one — the root included.
    func testAppIsInheritedFromNearestAncestor() {
        var store = ProgramStatusStore()
        store.apply(R(state: .working, app: "deploy"))
        store.apply(R(state: .working, id: "eu", app: "terraform"))
        store.apply(R(state: .working, id: "eu/vpc"))
        store.apply(R(state: .working, id: "us/vpc"))
        XCTAssertEqual(store.records["eu/vpc"]?.app, "terraform")
        XCTAssertEqual(store.records["us/vpc"]?.app, "deploy")
    }

    /// On a new prompt `working` and `blocked` die (and `idle` may); `done` and
    /// `error` survive but describe a program that is gone, so they stop being live.
    func testPromptReturnedEndsTheProgramsRecords() {
        var store = ProgramStatusStore()
        store.apply(R(state: .done, app: "claude-code"))
        store.apply(R(state: .working, id: "a"))
        store.apply(R(state: .blocked, id: "b"))
        store.apply(R(state: .idle, id: "c"))
        store.apply(R(state: .error, id: "d"))
        XCTAssertNotNil(store.liveRoot)

        store.promptReturned()
        XCTAssertEqual(Set(store.records.keys), ["", "d"])
        XCTAssertNil(store.liveRoot)

        store.apply(R(state: .idle, app: "claude-code"))
        XCTAssertEqual(store.liveRoot?.state, .idle, "a report means a program is running again")
    }

    func testEvictsLeastRecentlyUpdatedPastTheLimit() {
        var store = ProgramStatusStore()
        for i in 0...ProgramStatusStore.maxRecords {
            store.apply(R(state: .working, id: "r\(i)"))
        }
        store.apply(R(state: .working, id: "r0"))   // r0 refreshed, so r1 is the oldest
        store.apply(R(state: .working, id: "extra"))
        XCTAssertEqual(store.records.count, ProgramStatusStore.maxRecords)
        XCTAssertNotNil(store.records["r0"])
        XCTAssertNil(store.records["r1"])
    }

    func testDisplayTextLosesBidiAndInvisibleFormatting() {
        let r = R(state: .blocked, title: "a\u{202E}b", msg: "rm\u{200B} -rf\u{2066}x")
        XCTAssertEqual(r.title, "ab")
        XCTAssertEqual(r.msg, "rm -rfx")
    }

    func testRecordMapsToAgentStatusAndMessage() {
        func record(_ r: R) -> ProgramStatusRecord {
            var store = ProgramStatusStore()
            store.apply(r)
            return store.root!
        }
        XCTAssertEqual(record(R(state: .working)).agentStatus, .running)
        XCTAssertEqual(record(R(state: .blocked)).agentStatus, .waiting)
        XCTAssertEqual(record(R(state: .done)).agentStatus, .idle)
        XCTAssertEqual(record(R(state: .idle)).agentStatus, .idle)
        XCTAssertEqual(record(R(state: .error)).agentStatus, .error)
        XCTAssertEqual(record(R(state: .blocked, kind: .question)).message, "Needs an answer")
        XCTAssertEqual(record(R(state: .blocked, kind: .permission, msg: "approve Bash: ls")).message,
                       "approve Bash: ls")
        XCTAssertEqual(record(R(state: .working)).message, "")
    }
}
