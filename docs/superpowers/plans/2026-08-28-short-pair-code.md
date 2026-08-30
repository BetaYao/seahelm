# Short Numeric Pair Code Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let a browser pair to Host Gateway by entering an 8-digit code on any reachable page (HTTP or HTTPS), with no URL or root secret in the pairing payload, and remember a Mac-issued token for reconnect.

**Architecture:** Mac Settings shows a persisted 8-digit code. The browser opens same-origin `/ws`, sends `auth { code }`, and the Mac verifies the code (rate-limited by IP), then returns the existing HKDF auth token + `mac_id`. The browser stores `{ m, t }` in `localStorage` and never runs WebCrypto for Gateway pairing. Refreshing the code invalidates only the code; rotating `root_secret` revokes all tokens.

**Tech Stack:** Swift 5.10 / AppKit / Network.framework, existing `HostGatewaySession` / `HostGatewayAuth` / `MqttCrypto`, `clients/seahelm-web` static page, XCTest.

**Spec:** `docs/superpowers/specs/2026-08-28-short-pair-code-design.md`

## Global Constraints

- Code is exactly **8 digits**, zero-padded; display may group as `4829 1736`.
- Code lifetime: until Mac **Refresh code** (no auto TTL).
- Refresh code: invalidate old code only; **do not** revoke stored browser tokens.
- Revoke all remotes: rotate `mqtt.root_secret` → all tokens + force new code.
- Rate limit failed **code** auth: **5 failures / 60 s / client IP** → error `-32029 rate_limited`.
- Browser Gateway path must not depend on `crypto.subtle` / `e2ee.js`.
- WebSocket URL is always same-origin `ws(s)://<location.host>/ws` — never from a pair payload.
- Settings / web **fully replace** `seahelm://pair` QR and long link (Watch/MQTT pairing deferred).
- macOS 14+, Swift 5.10, `@testable import seahelm`, XCTest only.
- Persist new fields with `decodeIfPresent` / optional keys for backward compat.
- After modifying Swift sources that XcodeGen tracks by folder, no `project.yml` change is required (`Sources/` is a path group).

---

## File Structure

| File | Responsibility |
|---|---|
| `Sources/Core/PairingCodeStore.swift` | Generate / persist / verify 8-digit code |
| `Sources/Core/PairRateLimiter.swift` | Per-IP failed code attempt window |
| `Sources/Core/HostGatewayConfig.swift` | Add `pairCode` field + preserve through `edited` |
| `Sources/Core/HostGatewayAuth.swift` | Optional helper to normalize code (or keep on store only) |
| `Sources/Core/HostGatewaySession.swift` | Auth branch: token **or** code; return `mac_id` + `token` on code success |
| `Sources/Core/HostGatewayServer.swift` | Pass code store + limiter; extract client IP into session |
| `Sources/App/TabCoordinator.swift` | Construct store/limiter when starting Gateway |
| `Sources/UI/Settings/PairingWindowController.swift` | Replace QR/link pane with code UI |
| `Sources/UI/Settings/SettingsViewController.swift` | Wire refresh / revoke; update Host Gateway copy |
| `Sources/App/MainWindowController.swift` | Pairing context / revoke if menu window still used |
| `clients/seahelm-web/index.html` | Gate: 8-digit input; same-origin WS; no E2EE for Gateway |
| `Tests/PairingCodeStoreTests.swift` | Store unit tests |
| `Tests/PairRateLimiterTests.swift` | Limiter unit tests |
| `Tests/HostGatewaySessionTests.swift` | Code auth success / fail / rate limit |

---

### Task 1: `PairingCodeStore`

**Files:**
- Create: `Sources/Core/PairingCodeStore.swift`
- Modify: `Sources/Core/HostGatewayConfig.swift` — add `pairCode: String?`, CodingKey `pair_code`, pass through `edited(...)`
- Test: `Tests/PairingCodeStoreTests.swift`

**Interfaces:**
- Produces:
  - `struct PairingCodeStore` with:
    - `static func generate() -> String` — 8 digits, zero-padded, from `SecRandomCopyBytes`
    - `static func normalize(_ raw: String) -> String` — strip spaces/dashes, keep digits only
    - `static func isValidFormat(_ code: String) -> Bool` — exactly 8 digits after normalize
    - `mutating func ensureCode() -> String` — if missing/invalid, generate and set
    - `mutating func refresh() -> String` — always new code
    - `func verify(_ raw: String) -> Bool` — normalize + constant-time compare to stored
  - `HostGatewayConfig.pairCode: String?` with `CodingKeys.pairCode = "pair_code"`
  - `HostGatewayConfig.edited(..., pairCode: String?)` **or** preserve `existing?.pairCode` inside current `edited` so Settings edits do not wipe the code
- Consumes: none

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import seahelm

final class PairingCodeStoreTests: XCTestCase {
    func testGenerateIsEightDigits() {
        for _ in 0..<20 {
            let code = PairingCodeStore.generate()
            XCTAssertEqual(code.count, 8)
            XCTAssertTrue(code.allSatisfy(\.isNumber))
        }
    }

    func testNormalizeStripsSpaces() {
        XCTAssertEqual(PairingCodeStore.normalize("4829 1736"), "48291736")
    }

    func testVerifyAcceptsGroupedInput() {
        var store = PairingCodeStore(code: "48291736")
        XCTAssertTrue(store.verify("4829 1736"))
        XCTAssertFalse(store.verify("00000000"))
    }

    func testRefreshInvalidatesOld() {
        var store = PairingCodeStore(code: "11111111")
        let next = store.refresh()
        XCTAssertNotEqual(next, "11111111")
        XCTAssertFalse(store.verify("11111111"))
        XCTAssertTrue(store.verify(next))
    }

    func testEnsureCodeFillsMissing() {
        var store = PairingCodeStore(code: nil)
        let code = store.ensureCode()
        XCTAssertEqual(code.count, 8)
        XCTAssertEqual(store.code, code)
    }

    func testConfigRoundTripsPairCode() throws {
        var hg = HostGatewayConfig(enabled: true, port: 2783, pairCode: "12345678")
        let data = try JSONEncoder().encode(hg)
        let decoded = try JSONDecoder().decode(HostGatewayConfig.self, from: data)
        XCTAssertEqual(decoded.pairCode, "12345678")
        // edited must keep pair code when UI does not touch it
        let kept = HostGatewayConfig.edited(
            enabled: true, portText: "2783", publicURLText: "", from: hg)
        XCTAssertEqual(kept.pairCode, "12345678")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run:
```bash
xcodebuild -project seahelm.xcodeproj -scheme seahelmTests -configuration Debug \
  -skipPackagePluginValidation -skipMacroValidation \
  -only-testing:seahelmTests/PairingCodeStoreTests test
```
Expected: FAIL — `PairingCodeStore` / `pairCode` not found.

- [ ] **Step 3: Implement store + config field**

`Sources/Core/PairingCodeStore.swift`:

```swift
import Foundation
import Security

struct PairingCodeStore: Equatable {
    var code: String?

    static func generate() -> String {
        var bytes = [UInt8](repeating: 0, count: 8)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        precondition(status == errSecSuccess)
        // Map each byte into 0...9 without bias that matters at this size.
        return bytes.map { String($0 % 10) }.joined()
    }

    static func normalize(_ raw: String) -> String {
        String(raw.filter(\.isNumber))
    }

    static func isValidFormat(_ code: String) -> Bool {
        let n = normalize(code)
        return n.count == 8 && n.allSatisfy(\.isNumber)
    }

    mutating func ensureCode() -> String {
        if let code, Self.isValidFormat(code) { return Self.normalize(code) }
        let next = Self.generate()
        code = next
        return next
    }

    @discardableResult
    mutating func refresh() -> String {
        let next = Self.generate()
        code = next
        return next
    }

    func verify(_ raw: String) -> Bool {
        guard let code, Self.isValidFormat(code) else { return false }
        let expected = Array(Self.normalize(code).utf8)
        let got = Array(Self.normalize(raw).utf8)
        guard expected.count == got.count, got.count == 8 else { return false }
        var diff: UInt8 = 0
        for (a, b) in zip(expected, got) { diff |= a ^ b }
        return diff == 0
    }
}
```

In `HostGatewayConfig`:
- Add `var pairCode: String?`
- Init param `pairCode: String? = nil`
- `CodingKeys.pairCode = "pair_code"`
- In `edited(...)`, set `pairCode: existing?.pairCode` so Settings port/URL edits do not erase it

- [ ] **Step 4: Run tests — expect PASS**

Same `xcodebuild … PairingCodeStoreTests` command. Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/Core/PairingCodeStore.swift Sources/Core/HostGatewayConfig.swift \
  Tests/PairingCodeStoreTests.swift Tests/HostGatewayConfigTests.swift
git commit -m "$(cat <<'EOF'
feat: persist Host Gateway 8-digit pairing code

EOF
)"
```

---

### Task 2: `PairRateLimiter`

**Files:**
- Create: `Sources/Core/PairRateLimiter.swift`
- Test: `Tests/PairRateLimiterTests.swift`

**Interfaces:**
- Produces: `final class PairRateLimiter` with:
  - `init(maxFailures: Int = 5, window: TimeInterval = 60)`
  - `func allow(ip: String, now: Date = Date()) -> Bool` — false if locked out
  - `func recordFailure(ip: String, now: Date = Date())`
  - `func recordSuccess(ip: String)` — clear window for that IP
- Consumes: none

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import seahelm

final class PairRateLimiterTests: XCTestCase {
    func testAllowsUnderCap() {
        let lim = PairRateLimiter(maxFailures: 5, window: 60)
        let t0 = Date(timeIntervalSince1970: 1_000)
        for _ in 0..<4 { lim.recordFailure(ip: "1.1.1.1", now: t0) }
        XCTAssertTrue(lim.allow(ip: "1.1.1.1", now: t0))
    }

    func testBlocksAfterCap() {
        let lim = PairRateLimiter(maxFailures: 5, window: 60)
        let t0 = Date(timeIntervalSince1970: 1_000)
        for _ in 0..<5 { lim.recordFailure(ip: "1.1.1.1", now: t0) }
        XCTAssertFalse(lim.allow(ip: "1.1.1.1", now: t0))
        XCTAssertTrue(lim.allow(ip: "2.2.2.2", now: t0)) // other IP free
    }

    func testWindowExpiryUnlocks() {
        let lim = PairRateLimiter(maxFailures: 5, window: 60)
        let t0 = Date(timeIntervalSince1970: 1_000)
        for _ in 0..<5 { lim.recordFailure(ip: "1.1.1.1", now: t0) }
        XCTAssertFalse(lim.allow(ip: "1.1.1.1", now: t0))
        XCTAssertTrue(lim.allow(ip: "1.1.1.1", now: t0.addingTimeInterval(61)))
    }

    func testSuccessClearsFailures() {
        let lim = PairRateLimiter(maxFailures: 5, window: 60)
        let t0 = Date(timeIntervalSince1970: 1_000)
        for _ in 0..<4 { lim.recordFailure(ip: "1.1.1.1", now: t0) }
        lim.recordSuccess(ip: "1.1.1.1")
        for _ in 0..<4 { lim.recordFailure(ip: "1.1.1.1", now: t0) }
        XCTAssertTrue(lim.allow(ip: "1.1.1.1", now: t0))
    }
}
```

- [ ] **Step 2: Run — expect FAIL** (`PairRateLimiter` missing)

- [ ] **Step 3: Implement**

```swift
import Foundation

final class PairRateLimiter {
    private let maxFailures: Int
    private let window: TimeInterval
    private let lock = NSLock()
    private var failures: [String: [Date]] = [:]

    init(maxFailures: Int = 5, window: TimeInterval = 60) {
        self.maxFailures = maxFailures
        self.window = window
    }

    func allow(ip: String, now: Date = Date()) -> Bool {
        lock.lock(); defer { lock.unlock() }
        prune(ip: ip, now: now)
        return (failures[ip] ?? []).count < maxFailures
    }

    func recordFailure(ip: String, now: Date = Date()) {
        lock.lock(); defer { lock.unlock() }
        prune(ip: ip, now: now)
        failures[ip, default: []].append(now)
    }

    func recordSuccess(ip: String) {
        lock.lock(); defer { lock.unlock() }
        failures.removeValue(forKey: ip)
    }

    private func prune(ip: String, now: Date) {
        guard let list = failures[ip] else { return }
        let kept = list.filter { now.timeIntervalSince($0) < window }
        if kept.isEmpty { failures.removeValue(forKey: ip) }
        else { failures[ip] = kept }
    }
}
```

- [ ] **Step 4: Run — expect PASS**

```bash
xcodebuild -project seahelm.xcodeproj -scheme seahelmTests -configuration Debug \
  -skipPackagePluginValidation -skipMacroValidation \
  -only-testing:seahelmTests/PairRateLimiterTests test
```

- [ ] **Step 5: Commit**

```bash
git add Sources/Core/PairRateLimiter.swift Tests/PairRateLimiterTests.swift
git commit -m "$(cat <<'EOF'
feat: rate-limit Host Gateway pairing code attempts

EOF
)"
```

---

### Task 3: Code auth on `HostGatewaySession`

**Files:**
- Modify: `Sources/Core/HostGatewaySession.swift` — inject code store + rate limiter + client IP; extend `handleAuth`
- Modify: `Sources/Core/HostGatewayServer.swift` — pass dependencies; set client IP from `NWConnection`
- Modify: `Sources/App/TabCoordinator.swift` `setupHostGateway` — create store from config, persist on refresh if needed at start via `ensureCode`
- Test: `Tests/HostGatewaySessionTests.swift` — add code-auth cases

**Interfaces:**
- Consumes: `PairingCodeStore.verify`, `PairRateLimiter.allow/recordFailure/recordSuccess`, `HostGatewayAuth.expectedToken`
- Produces: `auth` success with `code` returns `result: { ok, mac_id, token, vt_binary, vt_deflate }`; rate limit returns `error: { code: -32029, message: "rate_limited" }`; bad code returns `result: { ok: false, … }` **or** `-32001` — pick **`result.ok = false` for wrong code** (matches today's token failure style) and **`error -32029` only for rate limit**
- `HostGatewaySession` init gains:
  - `pairingCode: PairingCodeStore` (value copy at session start is fine if server holds the live store and passes a closure — prefer **`codeVerifier: () -> PairingCodeStore`** or **`codeStore: PairingCodeProviding`** protocol so refresh on Settings is seen by live sessions)

Prefer a small protocol so the server owns the mutable store:

```swift
protocol PairingCodeVerifying: AnyObject {
    func verify(_ raw: String) -> Bool
}
protocol PairingCodeIssuing: AnyObject {
    // token issuance uses root secret already on the session
}
```

Simplest workable shape for this codebase:

```swift
// On HostGatewayServer / TabCoordinator:
final class LivePairingCode: PairingCodeVerifying {
    private let lock = NSLock()
    private var store: PairingCodeStore
    var onChange: ((PairingCodeStore) -> Void)?  // persist to config
    init(store: PairingCodeStore) { self.store = store }
    func current() -> String { lock.lock(); defer { lock.unlock() }; return store.ensureCode() }
    func refresh() -> String { /* lock; refresh; onChange?; return */ }
    func verify(_ raw: String) -> Bool { lock.lock(); defer { lock.unlock() }; return store.verify(raw) }
}
```

Session init:

```swift
init(..., pairingCode: PairingCodeVerifying?, rateLimiter: PairRateLimiter?, clientIP: String?)
```

`handleAuth` algorithm:

1. If `token` non-empty: existing verify; on success set authenticated; response **without requiring** `mac_id`/`token` echo (keep current fields; **also include `mac_id` + `token` when ok** so web can unify handling).
2. Else if `code` non-empty:
   - If `rateLimiter?.allow(ip:) == false` → encode error `-32029`.
   - Else if `pairingCode?.verify(code) != true` → `recordFailure`; return `ok: false`.
   - Else → `recordSuccess`; authenticate; return `ok: true, mac_id: expectedMacId, token: HostGatewayAuth.expectedToken(...)!, vt_*`.
3. Else → `ok: false`.

- [ ] **Step 1: Write failing session tests**

```swift
func testAuthWithCodeSucceedsAndReturnsToken() {
    let (s, _, _) = sessionWithCode("48291736")
    let frames = s.handle(#"{"id":"a","method":"auth","params":{"code":"4829 1736","vt_binary":true,"vt_deflate":true}}"#)
    let text = frames.compactMap { if case .text(let t) = $0 { return t } else { return nil } }.joined()
    XCTAssertTrue(text.contains(#""ok":true"#) || text.contains(#""ok": true"#))
    XCTAssertTrue(text.contains("mac_id"))
    XCTAssertTrue(text.contains("token"))
    // follow-up business call must work
    let snap = s.handle(#"{"id":"2","method":"session.snapshot","params":{}}"#)
    XCTAssertFalse(snap.map(asText).joined().contains("unauthorized"))
}

func testAuthWithWrongCodeFails() { /* ok false; snapshot unauthorized */ }

func testAuthCodeRateLimited() {
    // inject limiter with maxFailures: 2, record 2 failures, third returns -32029
}
```

Helper `sessionWithCode` must construct `LivePairingCode` / fake verifier.

- [ ] **Step 2: Run — expect FAIL**

- [ ] **Step 3: Implement session + server wiring**

Extract client IP in `HostGatewayServer.accept`:

```swift
let ip: String
if case .hostPort(let host, _) = connection.endpoint {
    ip = "\(host)"
} else {
    ip = "unknown"
}
```

Pass `pairingCode` and `rateLimiter` from `TabCoordinator.setupHostGateway`:

```swift
var store = PairingCodeStore(code: hgConfig.pairCode)
_ = store.ensureCode()
if store.code != hgConfig.pairCode {
    config.hostGateway?.pairCode = store.code
    // save config the same way mintPairingContext / applyChanges does
}
let live = LivePairingCode(store: store)
live.onChange = { [weak self] updated in
    self?.config.hostGateway?.pairCode = updated.code
    self?.saveConfigIfNeeded() // use existing persist path
}
```

Keep a strong reference on `TabCoordinator` (`pairingCodeLive`) so Settings refresh can call it.

- [ ] **Step 4: Run session + auth tests — expect PASS**

```bash
xcodebuild -project seahelm.xcodeproj -scheme seahelmTests -configuration Debug \
  -skipPackagePluginValidation -skipMacroValidation \
  -only-testing:seahelmTests/HostGatewaySessionTests \
  -only-testing:seahelmTests/HostGatewayAuthTests test
```

- [ ] **Step 5: Commit**

```bash
git add Sources/Core/HostGatewaySession.swift Sources/Core/HostGatewayServer.swift \
  Sources/Core/LivePairingCode.swift Sources/App/TabCoordinator.swift \
  Tests/HostGatewaySessionTests.swift
git commit -m "$(cat <<'EOF'
feat: authenticate Host Gateway clients with an 8-digit code

EOF
)"
```

---

### Task 4: Settings UI — code pane + revoke

**Files:**
- Rewrite: `Sources/UI/Settings/PairingWindowController.swift` (`PairingPaneView`)
- Modify: `Sources/UI/Settings/SettingsViewController.swift` — `buildPairingGroups`, Host Gateway subtitle copy, refresh/revoke actions
- Modify: `Sources/App/MainWindowController.swift` — menu “Pair remote client” if it still opens QR window; either show new pane or open Settings Remote tab

**Interfaces:**
- Consumes: `LivePairingCode.current()` / `refresh()`, `HostGatewayConfig.resolvedPageURL`
- Produces: UI showing code + access URL; no QR; no `seahelm://pair`

- [ ] **Step 1: Replace `PairingPaneView`**

New API:

```swift
final class PairingPaneView: NSView {
    var accessURL: String { didSet { urlField.stringValue = accessURL } }
    private let codeLabel = NSTextField(labelWithString: "")
    private let urlField = NSTextField(labelWithString: "")
    var onRefresh: (() -> String)?
    var onRevokeAll: (() -> Void)?

    func setCode(_ code: String) {
        // display as "XXXX XXXX"
        let n = PairingCodeStore.normalize(code)
        guard n.count == 8 else { codeLabel.stringValue = n; return }
        let i = n.index(n.startIndex, offsetBy: 4)
        codeLabel.stringValue = "\(n[..<i]) \(n[i...])"
    }
}
```

Buttons: Copy code, Refresh code, Revoke all remotes.  
Caption: “Open the access URL in a browser, then enter this code.”  
Remove QR image, long link field, `brokerURL`, `rootSecret`, `pairURI`.

- [ ] **Step 2: Wire Settings**

In `buildPairingGroups`:
- Build pane with `accessURL = (config.hostGateway ?? .init()).resolvedPageURL`
- `setCode` from live store / config.pairCode
- `onRefresh` → live.refresh(); persist; update label
- `onRevokeAll` → generate new `mqtt.root_secret`, persist, restart Host Gateway (existing setup/teardown), refresh code, drop sessions

Update Host Gateway **Public URL** subtitle: remove SubtleCrypto / HTTPS-only warning; say it is the address shown under Browser access / used for `resolvedPageURL`, not embedded in a pair secret.

Remove `refreshPairingLink` QR updates; replace with `refreshPairingCodeDisplay()` updating access URL + code.

- [ ] **Step 3: Manual build**

```bash
xcodebuild -project seahelm.xcodeproj -scheme seahelm -configuration Debug \
  -skipPackagePluginValidation -skipMacroValidation build
```
Expected: BUILD SUCCEEDED.

- [ ] **Step 4: Commit**

```bash
git add Sources/UI/Settings/PairingWindowController.swift \
  Sources/UI/Settings/SettingsViewController.swift \
  Sources/App/MainWindowController.swift
git commit -m "$(cat <<'EOF'
feat: show 8-digit pairing code in Settings instead of QR

EOF
)"
```

---

### Task 5: Web gate — code input, no E2EE

**Files:**
- Modify: `clients/seahelm-web/index.html` — `renderGate`, `connectGateway`, creds storage, remove `applyPair` for Gateway path
- Do **not** remove `e2ee.js` file (MQTT `?mqtt=1` may still need it); stop requiring it for Gateway

**Interfaces:**
- Consumes: `auth` response fields `mac_id`, `token`
- Produces: localStorage `{ m, t }` only

- [ ] **Step 1: Replace gate UI**

Unpaired gate:

```html
<div class="gate-card">
  <div class="gate-title">配对这台 Mac</div>
  <div class="gate-hint">在 Seahelm 设置里查看 8 位配对码，输入后连接</div>
  <input class="gate-input" id="gateCode" inputmode="numeric" autocomplete="one-time-code"
         maxlength="9" placeholder="1234 5678" />
  <button class="gate-primary" id="gatePair">配对并连接</button>
  <div class="gate-error" id="gateError" hidden></div>
</div>
```

`go()`:
1. Normalize code (digits only); if length !== 8 → fail.
2. Set `S.pendingCode = code` (temporary; cleared after auth).
3. `connect()` → Gateway.

- [ ] **Step 2: Change `connectGateway`**

```javascript
function connectGateway(_ignoredUrl){
  const scheme = location.protocol === 'https:' ? 'wss:' : 'ws:';
  const url = `${scheme}//${location.host}/ws`;
  // ...
  ws.onopen = () => {
    const params = { vt_binary: true, vt_deflate: typeof DecompressionStream === 'function' };
    if (S.pendingCode) { params.code = S.pendingCode; }
    else if (S.authPass) { params.mac_id = S.mac; params.token = S.authPass; }
    else { setStatus(false, '需要配对码'); ws.close(); return; }
    gwSend('auth', params, (r, err) => {
      if (err && err.code === -32029) { /* rate limited */ ...; return; }
      if (err || !r || r.ok === false) { /* unauthorized */ clear pending; ...; return; }
      S.mac = r.mac_id || S.mac;
      S.authPass = r.token || S.authPass;
      S.pendingCode = null;
      localStorage.setItem(CREDS_KEY, JSON.stringify({ m: S.mac, t: S.authPass }));
      // negotiate vt flags as today
      ...
    });
  };
}
```

Remove alert “需要先配对(seahelm://pair…)”.  
`useGatewayTransport`: when on Gateway-served page (path `/` with Host Gateway), default Gateway — already true when URL ends with `/ws` after connect; ensure Connect without broker field still uses Gateway when `location.port` is gateway or `?transport=gateway` / served from Host Gateway (same as today’s `/ws` heuristic after setting broker to same-origin `/ws` in `edgeBroker`-like helper):

```javascript
function gatewayWsURL(){
  const scheme = location.protocol === 'https:' ? 'wss:' : 'ws:';
  return `${scheme}//${location.host}/ws`;
}
// On load, if not ?mqtt=1, set broker field to gatewayWsURL() so Connect uses Gateway.
```

- [ ] **Step 3: Remove Gateway `applyPair` path**

Delete or gate behind `?mqtt=1` only: paste long link flow.  
`loadCreds` must tolerate missing `b`.

- [ ] **Step 4: Manual check**

With Gateway enabled: open `http://127.0.0.1:2783/`, enter code, confirm log shows `(vt format) binary+deflate` and First Mate fills. Reload page — auto-connect without code.

- [ ] **Step 5: Commit**

```bash
git add clients/seahelm-web/index.html
git commit -m "$(cat <<'EOF'
feat: pair seahelm-web with an 8-digit code over plain HTTP

EOF
)"
```

---

### Task 6: Spec status + smoke checklist

**Files:**
- Modify: `docs/superpowers/specs/2026-08-28-short-pair-code-design.md` — Status → Implemented (or “Ready for QA”)
- Optional note in `clients/seahelm-web/README.md` one-liner: production pairing is 8-digit code on Host Gateway page

- [ ] **Step 1: Run focused tests**

```bash
xcodebuild -project seahelm.xcodeproj -scheme seahelmTests -configuration Debug \
  -skipPackagePluginValidation -skipMacroValidation \
  -only-testing:seahelmTests/PairingCodeStoreTests \
  -only-testing:seahelmTests/PairRateLimiterTests \
  -only-testing:seahelmTests/HostGatewaySessionTests \
  -only-testing:seahelmTests/HostGatewayConfigTests test
```
Expected: all PASS.

- [ ] **Step 2: Update spec status line**

- [ ] **Step 3: Commit**

```bash
git add docs/superpowers/specs/2026-08-28-short-pair-code-design.md clients/seahelm-web/README.md
git commit -m "$(cat <<'EOF'
docs: mark short pair-code design implemented

EOF
)"
```

---

## Spec coverage (self-review)

| Spec requirement | Task |
|---|---|
| 8-digit code, refresh until manual | Task 1 + 4 |
| Remember token in localStorage | Task 5 |
| Full replace QR/long link in Settings + web | Task 4 + 5 |
| `auth { code }` → `mac_id` + `token` | Task 3 |
| Same-origin WS, HTTP works | Task 5 |
| Rate limit 5/60s/IP | Task 2 + 3 |
| Refresh code ≠ revoke tokens | Task 1 + 4 (revoke is separate) |
| Revoke all = rotate root | Task 4 |
| Unit tests store/limiter/session | Tasks 1–3 |
| Manual HTTP Tailscale | Task 5 Step 4 / Task 6 |

No TBD placeholders. Types: `PairingCodeStore`, `PairRateLimiter`, `LivePairingCode`, `HostGatewayConfig.pairCode` used consistently.
