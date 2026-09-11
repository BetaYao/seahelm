import XCTest
@testable import seahelm

/// Regression for the mid-session external-volume drop: attach clients spin,
/// `resolvingSymlinksInPath` beachballs the main thread, and the one-shot
/// health check never looks again.
final class VolumeDropRecoveryTests: XCTestCase {

    override func tearDown() {
        VolumeFence.resetForTesting()
        WorktreeDiscovery.resetCanonicalPathResolverForTesting()
        super.tearDown()
    }

    // MARK: - Bounded canonical paths

    /// `resolvingSymlinksInPath` against a stale mount blocks forever in the
    /// kernel. When the resolver times out, callers must still get a usable
    /// string-identity path rather than hanging on the main thread.
    func testCanonicalPathFallsBackWhenResolverTimesOut() {
        WorktreeDiscovery.canonicalPathResolverForTesting = { _ in nil }
        let path = "/Volumes/dead-disk/repo/../worktree"
        XCTAssertEqual(
            WorktreeDiscovery.canonicalPath(path),
            URL(fileURLWithPath: path).standardizedFileURL.path
        )
    }

    /// A fenced volume must never touch the filesystem for path compares —
    /// that is the beachball that freezes the fleet overview mid-drop.
    func testCanonicalPathSkipsFilesystemWhenVolumeIsFenced() {
        VolumeFence.fence("/Volumes/openbeta")
        var resolverCalls = 0
        WorktreeDiscovery.canonicalPathResolverForTesting = { path in
            resolverCalls += 1
            return path + "-resolved"
        }
        let result = WorktreeDiscovery.canonicalPath("/Volumes/openbeta/workspace/repo")
        XCTAssertEqual(result, "/Volumes/openbeta/workspace/repo")
        XCTAssertEqual(resolverCalls, 0)
    }

    func testVolumeFenceMatchesPathPrefixOnlyAtBoundary() {
        VolumeFence.fence("/Volumes/openbeta")
        XCTAssertTrue(VolumeFence.isFenced("/Volumes/openbeta/workspace/seahelm"))
        XCTAssertFalse(VolumeFence.isFenced("/Volumes/openbeta-backup/repo"))
        XCTAssertFalse(VolumeFence.isFenced("/Users/me/repo"))
    }

    // MARK: - Wedged attach clients (live parent)

    private static let zmxPath = "/App/Contents/Resources/bin/zmx"

    private func proc(_ pid: Int32, _ ppid: Int32, _ cmd: String) -> SessionManager.ZmxProcess {
        SessionManager.ZmxProcess(pid: pid, ppid: ppid, command: cmd)
    }

    private func attach(_ pid: Int32, _ ppid: Int32, _ session: String) -> SessionManager.ZmxProcess {
        proc(pid, ppid, "\(Self.zmxPath) attach \(session)")
    }

    /// After a volume drop the attach client hangs instead of exiting, so it
    /// still has Seahelm as a live parent. The ppid==1 orphan sweep leaves it
    /// alone forever — this is the 95% CPU corpse observed mid-session.
    func testWedgedAttachAgainstUnreachableSessionIsReapedEvenWithLiveParent() {
        let list = "  name=seahelm-dead\terr=Timeout\tstatus=unreachable"
        let processes = [
            proc(1_000, 1, "/App/Contents/MacOS/Seahelm"),
            attach(2_000, 1_000, "seahelm-dead"),
            attach(2_001, 1_000, "seahelm-alive"),
        ]
        let listAlive = list + "\n  name=seahelm-alive\tpid=9\tclients=1\tstart_dir=/tmp/ok"
        let pids = SessionManager.wedgedAttachClientPids(processes: processes, listOutput: listAlive)
        XCTAssertEqual(pids, [2_000])
    }

    func testWedgedAttachAgainstMissingSessionIsReaped() {
        let list = "  name=seahelm-other\tpid=1\tclients=1\tstart_dir=/tmp/o"
        let processes = [attach(300, 9478, "seahelm-gone")]
        XCTAssertEqual(
            SessionManager.wedgedAttachClientPids(processes: processes, listOutput: list),
            [300]
        )
    }

    func testHealthyAttachIsNotReapedAsWedged() {
        let list = "  name=seahelm-a\tpid=9\tclients=1\tstart_dir=/tmp/a"
        let processes = [attach(300, 9478, "seahelm-a")]
        XCTAssertEqual(SessionManager.wedgedAttachClientPids(processes: processes, listOutput: list), [])
    }

    /// `zmx run` hosts the session; only `forceKillSession` may tear it down.
    func testZmxRunIsNeverClassifiedAsWedgedAttach() {
        let list = "  name=seahelm-a\terr=Timeout\tstatus=unreachable"
        let processes = [
            proc(301, 1, "\(Self.zmxPath) run seahelm-a /bin/zsh -lic true"),
        ]
        XCTAssertEqual(SessionManager.wedgedAttachClientPids(processes: processes, listOutput: list), [])
    }

    // MARK: - Unreachable sessions on a dead start_dir

    func testUnreachableSessionsWithDeadStartDirAreNamedForCleanup() {
        let list = """
          name=seahelm-dead\terr=Timeout\tstatus=unreachable\tstart_dir=/Volumes/gone/repo
          name=seahelm-busy\terr=Timeout\tstatus=unreachable\tstart_dir=/tmp/still-here
          name=seahelm-ok\tpid=1\tclients=1\tstart_dir=/tmp/ok
        """
        let names = SessionManager.unreachableSessionNames(
            listOutput: list,
            startDirReachable: { path in
                path.hasPrefix("/tmp/")
            }
        )
        XCTAssertEqual(names, ["seahelm-dead"])
    }
}
