import Foundation

/// Blocking HTTPS over the system libcurl, keeping connections alive between
/// requests.
///
/// Why libcurl at all: inside this process URLSession requests to Telegram
/// hung — the first one or two completed, then most sat past their timeout
/// with neither a response nor an error — while the same requests from curl
/// never failed. `/usr/bin/curl` in a child process fixed that but paid a new
/// TCP + TLS handshake on every call, about 1–1.7s each on a typical link, so
/// every reply in a chat took two or three seconds to arrive. This is the same
/// library and the same sockets as that curl, minus the process: an easy
/// handle keeps its connection after a transfer, and handing it to the next
/// request skips the handshake (≈0.2–0.8s a call).
///
/// Handles are pooled rather than one per client because the bridge talks on
/// several threads at once — the long poll, the send queue, a button tap's
/// acknowledgement — and a libcurl handle is single-threaded. Each borrower
/// gets a handle of its own and gives it back warm.
final class CurlClient {
    struct Response {
        let status: Int
        let body: Data
        /// True when the request opened no new connection.
        let reused: Bool
    }

    enum Failure: Error, Equatable {
        /// `isCancelled` said stop.
        case cancelled
        /// Nothing came back within the deadline.
        case timedOut
        /// The body grew past `maxBytes`.
        case tooLarge
        /// Anything else libcurl reported, already worded for a log.
        case transport(String)
    }

    /// Idle handles kept warm. Past this a returned handle is closed: the
    /// bridge rarely has more than two or three requests in flight.
    static let poolLimit = 4

    private static let globalInit: Void = {
        curl_global_init(Int(CURL_GLOBAL_DEFAULT))
    }()

    private let lock = NSLock()
    private var idle: [UnsafeMutableRawPointer] = []

    init() {
        _ = Self.globalInit
    }

    deinit {
        for handle in idle { curl_easy_cleanup(handle) }
    }

    /// One request, blocking until it ends.
    ///
    /// `body` makes it a POST with `contentType`; nil is a GET. `isCancelled`
    /// is polled while the transfer runs — libcurl asks at least once a
    /// second, idle or not — so a long poll can be abandoned mid-wait.
    func perform(url: String, body: Data? = nil, contentType: String = "application/json",
                 timeout: Int, maxBytes: Int = .max,
                 isCancelled: @escaping () -> Bool = { false }) throws -> Response {
        let handle = acquire()
        var keep = true
        defer { release(handle, keep: keep) }

        let transfer = Transfer(maxBytes: maxBytes, isCancelled: isCancelled)
        let context = Unmanaged.passUnretained(transfer).toOpaque()
        var headers: UnsafeMutablePointer<curl_slist>?
        defer { curl_slist_free_all(headers) }

        // A recycled handle still holds the last request's options; reset
        // clears them and keeps its connection.
        curl_easy_reset(handle)
        var errorBuffer = [CChar](repeating: 0, count: Int(CURL_ERROR_SIZE) + 1)
        let code: CURLcode = errorBuffer.withUnsafeMutableBufferPointer { buffer in
            seahelm_curl_setopt_string(handle, CURLOPT_URL, url)
            seahelm_curl_setopt_pointer(handle, CURLOPT_ERRORBUFFER, buffer.baseAddress)
            // Several threads use libcurl at once; no signals for timeouts.
            seahelm_curl_setopt_long(handle, CURLOPT_NOSIGNAL, 1)
            seahelm_curl_setopt_long(handle, CURLOPT_TIMEOUT, timeout)
            seahelm_curl_setopt_long(handle, CURLOPT_CONNECTTIMEOUT, min(timeout, 15))
            seahelm_curl_setopt_long(handle, CURLOPT_TCP_KEEPALIVE, 1)
            seahelm_curl_setopt_string(handle, CURLOPT_ACCEPT_ENCODING, "")
            seahelm_curl_set_write(handle, curlWrite, context)
            seahelm_curl_set_progress(handle, curlProgress, context)
            if let body {
                headers = curl_slist_append(nil, "Content-Type: \(contentType)")
                seahelm_curl_setopt_headers(handle, headers)
                seahelm_curl_setopt_long(handle, CURLOPT_POST, 1)
                seahelm_curl_setopt_offset(handle, CURLOPT_POSTFIELDSIZE_LARGE, curl_off_t(body.count))
                // COPY: libcurl keeps its own copy for the life of the transfer.
                _ = body.withUnsafeBytes { raw in
                    seahelm_curl_setopt_pointer(handle, CURLOPT_COPYPOSTFIELDS,
                                                UnsafeMutableRawPointer(mutating: raw.baseAddress))
                }
            } else {
                seahelm_curl_setopt_long(handle, CURLOPT_HTTPGET, 1)
            }
            let code = curl_easy_perform(handle)
            // The buffer is about to go away; libcurl must not hold it.
            seahelm_curl_setopt_pointer(handle, CURLOPT_ERRORBUFFER, nil)
            return code
        }

        switch code {
        case CURLE_OK:
            return Response(status: seahelm_curl_response_code(handle), body: transfer.data,
                            reused: seahelm_curl_connects(handle) == 0)
        case CURLE_ABORTED_BY_CALLBACK:
            keep = false
            throw Failure.cancelled
        case CURLE_WRITE_ERROR where transfer.overflowed:
            keep = false
            throw Failure.tooLarge
        case CURLE_OPERATION_TIMEDOUT:
            keep = false
            throw Failure.timedOut
        default:
            // A connection that failed is not one to hand to the next caller.
            keep = false
            let detail = String(cString: errorBuffer)
            let summary = String(cString: curl_easy_strerror(code))
            throw Failure.transport(detail.isEmpty ? summary : "\(summary): \(detail)")
        }
    }

    // MARK: - Pool

    private func acquire() -> UnsafeMutableRawPointer {
        lock.lock()
        let reused = idle.popLast()
        lock.unlock()
        if let reused { return reused }
        guard let fresh = curl_easy_init() else {
            // Allocation failure inside libcurl; nothing sensible to carry on with.
            fatalError("curl_easy_init failed")
        }
        return fresh
    }

    private func release(_ handle: UnsafeMutableRawPointer, keep: Bool) {
        lock.lock()
        if keep, idle.count < Self.poolLimit {
            idle.append(handle)
            lock.unlock()
            return
        }
        lock.unlock()
        curl_easy_cleanup(handle)
    }
}

/// What one transfer accumulates, reached from the C callbacks through their
/// context pointer. Only ever touched by the thread running the transfer.
private final class Transfer {
    var data = Data()
    var overflowed = false
    let maxBytes: Int
    let isCancelled: () -> Bool

    init(maxBytes: Int, isCancelled: @escaping () -> Bool) {
        self.maxBytes = maxBytes
        self.isCancelled = isCancelled
    }
}

private let curlWrite: curl_write_callback = { pointer, size, count, context in
    guard let pointer, let context else { return 0 }
    let transfer = Unmanaged<Transfer>.fromOpaque(context).takeUnretainedValue()
    let length = size * count
    guard transfer.data.count + length <= transfer.maxBytes else {
        transfer.overflowed = true
        return 0
    }
    pointer.withMemoryRebound(to: UInt8.self, capacity: length) {
        transfer.data.append($0, count: length)
    }
    return length
}

private let curlProgress: curl_xferinfo_callback = { context, _, _, _, _ in
    guard let context else { return 0 }
    let transfer = Unmanaged<Transfer>.fromOpaque(context).takeUnretainedValue()
    return transfer.isCancelled() ? 1 : 0
}
