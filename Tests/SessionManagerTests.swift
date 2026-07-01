import XCTest
@testable import seahelm

class SessionManagerTests: XCTestCase {
    func testPersistentSessionNameSanitizesDots() {
        let name = SessionManager.persistentSessionName(for: "/Users/test/repos/my.project/feature-1")
        XCTAssertFalse(name.contains("."))
        XCTAssertTrue(name.hasPrefix("amux-"))
    }

    func testPersistentSessionNameSanitizesColons() {
        let name = SessionManager.persistentSessionName(for: "/Users/test/repo:name/branch")
        XCTAssertFalse(name.contains(":"))
    }

    func testPersistentSessionNameFormat() {
        let name = SessionManager.persistentSessionName(for: "/Users/test/myrepo/feature-branch")
        XCTAssertEqual(name, "amux-myrepo-feature-branch")
    }

    func testSessionNameWithNestedPath() {
        let name = SessionManager.persistentSessionName(for: "/home/user/workspace/org/repo/feature")
        XCTAssertEqual(name, "amux-repo-feature")
    }

    func testLongSessionNameIsTruncatedWithHash() {
        let name = SessionManager.persistentSessionName(for: "/Users/dev/workspace/amux/amux-dashboard-consolidation")
        XCTAssertTrue(name.count <= 40, "Session name '\(name)' exceeds 40 chars (\(name.count))")
        XCTAssertTrue(name.hasPrefix("amux-"))
    }

    func testTruncatedSessionNameIsDeterministic() {
        let path = "/Users/dev/workspace/amux/amux-dashboard-consolidation"
        let a = SessionManager.persistentSessionName(for: path)
        let b = SessionManager.persistentSessionName(for: path)
        XCTAssertEqual(a, b)
    }

    func testDifferentLongPathsProduceDifferentNames() {
        let a = SessionManager.persistentSessionName(for: "/workspace/very-long-repo-name-here/very-long-branch-name-alpha")
        let b = SessionManager.persistentSessionName(for: "/workspace/very-long-repo-name-here/very-long-branch-name-beta")
        XCTAssertNotEqual(a, b)
    }

    func testSessionNamesExtractedFromSplitLayout() {
        let layout = CodableSplitNode.split(
            axis: "horizontal",
            ratio: 0.5,
            first: .leaf(sessionName: "amux-repo-main"),
            second: .leaf(sessionName: "amux-repo-main-1")
        )

        XCTAssertEqual(
            SessionManager.sessionNames(in: layout),
            ["amux-repo-main", "amux-repo-main-1"]
        )
    }

    func testParseZmxSessionNamesReadsNameEqualsFormat() {
        let output = """
        name=amux-repo-main pid=123 cwd=/tmp/repo
        name=amux-repo-main-1 pid=456 cwd=/tmp/repo
        """

        XCTAssertEqual(
            SessionManager.parseZmxSessionNames(listOutput: output),
            ["amux-repo-main", "amux-repo-main-1"]
        )
    }

    func testOrphanZmxSessionNamesOnlyReturnsAmuxSessionsNotInActiveSet() {
        let output = """
        name=amux-repo-main pid=123 cwd=/tmp/repo
        name=amux-repo-main-1 pid=456 cwd=/tmp/repo
        name=third-party pid=789 cwd=/tmp/other
        """

        let orphaned = SessionManager.orphanZmxSessionNames(
            activeSessionNames: ["amux-repo-main"],
            listOutput: output
        )

        XCTAssertEqual(orphaned, ["amux-repo-main-1"])
    }

    func testOrphanZmxSessionNamesNeverReapsAttachedSessions() {
        // Regression: the orphan sweep force-killed sessions purely by name, so a
        // live pane (clients=1) whose name wasn't in the expected set got killed
        // mid-use — "Process exited. Press any key to close the terminal."
        // An attached session (clients>=1) must never be reaped, even if orphaned.
        let output = """
        name=amux-repo-attached\tpid=1\tclients=1\tstart_dir=/tmp/a
        name=amux-repo-detached\tpid=2\tclients=0\tstart_dir=/tmp/d
        """

        let orphaned = SessionManager.orphanZmxSessionNames(
            activeSessionNames: [],   // neither is "expected"
            listOutput: output
        )

        XCTAssertEqual(orphaned, ["amux-repo-detached"],
                       "a session with a live client must never be reaped as orphan")
    }
}
