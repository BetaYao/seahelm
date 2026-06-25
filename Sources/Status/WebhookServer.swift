import Foundation
import Network

class WebhookServer {
    private var listener4: NWListener?  // IPv4 loopback
    private var listener6: NWListener?  // IPv6 loopback
    private let port: UInt16
    private let onEvent: (WebhookEvent) -> String?
    private let queue = DispatchQueue(label: "seahelm.webhook-server")

    init(port: UInt16, onEvent: @escaping (WebhookEvent) -> String?) {
        self.port = port
        self.onEvent = onEvent
    }

    func start() {
        // Listen on both IPv4 and IPv6 loopback to handle clients
        // that resolve "localhost" to either ::1 or 127.0.0.1.
        listener4 = createListener(host: .ipv4(.loopback), label: "IPv4")
        listener6 = createListener(host: .ipv6(.loopback), label: "IPv6")

        if listener4 == nil, listener6 == nil {
            NSLog("[WebhookServer] Failed to create any listener on port \(port)")
        }
    }

    private func createListener(host: NWEndpoint.Host, label: String) -> NWListener? {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: host, port: NWEndpoint.Port(rawValue: port)!)

        let listener: NWListener
        do {
            // Port is already set in requiredLocalEndpoint; passing it again
            // to NWListener(using:on:) causes "cannot override" error.
            listener = try NWListener(using: params)
        } catch {
            NSLog("[WebhookServer] Failed to create \(label) listener: \(error)")
            return nil
        }

        listener.newConnectionHandler = { [weak self] connection in
            self?.handleConnection(connection)
        }

        listener.stateUpdateHandler = { [weak self] state in
            guard let self = self else { return }
            switch state {
            case .ready:
                NSLog("[WebhookServer] Listening on \(label) port \(self.port)")
            case .failed(let error):
                NSLog("[WebhookServer] \(label) listener failed: \(error)")
            default:
                break
            }
        }

        listener.start(queue: queue)
        return listener
    }

    func stop() {
        listener4?.cancel()
        listener4 = nil
        listener6?.cancel()
        listener6 = nil
    }

    private func handleConnection(_ connection: NWConnection) {
        connection.start(queue: queue)
        receiveData(connection: connection, buffer: Data())
    }

    private func receiveData(connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self = self else { return }

            var accumulated = buffer
            if let data = data {
                accumulated.append(data)
            }

            if isComplete || error != nil {
                self.processHTTPRequest(data: accumulated, connection: connection)
            } else {
                if self.hasCompleteHTTPRequest(accumulated) {
                    self.processHTTPRequest(data: accumulated, connection: connection)
                } else {
                    self.receiveData(connection: connection, buffer: accumulated)
                }
            }
        }
    }

    private func hasCompleteHTTPRequest(_ data: Data) -> Bool {
        let message = CFHTTPMessageCreateEmpty(kCFAllocatorDefault, true).takeRetainedValue()
        CFHTTPMessageAppendBytes(message, [UInt8](data), data.count)
        guard CFHTTPMessageIsHeaderComplete(message) else { return false }
        guard let contentLengthStr = CFHTTPMessageCopyHeaderFieldValue(message, "Content-Length" as CFString)?.takeRetainedValue() as String?,
              let contentLength = Int(contentLengthStr) else {
            return true  // No Content-Length means no body expected
        }
        let body = CFHTTPMessageCopyBody(message)?.takeRetainedValue() as Data?
        return (body?.count ?? 0) >= contentLength
    }

    private func processHTTPRequest(data: Data, connection: NWConnection) {
        let message = CFHTTPMessageCreateEmpty(kCFAllocatorDefault, true).takeRetainedValue()
        CFHTTPMessageAppendBytes(message, [UInt8](data), data.count)

        guard CFHTTPMessageIsHeaderComplete(message) else {
            sendResponse(connection: connection, statusCode: 400, body: "Bad Request")
            return
        }

        let method = CFHTTPMessageCopyRequestMethod(message)?.takeRetainedValue() as String? ?? ""
        let url = CFHTTPMessageCopyRequestURL(message)?.takeRetainedValue() as URL?
        let path = url?.path ?? ""
        let body = CFHTTPMessageCopyBody(message)?.takeRetainedValue() as Data?

        guard method == "POST", path == "/webhook" else {
            sendResponse(connection: connection, statusCode: 404, body: "Not Found")
            return
        }

        guard let body = body else {
            sendResponse(connection: connection, statusCode: 400, body: "Missing body")
            return
        }

        do {
            let event = try WebhookEvent.parse(from: body)
            let responseBody = onEvent(event) ?? "{}"

            sendResponse(connection: connection, statusCode: 200, body: responseBody)
        } catch {
            NSLog("[WebhookServer] Parse error: \(error)")
            sendResponse(connection: connection, statusCode: 400, body: "Bad Request")
        }
    }

    private func sendResponse(connection: NWConnection, statusCode: Int, body: String) {
        let statusText: String
        switch statusCode {
        case 200: statusText = "OK"
        case 400: statusText = "Bad Request"
        case 404: statusText = "Not Found"
        default: statusText = "Error"
        }

        let response = "HTTP/1.1 \(statusCode) \(statusText)\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
        let responseData = response.data(using: .utf8)!

        connection.send(content: responseData, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    deinit {
        stop()
    }
}
