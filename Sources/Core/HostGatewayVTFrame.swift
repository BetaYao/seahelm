import Compression
import Foundation

/// Binary wire format for VT payloads.
///
/// The JSON path costs exactly 4/3 in base64 plus a JSON escaping pass, measured
/// at 1.335x amplification over a 1 MiB capture. None of that buys anything: the
/// browser hands the bytes straight to `xterm.js`, which takes a `Uint8Array`.
///
/// ```
///   u8  version (1)
///   u8  flags       bit0 = payload is raw deflate
///   u8  kind        1 = vt.data, 2 = vt.snapshot
///   u8  keyLength   pane session keys are short; longer keys are rejected
///   ..  key         UTF-8, keyLength bytes
///   u16 cols        big endian, snapshot only
///   u16 rows        big endian, snapshot only
///   ..  payload
/// ```
///
/// Compression is **per frame**, not a stream with context takeover. Measured on
/// real captures (`top` repainting, `git diff`, `git log`), keeping the context
/// only wins at frame sizes that carry almost no data — 0.215x vs 0.222x at
/// 48KB, but 0.266x vs 0.429x at 512B. Small frames happen when little is being
/// written, which is exactly when latency matters and bandwidth does not, so the
/// stream state would buy ~3% on the frames that matter and add a
/// desynchronisation failure mode to a terminal that must stay in order.
enum HostGatewayVTFrame {
    static let version: UInt8 = 1
    static let deflateFlag: UInt8 = 1 << 0
    static let maxKeyLength = 255

    /// Below this, deflate is skipped: the header and the deflate block cost more
    /// than they save, and these are the latency-critical frames.
    static let minimumCompressedPayload = 512

    struct Decoded: Equatable {
        let kind: VTEvent.Kind
        let paneSessionKey: String
        let payload: Data
        let cols: Int?
        let rows: Int?
        let wasCompressed: Bool
    }

    static func encode(_ event: VTEvent, allowDeflate: Bool) -> Data? {
        let keyBytes = Array(event.paneSessionKey.utf8)
        guard keyBytes.count <= maxKeyLength else { return nil }

        var flags: UInt8 = 0
        var payload = event.payload
        if allowDeflate, payload.count >= minimumCompressedPayload,
           let deflated = deflate(payload), deflated.count < payload.count {
            payload = deflated
            flags |= deflateFlag
        }

        var out = Data()
        out.reserveCapacity(8 + keyBytes.count + payload.count)
        out.append(version)
        out.append(flags)
        out.append(event.kind.rawValue)
        out.append(UInt8(keyBytes.count))
        out.append(contentsOf: keyBytes)
        if event.kind == .snapshot {
            out.append(bigEndian: UInt16(clamping: event.cols ?? 0))
            out.append(bigEndian: UInt16(clamping: event.rows ?? 0))
        }
        out.append(payload)
        return out
    }

    static func decode(_ frame: Data) -> Decoded? {
        var index = frame.startIndex
        func byte() -> UInt8? {
            guard index < frame.endIndex else { return nil }
            defer { index = frame.index(after: index) }
            return frame[index]
        }
        guard let v = byte(), v == version,
              let flags = byte(),
              let rawKind = byte(), let kind = VTEvent.Kind(rawValue: rawKind),
              let keyLength = byte() else { return nil }

        guard let keyEnd = frame.index(index, offsetBy: Int(keyLength), limitedBy: frame.endIndex),
              let key = String(data: frame[index..<keyEnd], encoding: .utf8) else { return nil }
        index = keyEnd

        var cols: Int?
        var rows: Int?
        if kind == .snapshot {
            guard let c0 = byte(), let c1 = byte(), let r0 = byte(), let r1 = byte() else { return nil }
            cols = Int(UInt16(c0) << 8 | UInt16(c1))
            rows = Int(UInt16(r0) << 8 | UInt16(r1))
        }

        let body = Data(frame[index...])
        let compressed = flags & deflateFlag != 0
        let payload = compressed ? (inflate(body) ?? Data()) : body
        if compressed && payload.isEmpty && !body.isEmpty { return nil }

        return Decoded(kind: kind, paneSessionKey: key, payload: payload,
                       cols: cols, rows: rows, wasCompressed: compressed)
    }

    // MARK: - deflate

    /// `COMPRESSION_ZLIB` in Apple's framework is raw DEFLATE with no zlib
    /// wrapper, which is precisely what the browser's
    /// `DecompressionStream('deflate-raw')` expects.
    static func deflate(_ input: Data) -> Data? {
        guard input.count > 1 else { return nil }
        // Sized one byte UNDER the input, not over it.
        //
        // A frame is only sent compressed when compressing made it smaller, so
        // "did not fit" and "was not worth sending" are the same answer, and
        // this buffer gives it directly — `compression_encode_buffer` reports a
        // too-small destination as 0 written.
        //
        // Sizing it above the input instead — the obvious reading of "leave room
        // for the worst case", which the previous `+ 64` was a broken attempt at
        // — buys nothing. Measured on this framework: COMPRESSION_ZLIB expands
        // incompressible input by ~5 bytes per 16KB stored block (+460 bytes on
        // 1.5MB), so a generous buffer would succeed and the caller would throw
        // the result away for being bigger than what it started with. The old
        // constant only ever mattered for incompressible payloads above ~800KB,
        // and those went out raw either way.
        var output = Data(count: input.count - 1)
        let written = output.withUnsafeMutableBytes { dst -> Int in
            input.withUnsafeBytes { src -> Int in
                guard let dstBase = dst.bindMemory(to: UInt8.self).baseAddress,
                      let srcBase = src.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                return compression_encode_buffer(dstBase, dst.count,
                                                 srcBase, input.count,
                                                 nil, COMPRESSION_ZLIB)
            }
        }
        guard written > 0 else { return nil }
        output.removeSubrange(written...)
        return output
    }

    static func inflate(_ input: Data) -> Data? {
        guard !input.isEmpty else { return Data() }
        // Terminal payloads cap at `maxChunkBytes`; the multiplier only has to
        // cover the best case deflate can reach on that much text.
        var capacity = max(input.count * 8, 64 * 1024)
        for _ in 0..<4 {
            var output = Data(count: capacity)
            let written = output.withUnsafeMutableBytes { dst -> Int in
                input.withUnsafeBytes { src -> Int in
                    guard let dstBase = dst.bindMemory(to: UInt8.self).baseAddress,
                          let srcBase = src.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                    return compression_decode_buffer(dstBase, dst.count,
                                                     srcBase, input.count,
                                                     nil, COMPRESSION_ZLIB)
                }
            }
            guard written > 0 else { return nil }
            // A full buffer may mean truncation rather than a perfect fit.
            if written < capacity {
                output.removeSubrange(written...)
                return output
            }
            capacity *= 4
        }
        return nil
    }
}

private extension Data {
    mutating func append(bigEndian value: UInt16) {
        append(UInt8(truncatingIfNeeded: value >> 8))
        append(UInt8(truncatingIfNeeded: value))
    }
}
