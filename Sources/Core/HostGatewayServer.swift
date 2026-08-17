import Foundation
import Network

/// Localhost WebSocket server for browser / web clients (`ws://127.0.0.1:PORT/ws`).
final class HostGatewayServer {
    private let config: HostGatewayConfig
    private let router: ControlRouter
    private let expectedMacId: String
    private let rootSecretBase64url: String
    private let vt: HostGatewayVTAttaching
    private let queue = DispatchQueue(label: "seahelm.hostgateway", qos: .userInitiated)

    private var listener: NWListener?
    private var connections: [ObjectIdentifier: ConnectionState] = [:]
    private var readyHandlers: [() -> Void] = []
    private let stateLock = NSLock()
    private var _isListening = false

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
         vt: HostGatewayVTAttaching) {
        self.config = config
        self.router = router
        self.expectedMacId = expectedMacId
        self.rootSecretBase64url = rootSecretBase64url
        self.vt = vt
    }

    func start(onReady: (() -> Void)? = nil) {
        queue.async { [self] in
            if let onReady {
                self.readyHandlers.append(onReady)
            }
            guard self.listener == nil else {
                if self.isListening { self.fireReadyHandlers() }
                return
            }

            let parameters = NWParameters(tls: nil)
            parameters.allowLocalEndpointReuse = true
            parameters.acceptLocalOnly = true
            parameters.includePeerToPeer = false

            let wsOptions = NWProtocolWebSocket.Options()
            wsOptions.autoReplyPing = true
            wsOptions.setClientRequestHandler(self.queue) { _, headers in
                let path = headers.first { $0.name.lowercased() == ":path" }?.value
                    ?? headers.first { $0.name.lowercased() == "path" }?.value
                if let path, path != "/ws" {
                    return NWProtocolWebSocket.Response(status: .reject, subprotocol: nil, additionalHeaders: [])
                }
                return NWProtocolWebSocket.Response(status: .accept, subprotocol: nil, additionalHeaders: [])
            }
            parameters.defaultProtocolStack.applicationProtocols.insert(wsOptions, at: 0)

            guard let port = NWEndpoint.Port(rawValue: self.config.resolvedPort) else {
                self.isListening = false
                self.fireReadyHandlers()
                return
            }

            do {
                let listener = try NWListener(using: parameters, on: port)
                self.listener = listener
                listener.stateUpdateHandler = { [weak self] state in
                    guard let self else { return }
                    switch state {
                    case .ready:
                        self.isListening = true
                        self.fireReadyHandlers()
                    case .failed, .cancelled:
                        self.isListening = false
                        self.listener = nil
                    default:
                        break
                    }
                }
                listener.newConnectionHandler = { [weak self] connection in
                    self?.accept(connection)
                }
                listener.start(queue: self.queue)
            } catch {
                NSLog("[HostGateway] listener failed: \(error.localizedDescription)")
                self.isListening = false
                self.listener = nil
                self.fireReadyHandlers()
            }
        }
    }

    func stop() {
        queue.sync {
            for state in connections.values {
                state.connection.cancel()
            }
            connections.removeAll()
            listener?.cancel()
            listener = nil
            isListening = false
            readyHandlers.removeAll()
        }
    }

    // MARK: - Connection handling

    private func fireReadyHandlers() {
        let handlers = readyHandlers
        readyHandlers.removeAll()
        handlers.forEach { $0() }
    }

    private func accept(_ connection: NWConnection) {
        let session = HostGatewaySession(
            router: router,
            expectedMacId: expectedMacId,
            rootSecretBase64url: rootSecretBase64url,
            vt: vt)
        let key = ObjectIdentifier(connection)
        let state = ConnectionState(connection: connection, session: session)
        connections[key] = state

        session.onPendingOutbound = { [weak self, weak connection] in
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
                self.connections.removeValue(forKey: key)
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
            if let data,
               let metadata = wsMeta,
               metadata.opcode == .text,
               let text = String(data: data, encoding: .utf8) {
                let outbound = session.handle(text: text)
                for frame in outbound {
                    self.send(frame, on: connection)
                }
                self.sendPendingNotifications(for: connection, session: session)
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

    private func send(_ text: String, on connection: NWConnection) {
        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "hostgateway", metadata: [metadata])
        connection.send(
            content: Data(text.utf8),
            contentContext: context,
            isComplete: true,
            completion: .contentProcessed { _ in })
    }
}
