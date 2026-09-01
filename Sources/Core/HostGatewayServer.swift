import Foundation
import Network

/// WebSocket + static-page server for browser clients (`http://HOST:PORT/`, `ws://HOST:PORT/ws`).
///
/// One port serves both, which `NWProtocolWebSocket` cannot do on its own — with the
/// WebSocket protocol in the stack a plain `GET /` is never answered at all. So the
/// public port runs a bare TCP listener that reads the request head and demultiplexes:
/// a WebSocket upgrade is proxied byte-for-byte to an internal loopback listener that
/// keeps the real WebSocket stack, anything else is answered as a static file. The
/// framework still owns every frame; the front door only decides which door it is.
final class HostGatewayServer {
    private let config: HostGatewayConfig
    private let router: ControlRouter
    private let expectedMacId: String
    private let rootSecretBase64url: String
    private let vt: HostGatewayVTAttaching
    private let pairingCode: PairingCodeVerifying?
    private let rateLimiter: PairRateLimiter?
    private let staticFiles: HostGatewayStaticFiles
    private let queue = DispatchQueue(label: "seahelm.hostgateway", qos: .userInitiated)

    /// Public port: static files plus the upgrade demux.
    private var frontListener: NWListener?
    /// Loopback-only port carrying the WebSocket protocol stack.
    private var wsListener: NWListener?
    private var wsPort: UInt16 = 0

    /// Open questions/suggestions, shared by every session: one client answering
    /// resolves it for all of them, and a client arriving late needs the backlog.
    private let decisions = HostGatewayDecisions()
    private var eventToken: Int?
    private var connections: [ObjectIdentifier: ConnectionState] = [:]
    private var proxied: [ObjectIdentifier: NWConnection] = [:]
    private var readyHandlers: [() -> Void] = []
    private let stateLock = NSLock()
    private var _isListening = false

    /// Request head cap: real browser heads are ~1KB, so this only bounds abuse.
    private static let maxRequestHeadBytes = 16 * 1024

    private(set) var isListening: Bool {
        get {
            stateLock.lock()
            defer { stateLock.unlock() }
            return _isListening
        }
        set {
            stateLock.lock()
            _isListening = newValue
            stateLock.unlock()
        }
    }

    private struct ConnectionState {
        let connection: NWConnection
        let session: HostGatewaySession
    }

    init(config: HostGatewayConfig,
         router: ControlRouter,
         expectedMacId: String,
         rootSecretBase64url: String,
         vt: HostGatewayVTAttaching,
         pairingCode: PairingCodeVerifying? = nil,
         rateLimiter: PairRateLimiter? = nil) {
        self.config = config
        self.router = router
        self.expectedMacId = expectedMacId
        self.rootSecretBase64url = rootSecretBase64url
        self.vt = vt
        self.pairingCode = pairingCode
        self.rateLimiter = rateLimiter
        self.staticFiles = HostGatewayStaticFiles(
            root: HostGatewayStaticFiles.resolveRoot(override: config.webRoot))
    }

    func start(onReady: (() -> Void)? = nil) {
        queue.async { [self] in
            if let onReady {
                self.readyHandlers.append(onReady)
            }
            guard self.frontListener == nil, self.wsListener == nil else {
                if self.isListening { self.fireReadyHandlers() }
                return
            }
            self.subscribeToAgentEvents()
            self.startWebSocketListener()
        }
    }

    /// AgentRegistry → EventHub → every authenticated session.
    ///
    /// EventHub is already the fan-out seam the control socket and MQTT use, so
    /// the gateway subscribes rather than growing a second path out of the
    /// registry. Events arrive on main; everything here belongs to `queue`.
    private func subscribeToAgentEvents() {
        guard eventToken == nil else { return }
        eventToken = EventHub.shared.subscribe { [weak self] _, event in
            guard let self else { return }
            self.queue.async {
                let change = self.decisions.apply(event: event)
                if case .none = change { return }
                for state in self.connections.values {
                    state.session.pushDecision(change)
                }
            }
        }
    }

    func stop() {
        queue.sync {
            for state in connections.values {
                state.session.close()
                state.connection.cancel()
            }
            connections.removeAll()
            if let eventToken { EventHub.shared.unsubscribe(eventToken) }
            eventToken = nil
            for connection in proxied.values {
                connection.cancel()
            }
            proxied.removeAll()
            frontListener?.cancel()
            frontListener = nil
            wsListener?.cancel()
            wsListener = nil
            wsPort = 0
            isListening = false
            readyHandlers.removeAll()
        }
    }

    // MARK: - Listeners

    /// Internal listener: the real WebSocket stack, reachable only over loopback.
    private func startWebSocketListener() {
        let parameters = NWParameters(tls: nil)
        parameters.allowLocalEndpointReuse = true
        parameters.includePeerToPeer = false
        // Bind loopback on an ephemeral port: only the front door can reach it.
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: .any)

        let wsOptions = NWProtocolWebSocket.Options()
        wsOptions.autoReplyPing = true
        wsOptions.setClientRequestHandler(queue) { _, headers in
            let path = headers.first { $0.name.lowercased() == ":path" }?.value
                ?? headers.first { $0.name.lowercased() == "path" }?.value
            if let path, Self.requestPath(path) != "/ws" {
                return NWProtocolWebSocket.Response(status: .reject, subprotocol: nil, additionalHeaders: [])
            }
            return NWProtocolWebSocket.Response(status: .accept, subprotocol: nil, additionalHeaders: [])
        }
        parameters.defaultProtocolStack.applicationProtocols.insert(wsOptions, at: 0)

        do {
            let listener = try NWListener(using: parameters)
            wsListener = listener
            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    self.wsPort = listener.port?.rawValue ?? 0
                    self.startFrontListener()
                case .failed, .cancelled:
                    self.failStart("websocket listener \(state)")
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                self?.accept(connection)
            }
            listener.start(queue: queue)
        } catch {
            NSLog("[HostGateway] websocket listener failed: \(error.localizedDescription)")
            failStart("websocket listener error")
        }
    }

    /// Public listener: bare TCP, so a plain `GET` reaches us instead of stalling.
    private func startFrontListener() {
        guard frontListener == nil else { return }
        guard let port = NWEndpoint.Port(rawValue: config.resolvedPort) else {
            failStart("invalid port \(config.resolvedPort)")
            return
        }

        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        parameters.acceptLocalOnly = true
        parameters.includePeerToPeer = false

        do {
            let listener = try NWListener(using: parameters, on: port)
            frontListener = listener
            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    self.isListening = true
                    self.fireReadyHandlers()
                case .failed, .cancelled:
                    self.failStart("front listener \(state)")
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                self?.acceptFront(connection)
            }
            listener.start(queue: queue)
        } catch {
            NSLog("[HostGateway] front listener failed: \(error.localizedDescription)")
            failStart("front listener error")
        }
    }

    private func failStart(_ reason: String) {
        NSLog("[HostGateway] not listening: \(reason)")
        isListening = false
        frontListener?.cancel()
        frontListener = nil
        wsListener?.cancel()
        wsListener = nil
        wsPort = 0
        fireReadyHandlers()
    }

    private func fireReadyHandlers() {
        let handlers = readyHandlers
        readyHandlers.removeAll()
        handlers.forEach { $0() }
    }

    // MARK: - Front door: read the head, then pick a door

    private func acceptFront(_ connection: NWConnection) {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            if case .ready = state {
                self.readRequestHead(on: connection, buffered: Data())
            } else if case .failed = state {
                connection.cancel()
            }
        }
        connection.start(queue: queue)
    }

    private func readRequestHead(on connection: NWConnection, buffered: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buffer = buffered
            if let data { buffer.append(data) }

            if error != nil {
                connection.cancel()
                return
            }
            if let terminator = buffer.range(of: Data("\r\n\r\n".utf8)) {
                let head = String(decoding: buffer[buffer.startIndex..<terminator.lowerBound], as: UTF8.self)
                self.route(connection, head: head, rawRequest: buffer)
                return
            }
            if isComplete || buffer.count > Self.maxRequestHeadBytes {
                connection.cancel()
                return
            }
            self.readRequestHead(on: connection, buffered: buffer)
        }
    }

    private func route(_ connection: NWConnection, head: String, rawRequest: Data) {
        if Self.isWebSocketUpgrade(head: head) {
            proxyToWebSocket(connection, initial: rawRequest)
            return
        }
        let (method, target) = Self.requestLine(head: head)
        let headers = Self.parseRequestHeaders(head: head)
        let response = staticFiles.response(method: method, target: target, headers: headers)
        let close = Self.clientRequestsClose(head: head)
        let payload = HostGatewayStaticFiles.serialize(
            response, includeBody: method != "HEAD", connectionClose: close)
        connection.send(content: payload, isComplete: close, completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            if error != nil || close {
                connection.cancel()
                return
            }
            self.readRequestHead(on: connection, buffered: Data())
        })
    }

    // MARK: - Upgrade proxy

    /// Replay the client's handshake to the internal listener, then pump bytes both
    /// ways. Nothing here understands WebSocket framing — that stays the framework's.
    private func proxyToWebSocket(_ client: NWConnection, initial: Data) {
        guard wsPort != 0, let port = NWEndpoint.Port(rawValue: wsPort) else {
            client.cancel()
            return
        }
        let upstream = NWConnection(host: .ipv4(.loopback), port: port, using: .tcp)
        proxied[ObjectIdentifier(client)] = upstream

        upstream.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                upstream.send(content: initial, isComplete: true, completion: .contentProcessed { [weak self] error in
                    guard let self else { return }
                    if error != nil {
                        self.teardown(client, upstream)
                        return
                    }
                    self.pump(from: client, to: upstream)
                    self.pump(from: upstream, to: client)
                })
            case .failed, .cancelled:
                self.teardown(client, upstream)
            default:
                break
            }
        }
        upstream.start(queue: queue)
    }

    private func pump(from source: NWConnection, to destination: NWConnection) {
        source.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                destination.send(content: data, isComplete: true, completion: .contentProcessed { [weak self] sendError in
                    guard let self else { return }
                    if sendError != nil {
                        self.teardown(source, destination)
                        return
                    }
                    self.pump(from: source, to: destination)
                })
                return
            }
            if error != nil || isComplete {
                self.teardown(source, destination)
                return
            }
            self.pump(from: source, to: destination)
        }
    }

    private func teardown(_ first: NWConnection, _ second: NWConnection) {
        first.cancel()
        second.cancel()
        proxied.removeValue(forKey: ObjectIdentifier(first))
        proxied.removeValue(forKey: ObjectIdentifier(second))
    }

    // MARK: - Request parsing

    static func isWebSocketUpgrade(head: String) -> Bool {
        for line in head.split(separator: "\r\n", omittingEmptySubsequences: true).dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[line.startIndex..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            guard name == "upgrade" else { continue }
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces).lowercased()
            if value.contains("websocket") { return true }
        }
        return false
    }

    static func requestLine(head: String) -> (method: String, target: String) {
        guard let first = head.split(separator: "\r\n", omittingEmptySubsequences: true).first else {
            return ("GET", "/")
        }
        let parts = first.split(separator: " ", omittingEmptySubsequences: true)
        let method = parts.first.map { String($0).uppercased() } ?? "GET"
        let target = parts.count > 1 ? String(parts[1]) : "/"
        return (method, target)
    }

    /// Path portion of a request target, so `/ws?token=x` still routes as `/ws`.
    static func requestPath(_ target: String) -> String {
        if let cut = target.firstIndex(where: { $0 == "?" || $0 == "#" }) {
            return String(target[target.startIndex..<cut])
        }
        return target
    }

    static func parseRequestHeaders(head: String) -> HostGatewayStaticFiles.RequestHeaders {
        var acceptEncoding: String?
        var ifNoneMatch: String?
        for line in head.split(separator: "\r\n", omittingEmptySubsequences: true).dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[line.startIndex..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            switch name {
            case "accept-encoding":
                acceptEncoding = value
            case "if-none-match":
                ifNoneMatch = value
            default:
                break
            }
        }
        return HostGatewayStaticFiles.RequestHeaders(
            acceptEncoding: acceptEncoding, ifNoneMatch: ifNoneMatch)
    }

    /// HTTP/1.0 defaults to close; HTTP/1.1 defaults to keep-alive unless `Connection: close`.
    static func clientRequestsClose(head: String) -> Bool {
        guard let first = head.split(separator: "\r\n", omittingEmptySubsequences: true).first else {
            return true
        }
        let parts = first.split(separator: " ", omittingEmptySubsequences: true)
        let version = parts.count > 2 ? String(parts[2]).uppercased() : "HTTP/1.0"
        let isHTTP11 = version.hasPrefix("HTTP/1.1")
        if !isHTTP11 { return true }

        for line in head.split(separator: "\r\n", omittingEmptySubsequences: true).dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[line.startIndex..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            guard name == "connection" else { continue }
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces).lowercased()
            if value.contains("close") { return true }
        }
        return false
    }

    // MARK: - WebSocket sessions (internal listener)

    private func accept(_ connection: NWConnection) {
        let session = HostGatewaySession(
            router: router,
            expectedMacId: expectedMacId,
            rootSecretBase64url: rootSecretBase64url,
            vt: vt,
            decisions: decisions,
            pairingCode: pairingCode,
            rateLimiter: rateLimiter,
            clientIP: Self.clientIP(of: connection))
        let key = ObjectIdentifier(connection)
        let state = ConnectionState(connection: connection, session: session)
        connections[key] = state

        // The session is handed back as an argument rather than captured: a
        // closure that captured it made the session retain itself, so `deinit`
        // never ran and a closed tab kept its VT observer on the shared manager.
        session.setPendingOutboundHandler { [weak self, weak connection] session in
            guard let self, let connection else { return }
            self.queue.async {
                self.sendPendingNotifications(for: connection, session: session)
            }
        }

        connection.stateUpdateHandler = { [weak self] connState in
            guard let self else { return }
            switch connState {
            case .ready:
                self.receive(on: connection, session: session)
            case .failed, .cancelled:
                // Unsubscribe here rather than leaving it to ARC: the session is
                // still referenced by Network.framework's own handler graph at
                // this point, and until it unsubscribes it keeps queueing frames
                // for a socket that is gone.
                self.connections.removeValue(forKey: key)?.session.close()
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    private func receive(on connection: NWConnection, session: HostGatewaySession) {
        connection.receiveMessage { [weak self] data, context, _, error in
            guard let self else { return }
            if error != nil {
                connection.cancel()
                return
            }

            let wsMeta = context?.protocolMetadata(definition: NWProtocolWebSocket.definition)
                as? NWProtocolWebSocket.Metadata
            if let data, let metadata = wsMeta {
                if metadata.opcode == .text,
                   let text = String(data: data, encoding: .utf8) {
                    let outbound = session.handle(text: text)
                    for frame in outbound {
                        self.send(frame, on: connection)
                    }
                    self.sendPendingNotifications(for: connection, session: session)
                } else if metadata.opcode == .binary {
                    let outbound = session.handle(binary: data)
                    for frame in outbound {
                        self.send(frame, on: connection)
                    }
                    self.sendPendingNotifications(for: connection, session: session)
                }
            }

            if connection.state != .cancelled {
                self.receive(on: connection, session: session)
            }
        }
    }

    private func sendPendingNotifications(for connection: NWConnection, session: HostGatewaySession) {
        for frame in session.drainNotifications() {
            send(frame, on: connection)
        }
    }

    private func send(_ frame: HostGatewayWireFrame, on connection: NWConnection) {
        let opcode: NWProtocolWebSocket.Opcode
        let body: Data
        switch frame {
        case .text(let text):
            opcode = .text
            body = Data(text.utf8)
        case .binary(let data):
            opcode = .binary
            body = data
        }
        let metadata = NWProtocolWebSocket.Metadata(opcode: opcode)
        let context = NWConnection.ContentContext(identifier: "hostgateway", metadata: [metadata])
        connection.send(
            content: body,
            contentContext: context,
            isComplete: true,
            completion: .contentProcessed { _ in })
    }

    /// Best-effort remote address for pairing rate limits. Accepted connections
    /// expose the peer as `.hostPort`; anything else collapses to `"unknown"`.
    static func clientIP(of connection: NWConnection) -> String {
        if case .hostPort(let host, _) = connection.endpoint {
            return "\(host)"
        }
        return "unknown"
    }
}
