# Web Host Gateway Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let any public browser, after Settings pairing, open a real VT terminal against panes on the user's Mac via an in-app Host Gateway (WSS), with Cloudflare Tunnel providing reachability later.

**Architecture:** Seahelm embeds a localhost WebSocket server (`HostGatewayServer`). Clients authenticate with the existing pairing HKDF auth password (`MqttCrypto.authPassword`). Control methods reuse `ControlRouter`; VT uses `zmx attach` (same fidelity as `clients/seahelm-web/devbroker/zmx-vt.js`). Pairing QR/`b=` advertises the Gateway public WSS URL. Payload E2EE is **not** required on this path in P0 (Tunnel TLS + pair token); MQTT E2EE stays for Watch.

**Tech Stack:** Swift 5.10 / AppKit / Network.framework (`NWListener` + `NWProtocolWebSocket`), existing `ControlRouter` + `MqttCrypto`, bundled `zmx` + `zmx-attach.py`, `clients/seahelm-web` + xterm.js.

**Spec:** `docs/superpowers/specs/2026-08-10-web-host-gateway-design.md`

**Status (2026-08-17):** P0 complete. Tunnel UX / same-origin static hosting deferred to P1 (see bottom).

## P0 done when

Matches spec [§4.4 success criteria](../specs/2026-08-10-web-host-gateway-design.md#44-success-criteria):

- [x] **URL alone cannot control Seahelm** — Gateway rejects snapshot, VT, and send_* before successful `auth`.
- [x] **After pairing: real fleet list + live VT** — `session.snapshot` fills First Mate; `pane.vt_open` + notify `vt.snapshot`/`vt.data` + `pane.send_keys` yield a faithful terminal in the browser.
- [x] **Rotate pairing key invalidates old browsers** — new `mqtt.root_secret` → old HKDF auth tokens fail; Gateway drops stale sessions on restart.
- [x] **No devbroker required for production** — live Mac + Host Gateway + paired `seahelm-web`; `devbroker` / `mock:zmx` remain dev-only (`?mqtt=1`).

## Global Constraints

- Pairing URI shape stays `seahelm://pair?b=&m=&k=` (`MqttCrypto.pairURI`); only the meaning of `b=` changes to Gateway WSS.
- VT source must be `zmx attach` — never `zmx tail` / `zmx history --vt`.
- Never call `zmx detach` when a remote client closes (would kick Mac Ghostty too).
- URL alone must not authorize; reject all business methods before successful `auth`.
- Do not make production web depend on MQTT / `devbroker` / `live-bridge`.
- macOS 14+, Swift 5.10, `@testable import seahelm`, XCTest only.
- Prefer small new files under `Sources/Core/`; follow `decodeIfPresent` for config backward compat.

---

## File Structure

| File | Responsibility |
|---|---|
| `Sources/Core/HostGatewayConfig.swift` | Bind port, enable flag, public WSS URL for pairing `b=` |
| `Sources/Core/HostGatewayAuth.swift` | Derive expected token; verify `auth` params |
| `Sources/Core/HostGatewayFrame.swift` | Parse/serialize WS JSON (request / response / notify) |
| `Sources/Core/ZmxVTAttachManager.swift` | Per-pane attach lifecycle, snapshot/data callbacks, leases |
| `Sources/Core/HostGatewaySession.swift` | One WS client: auth gate → ControlRouter + VT manager |
| `Sources/Core/HostGatewayServer.swift` | `NWListener` WebSocket accept loop; fan-out sessions |
| `Resources/zmx-attach.py` | Bundled PTY relay (copy from `clients/seahelm-web/devbroker/zmx-attach.py`) |
| `Sources/Core/Config.swift` | Persist `hostGateway` |
| `Sources/App/MainWindowController.swift` | Start/stop Gateway; pairing context uses Gateway URL |
| `Sources/UI/Settings/PairingWindowController.swift` | Already URL-agnostic; callers pass Gateway URL |
| `Sources/UI/Settings/SettingsViewController.swift` | Pairing available without “MQTT configured” dead-end |
| `clients/seahelm-web/index.html` (+ small JS) | Gateway mode: auth then RPC/VT over one WSS |
| `Tests/HostGateway*.swift` | Unit tests per component |

**Out of this plan (P1 follow-up):** Cloudflare Tunnel Settings UX, same-origin static file serving from Gateway, key-rotation UI polish, Watch MQTT dual-URI.

---

### Task 1: `HostGatewayConfig` + Config wiring

**Files:**
- Create: `Sources/Core/HostGatewayConfig.swift`
- Modify: `Sources/Core/Config.swift` (add `hostGateway`, CodingKeys, decode defaults)
- Test: `Tests/HostGatewayConfigTests.swift`

**Interfaces:**
- Produces: `struct HostGatewayConfig: Codable, Equatable` with `enabled: Bool?`, `port: UInt16?`, `publicURL: String?`; `resolvedEnabled` (default `false`), `resolvedPort` (default `2783`), `resolvedPublicURL` (if `publicURL` empty → `ws://127.0.0.1:<port>/ws`)
- Consumes: existing `Config` decode patterns (`decodeIfPresent`)

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import seahelm

final class HostGatewayConfigTests: XCTestCase {
    func testDefaultsWhenKeyMissing() throws {
        let json = Data(#"{"workspace_paths":[],"active_workspace_index":0}"#.utf8)
        // Minimal decode path: decode HostGatewayConfig from absent key via Config if easier,
        // or decode HostGatewayConfig? directly:
        let cfg = try JSONDecoder().decode(HostGatewayConfig?.self, from: Data("null".utf8))
        XCTAssertNil(cfg)
        var hg = HostGatewayConfig()
        XCTAssertFalse(hg.resolvedEnabled)
        XCTAssertEqual(hg.resolvedPort, 2783)
        XCTAssertEqual(hg.resolvedPublicURL, "ws://127.0.0.1:2783/ws")
    }

    func testPublicURLOverride() {
        var hg = HostGatewayConfig()
        hg.publicURL = "wss://seahelm.example.com/ws"
        hg.port = 9
        XCTAssertEqual(hg.resolvedPublicURL, "wss://seahelm.example.com/ws")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -project seahelm.xcodeproj -scheme seahelmTests -configuration Debug -only-testing:seahelmTests/HostGatewayConfigTests test`
Expected: FAIL (type not found)

- [ ] **Step 3: Write minimal implementation**

```swift
// Sources/Core/HostGatewayConfig.swift
import Foundation

struct HostGatewayConfig: Codable, Equatable {
    var enabled: Bool?
    var port: UInt16?
    /// Public WSS URL embedded in pair `b=`. Empty → localhost derived URL.
    var publicURL: String?

    var resolvedEnabled: Bool { enabled ?? false }
    var resolvedPort: UInt16 { port ?? 2783 }
    var resolvedPublicURL: String {
        if let publicURL, !publicURL.isEmpty { return publicURL }
        return "ws://127.0.0.1:\(resolvedPort)/ws"
    }

    enum CodingKeys: String, CodingKey {
        case enabled, port
        case publicURL = "public_url"
    }
}
```

In `Config.swift`: add `var hostGateway: HostGatewayConfig?`, CodingKey `hostGateway = "host_gateway"`, `decodeIfPresent`, default `nil` in memberwise/init, encode if present. Match neighboring optional blocks (`mqtt`, `gmailMail`).

- [ ] **Step 4: Run tests and make sure they pass**

Run: same `xcodebuild … HostGatewayConfigTests`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add Sources/Core/HostGatewayConfig.swift Sources/Core/Config.swift Tests/HostGatewayConfigTests.swift
git commit -m "feat: add HostGatewayConfig"
```

---

### Task 2: Auth token verification

**Files:**
- Create: `Sources/Core/HostGatewayAuth.swift`
- Test: `Tests/HostGatewayAuthTests.swift`

**Interfaces:**
- Consumes: `MqttCrypto.authPassword`, `MqttCrypto.rootSecret(fromBase64url:)`
- Produces: `enum HostGatewayAuth { static func expectedToken(rootSecretBase64url: String) -> String?; static func verify(macId: String, token: String, expectedMacId: String, rootSecretBase64url: String) -> Bool }`

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import seahelm

final class HostGatewayAuthTests: XCTestCase {
    private let root = Data((0..<32).map { UInt8($0) })

    func testTokenMatchesMqttAuthPassword() {
        let b64 = MqttCrypto.base64url(root)
        let token = HostGatewayAuth.expectedToken(rootSecretBase64url: b64)
        XCTAssertEqual(token, MqttCrypto(rootSecret: root).authPassword)
    }

    func testVerifyAcceptsMatchingMacAndToken() {
        let b64 = MqttCrypto.base64url(root)
        let token = MqttCrypto(rootSecret: root).authPassword
        XCTAssertTrue(HostGatewayAuth.verify(
            macId: "live", token: token, expectedMacId: "live", rootSecretBase64url: b64))
    }

    func testVerifyRejectsWrongToken() {
        let b64 = MqttCrypto.base64url(root)
        XCTAssertFalse(HostGatewayAuth.verify(
            macId: "live", token: "nope", expectedMacId: "live", rootSecretBase64url: b64))
    }

    func testVerifyRejectsWrongMac() {
        let b64 = MqttCrypto.base64url(root)
        let token = MqttCrypto(rootSecret: root).authPassword
        XCTAssertFalse(HostGatewayAuth.verify(
            macId: "other", token: token, expectedMacId: "live", rootSecretBase64url: b64))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild … -only-testing:seahelmTests/HostGatewayAuthTests test`
Expected: FAIL

- [ ] **Step 3: Write minimal implementation**

```swift
import Foundation

enum HostGatewayAuth {
    static func expectedToken(rootSecretBase64url: String) -> String? {
        guard let bytes = MqttCrypto.rootSecret(fromBase64url: rootSecretBase64url) else { return nil }
        return MqttCrypto(rootSecret: bytes).authPassword
    }

    static func verify(macId: String, token: String,
                       expectedMacId: String, rootSecretBase64url: String) -> Bool {
        guard macId == expectedMacId,
              let expected = expectedToken(rootSecretBase64url: rootSecretBase64url),
              !token.isEmpty else { return false }
        // Constant-time-ish compare for equal-length hex strings
        guard token.utf8.count == expected.utf8.count else { return false }
        var diff: UInt8 = 0
        for (a, b) in zip(token.utf8, expected.utf8) { diff |= a ^ b }
        return diff == 0
    }
}
```

- [ ] **Step 4: Run tests — expect PASS**

- [ ] **Step 5: Commit**

```bash
git add Sources/Core/HostGatewayAuth.swift Tests/HostGatewayAuthTests.swift
git commit -m "feat: HostGateway pairing-token auth"
```

---

### Task 3: Frame codec

**Files:**
- Create: `Sources/Core/HostGatewayFrame.swift`
- Test: `Tests/HostGatewayFrameTests.swift`

**Interfaces:**
- Produces:
  - `enum HostGatewayInbound { case request(id: String, method: String, params: [String: Any]); case malformed }`
  - `enum HostGatewayOutbound { case response(id: String, result: Any?, error: [String: Any]?); case notify(method: String, params: [String: Any]) }`
  - `HostGatewayFrame.parse(_ text: String) -> HostGatewayInbound`
  - `HostGatewayFrame.encode(_ outbound: HostGatewayOutbound) -> String`

Wire rules:
- Request: `{"id":"…","method":"…","params":{…}}` (params optional → `[:]`)
- Response: `{"id":"…","result":…}` or `{"id":"…","error":{"code":…,"message":…}}`
- Notify (server→client): `{"type":"notify","method":"vt.data","params":{…}}` — no `id`

- [ ] **Step 1: Write the failing test**

```swift
final class HostGatewayFrameTests: XCTestCase {
    func testParseRequest() {
        let inbound = HostGatewayFrame.parse(#"{"id":"1","method":"auth","params":{"mac_id":"live"}}"#)
        guard case let .request(id, method, params) = inbound else { return XCTFail() }
        XCTAssertEqual(id, "1")
        XCTAssertEqual(method, "auth")
        XCTAssertEqual(params["mac_id"] as? String, "live")
    }

    func testEncodeNotify() throws {
        let s = HostGatewayFrame.encode(.notify(method: "vt.data",
            params: ["pane_session_key": "p1", "b64": "YQ=="]))
        let obj = try JSONSerialization.jsonObject(with: Data(s.utf8)) as! [String: Any]
        XCTAssertEqual(obj["type"] as? String, "notify")
        XCTAssertEqual(obj["method"] as? String, "vt.data")
    }

    func testEncodeErrorResponse() throws {
        let s = HostGatewayFrame.encode(.response(id: "9", result: nil,
            error: ["code": -32001, "message": "unauthorized"]))
        let obj = try JSONSerialization.jsonObject(with: Data(s.utf8)) as! [String: Any]
        XCTAssertEqual(obj["id"] as? String, "9")
        XCTAssertNotNil(obj["error"])
    }
}
```

- [ ] **Step 2: Run — expect FAIL**

- [ ] **Step 3: Implement `HostGatewayFrame`** using `JSONSerialization` (same style as `ControlProtocol` / socket path). Reject non-object / missing `method` as `.malformed`.

- [ ] **Step 4: Run — expect PASS**

- [ ] **Step 5: Commit** `feat: HostGateway JSON frame codec`

---

### Task 4: Session router (auth gate + ControlRouter)

**Files:**
- Create: `Sources/Core/HostGatewaySession.swift`
- Test: `Tests/HostGatewaySessionTests.swift`
- Reuse test fakes from `Tests/ControlRouterTests.swift` patterns

**Interfaces:**
- Consumes: `ControlRouter`, `HostGatewayAuth`, `HostGatewayFrame`, later `ZmxVTAttachManager` (stub protocol in this task)
- Produces:
```swift
protocol HostGatewayVTAttaching: AnyObject {
    func open(paneSessionKey: String) -> [String: Any]   // sync ack; bytes via callback
    func close(paneSessionKey: String)
    func keepalive(paneSessionKey: String)
    func sendKeys(paneSessionKey: String, utf8: Data) -> Bool
    var onNotify: ((String, [String: Any]) -> Void)? { get set } // method, params
}

final class HostGatewaySession {
    init(router: ControlRouter,
         expectedMacId: String,
         rootSecretBase64url: String,
         vt: HostGatewayVTAttaching)
    /// Handle one inbound text frame; returns zero or more outbound text frames to send.
    func handle(text: String) -> [String]
}
```

Behavior:
1. Before auth: only `method == "auth"` accepted; others → error `-32001 unauthorized`.
2. `auth` params: `mac_id`, `token` → `HostGatewayAuth.verify`; set `authenticated = true`; result `{"ok":true}`.
3. After auth: `session.snapshot`, `pane.list`, `pane.send_keys` (and other ControlRouter methods) → `router.handle`.
4. Map VT methods:
   - `pane.vt_open` → `vt.open` + result
   - `pane.vt_close` / `pane.vt_keepalive` similarly
   - Prefer ControlRouter for `pane.send_keys` when targeting station id; for open VT stream, also call `vt.sendKeys` when an attach exists (implement detail in Task 5 — for this task, if `vt` reports open, prefer `vt.sendKeys` with base64/utf8 from params).
5. When `vt.onNotify` fires, session queues notify frames (tests can call a `drainNotifications()` or pass a capture array via the vt fake).

- [ ] **Step 1: Write failing tests** covering: reject snapshot before auth; auth success; snapshot after auth calls router; wrong token fails.

Use a minimal `ControlDataSource` fake returning one `PaneSnapshot`.

- [ ] **Step 2: Run — expect FAIL**

- [ ] **Step 3: Implement session** (VT protocol with no-op fake for non-VT tests)

- [ ] **Step 4: Run — expect PASS**

- [ ] **Step 5: Commit** `feat: HostGatewaySession auth + control routing`

---

### Task 5: `ZmxVTAttachManager`

**Files:**
- Create: `Sources/Core/ZmxVTAttachManager.swift`
- Create: `Resources/zmx-attach.py` (copy verbatim from `clients/seahelm-web/devbroker/zmx-attach.py`)
- Modify: `project.yml` to include `Resources/zmx-attach.py` as a resource (or folder entry)
- Test: `Tests/ZmxVTAttachManagerTests.swift` (logic tests with injectable runner)

**Interfaces:**
- Consumes: `ZmxLocator.executable()`, `Station.zmxAttachCommand` patterns; clear `ZMX_SESSION` in child env
- Produces: `final class ZmxVTAttachManager: HostGatewayVTAttaching`

Port the lease/snapshot rules from `zmx-vt.js`:
- `SNAPSHOT_IDLE_MS = 160`, `SNAPSHOT_MAX_MS = 2500`, coalesce live data ~16ms, `LEASE_TTL_MS = 60000`
- `open`: spawn `python3 Resources/zmx-attach.py <zmx> attach <paneSessionKey>` with env `ZMX_SESSION` unset; read stdout as VT bytes
- First burst → `onNotify("vt.snapshot", [pane_session_key, b64, cols, rows])` then live `vt.data`
- Geometry: read tty size the same way as the Python helper / Node (`stty size` via session pid) — if unavailable default `cols=120, rows=32` and still pin
- `close`: terminate **only** the attach child process; never run `zmx detach`
- `keepalive`: refresh lease deadline; timer reap expired
- `sendKeys`: write bytes to the attach child's stdin (pty)

For unit tests without real zmx: inject a `VTProcessSpawning` protocol that returns a pipe-backed fake process.

- [ ] **Step 1: Write failing test** — fake process emits bytes; after idle, snapshot then data notifies fire; close stops process; keepalive extends lease.

- [ ] **Step 2: Run — expect FAIL**

- [ ] **Step 3: Implement manager + bundle `zmx-attach.py`; run `xcodegen generate` if `project.yml` changed**

- [ ] **Step 4: Run unit tests — PASS** (manual smoke with live zmx is Task 8)

- [ ] **Step 5: Commit** `feat: ZmxVTAttachManager for Host Gateway VT`

---

### Task 6: `HostGatewayServer` (Network.framework WebSocket)

**Files:**
- Create: `Sources/Core/HostGatewayServer.swift`
- Test: `Tests/HostGatewayServerTests.swift` (loopback connect)

**Interfaces:**
```swift
final class HostGatewayServer {
    init(config: HostGatewayConfig,
         router: ControlRouter,
         expectedMacId: String,
         rootSecretBase64url: String,
         vt: HostGatewayVTAttaching)
    func start()
    func stop()
    var isListening: Bool { get }
}
```

Implementation notes:
- Bind `127.0.0.1` + `config.resolvedPort` with `NWListener`.
- Use `NWParameters` including `NWProtocolWebSocket.Options` (follow Apple WS server samples).
- Path: only accept upgrades to `/ws` (reject others with HTTP 404 if doing manual HTTP; if using pure WS params, document that clients must dial `ws://127.0.0.1:PORT/ws`).
- Per connection: create `HostGatewaySession`; on receive `.text`, call `handle` and send each outbound string as a WS text frame.
- Wire `vt.onNotify` → encode notify → send on that connection only (map pane→interested sessions later; P0: notify the session that opened the VT).

- [ ] **Step 1: Write failing integration test** — start server on port `0` or high ephemeral if supported; else fixed `27999` in test; connect with `URLSessionWebSocketTask`; send auth; expect ok; send `session.snapshot`; expect result array. Tear down in `defer`.

If NWListener WS proves awkward in CI, keep a `HostGatewayServer` that can also accept **newline-delimited TCP** for tests (`wsMode` vs `lineMode`) — but production path must be WebSocket for browsers. Prefer getting WS working; document flaky CI skip only as last resort.

- [ ] **Step 2: Run — expect FAIL**

- [ ] **Step 3: Implement server**

- [ ] **Step 4: Run — expect PASS**

- [ ] **Step 5: Commit** `feat: HostGatewayServer WebSocket listener`

---

### Task 7: App lifecycle + pairing `b=`

**Files:**
- Modify: `Sources/App/MainWindowController.swift` (`mintPairingContext`, window setup / teardown)
- Modify: `Sources/App/TabCoordinator.swift` if that owns `mqttDataSource` / control router — start Gateway next to control socket using the same `ControlRouter` / data source
- Modify: `Sources/UI/Settings/SettingsViewController.swift` pairing empty-state copy
- Test: extend or add `Tests/HostGatewayPairingURLTests.swift` for URL selection helper

**Interfaces:**
```swift
enum HostGatewayPairing {
    /// Prefer hostGateway.resolvedPublicURL when Gateway is the web path.
    static func clientEntryURL(hostGateway: HostGatewayConfig?, mqtt: MqttConfig?) -> String
}
```

P0 rule: if `hostGateway?.resolvedEnabled == true`, pairing `b=` = `hostGateway.resolvedPublicURL`; else keep MQTT `resolvedClientBrokerURL` (Watch-only / legacy).

`mintPairingContext`:
1. Ensure `mqtt.root_secret` still minted (shared `k=`).
2. Ensure `hostGateway` exists when enabling remote web (or document that user sets `enabled: true` in config for P0).
3. Pass `clientEntryURL(...)` into `PairingPaneView` / `PairingWindowController` instead of always `mqtt.resolvedClientBrokerURL`.

Start Gateway after control socket has a data source; stop on window close / app terminate.

Settings: change “MQTT is not configured” empty state to still allow pairing when Gateway or mqtt can mint context (MainWindow already mints mqtt — fix delegate nil path / subtitle only).

- [ ] **Step 1: Write failing test for `clientEntryURL` precedence**

- [ ] **Step 2: Run — FAIL**

- [ ] **Step 3: Implement helper + wire MainWindow / Settings**

- [ ] **Step 4: Run tests — PASS**; manual: set config snippet, launch app, open Pairing, confirm link contains `ws://127.0.0.1:2783/ws` (or public_url)

- [ ] **Step 5: Commit** `feat: wire Host Gateway into app + pairing URL`

---

### Task 8: Web client Gateway mode

**Files:**
- Modify: `clients/seahelm-web/index.html` (and extract minimal `gateway.js` only if the file is unmaintainable — prefer smallest change)
- Modify: `clients/seahelm-web/README.md` — production path vs `devbroker`

**Behavior:**
1. After `applyPair`, if `b` path is `/ws` or query/localStorage `transport=gateway`, use **WebSocket** instead of MQTT.
2. On open: send `auth` with `mac_id` + `token` (`E2EE.deriveKeys(…).password`).
3. Subscribe-equivalent: call `session.snapshot` on connect; render First Mate from result (adapt existing tree builders).
4. On pane select: `pane.vt_open`; handle `notify` `vt.snapshot` / `vt.data` into existing xterm path (reuse b64 decode logic from MQTT VT handler).
5. Keystrokes: `pane.send_keys` with same params as today.
6. Keep MQTT path behind a flag for `devbroker` debugging (`?mqtt=1` or hostname localhost:28083).

- [ ] **Step 1: Manual fixture** — with Gateway running and one zmx pane, open `index.html`, paste pair link, connect, open pane, type `echo ok`.

- [ ] **Step 2: Implement JS changes incrementally; keep e2ee.js deriveKeys for token**

- [ ] **Step 3: Update README** with Gateway-first instructions; mark `npm run mock:zmx` as dev-only

- [ ] **Step 4: Commit** `feat: seahelm-web Host Gateway transport`

---

### Task 9: Docs cross-links + P0 checklist

**Files:**
- Modify: `docs/superpowers/specs/2026-08-10-web-host-gateway-design.md` (status → Implementing / Done P0 when finished)
- Modify: `clients/seahelm-web/README.md` (if not done in Task 8)
- Optional: short note in `docs/remote-clients-design.md` §0 that **web VT production path is Host Gateway**, MQTT remains Watch/ESP

- [x] **Step 1: Add a “P0 done when” checklist** matching spec §4.4 success criteria into the plan doc or README

- [x] **Step 2: Commit** `docs: point web remote control at Host Gateway`

---

## P1 (separate plan later)

- Cloudflare Tunnel Settings (store `public_url`, helper commands)
- Serve `seahelm-web` static files from Gateway origin
- Rotate pairing key UI that calls Gateway `stop` sessions
- Dual pair URI for Watch MQTT + Web Gateway if both needed

---

## Self-review (plan vs spec)

| Spec requirement | Task |
|---|---|
| In-app Host Gateway + pair auth | 2, 4, 6, 7 |
| ControlProtocol reuse | 4 |
| VT via zmx attach + vt_open/data/close | 5, 8 |
| Pairing UI reuse; `b=` → Gateway | 7 |
| URL alone insufficient | 2, 4 |
| No production MQTT VT | 8 README + Global Constraints |
| Tunnel UX | Deferred P1 (explicit) |
| Ghostty feed out of scope | Global Constraints / Task 5 |

No TBD placeholders in tasks. Types: `HostGatewayVTAttaching`, `HostGatewaySession.handle`, `HostGatewayConfig.resolvedPublicURL` used consistently.
