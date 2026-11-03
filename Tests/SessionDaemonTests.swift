import XCTest
@testable import seahelm

final class SessionDaemonTests: XCTestCase {
    func testSocketDir() {
        XCTAssertEqual(SeahelmdLocator.socketDir(environment: [:]), "/tmp/seahelmd-\(getuid())")
        XCTAssertEqual(SeahelmdLocator.socketDir(environment: ["SEAHELMD_DIR": "/s"]), "/s")
    }

    func testFactsAreTheBundledCatppuccinPalettes() {
        XCTAssertEqual(SeahelmdLocator.facts(dark: true), "fg=cdd6f4 bg=1e1e2e cursor=f5e0dc dark=1")
        XCTAssertEqual(SeahelmdLocator.facts(dark: false), "fg=4c4f69 bg=eff1f5 cursor=dc8a78 dark=0")
    }

    /// seahelmd's `list` rows read the way every parser expects.
    func testListRowsParse() {
        let rows = "name=seahelm-a\tpid=10\tclients=1\tcreated=1793700000\tcmd=claude\tcwd=/w/a\tstart_dir=/w/a\n"
            + "name=seahelm-b\tpid=20\tclients=0\tcreated=1793700001\tcmd=zsh\tcwd=/w/b c\tstart_dir=/w/b c\n"
            + "name=seahelm-c\tstatus=unreachable\n"
            + "name=seahelm-held\tpid=\tclients=0\tcreated=1793700002\tcmd=\tcwd=/w/h\tstart_dir=/w/h\n"
        XCTAssertEqual(SessionManager.parseSeahelmdSessionNames(listOutput: rows),
                       ["seahelm-a", "seahelm-b", "seahelm-c", "seahelm-held"])
        let b = SessionManager.parseSeahelmdSessions(listOutput: rows).first { $0.name == "seahelm-b" }
        XCTAssertEqual(b?.pid, 20)
        XCTAssertEqual(b?.clients, 0)
        XCTAssertEqual(b?.startDir, "/w/b c")
        XCTAssertEqual(SessionManager.reachability(of: "seahelm-c", listOutput: rows), .unreachable)
        XCTAssertEqual(SessionManager.reachability(of: "seahelm-held", listOutput: rows), .reachable)
        XCTAssertEqual(ProcessProbe.sessionPid(paneSessionKey: "seahelm-b", seahelmdListOutput: rows), 20)
        XCTAssertNil(SessionManager.parseSeahelmdSessions(listOutput: rows).first { $0.name == "seahelm-held" }?.pid)
    }
}
