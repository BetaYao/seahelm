import XCTest
@testable import seahelm

final class ProcessProbeTests: XCTestCase {

    private func manifest(id: String, exec: [String] = [], argv: [String] = [],
                          generic: [String] = []) -> AgentManifest {
        let json = """
        { "id": "\(id)", "process": { "exec_names": \(json(exec)),
          "argv_contains": \(json(argv)), "generic_runtimes": \(json(generic)) }, "rules": [] }
        """
        return try! JSONDecoder().decode(AgentManifest.self, from: Data(json.utf8))
    }
    private func json(_ a: [String]) -> String {
        "[" + a.map { "\"\($0)\"" }.joined(separator: ",") + "]"
    }
    private func p(_ pid: Int32, _ ppid: Int32, _ argv: [String]) -> ProcessProbe.Proc {
        ProcessProbe.Proc(pid: pid, ppid: ppid, argv: argv)
    }

    func testSessionPidParse() {
        let out = """
          name=amux-repo-feat\tpid=4242\tclients=1\tstart_dir=/x
          name=other\tpid=99\tclients=0\tstart_dir=/y
        """
        XCTAssertEqual(ProcessProbe.sessionPid(sessionName: "amux-repo-feat", zmxListOutput: out), 4242)
        XCTAssertNil(ProcessProbe.sessionPid(sessionName: "missing", zmxListOutput: out))
    }

    func testDirectExecMatch() {
        let ms = [manifest(id: "claude", exec: ["claude"]), manifest(id: "codex", exec: ["codex"])]
        let procs = [p(2, 1, ["/bin/zsh"]), p(3, 2, ["/opt/homebrew/bin/claude", "--foo"])]
        XCTAssertEqual(ProcessProbe.identify(procs: procs, manifests: ms), "claude")
    }

    func testWrapperPenetrationNodeToCodex() {
        let ms = [manifest(id: "codex", exec: ["codex"], argv: ["codex"], generic: ["node"])]
        // codex launched via node: argv0 is node, argv contains the codex path.
        let procs = [p(5, 1, ["node", "/usr/local/lib/codex/bin/codex.js"])]
        XCTAssertEqual(ProcessProbe.identify(procs: procs, manifests: ms), "codex")
    }

    func testGenericRuntimeAloneDoesNotMatch() {
        let ms = [manifest(id: "codex", exec: ["codex"], argv: ["codex"], generic: ["node"])]
        let procs = [p(5, 1, ["node", "/some/other/app.js"])]
        XCTAssertNil(ProcessProbe.identify(procs: procs, manifests: ms))
    }

    func testExecNamesWinsOverArgv() {
        let ms = [manifest(id: "claude", exec: ["claude"]),
                  manifest(id: "codex", exec: ["codex"], argv: ["codex"], generic: ["node"])]
        let procs = [p(9, 1, ["/bin/claude"])]
        XCTAssertEqual(ProcessProbe.identify(procs: procs, manifests: ms), "claude")
    }

    func testDescendantsWalk() {
        let all = [p(2, 1, ["zsh"]), p(3, 2, ["node"]), p(4, 3, ["codex"]), p(5, 1, ["unrelated"])]
        let d = ProcessProbe.descendants(of: 2, in: all).map(\.pid).sorted()
        XCTAssertEqual(d, [3, 4])
    }
}
