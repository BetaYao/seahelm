import XCTest
@testable import seahelm

final class SeahelmHookInstallerTests: XCTestCase {
    /// Records every JSON-RPC line written to a Unix socket: a stand-in for
    /// seahelm-core.
    final class LineCapture {
        let path = "/tmp/sh-core-\(UUID().uuidString.prefix(8)).sock"
        private(set) var params: [[String: Any]] = []
        private let lock = NSLock()
        private var fd: Int32 = -1

        init() throws {
            let sock = socket(AF_UNIX, SOCK_STREAM, 0)
            fd = sock
            var addr = sockaddr_un()
            addr.sun_family = sa_family_t(AF_UNIX)
            _ = withUnsafeMutablePointer(to: &addr.sun_path.0) { dst in path.withCString { strcpy(dst, $0) } }
            let bound = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(sock, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
            }
            guard bound == 0, listen(sock, 8) == 0 else { throw NSError(domain: "LineCapture", code: 1) }
            let fd = sock
            Thread.detachNewThread { [weak self] in
                while true {
                    let c = accept(fd, nil, nil)
                    guard c >= 0 else { return }
                    var data = Data()
                    var buf = [UInt8](repeating: 0, count: 4096)
                    while true {
                        let n = read(c, &buf, buf.count)
                        guard n > 0 else { break }
                        data.append(contentsOf: buf[0..<n])
                        if data.contains(0x0A) { break }
                    }
                    close(c)
                    if let line = data.split(separator: 0x0A).first,
                       let obj = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                       let p = obj["params"] as? [String: Any] {
                        self?.lock.lock(); self?.params.append(p); self?.lock.unlock()
                    }
                }
            }
        }

        func waitFor(_ count: Int) -> [[String: Any]] {
            let deadline = Date().addingTimeInterval(3)
            while Date() < deadline {
                lock.lock(); let n = params.count; lock.unlock()
                if n >= count { break }
                Thread.sleep(forTimeInterval: 0.05)
            }
            lock.lock(); defer { lock.unlock() }
            return params
        }

        deinit { close(fd); unlink(path) }
    }

    /// End to end: the bundled bridge reaches seahelm-core, stamped with the
    /// source it was invoked with (and none when invoked without one) and with
    /// the pane it runs in.
    func testBundledHookReachesTheCoreStampedWithSourceAndPane() throws {
        let hook = try XCTUnwrap(SeahelmHookInstaller.bundled, "the app bundles Resources/bin/seahelm-hook")
        let core = try LineCapture()

        func runHook(args: [String], env: [String: String]) throws -> (Int32, Data) {
            let p = Process()
            p.executableURL = hook
            p.arguments = args
            p.environment = env.merging(["SEAHELM_CORE_SOCKET": core.path]) { a, _ in a }
            let input = Pipe(), output = Pipe()
            p.standardInput = input
            p.standardOutput = output
            try p.run()
            input.fileHandleForWriting.write(Data(#"{"hook_event_name":"Stop","session_id":"s","cwd":"/wt"}"#.utf8))
            try? input.fileHandleForWriting.close()
            p.waitUntilExit()
            return (p.terminationStatus, output.fileHandleForReading.readDataToEndOfFile())
        }

        let tagged = try runHook(args: ["claude-code"], env: ["SEAHELM_PANE_ID": "seahelm-repo-main"])
        let untagged = try runHook(args: [], env: ["SEAHELMD_SESSION": "seahelm-repo-wt"])
        XCTAssertEqual(tagged.0, 0)
        XCTAssertEqual(untagged.0, 0)
        XCTAssertTrue(tagged.1.isEmpty && untagged.1.isEmpty, "Stop prints nothing")
        let got = core.waitFor(2)
        XCTAssertEqual(got.count, 2, "both hook invocations should reach the core")
        XCTAssertEqual(got.first?["seahelm_source"] as? String, "claude-code")
        XCTAssertEqual(got.first?["seahelm_pane_id"] as? String, "seahelm-repo-main")
        XCTAssertNil(got.last?["seahelm_source"], "untagged call must not emit an empty source")
        XCTAssertEqual(got.last?["seahelm_pane_id"] as? String, "seahelm-repo-wt")
    }

    func testInstallCopiesTheBundledBinary() throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("seahelm-hook-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let source = tmp.appendingPathComponent("src-hook")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: source)
        let bin = tmp.appendingPathComponent("bin")
        XCTAssertTrue(SeahelmHookInstaller.ensureInstalled(binDirectory: bin, from: source))
        let path = bin.appendingPathComponent("seahelm-hook").path
        let attrs = try FileManager.default.attributesOfItem(atPath: path)
        XCTAssertEqual(((attrs[.posixPermissions] as? NSNumber)?.intValue ?? 0) & 0o111, 0o111)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), try Data(contentsOf: source))
        XCTAssertFalse(SeahelmHookInstaller.ensureInstalled(binDirectory: bin, from: source)) // idempotent
        XCTAssertFalse(SeahelmHookInstaller.ensureInstalled(binDirectory: bin, from: nil))
    }
}

final class ClaudeHooksMigrationTests: XCTestCase {
    func testIsSeahelmManaged() {
        let httpEntry: [[String: Any]] = [["hooks": [["type": "http", "url": "http://localhost:7070/webhook"]]]]
        let cmdEntry: [[String: Any]] = [["hooks": [["type": "command", "command": "/x/seahelm-hook"]]]]
        let userEntry: [[String: Any]] = [["hooks": [["type": "command", "command": "/usr/bin/my-linter"]]]]
        XCTAssertTrue(ClaudeHooksSetup.isSeahelmManaged(httpEntry))
        XCTAssertTrue(ClaudeHooksSetup.isSeahelmManaged(cmdEntry))
        XCTAssertFalse(ClaudeHooksSetup.isSeahelmManaged(userEntry))
        XCTAssertFalse(ClaudeHooksSetup.isSeahelmManaged(nil))
    }

    func testEntriesEqualCanonical() {
        let a: [String: Any] = ["type": "command", "command": "/x", "extra": 1]
        let b: [String: Any] = ["command": "/x", "extra": 1, "type": "command"]  // reordered
        XCTAssertTrue(ClaudeHooksSetup.entriesEqual(a, b))
        XCTAssertFalse(ClaudeHooksSetup.entriesEqual(a, ["type": "http"]))
    }
}
