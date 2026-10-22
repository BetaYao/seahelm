import XCTest
@testable import seahelm

final class PanePresenceTests: XCTestCase {
    private func entry(_ origin: String, _ actor: String, note: String? = nil) -> PresenceEntry {
        PresenceEntry(originStationId: origin, actor: actor, note: note)
    }

    func testAPaneActingOnItselfShowsNothing() {
        var ledger = PresenceLedger()
        XCTAssertFalse(ledger.note(target: "p1", entry: entry("p1", "Claude Code #1")))
        XCTAssertTrue(ledger.entries(for: "p1").isEmpty)
    }

    func testOneActorIsOnePillWhateverItsCallCount() {
        var ledger = PresenceLedger()
        let now = Date()
        ledger.note(target: "p2", entry: entry("p1", "Claude Code #1", note: "reading"), now: now)
        ledger.note(target: "p2", entry: entry("p1", "Claude Code #1", note: "running tests"), now: now.addingTimeInterval(1))
        ledger.note(target: "p2", entry: entry("p3", "Codex #3"), now: now.addingTimeInterval(1))
        XCTAssertEqual(ledger.entries(for: "p2").map(\.label), ["Claude Code #1 · running tests", "Codex #3"])
    }

    /// A pill lingers after the last call and then goes; each call restarts it.
    func testMarksLapse() {
        var ledger = PresenceLedger()
        let now = Date()
        ledger.note(target: "p2", entry: entry("p1", "A"), now: now)
        ledger.note(target: "p2", entry: entry("p3", "B"), now: now.addingTimeInterval(4))
        let lapse = now.addingTimeInterval(PresenceLedger.linger + 1)
        XCTAssertEqual(ledger.prune(now: lapse), ["p2"])
        XCTAssertEqual(ledger.entries(for: "p2").map(\.actor), ["B"])
        XCTAssertEqual(ledger.prune(now: lapse.addingTimeInterval(PresenceLedger.linger)), ["p2"])
        XCTAssertTrue(ledger.entries(for: "p2").isEmpty)
        XCTAssertNil(ledger.nextExpiry)
    }

    func testNotesAreOneShortLine() {
        XCTAssertNil(PresenceLedger.cleanNote("   "))
        XCTAssertEqual(PresenceLedger.cleanNote(" first line \nsecond"), "first line")
        let long = String(repeating: "x", count: 200)
        XCTAssertEqual(PresenceLedger.cleanNote(long)?.count, PresenceLedger.maxNoteLength)
    }

    /// The router reports the caller on the pane it targets — or, for a split,
    /// on the pane it made — and never for calls that name no caller.
    func testRouterNotesPresenceForPaneActions() {
        final class Spy: ControlDataSource {
            var noted: [(String, String, String?)] = []
            func snapshotPanes() -> [PaneSnapshot] { [] }
            func readPane(paneId: String, source: String, lines: Int) -> String? { "" }
            func ingestHook(json: [String: Any]) {}
            func sendText(paneId: String, text: String, enter: Bool) -> Bool { true }
            func splitPane(paneId: String?, direction: String, focus: Bool) -> String? { "new" }
            func notePresence(callerPaneId: String, targetPaneId: String, note: String?) {
                noted.append((callerPaneId, targetPaneId, note))
            }
        }
        let spy = Spy()
        let router = ControlRouter(dataSource: spy)
        _ = router.handle(method: "pane.run", params: [
            "pane_id": "p2", "command": "ls", "_meta": ["caller": "p1", "note": "listing"]])
        _ = router.handle(method: "pane.split", params: ["pane_id": "p1", "_meta": ["caller": "p1"]])
        _ = router.handle(method: "pane.run", params: ["pane_id": "p2", "command": "ls"])
        _ = router.handle(method: "pane.close", params: ["pane_id": "p2", "_meta": ["caller": "p1"]])
        XCTAssertEqual(spy.noted.map { "\($0.0)>\($0.1):\($0.2 ?? "")" }, ["p1>p2:listing", "p1>new:"])
    }
}
