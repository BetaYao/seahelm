# seahelm-web Poor-Network Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make seahelm-web usable on weak links by speeding page load, bounding VT backlog with drop-old/resync, prioritizing control/keys over VT, and letting the user choose single-pane vs mirror attach.

**Architecture:** Keep one Host Gateway WebSocket and the zmx-attach PTY model. Harden `HostGatewayStaticFiles`/`HostGatewayServer` for gzip+cache+keep-alive; extend `HostGatewaySession` with dual egress queues and byte budgets; add negotiated binary key frames; add a client VT mode toggle defaulting to single-pane.

**Tech Stack:** Swift 5.10 / Network.framework / Compression (zlib), XCTest, static `clients/seahelm-web` (xterm.js).

**Spec:** `docs/superpowers/specs/2026-08-29-seahelm-web-poor-network-design.md`

## Global Constraints

- VT source remains `zmx attach` — never `zmx tail` / `zmx history --vt`.
- Never call `zmx detach` when a remote client closes.
- One WebSocket only (no dual-socket in this plan).
- Default client VT mode is **single**; mirror is opt-in and persisted.
- Binary keys and VT binary/deflate remain negotiated; old clients keep working.
- macOS 14+, Swift 5.10, `@testable import seahelm`, XCTest only.
- Prefer small focused types under `Sources/Core/`; extend existing Host Gateway tests.

---

## File Structure

| File | Responsibility |
|---|---|
| `Sources/Core/HostGatewayStaticFiles.swift` | gzip, ETag, Cache-Control, Accept-Encoding-aware responses |
| `Sources/Core/HostGatewayServer.swift` | HTTP keep-alive for static; WS binary inbound for keys; paced VT send |
| `Sources/Core/HostGatewaySession.swift` | High/low egress queues, VT byte budget, drop-old + resync, keys_binary auth |
| `Sources/Core/HostGatewayKeyFrame.swift` | Binary inbound key frame encode/decode |
| `Sources/Core/ZmxVTAttachManager.swift` | Optional per-pane coalesce stretch when session requests it (light) |
| `clients/seahelm-web/index.html` | Deferred WebGL, VT mode toggle, write-chain drop, binary keys |
| `clients/seahelm-web/README.md` | Document mode toggle + load behavior |
| `project.yml` | Exclude `bench.html` / `bench-corpus.js` from bundle |
| `Tests/HostGatewayStaticFilesTests.swift` | gzip / cache / 304 |
| `Tests/HostGatewaySessionBackpressureTests.swift` | Queue budget, priority, resync |
| `Tests/HostGatewayKeyFrameTests.swift` | Binary keys round-trip |

---

### Task 1: Static gzip + cache headers

**Files:**
- Modify: `Sources/Core/HostGatewayStaticFiles.swift`
- Modify: `Tests/HostGatewayStaticFilesTests.swift`

**Interfaces:**
- Produces:
  - `HostGatewayStaticFiles.RequestHeaders` with at least `acceptEncoding: String?`, `ifNoneMatch: String?`
  - `response(method:target:headers:) -> Response`
  - `Response` gains `cacheControl: String`, `contentEncoding: String?`, `etag: String?`, `vary: String?`
  - `serialize(_:includeBody:) -> Data` emits those headers; `Content-Length` is compressed size when gzipped
- Consumes: existing `resolve` / `contentType`

- [ ] **Step 1: Write the failing tests**

Append to `Tests/HostGatewayStaticFilesTests.swift`:

```swift
func testGzipWhenAccepted() {
    // Make body large enough that gzip shrinks it.
    let raw = Data(repeating: 0x61, count: 4096) // "aaaa..."
    try! raw.write(to: root.appendingPathComponent("big.js"))
    let response = files.response(
        method: "GET",
        target: "/big.js",
        headers: .init(acceptEncoding: "gzip, deflate", ifNoneMatch: nil))
    XCTAssertEqual(response.status, 200)
    XCTAssertEqual(response.contentEncoding, "gzip")
    XCTAssertLessThan(response.body.count, raw.count)
    XCTAssertEqual(response.cacheControl, "public, max-age=86400")
    XCTAssertNotNil(response.etag)
}

func testNoGzipWithoutAcceptEncoding() {
    let response = files.response(
        method: "GET", target: "/e2ee.js",
        headers: .init(acceptEncoding: nil, ifNoneMatch: nil))
    XCTAssertNil(response.contentEncoding)
    XCTAssertEqual(String(decoding: response.body, as: UTF8.self), "var E2EE;")
}

func testHtmlIsNoCache() {
    let response = files.response(
        method: "GET", target: "/",
        headers: .init(acceptEncoding: "gzip", ifNoneMatch: nil))
    XCTAssertEqual(response.cacheControl, "no-cache")
}

func testVersionedAssetIsImmutable() {
    let response = files.response(
        method: "GET", target: "/e2ee.js?v=20260724",
        headers: .init(acceptEncoding: nil, ifNoneMatch: nil))
    XCTAssertEqual(response.cacheControl, "public, max-age=31536000, immutable")
}

func testETagYields304() {
    let first = files.response(
        method: "GET", target: "/e2ee.js",
        headers: .init(acceptEncoding: nil, ifNoneMatch: nil))
    let etag = try! XCTUnwrap(first.etag)
    let again = files.response(
        method: "GET", target: "/e2ee.js",
        headers: .init(acceptEncoding: nil, ifNoneMatch: etag))
    XCTAssertEqual(again.status, 304)
    XCTAssertTrue(again.body.isEmpty)
}

func testSerializeIncludesEncodingAndCache() {
    let response = HostGatewayStaticFiles.Response(
        status: 200, reason: "OK",
        contentType: "text/javascript; charset=utf-8",
        body: Data([0x1f, 0x8b]),
        cacheControl: "public, max-age=86400",
        contentEncoding: "gzip",
        etag: "\"abc\"",
        vary: "Accept-Encoding")
    let wire = String(decoding: HostGatewayStaticFiles.serialize(response, includeBody: true), as: UTF8.self)
    XCTAssertTrue(wire.contains("Content-Encoding: gzip\r\n"))
    XCTAssertTrue(wire.contains("Cache-Control: public, max-age=86400\r\n"))
    XCTAssertTrue(wire.contains("ETag: \"abc\"\r\n"))
    XCTAssertTrue(wire.contains("Vary: Accept-Encoding\r\n"))
    XCTAssertFalse(wire.contains("Connection: close\r\n"))
}
```

Update existing call sites in this file that use `response(method:target:)` to pass `headers: .init(acceptEncoding: nil, ifNoneMatch: nil)` (or add a defaulted overload).

- [ ] **Step 2: Run tests to verify they fail**

```bash
xcodebuild -project seahelm.xcodeproj -scheme seahelmTests -configuration Debug \
  -skipPackagePluginValidation -skipMacroValidation \
  -only-testing:seahelmTests/HostGatewayStaticFilesTests test
```

Expected: FAIL — missing `headers` / `contentEncoding` / etc.

- [ ] **Step 3: Implement minimal StaticFiles support**

In `HostGatewayStaticFiles.swift`:

```swift
struct RequestHeaders: Equatable {
    var acceptEncoding: String?
    var ifNoneMatch: String?
}

struct Response: Equatable {
    let status: Int
    let reason: String
    let contentType: String
    let body: Data
    let cacheControl: String
    let contentEncoding: String?
    let etag: String?
    let vary: String?
}

func response(method: String, target: String,
              headers: RequestHeaders = .init()) -> Response {
    // ... existing 405/404 guards ...
    // After reading `data` from disk:
    let etag = Self.etag(for: data)
    if let inm = headers.ifNoneMatch, inm == etag {
        return Response(status: 304, reason: "Not Modified",
                        contentType: contentType, body: Data(),
                        cacheControl: cacheControl(for: target, pathExtension:),
                        contentEncoding: nil, etag: etag, vary: nil)
    }
    let wantGzip = Self.acceptsGzip(headers.acceptEncoding)
        && Self.gzipable(pathExtension)
    var body = data
    var encoding: String? = nil
    var vary: String? = nil
    if wantGzip, let gz = Self.gzip(data), gz.count < data.count {
        body = gz
        encoding = "gzip"
        vary = "Accept-Encoding"
    }
    return Response(status: 200, reason: "OK", contentType: ...,
                    body: body,
                    cacheControl: Self.cacheControl(for: target, pathExtension: ...),
                    contentEncoding: encoding, etag: etag, vary: vary)
}
```

Helpers:

- `acceptsGzip`: token-split `Accept-Encoding`, true if `gzip` present (ignore q=0).
- `gzipable`: html/htm/js/mjs/css/svg/json/map/txt/md.
- `gzip(_:)`: Foundation/`Compression` raw zlib wrapped as gzip (header + CRC), or `Data` via `NSData` compression if already used elsewhere — match existing deflate style in `HostGatewayVTFrame` only if you add a proper gzip container; simplest portable approach: use `Compression` zlib and write RFC 1952 gzip framing, **or** shell out is forbidden — implement gzip framing in ~40 lines.
- `etag(for:)`: `"\"\(sha256-or-fnv hex of bytes)\""` — SHA256 via CryptoKit is fine.
- `cacheControl(for:pathExtension:)`:
  - html/htm → `no-cache`
  - target contains `?v=` or `?v&` query → `public, max-age=31536000, immutable`
  - else → `public, max-age=86400`

`serialize`: emit optional `Content-Encoding`, `ETag`, `Vary`, `Cache-Control`; use `Connection: keep-alive` instead of `close`. For 304, `Content-Length: 0` and no body.

Keep a convenience overload `response(method:target:)` calling empty headers so other call sites compile.

- [ ] **Step 4: Run tests — expect PASS**

Same `xcodebuild` command as Step 2.

- [ ] **Step 5: Commit**

```bash
git add Sources/Core/HostGatewayStaticFiles.swift Tests/HostGatewayStaticFilesTests.swift
git commit -m "feat: gzip and cache headers for Host Gateway static files"
```

---

### Task 2: HTTP keep-alive for static requests

**Files:**
- Modify: `Sources/Core/HostGatewayServer.swift` (`route` / request-head loop ~267–278)
- Test: extend `Tests/HostGatewayServerTests.swift` **or** add a focused unit test on a extracted `shouldKeepAlive(requestHead:)` helper if full NW loop is hard to unit-test

**Interfaces:**
- Produces: after a static response with keep-alive, connection stays open and reads another request head; `Connection: close` only when client asked or on error
- Consumes: `HostGatewayStaticFiles.serialize` (already keep-alive)

- [ ] **Step 1: Write failing test for header parse helper**

In `HostGatewayServer` (or StaticFiles), add:

```swift
static func clientRequestsClose(head: String) -> Bool {
    // HTTP/1.0 default close; HTTP/1.1 default keep-alive unless Connection: close
}
```

Test:

```swift
func testKeepAliveDefaultHttp11() {
    XCTAssertFalse(HostGatewayServer.clientRequestsClose(
        head: "GET / HTTP/1.1\r\nHost: x\r\n"))
    XCTAssertTrue(HostGatewayServer.clientRequestsClose(
        head: "GET / HTTP/1.1\r\nHost: x\r\nConnection: close\r\n"))
    XCTAssertTrue(HostGatewayServer.clientRequestsClose(
        head: "GET / HTTP/1.0\r\nHost: x\r\n"))
}
```

- [ ] **Step 2: Run test — expect FAIL** (symbol missing)

- [ ] **Step 3: Implement keep-alive path**

Replace `route` static branch:

```swift
let headers = Self.parseRequestHeaders(head) // Accept-Encoding, If-None-Match, Connection
let response = staticFiles.response(method: method, target: target, headers: headers)
let close = Self.clientRequestsClose(head: head)
var payload = HostGatewayStaticFiles.serialize(response, includeBody: method != "HEAD")
// If serialize always says keep-alive, rewrite Connection when close==true:
if close {
    // ensure serialize can take connectionClose: Bool, or replace header string
}
connection.send(content: payload, isComplete: close, completion: .contentProcessed { [weak self] error in
    guard let self else { return }
    if error != nil || close {
        connection.cancel()
        return
    }
    self.readRequestHead(on: connection, buffered: Data())
})
```

Parse `Accept-Encoding` / `If-None-Match` from `head` into `RequestHeaders`.

- [ ] **Step 4: Run HostGatewayServer + StaticFiles tests — PASS**

- [ ] **Step 5: Commit**

```bash
git add Sources/Core/HostGatewayServer.swift Tests/HostGatewayServerTests.swift Tests/HostGatewayStaticFilesTests.swift
git commit -m "feat: HTTP keep-alive for Host Gateway static hosting"
```

---

### Task 3: Defer WebGL + exclude bench from bundle

**Files:**
- Modify: `clients/seahelm-web/index.html` (script tags + `attachWebglRenderer`)
- Modify: `project.yml` Bundle seahelm-web rsync excludes
- Modify: `clients/seahelm-web/README.md` (one line on deferred WebGL)
- Run: `xcodegen generate` after `project.yml`

**Interfaces:**
- Produces: default HTML loads `e2ee.js` + `xterm.js` only; WebGL addon loaded on first terminal open via dynamic `<script>` or `import()`; bench files not copied into app Resources

- [ ] **Step 1: Change HTML script includes**

Remove synchronous:

```html
<script src="./xterm-addon-webgl.js"></script>
```

Keep:

```html
<script src="./xterm.js"></script>
<script src="./e2ee.js"></script>
```

- [ ] **Step 2: Lazy-load WebGL in `attachWebglRenderer`**

```javascript
let webglAddonPromise = null;
function loadWebglAddon(){
  if (typeof WebglAddon !== 'undefined' && WebglAddon.WebglAddon) {
    return Promise.resolve(WebglAddon);
  }
  if (webglAddonPromise) return webglAddonPromise;
  webglAddonPromise = new Promise((resolve, reject) => {
    const s = document.createElement('script');
    s.src = './xterm-addon-webgl.js';
    s.onload = () => resolve(window.WebglAddon || WebglAddon);
    s.onerror = () => reject(new Error('webgl addon failed'));
    document.head.appendChild(s);
  });
  return webglAddonPromise;
}

function attachWebglRenderer(term){
  if (RENDERER === 'ghostty') return;
  loadWebglAddon().then((mod) => {
    const Ctor = mod.WebglAddon || mod;
    const addon = new Ctor();
    addon.onContextLoss(() => { try { addon.dispose(); } catch (e) {} });
    term.loadAddon(addon);
  }).catch((e) => {
    log('sys', '(webgl)', `不可用,回退 DOM 渲染: ${e && e.message}`);
  });
}
```

Adapt to how the vendored file exposes `WebglAddon` today (check global name before coding).

- [ ] **Step 3: Exclude bench from bundle**

In `project.yml` rsync:

```bash
rsync -a \
  --exclude '.gitignore' --exclude 'README.md' \
  --exclude 'bench.html' --exclude 'bench-corpus.js' \
  "${SRC}/" "${DEST}/"
```

Run `xcodegen generate`.

- [ ] **Step 4: Smoke-check** — open `index.html` in Safari/Chrome local file or Gateway; confirm Network panel does not request `xterm-addon-webgl.js` until a pane opens; ghostty still only on `?renderer=ghostty`.

- [ ] **Step 5: Commit**

```bash
git add clients/seahelm-web/index.html clients/seahelm-web/README.md project.yml seahelm.xcodeproj/project.pbxproj
git commit -m "perf: defer WebGL addon and skip bench assets in Gateway bundle"
```

---

### Task 4: Single / mirror VT mode toggle

**Files:**
- Modify: `clients/seahelm-web/index.html`
- Modify: `clients/seahelm-web/README.md`

**Interfaces:**
- Produces: `localStorage.seahelm_vt_mode` = `single` | `mirror` (default `single`); header control toggles; `mountPanes` respects preference unless layout cannot mirror

- [ ] **Step 1: Add state + UI control**

Near renderer badge:

```html
<button class="renderer-badge" id="vtModeBadge" title="VT 订阅模式">单屏</button>
```

```javascript
const VT_MODE_KEY = 'seahelm_vt_mode';
function loadVtMode(){
  const v = localStorage.getItem(VT_MODE_KEY);
  return v === 'mirror' ? 'mirror' : 'single'; // default single
}
function setVtMode(mode){
  localStorage.setItem(VT_MODE_KEY, mode);
  renderVtModeBadge();
  // remount if a worktree is open
  if (S.sel) {
    const path = S.sel, focus = S.vt.focus || S.selPane;
    unmountPanes();
    requestLayout(path); // or remount with cached tree if available
  }
}
function renderVtModeBadge(){
  const el = $('vtModeBadge');
  if (!el) return;
  const mode = loadVtMode();
  el.textContent = mode === 'mirror' ? '镜像' : '单屏';
  el.title = mode === 'mirror'
    ? '镜像：每个 pane 一路 VT — 点击切到单屏'
    : '单屏：只订阅焦点 pane — 点击切到镜像';
  el.onclick = () => setVtMode(mode === 'mirror' ? 'single' : 'mirror');
}
```

- [ ] **Step 2: Gate `mountPanes` mode selection**

Replace mode decision:

```javascript
const preferMirror = loadVtMode() === 'mirror';
S.vt.mode = (preferMirror && layoutFitsMirror(tree, wrap.clientWidth)) ? 'mirror' : 'single';
```

In `handleViewportResize`, same preference when deciding remount.

- [ ] **Step 3: README** — document default single + toggle.

- [ ] **Step 4: Manual check** — default opens one attach; switch to 镜像 opens N; switch back closes extras. Narrow window still forces single.

- [ ] **Step 5: Commit**

```bash
git add clients/seahelm-web/index.html clients/seahelm-web/README.md
git commit -m "feat: single/mirror VT subscribe toggle (default single)"
```

---

### Task 5: Session egress priority + VT byte budget + resync

**Files:**
- Modify: `Sources/Core/HostGatewaySession.swift`
- Create: `Tests/HostGatewaySessionBackpressureTests.swift`
- Optionally touch: `Sources/Core/ZmxVTAttachManager.swift` only if exposing a coalesce hint API; otherwise stretch coalesce later / skip if too invasive — **prefer session-only first**

**Interfaces:**
- Produces:
  - Constants: `maxPendingVTBytes = 256 * 1024`, `maxPendingVTBytesPerPane = 128 * 1024`, `resyncMinInterval = 1.0`
  - `Pending` distinguishes `.high(HostGatewayWireFrame)` vs `.vt(VTEvent)`
  - `enqueue` (RPC/decisions) → high; `enqueueVT` → low with budget
  - On per-pane or total overflow: drop older `.vt` for that pane, set `needsResync`, enqueue synthetic empty/minimal `VTEvent(kind: .snapshot, ...)` rate-limited
  - `drainNotifications()` returns **all high frames first**, then VT frames (encode as today)
- Consumes: existing `encodeVT`, `openVTKeys`, auth flags

- [ ] **Step 1: Write failing tests**

```swift
import XCTest
@testable import seahelm

final class HostGatewaySessionBackpressureTests: XCTestCase {
    final class FakeVT: HostGatewayVTAttaching {
        var opens: [String] = []
        func open(paneSessionKey: String) -> [String: Any] {
            opens.append(paneSessionKey)
            return ["ok": true]
        }
        func close(paneSessionKey: String) {}
        func keepalive(paneSessionKey: String) {}
        func sendKeys(paneSessionKey: String, utf8: Data) -> Bool { true }
        var observer: ((VTEvent) -> Void)?
        func addObserver(_ observer: @escaping (VTEvent) -> Void) -> Int {
            self.observer = observer; return 1
        }
        func removeObserver(_ token: Int) { observer = nil }
    }

    // Build session with fake router/vt like HostGatewaySessionTests — copy helpers.

    func testHighPriorityDrainsBeforeVT() { /* enqueue VT then decision; drain; first frames are pane.event / ready */ }
    func testDropsOldVTWhenOverBudget() { /* append many large vt.data; pending VT byte estimate ≤ cap; needs snapshot at end */ }
    func testResyncRateLimited() { /* two overflows within 1s → one snapshot */ }
}
```

Mirror construction patterns from `Tests/HostGatewaySessionTests.swift` (read that file and copy the fake router setup verbatim).

- [ ] **Step 2: Run — FAIL**

```bash
xcodebuild ... -only-testing:seahelmTests/HostGatewaySessionBackpressureTests test
```

- [ ] **Step 3: Implement queue policy in `HostGatewaySession`**

Sketch:

```swift
private enum Pending {
    case high(HostGatewayWireFrame)
    case vt(VTEvent)
}

private var needsResync: [String: Date] = [:] // pane → last resync time
private var pendingVTBytes: Int = 0

private func enqueue(_ frame: HostGatewayWireFrame) {
    lock.lock()
    pending.append(.high(frame))
    let notify = pendingOutbound
    lock.unlock()
    notify?(self)
}

private func enqueueVT(_ event: VTEvent) {
    lock.lock()
    defer {
        let notify = pendingOutbound
        lock.unlock()
        notify?(self)
    }
    guard authenticated, openVTKeys.contains(event.paneSessionKey) else { return }

    pending.append(.vt(event))
    pendingVTBytes += event.payload.count
    trimVTIfNeeded(pane: event.paneSessionKey)
}

private func trimVTIfNeeded(pane: String) {
    // While pendingVTBytes > max OR per-pane sum > perPaneMax:
    // remove oldest .vt for `pane` (or any pane if total), subtract bytes.
    // Then maybeScheduleResync(pane)
}

private func maybeScheduleResync(pane: String) {
    let now = Date()
    if let last = needsResync[pane], now.timeIntervalSince(last) < 1.0 { return }
    needsResync[pane] = now
    let snap = VTEvent(kind: .snapshot, paneSessionKey: pane, payload: Data(), cols: nil, rows: nil)
    pending.append(.vt(snap))
}

func drainNotifications() -> [HostGatewayWireFrame] {
    lock.lock()
    let high = pending.compactMap { if case .high(let f) = $0 { return f } else { return nil } }
    let vts = pending.compactMap { if case .vt(let e) = $0 { return e } else { return nil } }
    pending.removeAll()
    pendingVTBytes = 0
    let binary = vtBinary
    let deflate = vtDeflate
    lock.unlock()
    return high + vts.map { encodeVT($0, binary: binary, deflate: deflate) }
}
```

Wire `handle` / auth replies as **return values** today (not via pending) — leave that as-is so request/response stays immediate. Only async notifies use queues.

Optional follow-up in same task: make `HostGatewayServer.send` chain `contentProcessed` before sending the next low-priority frame (high still flush immediately). If that balloons scope, ship session-side budget first and note server pacing as Task 5b only if tests need it.

- [ ] **Step 4: Run backpressure + existing HostGatewaySession tests — PASS**

- [ ] **Step 5: Commit**

```bash
git add Sources/Core/HostGatewaySession.swift Tests/HostGatewaySessionBackpressureTests.swift
git commit -m "feat: Host Gateway VT backpressure with drop-old resync"
```

---

### Task 6: Browser write-chain drop under decode backlog

**Files:**
- Modify: `clients/seahelm-web/index.html` (`onGatewayBinaryFrame` / `handleVT` path)

**Interfaces:**
- Produces: per-pane pending apply depth capped (e.g. `N=8`); drop intermediate `vt.data`, never drop the newest; snapshots always applied

- [ ] **Step 1: Implement depth tracking**

```javascript
const VT_APPLY_MAX = 8;
const vtApplyDepth = new Map(); // key → count of queued applies

function onGatewayBinaryFrame(buf){
  const f = parseVTFrame(buf);
  if (!f) { ...; return; }
  const depth = vtApplyDepth.get(f.key) || 0;
  if (f.type === 'vt.data' && depth >= VT_APPLY_MAX) {
    // Drop this frame (old data). Newest-wins: alternatively replace a slot —
    // simplest correct approach: if depth >= MAX, skip enqueue of this data frame.
    log('sys', '(vt drop)', f.key);
    return;
  }
  vtApplyDepth.set(f.key, depth + 1);
  const prior = vtWriteChains.get(f.key) || Promise.resolve();
  const next = prior.then(async () => {
    try {
      const bytes = f.deflated ? await inflateRaw(f.body) : f.body;
      handleVT(f.key, { type: f.type, bytes, cols: f.cols, rows: f.rows });
    } finally {
      vtApplyDepth.set(f.key, Math.max(0, (vtApplyDepth.get(f.key) || 1) - 1));
    }
  }).catch(...);
  vtWriteChains.set(f.key, next);
}
```

Apply the same depth guard in JSON `onGatewayNotify` for `vt.data`.

- [ ] **Step 2: Manual / note** — under throttle, terminal may jump but must not reorder.

- [ ] **Step 3: Commit**

```bash
git add clients/seahelm-web/index.html
git commit -m "fix: drop excess VT apply frames on the browser under backlog"
```

---

### Task 7: Binary key frames (negotiate + server + client)

**Files:**
- Create: `Sources/Core/HostGatewayKeyFrame.swift`
- Create: `Tests/HostGatewayKeyFrameTests.swift`
- Modify: `Sources/Core/HostGatewaySession.swift` (`handleAuth` → `keys_binary`; add `handle(binary:)`)
- Modify: `Sources/Core/HostGatewayServer.swift` (`receive` handles `.binary` opcode)
- Modify: `clients/seahelm-web/index.html` (auth flag + binary send path)

**Interfaces:**
- Produces:
  ```
  u8 version=1 | u8 kind=1 (keys) | u8 keyLen | key UTF-8 | payload UTF-8 bytes
  ```
  - `HostGatewayKeyFrame.encode(paneSessionKey:utf8:) -> Data?`
  - `HostGatewayKeyFrame.decode(_:) -> (paneSessionKey, utf8)?`
  - Auth result includes `keys_binary: Bool`
  - Server: binary WS → `session.handle(binary:)` → `vt.sendKeys`
- Consumes: existing `sendKeys`, `isVTOpen`

- [ ] **Step 1: Failing frame tests**

```swift
func testRoundTrip() {
    let key = "seahelm-main-p1"
    let utf8 = Data("hello".utf8)
    let frame = try! XCTUnwrap(HostGatewayKeyFrame.encode(paneSessionKey: key, utf8: utf8))
    let decoded = try! XCTUnwrap(HostGatewayKeyFrame.decode(frame))
    XCTAssertEqual(decoded.paneSessionKey, key)
    XCTAssertEqual(decoded.utf8, utf8)
}

func testRejectsOversizedKey() {
    let key = String(repeating: "a", count: 300)
    XCTAssertNil(HostGatewayKeyFrame.encode(paneSessionKey: key, utf8: Data()))
}
```

- [ ] **Step 2: Implement `HostGatewayKeyFrame`**

```swift
enum HostGatewayKeyFrame {
    static let version: UInt8 = 1
    static let kindKeys: UInt8 = 1
    static let maxKeyLength = 255

    static func encode(paneSessionKey: String, utf8: Data) -> Data? { ... }
    static func decode(_ frame: Data) -> (paneSessionKey: String, utf8: Data)? { ... }
}
```

- [ ] **Step 3: Session + server wiring**

Auth:

```swift
let keysBinary = ok && (params["keys_binary"] as? Bool ?? false)
// store keysBinary on session
result: ["ok": ok, "vt_binary": binary, "vt_deflate": deflate, "keys_binary": keysBinary]
```

```swift
func handle(binary: Data) -> [HostGatewayWireFrame] {
    guard authenticated else { return [] }
    guard keysBinary, let decoded = HostGatewayKeyFrame.decode(binary) else { return [] }
    guard isVTOpen(decoded.paneSessionKey) else { /* error frame optional */ return [] }
    _ = vt.sendKeys(paneSessionKey: decoded.paneSessionKey, utf8: decoded.utf8)
    return [] // no RPC id; fire-and-forget like coalesced keys
}
```

Server `receive`:

```swift
if metadata.opcode == .binary, let data {
    let outbound = session.handle(binary: data)
    for frame in outbound { send(frame, on: connection) }
    sendPendingNotifications(...)
}
```

- [ ] **Step 4: Client**

On auth:

```javascript
gwSend('auth', {
  mac_id: S.mac, token: S.authPass,
  vt_binary: true,
  vt_deflate: typeof DecompressionStream === 'function',
  keys_binary: true,
}, (r, err) => {
  S.gw.keysBinary = !!(r && r.keys_binary);
  ...
});
```

Replace key flush send:

```javascript
function sendKeysBinaryOrRpc(key, bytes) {
  if (S.gw && S.gw.keysBinary && S.gw.ws.readyState === WebSocket.OPEN) {
    const frame = encodeKeyFrame(key, bytes); // mirror Swift layout in JS
    S.gw.ws.send(frame);
    log('tx', 'keys', `${key} ${bytes.length}B`);
    return;
  }
  sendCommand('pane.send_keys', { pane_session_key: key, b64: bytesToB64(bytes) });
}
```

Use this from the 10ms `onData` flush and `sendRawKey`.

- [ ] **Step 5: Run KeyFrame + Session + Server tests — PASS**

- [ ] **Step 6: Commit**

```bash
git add Sources/Core/HostGatewayKeyFrame.swift Sources/Core/HostGatewaySession.swift \
  Sources/Core/HostGatewayServer.swift Tests/HostGatewayKeyFrameTests.swift \
  clients/seahelm-web/index.html
git commit -m "feat: negotiated binary send_keys on Host Gateway"
```

---

### Task 8: README + verification pass

**Files:**
- Modify: `clients/seahelm-web/README.md` (summarize all four workstreams)
- Run full Host Gateway test filter

- [ ] **Step 1: Update README** with: gzip/cache, default single-pane toggle, backpressure behavior (user-visible: may jump under lag), binary keys automatic when supported.

- [ ] **Step 2: Run**

```bash
xcodebuild -project seahelm.xcodeproj -scheme seahelmTests -configuration Debug \
  -skipPackagePluginValidation -skipMacroValidation \
  -only-testing:seahelmTests/HostGatewayStaticFilesTests \
  -only-testing:seahelmTests/HostGatewaySessionTests \
  -only-testing:seahelmTests/HostGatewaySessionBackpressureTests \
  -only-testing:seahelmTests/HostGatewayKeyFrameTests \
  -only-testing:seahelmTests/HostGatewayServerTests \
  -only-testing:seahelmTests/HostGatewayVTFrameTests \
  test
```

Expected: all PASS.

- [ ] **Step 3: Manual on Tailscale/DERP** — page loads faster on repeat visit; single-pane default; typing remains responsive when `top` is flooding.

- [ ] **Step 4: Commit**

```bash
git add clients/seahelm-web/README.md
git commit -m "docs: seahelm-web poor-network behavior in README"
```

---

## Spec coverage checklist

| Spec section | Task |
|---|---|
| §1 Static gzip | Task 1 |
| §1 Cache-Control / ETag | Task 1 |
| §1 keep-alive | Task 2 |
| §1 defer WebGL / exclude bench | Task 3 |
| §2 single/mirror toggle, default single | Task 4 |
| §3 bounded queue drop-old / resync | Task 5 |
| §3 browser write-chain drop | Task 6 |
| §4 control priority | Task 5 (high before low) |
| §4 binary keys | Task 7 |
| Testing / README | Tasks 1–8 |

## Out of plan (explicit)

- Dual WebSocket
- Brotli
- Keeping xterm alive across pane switches without dispose
- Server-side coalesce stretch in `ZmxVTAttachManager` (optional later if Task 5 insufficient)
