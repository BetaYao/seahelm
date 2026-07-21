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
          name=seahelm-repo-feat\tpid=4242\tclients=1\tstart_dir=/x
          name=other\tpid=99\tclients=0\tstart_dir=/y
        """
        XCTAssertEqual(ProcessProbe.sessionPid(sessionName: "seahelm-repo-feat", zmxListOutput: out), 4242)
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

    func testBundledManifestsAllLoadAndIdentify() {
        // Every AI agent must have a loadable manifest with a process block, and
        // the probe must map it back to the right SailorType.
        let store = ManifestStore.shared
        for id in ["claude", "codex", "opencode", "gemini", "cline", "goose", "amp", "aider", "cursor", "kiro"] {
            guard let cm = store.manifest(for: id) else {
                XCTFail("missing manifest \(id)"); continue
            }
            XCTAssertNotNil(cm.manifest.process, "\(id) has no process block")
            XCTAssertNotEqual(SailorType.fromManifestId(id), .unknown, "\(id) has no SailorType")
        }
    }

    func testIdentifyOpencodeFromProcess() {
        let ms = ManifestStore.shared.all.map(\.manifest)
        let procs = [p(7, 1, ["node", "/opt/opencode/bin/opencode"])]
        XCTAssertEqual(ProcessProbe.identify(procs: procs, manifests: ms), "opencode")
    }

    /// Cursor's primary CLI entrypoint is now `agent` (cursor-agent remains an
    /// alias). argv0 is `/…/bin/agent`; the install path still contains
    /// `cursor-agent`, so either exec_names or argv_contains must identify it.
    func testIdentifyCursorAgentCLIEntrypoint() {
        let ms = ManifestStore.shared.all.map(\.manifest)
        let viaAgent = [p(7, 1, [
            "/Users/me/.local/bin/agent",
            "--use-system-ca",
            "/Users/me/.local/share/cursor-agent/versions/2026.07.17/index.js",
        ])]
        XCTAssertEqual(ProcessProbe.identify(procs: viaAgent, manifests: ms), "cursor")

        let viaAlias = [p(8, 1, ["/Users/me/.local/bin/cursor-agent"])]
        XCTAssertEqual(ProcessProbe.identify(procs: viaAlias, manifests: ms), "cursor")
    }

    func testDescendantsWalk() {
        let all = [p(2, 1, ["zsh"]), p(3, 2, ["node"]), p(4, 3, ["codex"]), p(5, 1, ["unrelated"])]
        let d = ProcessProbe.descendants(of: 2, in: all).map(\.pid).sorted()
        XCTAssertEqual(d, [3, 4])
    }

    func testForegroundCommandLinePrefersLeafJob() {
        // Session shell descendants: node wrapper → real command.
        let procs = [
            p(3, 2, ["node", "/opt/tool/bin/wrapper.js"]),
            p(4, 3, ["/opt/homebrew/bin/brew", "update"]),
        ]
        XCTAssertEqual(ProcessProbe.foregroundCommandLine(from: procs), "brew update")
    }

    func testForegroundCommandLineSkipsNestedShells() {
        let procs = [
            p(3, 2, ["/bin/bash", "-c", "sleep 1"]),
            p(4, 3, ["/bin/sleep", "1"]),
        ]
        XCTAssertEqual(ProcessProbe.foregroundCommandLine(from: procs), "sleep 1")
    }

    func testForegroundCommandLineNilWhenOnlyShells() {
        let procs = [p(3, 2, ["/bin/zsh"]), p(4, 3, ["bash"])]
        XCTAssertNil(ProcessProbe.foregroundCommandLine(from: procs))
    }
}
