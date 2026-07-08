import Foundation

/// Installs `~/.local/bin/seahelm`, the agent-facing CLI wrapper around the
/// control socket. Agents (and humans) call e.g. `seahelm pane run <id> npm test`
/// instead of hand-crafting JSON and piping it through `nc -U`. The script is
/// pure python3 (present wherever the CLTs/agent runtimes are) and talks the same
/// newline-delimited JSON protocol as ControlSocketServer.
enum SeahelmCliInstaller {
    private static let versionMarker = "# seahelm-cli v1"

    static func scriptContents() -> String {
        return #"""
        #!/usr/bin/env python3
        \#(versionMarker) — managed by seahelm. Do not edit; overwritten on launch.
        import sys, os, json, socket

        SOCK = os.environ.get("SEAHELM_SOCKET_PATH") or os.path.expanduser("~/.config/seahelm/seahelm.sock")

        def die(msg, code=2):
            sys.stderr.write("seahelm: " + msg + "\n"); sys.exit(code)

        def call(method, params, timeout=40.0):
            try:
                s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
                s.settimeout(timeout)
                s.connect(SOCK)
                s.sendall((json.dumps({"id": "cli", "method": method, "params": params}) + "\n").encode())
                buf = b""
                while b"\n" not in buf:
                    chunk = s.recv(65536)
                    if not chunk:
                        break
                    buf += chunk
                s.close()
            except Exception as e:
                die("socket error: %s (is seahelm running?)" % e)
            try:
                obj = json.loads(buf.split(b"\n", 1)[0])
            except Exception:
                die("bad response")
            if "error" in obj:
                die(obj["error"].get("message", "error"))
            return obj.get("result", {})

        def opt(a, name, default=None):
            return a[a.index(name) + 1] if name in a and a.index(name) + 1 < len(a) else default

        def has(a, name):
            return name in a

        def main():
            argv = sys.argv[1:]
            if not argv:
                die("usage: seahelm <ping|session|pane|wait> ...", 2)
            g = argv[0]; a = argv[1:]

            if g == "ping":
                call("ping", {}); print("pong"); return

            if g == "session" and a[:1] == ["snapshot"]:
                print(json.dumps(call("session.snapshot", {}).get("panes", []), indent=2)); return

            if g == "wait":
                if not a: die("usage: seahelm wait <output|agent-status> <pane> ...")
                sub = a[0]; rest = a[1:]
                if not rest: die("pane id required")
                pane = rest[0]
                tmo = int(opt(rest, "--timeout", "30000"))
                if sub == "output":
                    m = opt(rest, "--match");
                    if m is None: die("--match required")
                    p = {"pane_id": pane, "match": m, "timeout_ms": tmo,
                         "source": opt(rest, "--source", "recent"), "regex": has(rest, "--regex")}
                    r = call("wait.output", p, timeout=tmo / 1000 + 10)
                elif sub == "agent-status":
                    st = opt(rest, "--status")
                    if st is None: die("--status required")
                    r = call("wait.agent_status", {"pane_id": pane, "status": st, "timeout_ms": tmo},
                             timeout=tmo / 1000 + 10)
                else:
                    die("unknown wait: %s" % sub)
                sys.exit(0 if r.get("matched") else 1)

            if g == "pane":
                if not a: die("usage: seahelm pane <list|read|run|send-text|send-keys|split> ...")
                sub = a[0]; rest = a[1:]
                if sub == "list":
                    print(json.dumps(call("pane.list", {}).get("panes", []), indent=2)); return
                if sub == "read":
                    if not rest: die("pane id required")
                    r = call("pane.read", {"pane_id": rest[0], "source": opt(rest, "--source", "visible"),
                                           "lines": int(opt(rest, "--lines", "100"))})
                    sys.stdout.write(r.get("text", "")); return
                if sub == "run":
                    if len(rest) < 2: die("usage: seahelm pane run <pane> <command...>")
                    call("pane.run", {"pane_id": rest[0], "command": " ".join(rest[1:])}); return
                if sub == "send-text":
                    if len(rest) < 2: die("usage: seahelm pane send-text <pane> <text...>")
                    call("pane.send_text", {"pane_id": rest[0], "text": " ".join(rest[1:])}); return
                if sub == "send-keys":
                    if len(rest) < 2: die("usage: seahelm pane send-keys <pane> <key...>")
                    call("pane.send_keys", {"pane_id": rest[0], "keys": rest[1:]}); return
                if sub == "split":
                    # optional positional pane id (a token not starting with --)
                    pane = rest[0] if rest and not rest[0].startswith("--") else None
                    p = {"direction": opt(rest, "--direction", "right"), "focus": not has(rest, "--no-focus")}
                    if pane: p["pane_id"] = pane
                    print(call("pane.split", p).get("pane_id", "")); return
                die("unknown pane subcommand: %s" % sub)

            die("unknown command: %s" % g)

        main()
        """#
    }

    @discardableResult
    static func ensureInstalled() -> Bool {
        let bin = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin")
        return ensureInstalled(binDirectory: bin)
    }

    @discardableResult
    static func ensureInstalled(binDirectory: URL) -> Bool {
        let scriptURL = binDirectory.appendingPathComponent("seahelm")
        let desired = scriptContents()
        if let existing = try? String(contentsOf: scriptURL, encoding: .utf8),
           existing.contains(versionMarker), existing == desired {
            return false
        }
        do {
            try FileManager.default.createDirectory(at: binDirectory, withIntermediateDirectories: true)
            try desired.write(to: scriptURL, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
            return true
        } catch {
            NSLog("[SeahelmCliInstaller] Failed to install: \(error)")
            return false
        }
    }
}
