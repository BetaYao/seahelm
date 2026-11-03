import XCTest
@testable import seahelm

final class SessionDaemonTests: XCTestCase {
    func testSocketDir() {
        XCTAssertEqual(ZmxLocator.socketDir(environment: [:]), "/tmp/seahelmd-\(getuid())")
        XCTAssertEqual(ZmxLocator.socketDir(environment: ["SEAHELMD_DIR": "/s"]), "/s")
    }

    func testFactsAreTheBundledCatppuccinPalettes() {
        XCTAssertEqual(ZmxLocator.facts(dark: true), "fg=cdd6f4 bg=1e1e2e cursor=f5e0dc dark=1")
        XCTAssertEqual(ZmxLocator.facts(dark: false), "fg=4c4f69 bg=eff1f5 cursor=dc8a78 dark=0")
    }

    /// seahelmd's `list` rows read the way every parser expects.
    func testListRowsParse() {
        let rows = "name=seahelm-a\tpid=10\tclients=1\tcreated=1793700000\tcmd=claude\tcwd=/w/a\tstart_dir=/w/a\n"
            + "name=seahelm-b\tpid=20\tclients=0\tcreated=1793700001\tcmd=zsh\tcwd=/w/b c\tstart_dir=/w/b c\n"
            + "name=seahelm-c\tstatus=unreachable\n"
            + "name=seahelm-held\tpid=\tclients=0\tcreated=1793700002\tcmd=\tcwd=/w/h\tstart_dir=/w/h\n"
        XCTAssertEqual(SessionManager.parseZmxSessionNames(listOutput: rows),
                       ["seahelm-a", "seahelm-b", "seahelm-c", "seahelm-held"])
        let b = SessionManager.parseZmxSessions(listOutput: rows).first { $0.name == "seahelm-b" }
        XCTAssertEqual(b?.pid, 20)
        XCTAssertEqual(b?.clients, 0)
        XCTAssertEqual(b?.startDir, "/w/b c")
        XCTAssertEqual(SessionManager.reachability(of: "seahelm-c", listOutput: rows), .unreachable)
        XCTAssertEqual(SessionManager.reachability(of: "seahelm-held", listOutput: rows), .reachable)
        XCTAssertEqual(ProcessProbe.sessionPid(paneSessionKey: "seahelm-b", zmxListOutput: rows), 20)
        XCTAssertNil(SessionManager.parseZmxSessions(listOutput: rows).first { $0.name == "seahelm-held" }?.pid)
    }

    // MARK: - Ending the zmx sessions left from before seahelmd

    func testLegacySocketDirIsZmxsOwnRule() {
        let uid = getuid()
        XCTAssertEqual(LegacyZmxSessions.socketDir(environment: ["ZMX_DIR": "/x"]), "/x")
        XCTAssertEqual(LegacyZmxSessions.socketDir(environment: ["XDG_RUNTIME_DIR": "/run/u"]), "/run/u/zmx")
        XCTAssertEqual(LegacyZmxSessions.socketDir(environment: ["TMPDIR": "/var/folders/ab/T/"]), "/var/folders/ab/T/zmx-\(uid)")
        XCTAssertEqual(LegacyZmxSessions.socketDir(environment: [:]), "/tmp/zmx-\(uid)")
    }

    /// Only the sessions seahelm named; one the user started by hand is theirs.
    func testOnlySeahelmsOwnSessionsAreEnded() {
        XCTAssertEqual(LegacyZmxSessions.managedSessions(in: ["seahelm-b", "mine", "amux-old", "seahelm-a.log"]),
                       ["amux-old", "seahelm-a.log", "seahelm-b"].sorted())
    }

    /// For real: a process holding a socket in the zmx directory is ended and
    /// the socket removed; a hand-made session is left alone.
    func testEndAllEndsWhatHoldsTheSockets() throws {
        let dir = "/tmp/zmx-xc-\(getpid())"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        func listener(_ name: String) throws -> Process {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            p.arguments = ["-c", "import socket,sys,time\ns=socket.socket(socket.AF_UNIX)\ns.bind(sys.argv[1])\ns.listen()\ntime.sleep(60)",
                           "\(dir)/\(name)"]
            try p.run()
            return p
        }
        let ours = try listener("seahelm-old-pane")
        let theirs = try listener("by-hand")
        defer { theirs.terminate() }
        let deadline = Date().addingTimeInterval(5)
        while !FileManager.default.fileExists(atPath: "\(dir)/by-hand") || !FileManager.default.fileExists(atPath: "\(dir)/seahelm-old-pane") {
            XCTAssertLessThan(Date(), deadline); Thread.sleep(forTimeInterval: 0.05)
        }
        XCTAssertEqual(LegacyZmxSessions.endAll(environment: ["ZMX_DIR": dir]), ["seahelm-old-pane"])
        ours.waitUntilExit()
        XCTAssertFalse(FileManager.default.fileExists(atPath: "\(dir)/seahelm-old-pane"))
        XCTAssertTrue(theirs.isRunning, "a session the user made by hand was touched")
        XCTAssertEqual(LegacyZmxSessions.endAll(environment: ["ZMX_DIR": dir]), [], "a second launch does nothing")
    }
}
