import Foundation

protocol HostGatewayVTAttaching: AnyObject {
    func open(paneSessionKey: String) -> [String: Any]
    func close(paneSessionKey: String)
    func keepalive(paneSessionKey: String)
    func sendKeys(paneSessionKey: String, utf8: Data) -> Bool
    /// A subscription rather than a single slot: the manager is shared by every
    /// connection, and one assignable callback meant the newest browser muted all
    /// the others. Returns a token to unsubscribe with.
    @discardableResult
    func addObserver(_ observer: @escaping (VTEvent) -> Void) -> Int
    func removeObserver(_ token: Int)
}

final class HostGatewaySession {
    private let router: ControlRouter
    private let expectedMacId: String
    private let rootSecretBase64url: String
    private let vt: HostGatewayVTAttaching
    /// Shared with the server, which feeds it EventHub and fans out the results.
    private let decisions: HostGatewayDecisions
    private let pairingCode: PairingCodeVerifying?
    private let rateLimiter: PairRateLimiter?
    private let clientIP: String

    /// Caps on queued VT payload (uncompressed). Overflow drops oldest `.vt`
    /// for the overflowing pane (or globally, if the session total is over)
    /// and rate-limits a synthetic empty snapshot so the client can reset.
    static let maxPendingVTBytes = 256 * 1024
    static let maxPendingVTBytesPerPane = 128 * 1024
    static let resyncMinInterval: TimeInterval = 1.0

    /// A queued outbound frame.
    ///
    /// High-priority frames (decisions / control notifies) drain before VT.
    /// VT events are queued as events and encoded at drain time. `emit` runs on
    /// the VT manager's serial queue — the same one that has to drain the PTY —
    /// so deflating a 48KB chunk there stalls reading for every pane, and does it
    /// once per connected browser. Decisions are already text, so they queue
    /// encoded.
    ///
    /// The trade is that a queued VT frame is held uncompressed, so a client that
    /// stalls holds more memory than it used to. That is bounded: drop-old keeps
    /// pending VT at `maxPendingVTBytes` (and `maxPendingVTBytesPerPane` per
    /// pane), only panes this client opened are queued at all, and every enqueue
    /// wakes a drain.
    private enum Pending {
        case high(HostGatewayWireFrame)
        case vt(VTEvent)
    }

    /// One lock for all mutable state, because the state is read across two
    /// queues that take turns on it: the gateway's (auth, requests, drain) and
    /// the VT manager's (the observer). The array alone was locked before, and
    /// the negotiation flags next to it were not — a frame emitted during auth
    /// could be encoded against a half-published negotiation, and one emitted
    /// before the server installed its handler was queued with nothing to wake
    /// it up. Nothing may call into `vt` or `router` while holding it: those
    /// hop to the VT queue, which is where the observer takes this same lock.
    private let lock = NSLock()
    private var authenticated = false
    private var openVTKeys: Set<String> = []
    private var pending: [Pending] = []
    /// pane → last forced-resync time. Also the rate-limit clock.
    private var needsResync: [String: Date] = [:]
    private var pendingVTBytes: Int = 0
    private var vtObserverToken: Int?
    /// Negotiated at auth. Absent means a client from before binary VT, which
    /// still gets base64 inside a JSON notify.
    private var vtBinary = false
    private var vtDeflate = false
    private var pendingOutbound: ((HostGatewaySession) -> Void)?

    init(router: ControlRouter,
         expectedMacId: String,
         rootSecretBase64url: String,
         vt: HostGatewayVTAttaching,
         decisions: HostGatewayDecisions = HostGatewayDecisions(),
         pairingCode: PairingCodeVerifying? = nil,
         rateLimiter: PairRateLimiter? = nil,
         clientIP: String = "unknown") {
        self.router = router
        self.expectedMacId = expectedMacId
        self.rootSecretBase64url = rootSecretBase64url
        self.vt = vt
        self.decisions = decisions
        self.pairingCode = pairingCode
        self.rateLimiter = rateLimiter
        self.clientIP = clientIP
        vtObserverToken = vt.addObserver { [weak self] event in
            self?.enqueueVT(event)
        }
    }

    /// Stop costing the shared manager encode work for a socket nobody reads.
    ///
    /// Called by the server when the connection goes away, so teardown does not
    /// wait on the last reference being dropped somewhere in Network.framework's
    /// handler graph. Idempotent; `deinit` repeats it for any path that simply
    /// releases the session.
    func close() {
        lock.lock()
        let token = vtObserverToken
        vtObserverToken = nil
        pendingOutbound = nil
        pending.removeAll()
        pendingVTBytes = 0
        needsResync.removeAll()
        lock.unlock()
        if let token { vt.removeObserver(token) }
    }

    deinit {
        if let vtObserverToken { vt.removeObserver(vtObserverToken) }
    }

    /// Where a queued notify gets flushed to the socket.
    ///
    /// The handler receives the session instead of capturing it. That is the
    /// whole point of the shape: the natural spelling at the call site captured
    /// `session` strongly, which made every session retain its own callback, so
    /// `deinit` never ran and a closed browser tab left its VT observer
    /// registered on the shared manager — encoding and deflating every pane's
    /// output forever, and holding the manager alive past the point where the
    /// app tried to tear it down.
    func setPendingOutboundHandler(_ handler: @escaping (HostGatewaySession) -> Void) {
        lock.lock()
        pendingOutbound = handler
        lock.unlock()
    }

    /// Chooses the wire shape this client negotiated.
    private func encodeVT(_ event: VTEvent, binary: Bool, deflate: Bool) -> HostGatewayWireFrame {
        if binary, let frame = HostGatewayVTFrame.encode(event, allowDeflate: deflate) {
            return .binary(frame)
        }
        return .text(HostGatewayFrame.encode(
            .notify(method: event.kind.legacyMethod, params: event.legacyNotifyParams)))
    }

    /// VT manager's queue → this session's outbound queue.
    ///
    /// Two gates, both load-bearing. `authenticated`: the observer is live from
    /// `init`, so without it anything that completes the WebSocket upgrade reads
    /// every pane's screen — including whatever an agent has on it — without ever
    /// presenting a token. `openVTKeys`: the manager broadcasts every pane to
    /// every observer, so without it one browser receives the contents of panes
    /// another browser opened, separately encoded for each of them.
    private func enqueueVT(_ event: VTEvent) {
        lock.lock()
        let wanted = authenticated && openVTKeys.contains(event.paneSessionKey)
        if wanted {
            pending.append(.vt(event))
            pendingVTBytes += event.payload.count
            trimVTIfNeeded(pane: event.paneSessionKey)
        }
        let notify = wanted ? pendingOutbound : nil
        lock.unlock()
        notify?(self)
    }

    private func enqueue(_ frame: HostGatewayWireFrame) {
        lock.lock()
        pending.append(.high(frame))
        let notify = pendingOutbound
        lock.unlock()
        notify?(self)
    }

    /// Must run while `lock` is held.
    private func trimVTIfNeeded(pane: String) {
        var dropped = Set<String>()
        while panePendingVTBytes(pane) > Self.maxPendingVTBytesPerPane {
            guard let key = dropOldestVT(pane: pane) else { break }
            dropped.insert(key)
        }
        while pendingVTBytes > Self.maxPendingVTBytes {
            guard let key = dropOldestVT(pane: nil) else { break }
            dropped.insert(key)
        }
        for key in dropped {
            maybeScheduleResync(pane: key)
        }
    }

    private func panePendingVTBytes(_ pane: String) -> Int {
        var n = 0
        for item in pending {
            if case .vt(let e) = item, e.paneSessionKey == pane {
                n += e.payload.count
            }
        }
        return n
    }

    /// Drops the oldest `vt.data` for `pane` (or any pane if `pane` is nil).
    /// Falls back to any `.vt` so a huge snapshot cannot pin the budget over cap.
    private func dropOldestVT(pane: String?) -> String? {
        func matches(_ event: VTEvent) -> Bool {
            pane.map { event.paneSessionKey == $0 } ?? true
        }
        let dataIdx = pending.firstIndex {
            if case .vt(let e) = $0, e.kind == .data, matches(e) { return true }
            return false
        }
        let idx = dataIdx ?? pending.firstIndex {
            if case .vt(let e) = $0, matches(e) { return true }
            return false
        }
        guard let idx, case .vt(let event) = pending.remove(at: idx) else { return nil }
        pendingVTBytes -= event.payload.count
        if pendingVTBytes < 0 { pendingVTBytes = 0 }
        return event.paneSessionKey
    }

    private func maybeScheduleResync(pane: String) {
        // A still-queued real snapshot *is* the resync. An empty synthetic after
        // it would make the client term.reset() to a blank screen and undo it.
        if restackRealSnapshot(pane: pane) { return }

        let now = Date()
        let allowed = needsResync[pane].map { now.timeIntervalSince($0) >= Self.resyncMinInterval } ?? true
        let existing = pending.lastIndex {
            if case .vt(let e) = $0,
               e.kind == .snapshot,
               e.paneSessionKey == pane,
               e.payload.isEmpty { return true }
            return false
        }
        if let existing {
            let item = pending.remove(at: existing)
            pending.append(item)
            if allowed { needsResync[pane] = now }
            return
        }
        guard allowed else { return }
        needsResync[pane] = now
        pending.append(.vt(VTEvent(kind: .snapshot, paneSessionKey: pane, payload: Data())))
    }

    /// If a non-empty snapshot for `pane` survived trim, drop later `.data` for
    /// that pane and restack the snapshot last so drain ends on a consistent
    /// screen. Returns true when that happened (caller must not append empty).
    private func restackRealSnapshot(pane: String) -> Bool {
        let snapIdx = pending.lastIndex {
            if case .vt(let e) = $0,
               e.kind == .snapshot,
               e.paneSessionKey == pane,
               !e.payload.isEmpty { return true }
            return false
        }
        guard let snapIdx else { return false }
        var i = pending.count - 1
        while i > snapIdx {
            if case .vt(let e) = pending[i],
               e.paneSessionKey == pane,
               e.kind == .data {
                pendingVTBytes -= e.payload.count
                pending.remove(at: i)
            }
            i -= 1
        }
        if pendingVTBytes < 0 { pendingVTBytes = 0 }
        let item = pending.remove(at: snapIdx)
        pending.append(item)
        return true
    }

    /// Server → session: an event that opened or closed a decision.
    func pushDecision(_ change: HostGatewayDecisions.Change) {
        lock.lock()
        let ready = authenticated
        lock.unlock()
        guard ready else { return }
        switch change {
        case .opened(let d):
            enqueue(.text(HostGatewayFrame.encode(
                .notify(method: "pane.event", params: HostGatewayDecisions.notifyParams(for: d)))))
        case .cleared(let key):
            enqueue(.text(HostGatewayFrame.encode(
                .notify(method: "pane.event",
                        params: HostGatewayDecisions.clearedParams(paneSessionKey: key)))))
        case .none:
            return
        }
    }

    /// Answering locally clears it for everyone; other clients must be told.
    private func queueDecisionCleared(_ key: String) {
        enqueue(.text(HostGatewayFrame.encode(
            .notify(method: "pane.event",
                    params: HostGatewayDecisions.clearedParams(paneSessionKey: key)))))
    }

    func drainNotifications() -> [HostGatewayWireFrame] {
        lock.lock()
        let queued = pending
        pending.removeAll()
        pendingVTBytes = 0
        let binary = vtBinary
        let deflate = vtDeflate
        lock.unlock()
        // Encoding happens here — on the gateway's queue, outside the lock, and
        // off the queue that reads the PTY. High-priority control always
        // precedes VT, even if the VT was enqueued first.
        let high = queued.compactMap { item -> HostGatewayWireFrame? in
            if case .high(let frame) = item { return frame }
            return nil
        }
        let vts = queued.compactMap { item -> VTEvent? in
            if case .vt(let event) = item { return event }
            return nil
        }
        return high + vts.map { encodeVT($0, binary: binary, deflate: deflate) }
    }

    func handle(text: String) -> [HostGatewayWireFrame] {
        switch HostGatewayFrame.parse(text) {
        case .malformed:
            return [.text(encodeError(id: "", code: ControlError.parse, message: "parse error"))]
        case .request(let id, let method, let params):
            lock.lock()
            let ready = authenticated
            lock.unlock()
            if !ready {
                guard method == "auth" else {
                    return [.text(encodeError(id: id, code: -32001, message: "unauthorized"))]
                }
                return handleAuth(id: id, params: params).map { .text($0) }
            }
            return [.text(handleAuthenticated(id: id, method: method, params: params))]
        }
    }

    private func handleAuth(id: String, params: [String: Any]) -> [String] {
        let macId = params["mac_id"] as? String ?? ""
        let token = params["token"] as? String ?? ""
        let code = params["code"] as? String ?? ""

        // Token path wins when both are present (return visits).
        if !token.isEmpty {
            let ok = HostGatewayAuth.verify(
                macId: macId, token: token,
                expectedMacId: expectedMacId, rootSecretBase64url: rootSecretBase64url)
            return finishAuth(id: id, ok: ok, params: params, issuedToken: ok ? token : nil)
        }

        if !code.isEmpty {
            if let rateLimiter, !rateLimiter.allow(ip: clientIP) {
                return [encodeError(id: id, code: -32029, message: "rate_limited")]
            }
            let matched = pairingCode?.verify(code) == true
            if matched {
                rateLimiter?.recordSuccess(ip: clientIP)
                let issued = HostGatewayAuth.expectedToken(rootSecretBase64url: rootSecretBase64url)
                return finishAuth(id: id, ok: issued != nil, params: params, issuedToken: issued)
            }
            rateLimiter?.recordFailure(ip: clientIP)
            return finishAuth(id: id, ok: false, params: params, issuedToken: nil)
        }

        return finishAuth(id: id, ok: false, params: params, issuedToken: nil)
    }

    private func finishAuth(id: String, ok: Bool, params: [String: Any], issuedToken: String?) -> [String] {
        // Opt-in, so a cached page from before the binary frame keeps working
        // against a new Mac rather than rendering nothing.
        let binary = ok && (params["vt_binary"] as? Bool ?? false)
        let deflate = binary && (params["vt_deflate"] as? Bool ?? false)
        if ok {
            lock.lock()
            authenticated = true
            vtBinary = binary
            vtDeflate = deflate
            lock.unlock()
        }
        var result: [String: Any] = [
            "ok": ok,
            "vt_binary": binary,
            "vt_deflate": deflate,
        ]
        if ok {
            result["mac_id"] = expectedMacId
            if let issuedToken { result["token"] = issuedToken }
            // Fold the session snapshot into the reply. The client asked for it
            // unconditionally on the very next round trip, and a round trip is
            // the expensive unit here: ~240ms p50 from a phone over the tunnel,
            // against ~3ms of work on this side. Four serial trips stood between
            // opening the page and seeing a pane; this removes one of them.
            //
            // A client that predates this simply ignores the extra key and makes
            // the call it always made.
            if case .ok(let snapshot) = router.handle(method: "session.snapshot", params: [:]),
               let panes = snapshot["panes"] {
                result["panes"] = panes
            }
        }
        var out = [HostGatewayFrame.encode(.response(id: id, result: result, error: nil))]
        if ok {
            // Replay what is already open. Without this a client that connects a
            // second after a question is raised waits for an event it has missed.
            for d in decisions.pending() {
                out.append(HostGatewayFrame.encode(
                    .notify(method: "pane.event", params: HostGatewayDecisions.notifyParams(for: d))))
            }
        }
        return out
    }

    private func handleAuthenticated(id: String, method: String, params: [String: Any]) -> String {
        switch method {
        case "pane.vt_open":
            let key = paneSessionKey(from: params)
            // Registered before the open, and withdrawn if it failed. The other
            // order leaves a window: the manager starts producing for this pane
            // the moment the attach spawns, and a key inserted after `vt.open`
            // returns would drop whatever landed in between — including, on a
            // slow spawn, the opening snapshot.
            //
            // `vt.open` itself is called outside the lock on purpose: it hops to
            // the VT manager's queue, which is where the observer takes this
            // same lock.
            lock.lock()
            openVTKeys.insert(key)
            lock.unlock()
            let result = vt.open(paneSessionKey: key)
            // Only route send_keys to VT — and only accept its frames — when open
            // actually succeeded.
            if (result["ok"] as? Bool) == false {
                lock.lock()
                openVTKeys.remove(key)
                lock.unlock()
            }
            return HostGatewayFrame.encode(.response(id: id, result: result, error: nil))
        case "pane.vt_close":
            let key = paneSessionKey(from: params)
            vt.close(paneSessionKey: key)
            lock.lock()
            openVTKeys.remove(key)
            lock.unlock()
            return HostGatewayFrame.encode(.response(id: id, result: ["ok": true], error: nil))
        case "pane.vt_keepalive":
            let key = paneSessionKey(from: params)
            vt.keepalive(paneSessionKey: key)
            return HostGatewayFrame.encode(.response(id: id, result: ["ok": true], error: nil))
        case "question.answer":
            // The on-screen prompt is navigated, not addressed: move down `index`
            // times, then Return.
            let qKey = paneSessionKey(from: params)
            let qIndex = max(0, params["index"] as? Int ?? 0)
            var keys = Array(repeating: "down", count: qIndex)
            keys.append("enter")
            let answered = router.handle(method: "pane.send_keys",
                                         params: ["pane_id": qKey, "keys": keys])
            decisions.clear(paneSessionKey: qKey)
            queueDecisionCleared(qKey)
            return encodeControlResult(id: id, result: answered)
        case "suggest.pick":
            // A suggestion is text, so the chosen option is typed verbatim — the
            // index only means something next to the options we pushed.
            let sKey = paneSessionKey(from: params)
            let sIndex = max(0, params["index"] as? Int ?? 0)
            let opts = decisions.options(forPaneSessionKey: sKey)
            guard sIndex < opts.count else {
                return encodeError(id: id, code: ControlError.invalidParams,
                                   message: "no such suggestion")
            }
            let picked = router.handle(method: "pane.send_text",
                                       params: ["pane_id": sKey, "text": opts[sIndex], "enter": true])
            decisions.clear(paneSessionKey: sKey)
            queueDecisionCleared(sKey)
            return encodeControlResult(id: id, result: picked)
        case "decision.dismiss":
            // Two stores hold the same suggestion: this one, which feeds remote
            // clients, and FirstMate's pending orders, which the desktop island
            // draws. Declining has to reach both, or the card the user just
            // dismissed is still standing on the Mac.
            let dKey = paneSessionKey(from: params)
            decisions.clear(paneSessionKey: dKey)
            // Replayed on the next authentication if left open, so clearing the
            // local store is what stops a dismissal from coming back on reload.
            queueDecisionCleared(dKey)
            _ = router.handle(method: "decision.dismiss", params: ["pane_id": dKey])
            return HostGatewayFrame.encode(.response(id: id, result: ["dismissed": true], error: nil))
        case "pane.send_keys":
            if let key = vtKey(from: params), isVTOpen(key),
               let utf8 = utf8Payload(from: params) {
                let sent = vt.sendKeys(paneSessionKey: key, utf8: utf8)
                return HostGatewayFrame.encode(.response(id: id, result: ["sent": sent], error: nil))
            }
            return encodeControlResult(id: id, result: router.handle(method: method, params: params))
        default:
            return encodeControlResult(id: id, result: router.handle(method: method, params: params))
        }
    }

    private func isVTOpen(_ key: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return openVTKeys.contains(key)
    }

    private func paneSessionKey(from params: [String: Any]) -> String {
        (params["pane_session_key"] as? String)
            ?? (params["pane_id"] as? String)
            ?? ""
    }

    private func vtKey(from params: [String: Any]) -> String? {
        let key = paneSessionKey(from: params)
        return key.isEmpty ? nil : key
    }

    private func utf8Payload(from params: [String: Any]) -> Data? {
        if let b64 = params["b64"] as? String, let data = Data(base64Encoded: b64) {
            return data
        }
        if let text = params["text"] as? String {
            return Data(text.utf8)
        }
        return nil
    }

    private func encodeControlResult(id: String, result: ControlResult) -> String {
        switch result {
        case .ok(let dict):
            return HostGatewayFrame.encode(.response(id: id, result: dict, error: nil))
        case .error(let code, let message):
            return encodeError(id: id, code: code, message: message)
        }
    }

    private func encodeError(id: String, code: Int, message: String) -> String {
        HostGatewayFrame.encode(.response(
            id: id, result: nil, error: ["code": code, "message": message]))
    }
}
