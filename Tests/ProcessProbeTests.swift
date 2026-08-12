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
    private func p(_ pid: Int32, _ ppid: Int32, _ argv: [String], mb: UInt64) -> ProcessProbe.Proc {
        ProcessProbe.Proc(pid: pid, ppid: ppid, argv: argv, residentBytes: mb * 1_048_576)
    }

    func testSessionPidParse() {
        let out = """
          name=seahelm-repo-feat\tpid=4242\tclients=1\tstart_dir=/x
          name=other\tpid=99\tclients=0\tstart_dir=/y
        """
        XCTAssertEqual(ProcessProbe.sessionPid(paneSessionKey: "seahelm-repo-feat", zmxListOutput: out), 4242)
        XCTAssertNil(ProcessProbe.sessionPid(paneSessionKey: "missing", zmxListOutput: out))
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
        // the probe must map it back to the right AgentType.
        let store = ManifestStore.shared
        for id in ["claude", "codex", "opencode", "gemini", "cline", "goose", "amp", "aider", "cursor", "kiro"] {
            guard let cm = store.manifest(for: id) else {
                XCTFail("missing manifest \(id)"); continue
            }
            XCTAssertNotNil(cm.manifest.process, "\(id) has no process block")
            XCTAssertNotEqual(AgentType.fromManifestId(id), .unknown, "\(id) has no AgentType")
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

    func testSessionMemoryIncludesAgentSubtree() {
        let ms = [manifest(id: "claude", exec: ["claude"], argv: ["claude-code"], generic: ["node"])]
        let all = [
            p(2, 1, ["/bin/zsh"], mb: 1),
            p(3, 2, ["/opt/homebrew/bin/claude"], mb: 20),
            p(4, 3, ["node", "/Users/me/.claude/helper.js"], mb: 300),
            p(5, 2, ["/usr/bin/git", "status"], mb: 9),
        ]

        let mem = ProcessProbe.memory(rootPid: 2, in: all, manifests: ms)

        XCTAssertEqual(mem.totalBytes, 330 * 1_048_576)
        XCTAssertEqual(mem.agentBytes, 320 * 1_048_576)
        XCTAssertNotNil(mem.processName)
    }

    func testSessionMemoryCountsClaudeCodeNodeWrapperAndChildren() {
        let ms = [manifest(id: "claude", argv: ["claude-code"], generic: ["node"])]
        let all = [
            p(2, 1, ["/bin/zsh"], mb: 1),
            p(3, 2, ["node", "/Users/me/.local/bin/claude-code"], mb: 120),
            p(4, 3, ["/usr/bin/python3", "worker.py"], mb: 80),
        ]

        let mem = ProcessProbe.memory(rootPid: 2, in: all, manifests: ms)

        XCTAssertEqual(mem.totalBytes, 201 * 1_048_576)
        XCTAssertEqual(mem.agentBytes, 200 * 1_048_576)
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

    // MARK: - Live sysctl reads
    //
    // `argv(of:)` parses the KERN_PROCARGS2 blob through a raw pointer now, so
    // these run it against this very process — the one argv whose shape the test
    // can predict.

    func testArgvReadsOwnProcess() {
        let argv = ProcessProbe.argv(of: getpid())
        XCTAssertFalse(argv.isEmpty, "argv for the running test process must parse")
        XCTAssertFalse(argv[0].isEmpty, "argv0 must not be blank")
        XCTAssertEqual(argv, ProcessProbe.argv(of: getpid()), "parse must be stable across calls")
    }

    func testArgvIsStableWhenABufferIsReusedAcrossProcesses() {
        // The batch path reuses one buffer, so a long argv followed by a short one
        // must not leave the earlier process's bytes visible in the second result.
        let table = ProcessProbe.processTable()
        XCTAssertFalse(table.isEmpty)
        let sampled = Array(table.prefix(40))
        let batch = ProcessProbe.withArgv(sampled)
        for proc in batch {
            XCTAssertEqual(proc.argv, ProcessProbe.argv(of: proc.pid),
                           "pid \(proc.pid) parsed differently in the batch than on its own")
        }
    }

    func testProcessTableCarriesTreeShapeWithoutArgv() {
        let table = ProcessProbe.processTable()
        guard let own = table.first(where: { $0.pid == getpid() }) else {
            return XCTFail("own pid missing from the process table")
        }
        XCTAssertEqual(own.ppid, getppid())
        XCTAssertTrue(own.argv.isEmpty, "processTable must not pay for argv")
        XCTAssertNil(own.residentBytes, "processTable must not fork ps for rss")
    }
}
