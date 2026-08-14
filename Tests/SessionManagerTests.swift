import XCTest
@testable import seahelm

class SessionManagerTests: XCTestCase {
    func testPersistentSessionNameSanitizesDots() {
        let name = SessionManager.persistentSessionName(for: "/Users/test/repos/my.project/feature-1")
        XCTAssertFalse(name.contains("."))
        XCTAssertTrue(name.hasPrefix("seahelm-"))
    }

    func testPersistentSessionNameSanitizesColons() {
        let name = SessionManager.persistentSessionName(for: "/Users/test/repo:name/branch")
        XCTAssertFalse(name.contains(":"))
    }

    func testPersistentSessionNameFormat() {
        let name = SessionManager.persistentSessionName(for: "/Users/test/myrepo/feature-branch")
        XCTAssertEqual(name, "seahelm-myrepo-feature-branch")
    }

    func testSessionNameWithNestedPath() {
        let name = SessionManager.persistentSessionName(for: "/home/user/workspace/org/repo/feature")
        XCTAssertEqual(name, "seahelm-repo-feature")
    }

    func testLongSessionNameIsTruncatedWithHash() {
        let name = SessionManager.persistentSessionName(for: "/Users/dev/workspace/seahelm/seahelm-dashboard-consolidation")
        XCTAssertTrue(name.count <= 40, "Session name '\(name)' exceeds 40 chars (\(name.count))")
        XCTAssertTrue(name.hasPrefix("seahelm-"))
    }

    func testTruncatedSessionNameIsDeterministic() {
        let path = "/Users/dev/workspace/seahelm/seahelm-dashboard-consolidation"
        let a = SessionManager.persistentSessionName(for: path)
        let b = SessionManager.persistentSessionName(for: path)
        XCTAssertEqual(a, b)
    }

    func testDifferentLongPathsProduceDifferentNames() {
        let a = SessionManager.persistentSessionName(for: "/workspace/very-long-repo-name-here/very-long-branch-name-alpha")
        let b = SessionManager.persistentSessionName(for: "/workspace/very-long-repo-name-here/very-long-branch-name-beta")
        XCTAssertNotEqual(a, b)
    }

    func testParseZmxSessionNamesReadsNameEqualsFormat() {
        let output = """
        name=seahelm-repo-main pid=123 cwd=/tmp/repo
        name=seahelm-repo-main-1 pid=456 cwd=/tmp/repo
        """

        XCTAssertEqual(
            SessionManager.parseZmxSessionNames(listOutput: output),
            ["seahelm-repo-main", "seahelm-repo-main-1"]
        )
    }

    func testOrphanZmxSessionNamesOnlyReturnsSeahelmSessionsNotInActiveSet() {
        let output = """
        name=seahelm-repo-main pid=123 clients=1 cwd=/tmp/repo
        name=seahelm-repo-main-1 pid=456 clients=0 cwd=/tmp/repo
        name=third-party pid=789 clients=0 cwd=/tmp/other
        """

        let orphaned = SessionManager.orphanZmxSessionNames(
            activeSessionNames: ["seahelm-repo-main"],
            listOutput: output
        )

        XCTAssertEqual(orphaned, ["seahelm-repo-main-1"])
    }

    func testOrphanZmxSessionNamesNeverReapsAttachedSessions() {
        // Regression: the orphan sweep force-killed sessions purely by name, so a
        // live pane (clients=1) whose name wasn't in the expected set got killed
        // mid-use — "Process exited. Press any key to close the terminal."
        // An attached session (clients>=1) must never be reaped, even if orphaned.
        let output = """
        name=seahelm-repo-attached\tpid=1\tclients=1\tstart_dir=/tmp/a
        name=seahelm-repo-detached\tpid=2\tclients=0\tstart_dir=/tmp/d
        """

        let orphaned = SessionManager.orphanZmxSessionNames(
            activeSessionNames: [],   // neither is "expected"
            listOutput: output
        )

        XCTAssertEqual(orphaned, ["seahelm-repo-detached"],
                       "a session with a live client must never be reaped as orphan")
    }

    func testOrphanZmxSessionNamesHandlesLegacyAmuxPrefix() {
        let output = """
        name=amux-repo-feature pid=123 clients=0 cwd=/tmp/repo
        name=seahelm-repo-other pid=456 clients=0 cwd=/tmp/other
        """

        let orphaned = SessionManager.orphanZmxSessionNames(
            activeSessionNames: ["seahelm-repo-feature"],
            listOutput: output
        )

        XCTAssertEqual(orphaned, ["amux-repo-feature", "seahelm-repo-other"])
    }

    func testOrphanZmxSessionNamesDoesNotReapActiveAmuxSession() {
        let output = """
        name=amux-repo-feature pid=123 clients=1 cwd=/tmp/repo
        name=amux-repo-detached pid=456 clients=0 cwd=/tmp/other
        """

        let orphaned = SessionManager.orphanZmxSessionNames(
            activeSessionNames: [],
            listOutput: output
        )

        XCTAssertEqual(orphaned, ["amux-repo-detached"],
                       "amux- session with a live client must not be reaped")
    }

    func testOrphanZmxSessionNamesNeverReapsUnreachableSessions() {
        // Regression: a busy daemon that misses the `zmx list` control-socket
        // probe reports `status=unreachable`/`err=…` with no `clients=` field.
        // The old guard read a missing clients count as 0 and reaped it, killing
        // the live pane mid-use. Only positively-idle, reachable sessions
        // (clients=0, no error) may be reaped.
        let output = """
          name=seahelm-repo-busy\terr=Timeout\tstatus=unreachable
          name=seahelm-repo-nostatus\tpid=3\tstart_dir=/tmp/n
          name=seahelm-repo-idle\tpid=4\tclients=0\tcreated=1\tstart_dir=/tmp/i
        """

        let orphaned = SessionManager.orphanZmxSessionNames(
            activeSessionNames: [],   // none are "expected"
            listOutput: output
        )

        XCTAssertEqual(orphaned, ["seahelm-repo-idle"],
                       "only a reachable session with a known clients=0 may be reaped")
    }

    // MARK: - Session monitor parsing

    func testParseZmxSessionsReadsEveryField() {
        let output = "  name=seahelm-repo-main\tpid=123\tclients=2\tcreated=1785228325\tstart_dir=/tmp/repo"

        let sessions = SessionManager.parseZmxSessions(listOutput: output)

        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions[0].name, "seahelm-repo-main")
        XCTAssertEqual(sessions[0].pid, 123)
        XCTAssertEqual(sessions[0].clients, 2)
        XCTAssertEqual(sessions[0].created, Date(timeIntervalSince1970: 1_785_228_325))
        XCTAssertEqual(sessions[0].startDir, "/tmp/repo")
        XCTAssertTrue(sessions[0].isManaged)
        XCTAssertFalse(sessions[0].isDetached)
    }

    /// The monitor lists everything `zmx list` reports, including sessions the
    /// user started by hand — hiding rows from a cleanup screen is the one thing
    /// it must not do. `isManaged` is what gates the kill buttons instead.
    func testParseZmxSessionsIncludesUnmanagedSessions() {
        let output = """
          name=seahelm-repo-main\tpid=1\tclients=1
          name=my-own-session\tpid=2\tclients=1
        """

        let sessions = SessionManager.parseZmxSessions(listOutput: output)

        XCTAssertEqual(sessions.map(\.name), ["seahelm-repo-main", "my-own-session"])
        XCTAssertEqual(sessions.map(\.isManaged), [true, false])
    }

    /// A missing `clients=` is unknown, not zero — the distinction is what keeps
    /// a busy-but-unreported session out of "Kill All Detached".
    func testParseZmxSessionsKeepsMissingClientsNil() {
        let sessions = SessionManager.parseZmxSessions(
            listOutput: "  name=seahelm-repo-busy\terr=Timeout\tstatus=unreachable")

        XCTAssertEqual(sessions.count, 1)
        XCTAssertNil(sessions[0].clients)
        XCTAssertFalse(sessions[0].isDetached)
    }

    func testParseZmxSessionsKeepsSpacesInStartDir() {
        let sessions = SessionManager.parseZmxSessions(
            listOutput: "  name=seahelm-a\tpid=1\tclients=0\tstart_dir=/tmp/my repo/wt")

        XCTAssertEqual(sessions[0].startDir, "/tmp/my repo/wt")
        XCTAssertTrue(sessions[0].isDetached)
    }

    func testParseZmxSessionsIgnoresBlankLines() {
        XCTAssertTrue(SessionManager.parseZmxSessions(listOutput: "\n  \n").isEmpty)
    }

    // MARK: - Orphan zmx client processes

    private static let zmxPath = "/App/Contents/Resources/bin/zmx"

    private func proc(_ pid: Int32, _ ppid: Int32, _ cmd: String) -> SessionManager.ZmxProcess {
        SessionManager.ZmxProcess(pid: pid, ppid: ppid, command: cmd)
    }

    private func zmx(_ pid: Int32, _ ppid: Int32, _ session: String = "seahelm-a") -> SessionManager.ZmxProcess {
        proc(pid, ppid, "\(Self.zmxPath) attach \(session)")
    }

    /// The login wrapper Station spawns each pane through. Its command line names
    /// the zmx binary but quotes it, so it must not read as a zmx process itself.
    private static let loginWrapper =
        "/usr/bin/login -flp me /bin/bash -c exec -l /usr/bin/env -u ZMX_SESSION '\(zmxPath)' attach seahelm-a"

    /// The shape a pane actually has: app → login → client → daemon → shell,
    /// with `zmx list` reporting the *shell's* pid for the session.
    private func livePaneTree() -> [SessionManager.ZmxProcess] {
        [
            proc(79811, 1, "/App/Contents/MacOS/Seahelm"),
            proc(95359, 79811, Self.loginWrapper),
            zmx(95362, 95359),
            zmx(95363, 95362),
            proc(95364, 95363, "-zsh"),
        ]
    }

    func testLivePaneReapsNothing() {
        let pids = SessionManager.orphanZmxClientPids(processes: livePaneTree(), sessionPids: [95364])
        XCTAssertEqual(pids, [], "nothing is orphaned while the app is alive")
    }

    /// The regression: `zmx list` reports the pid of the process *inside* the
    /// session, so a set of those pids never intersects the zmx processes being
    /// swept — the sweep reaped every surviving daemon and killed all 8 live
    /// sessions ~5 minutes after each restart.
    func testOrphanedDaemonIsNeverReaped() {
        // The previous app (and its login) are gone; the client was adopted by
        // launchd and still parents the daemon that holds the agent.
        let processes = [zmx(95362, 1), zmx(95363, 95362), proc(95364, 95363, "-zsh")]
        let pids = SessionManager.orphanZmxClientPids(processes: processes, sessionPids: [95364])
        XCTAssertEqual(pids, [95362], "the client is reaped, the daemon hosting the session is not")
    }

    /// Once its client is gone the daemon is the ppid-1 zmx process itself.
    func testLoneOrphanedDaemonIsKept() {
        let processes = [zmx(95363, 1), proc(95364, 95363, "-zsh")]
        XCTAssertEqual(SessionManager.orphanZmxClientPids(processes: processes, sessionPids: [95364]), [])
    }

    func testOrphanClientIsReaped() {
        let processes = livePaneTree() + [zmx(300, 1)]
        XCTAssertEqual(SessionManager.orphanZmxClientPids(processes: processes, sessionPids: [95364]), [300])
    }

    func testClientWithLiveParentIsKept() {
        let processes = livePaneTree() + [zmx(300, 9478)]
        XCTAssertEqual(SessionManager.orphanZmxClientPids(processes: processes, sessionPids: [95364]), [])
    }

    /// Without session pids every daemon looks orphaned, so the sweep must
    /// refuse rather than guess.
    func testEmptySessionListReapsNothing() {
        XCTAssertEqual(SessionManager.orphanZmxClientPids(processes: [zmx(300, 1)], sessionPids: []), [])
    }

    /// A session whose daemon can't be resolved (ps and `zmx list` disagreeing,
    /// e.g. the shell exited between the two calls) abandons the whole sweep:
    /// reaping nothing costs CPU, guessing costs agents.
    func testUnresolvableSessionAbandonsSweep() {
        let processes = livePaneTree() + [zmx(300, 1)]
        XCTAssertEqual(SessionManager.orphanZmxClientPids(processes: processes, sessionPids: [95364, 777]), [])
    }

    /// Future-proofing: if zmx ever reports the daemon's own pid, the walk starts
    /// at that pid and still protects it.
    func testDaemonReportedDirectlyIsKept() {
        let processes = [zmx(95363, 1), proc(95364, 95363, "-zsh")]
        XCTAssertEqual(SessionManager.orphanZmxClientPids(processes: processes, sessionPids: [95363]), [])
    }

    /// The two worst offenders found were spinning against live sessions, so a
    /// "target session is gone" test would have missed them entirely.
    func testOrphanAgainstLiveSessionIsStillReaped() {
        let processes = livePaneTree() + [zmx(300, 1, "seahelm-a")]
        XCTAssertEqual(SessionManager.orphanZmxClientPids(processes: processes, sessionPids: [95364]), [300])
    }

    /// Every row is parsed now — resolving a daemon means walking parents through
    /// the non-zmx processes in between — so the binary test moved to `isZmxBinary`.
    func testParsePsOutputKeepsEveryRowAndFlagsZmxBinaries() {
        let ps = """
          300     1 /Volumes/x/Seahelm.app/Contents/Resources/bin/zmx attach seahelm-a
          301  9478 /Volumes/x/Seahelm.app/Contents/Resources/bin/zmx run seahelm-b /bin/zsh
          302     1 /usr/bin/node --flag zmx-ish-name
          303     1 claude --resume zmx
          304     1 /usr/bin/login -flp me /bin/bash -c exec -l /usr/bin/env '/App/bin/zmx' attach seahelm-a
        """
        let parsed = SessionManager.parseZmxProcesses(psOutput: ps)
        XCTAssertEqual(parsed.map(\.pid), [300, 301, 302, 303, 304])
        XCTAssertEqual(
            parsed.filter(\.isZmxBinary).map(\.pid), [300, 301],
            "only the vendored zmx binary counts — not a login wrapper naming it")
    }
}
