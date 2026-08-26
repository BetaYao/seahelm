import Foundation

/// One VT emission from a pane, before any wire encoding.
///
/// The manager used to base64 its payload and hand the gateway a JSON-ready
/// dictionary, which put the wire format inside the PTY reader: the bytes were
/// already 4/3 larger and already text by the time anything that knew about the
/// socket could see them. It emits bytes now, and the gateway decides how they
/// travel.
struct VTEvent: Equatable {
    enum Kind: UInt8, Equatable {
        case data = 1
        case snapshot = 2

        /// Legacy JSON notify method name, kept for clients that predate the
        /// binary frame.
        var legacyMethod: String {
            switch self {
            case .data: return "vt.data"
            case .snapshot: return "vt.snapshot"
            }
        }
    }

    let kind: Kind
    let paneSessionKey: String
    let payload: Data
    let cols: Int?
    let rows: Int?

    init(kind: Kind, paneSessionKey: String, payload: Data, cols: Int? = nil, rows: Int? = nil) {
        self.kind = kind
        self.paneSessionKey = paneSessionKey
        self.payload = payload
        self.cols = cols
        self.rows = rows
    }

    /// The pre-binary representation: base64 inside a JSON notify envelope.
    var legacyNotifyParams: [String: Any] {
        var params: [String: Any] = [
            "pane_session_key": paneSessionKey,
            "b64": payload.base64EncodedString(),
        ]
        if let cols { params["cols"] = cols }
        if let rows { params["rows"] = rows }
        return params
    }
}

/// What actually goes out on the socket. VT rides binary frames when the client
/// asked for them; everything else stays newline-free JSON text.
enum HostGatewayWireFrame: Equatable {
    case text(String)
    case binary(Data)
}
