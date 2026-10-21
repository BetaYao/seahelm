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
    private let shareLinks: ShareLinkVerifying?
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
    private let access: HostGatewayAccess
    /// Last `agent_type` sent per pane, so a `pane.updated` that changes it —
    /// an agent starting, or exiting back to the shell — still reaches the page.
    private var sentAgentTypes: [String: String] = [:]
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
    private var keysBinary = false
    private var pendingOutbound: ((HostGatewaySession) -> Void)?
    private var decisionCleared: ((HostGatewaySession, String) -> Void)?
    /// Set when the client signed in with a share link: the one pane this
    /// connection may see and act on. Nil is a paired client, who gets the fleet.
    private var sharedPane: SharedPane?

    /// A pane goes by two names on the wire — its session key, which the link
    /// carries, and its station id, which some events use — so both are kept.
    struct SharedPane: Equatable {
        let key: String
        /// The link it came in on, so revoking or outliving that link can drop
        /// this connection (`HostGatewayServer.enforceShareLinks`).
        let linkId: String
        var paneId: String?
        /// Who is on the other end: the link's recipient, else the name the page
        /// gave. Messages sent from here go to the agent signed with it.
        let sender: String

        func names(_ ref: String) -> Bool {
            !ref.isEmpty && (ref == key || ref == paneId)
        }
    }

    init(router: ControlRouter,
         expectedMacId: String,
         rootSecretBase64url: String,
         vt: HostGatewayVTAttaching,
         decisions: HostGatewayDecisions = HostGatewayDecisions(),
         pairingCode: PairingCodeVerifying? = nil,
         rateLimiter: PairRateLimiter? = nil,
         shareLinks: ShareLinkVerifying? = nil,
         clientIP: String = "unknown",
         access: HostGatewayAccess = HostGatewayAccess()) {
        self.access = access
        self.router = router
        self.expectedMacId = expectedMacId
        self.rootSecretBase64url = rootSecretBase64url
        self.vt = vt
        self.decisions = decisions
        self.pairingCode = pairingCode
        self.rateLimiter = rateLimiter
        self.shareLinks = shareLinks
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

    /// Called when this client answers, picks or dismisses a decision, so the
    /// server can tell every other client. The decision store is shared: once
    /// one browser cleared it, the prompt that follows finds nothing to expire,
    /// and a second browser — or the phone — kept the card until it reconnected.
    func setDecisionClearedHandler(_ handler: @escaping (HostGatewaySession, String) -> Void) {
        lock.lock()
        decisionCleared = handler
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
            guard inScope(d.paneSessionKey, d.paneId) else { return }
            enqueue(.text(HostGatewayFrame.encode(
                .notify(method: "pane.event", params: HostGatewayDecisions.notifyParams(for: d)))))
        case .cleared(let key):
            guard inScope(key) else { return }
            enqueue(.text(HostGatewayFrame.encode(
                .notify(method: "pane.event",
                        params: HostGatewayDecisions.clearedParams(paneSessionKey: key)))))
        case .none:
            return
        }
    }

    /// Server → session: a pane changed status or closed — what keeps the fleet
    /// list in step after the snapshot it was sent on authentication.
    func pushPaneEvent(_ event: [String: Any]) {
        guard inScope(event["pane_id"] as? String, event["pane_session_key"] as? String) else { return }
        lock.lock()
        let ready = authenticated
        let note = ready ? Self.paneNotify(for: event, sentAgentTypes: &sentAgentTypes) : nil
        lock.unlock()
        guard let note else { return }
        enqueue(.text(HostGatewayFrame.encode(.notify(method: note.method, params: note.params))))
    }

    /// The EventHub events the fleet list needs, in wire shape. `pane.updated`
    /// fires on every hook and mostly changes nothing the list draws, so it is
    /// passed on only when it moves the pane's `agent_type` — the page tells an
    /// agent from a bare shell by it, and an agent exiting at rest changes no
    /// status. `sentAgentTypes` is what this client was last told, per pane.
    static func paneNotify(
        for event: [String: Any],
        sentAgentTypes: inout [String: String]
    ) -> (method: String, params: [String: Any])? {
        let method: String, keys: [String]
        let paneKey = (event["pane_id"] as? String) ?? ""
        let agentType = event["agent_type"] as? String
        switch event["type"] as? String {
        case "pane.status_changed":
            method = "pane.status"
            keys = Self.paneStatusKeys
            if let agentType { sentAgentTypes[paneKey] = agentType }
        case "pane.updated":
            guard let agentType, sentAgentTypes[paneKey] != agentType else { return nil }
            sentAgentTypes[paneKey] = agentType
            method = "pane.status"
            keys = Self.paneStatusKeys
        case "pane.closed":
            method = "pane.closed"
            keys = ["pane_id", "pane_session_key", "worktree_path"]
            sentAgentTypes.removeValue(forKey: paneKey)
        default:
            return nil
        }
        var params: [String: Any] = [:]
        for key in keys { params[key] = event[key] }
        return (method, params)
    }

    /// The `since_seq` a reconnecting client sends, if any. Zero is "nothing
    /// held", which is the full replay anyway.
    static func sinceSeq(_ params: [String: Any]) -> UInt64? {
        guard let n = params["since_seq"] as? NSNumber, n.int64Value > 0 else { return nil }
        return n.uint64Value
    }

    static func agentTypes(inSnapshotPanes panes: Any) -> [String: String] {
        var out: [String: String] = [:]
        for pane in panes as? [[String: Any]] ?? [] {
            if let id = pane["pane_id"] as? String, let type = pane["agent_type"] as? String {
                out[id] = type
            }
        }
        return out
    }

    private static let paneStatusKeys = ["pane_id", "pane_session_key", "status", "old_status",
                                         "agent_type", "worktree_path", "last_message"]

    /// Server → session: a MessageStream timeline item.
    func pushMessage(_ event: MessageEvent) {
        lock.lock()
        let ready = authenticated
        lock.unlock()
        guard ready, inScope(event.paneSessionKey, event.paneId) else { return }
        enqueue(.text(HostGatewayFrame.encode(
            .notify(method: "pane.message", params: event.dict))))
    }

    /// Answering locally clears it for everyone; other clients must be told.
    private func queueDecisionCleared(_ key: String) {
        enqueue(.text(HostGatewayFrame.encode(
            .notify(method: "pane.event",
                    params: HostGatewayDecisions.clearedParams(paneSessionKey: key)))))
        lock.lock()
        let tellOthers = decisionCleared
        lock.unlock()
        tellOthers?(self, key)
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
            if let shared = shareGate(id: id, method: method, params: params) {
                return [.text(shared)]
            }
            if Self.slowMethods.contains(method) {
                // Seconds of git: run it off the gateway queue, which every
                // pane's VT stream shares, and send the reply when it lands.
                let router = self.router
                DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                    let result = router.handle(method: method, params: params)
                    guard let self else { return }
                    self.enqueue(.text(self.encodeControlResult(id: id, result: result)))
                }
                return []
            }
            return [.text(handleAuthenticated(id: id, method: method, params: params))]
        }
    }

    /// Methods that block — git, or a PATH lookup per agent — and must not
    /// hold the gateway queue.
    static let slowMethods: Set<String> = ["worktree.create", "worktree.options"]

    /// Negotiated binary `send_keys` — fire-and-forget, no RPC id.
    func handle(binary: Data) -> [HostGatewayWireFrame] {
        lock.lock()
        let ready = authenticated
        let allowKeys = keysBinary
        lock.unlock()
        guard ready, allowKeys,
              let decoded = HostGatewayKeyFrame.decode(binary) else { return [] }
        guard isVTOpen(decoded.paneSessionKey) else { return [] }
        _ = vt.sendKeys(paneSessionKey: decoded.paneSessionKey, utf8: decoded.utf8)
        return []
    }

    private func handleAuth(id: String, params: [String: Any]) -> [String] {
        let macId = params["mac_id"] as? String ?? ""
        let token = params["token"] as? String ?? ""
        let code = params["code"] as? String ?? ""

        let initData = params["telegram_init_data"] as? String ?? ""

        // A share link: no pairing behind it, so it gets no token, and the
        // session is held to the one pane the link was minted for.
        let share = params["share"] as? String ?? ""
        if !share.isEmpty {
            let pane = params["pane"] as? String ?? ""
            let check = shareLinks?.check(token: share, paneSessionKey: pane, now: Date()) ?? .invalid
            guard case .valid(let linkId, let recipient) = check else {
                return finishAuth(id: id, ok: false, params: params, issuedToken: nil,
                                  reason: check == .expired ? "expired" : "invalid")
            }
            // A link made for someone speaks as them; an open one asks the page,
            // which asks the person and comes back with `name`.
            guard let sender = recipient ?? ShareLinkStore.senderName(params["name"] as? String) else {
                return finishAuth(id: id, ok: false, params: params, issuedToken: nil, reason: "name_required")
            }
            lock.lock()
            sharedPane = SharedPane(key: pane, linkId: linkId, paneId: nil, sender: sender)
            lock.unlock()
            return finishAuth(id: id, ok: true, params: params, issuedToken: nil)
        }

        // Token path wins when both are present (return visits).
        if !token.isEmpty {
            let ok = HostGatewayAuth.verify(
                macId: macId, token: token,
                expectedMacId: expectedMacId, rootSecretBase64url: rootSecretBase64url)
            return finishAuth(id: id, ok: ok, params: params, issuedToken: ok ? token : nil)
        }

        if !initData.isEmpty {
            let user = access.telegramUser(initData: initData)
            let issued = user == nil ? nil : HostGatewayAuth.expectedToken(rootSecretBase64url: rootSecretBase64url)
            NSLog("[HostGateway] Telegram sign-in \(issued == nil ? "refused" : "accepted") for \(user.map { String($0.id) } ?? "?")")
            return finishAuth(id: id, ok: issued != nil, params: params, issuedToken: issued)
        }

        if !code.isEmpty {
            // No Access in front of this host: a code would be open to anyone.
            guard !access.isTelegramOnly else {
                NSLog("[HostGateway] Pairing code refused on the Telegram host")
                return finishAuth(id: id, ok: false, params: params, issuedToken: nil)
            }
            // Every proxied upgrade reaches the session from loopback, so the
            // address that means anything is the one the front door saw.
            let clientIP = access.frontClientIP() ?? self.clientIP
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

    private func finishAuth(id: String, ok: Bool, params: [String: Any], issuedToken: String?,
                            reason: String? = nil) -> [String] {
        // Opt-in, so a cached page from before the binary frame keeps working
        // against a new Mac rather than rendering nothing.
        let binary = ok && (params["vt_binary"] as? Bool ?? false)
        let deflate = binary && (params["vt_deflate"] as? Bool ?? false)
        let keysBin = ok && (params["keys_binary"] as? Bool ?? false)
        if ok {
            lock.lock()
            authenticated = true
            vtBinary = binary
            vtDeflate = deflate
            keysBinary = keysBin
            lock.unlock()
        }
        var result: [String: Any] = [
            "ok": ok,
            "vt_binary": binary,
            "vt_deflate": deflate,
            "keys_binary": keysBin,
        ]
        if let reason { result["reason"] = reason }
        // A client that kept its timeline across the drop says how far it got,
        // and gets only what came after. `replay` tells it which one it got:
        // "full" means drop what it holds, as a client from before this does.
        let delta = ok ? Self.sinceSeq(params).flatMap { MessageStreamHub.shared.replay(after: $0) } : nil
        if ok {
            result["replay"] = delta == nil ? "full" : "delta"
            let reset = delta?.truncated.filter { inScope($0) } ?? []
            if !reset.isEmpty { result["reset_panes"] = reset }
            result["mac_id"] = expectedMacId
            if let issuedToken { result["token"] = issuedToken }
            if let shared = currentSharedPane() {
                result["share"] = shared.key
                result["share_sender"] = shared.sender
            }
            // Fold the session snapshot into the reply. The client asked for it
            // unconditionally on the very next round trip, and a round trip is
            // the expensive unit here: ~240ms p50 from a phone over the tunnel,
            // against ~3ms of work on this side. Four serial trips stood between
            // opening the page and seeing a pane; this removes one of them.
            //
            // A client that predates this simply ignores the extra key and makes
            // the call it always made.
            if case .ok(let snapshot) = router.handle(method: "session.snapshot", params: [:]),
               let all = snapshot["panes"] {
                let panes = scopedPanes(all)
                result["panes"] = panes
                // What the page now believes, so the first `pane.updated` is
                // compared against it rather than sent for every pane.
                lock.lock()
                sentAgentTypes = Self.agentTypes(inSnapshotPanes: panes)
                lock.unlock()
            }
        }
        var out = [HostGatewayFrame.encode(.response(id: id, result: result, error: nil))]
        if ok {
            // Replay what is already open. Without this a client that connects a
            // second after a question is raised waits for an event it has missed.
            for d in decisions.pending() where inScope(d.paneSessionKey, d.paneId) {
                out.append(HostGatewayFrame.encode(
                    .notify(method: "pane.event", params: HostGatewayDecisions.notifyParams(for: d))))
            }
            // Replay MessageStream rings so text-mode clients paint without an
            // extra round trip (and without needing VT).
            for ev in delta?.events ?? MessageStreamHub.shared.snapshot(paneId: nil)
            where inScope(ev.paneSessionKey, ev.paneId) {
                out.append(HostGatewayFrame.encode(
                    .notify(method: "pane.message", params: ev.dict)))
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

    // MARK: - Share links

    /// Refused on a share link: what was asked is not about the shared pane.
    static let shareForbidden = -32003

    /// What a share client may call. Anything that names a pane must name the
    /// shared one; the rest of the control API — splitting, closing, creating
    /// worktrees, reading or driving other panes — is not on offer.
    static let shareMethods: Set<String> = [
        "ping", "session.snapshot", "pane.list", "fleet.groups", "layout.live",
        "pane.vt_open", "pane.vt_close", "pane.vt_keepalive", "pane.send_keys", "pane.send_text",
        "message.history", "question.answer", "suggest.pick", "decision.dismiss",
    ]

    /// The share link this connection signed in with; nil for a paired client.
    var shareLinkId: String? { currentSharedPane()?.linkId }
    /// The name this share connection speaks under; nil for a paired client.
    var shareSender: String? { currentSharedPane()?.sender }

    /// What a message sent through a share link is prefixed with, so the agent
    /// can tell it from the owner's own.
    static func sharePrefix(_ sender: String) -> String { "[from \(sender)] " }

    private func currentSharedPane() -> SharedPane? {
        lock.lock()
        defer { lock.unlock() }
        return sharedPane
    }

    /// True for a paired client, and for a share client only when one of
    /// `refs` names its pane.
    private func inScope(_ refs: String?...) -> Bool {
        guard let shared = currentSharedPane() else { return true }
        return refs.contains { $0.map(shared.names) ?? false }
    }

    /// The snapshot's panes as this client may see them. On a share link that
    /// is the shared pane alone, whose station id is learnt here for the events
    /// that name it by that.
    private func scopedPanes(_ panes: Any) -> Any {
        guard let shared = currentSharedPane() else { return panes }
        let kept = (panes as? [[String: Any]] ?? []).filter {
            shared.names($0["pane_session_key"] as? String ?? "") || shared.names($0["pane_id"] as? String ?? "")
        }
        if let id = kept.first?["pane_id"] as? String, !id.isEmpty {
            lock.lock()
            sharedPane?.paneId = id
            lock.unlock()
        }
        return kept
    }

    /// A share client's request: answered here (filtered or refused), or nil to
    /// go the way a paired client's does. Nil straight away for a paired client.
    private func shareGate(id: String, method: String, params: [String: Any]) -> String? {
        guard let shared = currentSharedPane() else { return nil }
        let refuse = { self.encodeError(id: id, code: Self.shareForbidden, message: "not allowed on a shared pane") }
        guard Self.shareMethods.contains(method) else { return refuse() }
        switch method {
        case "ping":
            return nil
        case "session.snapshot", "pane.list":
            guard case .ok(var dict) = router.handle(method: method, params: params) else { return nil }
            dict["panes"] = scopedPanes(dict["panes"] ?? [])
            return encodeControlResult(id: id, result: .ok(dict))
        case "fleet.groups":
            // The shared pane's worktree only: it is the one row the page draws.
            let mine = (scopedPanes(snapshotPanes()) as? [[String: Any]] ?? []).first
            let worktree = mine?["worktree_path"] as? String ?? ""
            guard case .ok(var dict) = router.handle(method: method, params: params) else { return nil }
            dict["groups"] = (dict["groups"] as? [[String: Any]] ?? []).compactMap { group -> [String: Any]? in
                let items = (group["items"] as? [[String: Any]] ?? [])
                    .filter { ($0["worktree_path"] as? String) == worktree }
                guard !items.isEmpty else { return nil }
                var g = group
                g["items"] = items
                return g
            }
            return encodeControlResult(id: id, result: .ok(dict))
        case "layout.live":
            // A worktree's split tree names its other panes. Without one the page
            // stacks the panes it knows, which here is the shared one.
            return encodeError(id: id, code: ControlError.notFound, message: "no live layout")
        default:
            // Every name given must be the shared pane's: the router acts on
            // `pane_id`, the gateway on `pane_session_key`, so checking only one
            // would let the other point somewhere else.
            let refs = ["pane_session_key", "pane_id"].compactMap { params[$0] as? String }
            guard !refs.isEmpty, refs.allSatisfy(shared.names) else { return refuse() }
            // A message (text sent with Enter) carries who said it. Keystrokes
            // typed into the terminal cannot be told apart and go as they are.
            // `command` is the router's other name for `text`.
            if method == "pane.send_text", params["enter"] as? Bool == true,
               let text = (params["text"] as? String) ?? (params["command"] as? String), !text.isEmpty {
                var signed = params
                signed["command"] = nil
                signed["text"] = Self.sharePrefix(shared.sender) + text
                return handleAuthenticated(id: id, method: method, params: signed)
            }
            return nil
        }
    }

    private func snapshotPanes() -> Any {
        guard case .ok(let dict) = router.handle(method: "session.snapshot", params: [:]) else { return [] }
        return dict["panes"] ?? []
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
