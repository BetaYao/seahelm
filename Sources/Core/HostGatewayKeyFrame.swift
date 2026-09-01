import Foundation

/// Binary inbound frame for `pane.send_keys` (negotiated via `keys_binary` on auth).
///
/// ```
///   u8  version (1)
///   u8  kind        1 = keys
///   u8  keyLength
///   ..  key         UTF-8 pane session key
///   ..  payload     raw UTF-8 keystrokes
/// ```
enum HostGatewayKeyFrame {
    static let version: UInt8 = 1
    static let kindKeys: UInt8 = 1
    static let maxKeyLength = 255

    static func encode(paneSessionKey: String, utf8: Data) -> Data? {
        let keyBytes = Array(paneSessionKey.utf8)
        guard keyBytes.count <= maxKeyLength else { return nil }
        var out = Data()
        out.reserveCapacity(3 + keyBytes.count + utf8.count)
        out.append(version)
        out.append(kindKeys)
        out.append(UInt8(keyBytes.count))
        out.append(contentsOf: keyBytes)
        out.append(utf8)
        return out
    }

    static func decode(_ frame: Data) -> (paneSessionKey: String, utf8: Data)? {
        var index = frame.startIndex
        func byte() -> UInt8? {
            guard index < frame.endIndex else { return nil }
            defer { index = frame.index(after: index) }
            return frame[index]
        }
        guard let v = byte(), v == version,
              let kind = byte(), kind == kindKeys,
              let keyLength = byte() else { return nil }
        guard let keyEnd = frame.index(index, offsetBy: Int(keyLength), limitedBy: frame.endIndex),
              let key = String(data: frame[index..<keyEnd], encoding: .utf8) else { return nil }
        index = keyEnd
        return (key, Data(frame[index...]))
    }
}
