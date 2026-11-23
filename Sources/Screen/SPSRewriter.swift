import Foundation

/// Marks an H.264 SPS as never reordering frames, so a decoder hands each
/// frame out as soon as it is decoded.
///
/// Without a VUI `bitstream_restriction` a decoder must assume the worst and
/// holds frames until its picture buffer fills: Chrome's WebCodecs decoder
/// showed nothing at all for a still screen until flushed (VideoToolbox's
/// encoder writes no restriction, even with frame reordering off). WebRTC
/// solves the same thing the same way (`SpsVuiRewriter`): add or replace the
/// restriction with `max_num_reorder_frames = 0` and
/// `max_dec_frame_buffering = max_num_ref_frames`.
enum SPSRewriter {
    /// The SPS NAL unit (header byte first, no start code) rewritten, or nil
    /// when it cannot be parsed (the caller keeps the original).
    static func lowLatency(_ nal: Data) -> Data? {
        let bytes = [UInt8](nal)
        guard bytes.count > 4, bytes[0] & 0x1F == 7 else { return nil }
        let rbsp = unescape(Array(bytes[1...]))
        var r = BitReader(rbsp)
        guard let parsed = try? parse(&r) else { return nil }
        var w = BitWriter()
        // Everything up to where the restriction goes, as it was.
        var copy = BitReader(rbsp)
        for _ in 0..<parsed.keepBits { w.bit(copy.bit() ?? 0) }
        if !parsed.hadVUI {
            w.bit(1) // vui_parameters_present_flag
            for _ in 0..<8 { w.bit(0) } // aspect, overscan, signal, chroma loc, timing, nal hrd, vcl hrd, pic_struct
        }
        w.bit(1) // bitstream_restriction_flag
        w.bit(1) // motion_vectors_over_pic_boundaries_flag
        w.ue(2)  // max_bytes_per_pic_denom
        w.ue(1)  // max_bits_per_mb_denom
        w.ue(16) // log2_max_mv_length_horizontal
        w.ue(16) // log2_max_mv_length_vertical
        w.ue(0)  // max_num_reorder_frames
        w.ue(max(1, parsed.maxNumRefFrames)) // max_dec_frame_buffering
        w.trailing()
        return Data([bytes[0]] + escape(w.bytes))
    }

    struct Parsed {
        /// Bits to copy before writing the restriction: up to and including
        /// `vui_parameters_present_flag` when there is a VUI (then up to its
        /// `bitstream_restriction_flag`, exclusive), else up to the flag,
        /// exclusive.
        var keepBits: Int
        var hadVUI: Bool
        var maxNumRefFrames: UInt32
    }

    enum ParseError: Error { case truncated, unsupported }

    static func parse(_ r: inout BitReader) throws -> Parsed {
        func u(_ n: Int) throws -> UInt32 { guard let v = r.bits(n) else { throw ParseError.truncated }; return v }
        func ue() throws -> UInt32 { guard let v = r.ue() else { throw ParseError.truncated }; return v }
        func se() throws { _ = try ue() }

        let profile = try u(8)
        _ = try u(8) // constraint flags
        _ = try u(8) // level
        _ = try ue() // seq_parameter_set_id
        if [100, 110, 122, 244, 44, 83, 86, 118, 128, 138, 139, 134, 135].contains(profile) {
            let chroma = try ue()
            if chroma == 3 { _ = try u(1) }
            _ = try ue(); _ = try ue() // bit depths
            _ = try u(1) // qpprime_y_zero_transform_bypass_flag
            if try u(1) == 1 { // seq_scaling_matrix_present_flag
                for i in 0..<(chroma == 3 ? 12 : 8) where try u(1) == 1 {
                    let size = i < 6 ? 16 : 64
                    var last: Int32 = 8, next: Int32 = 8
                    for _ in 0..<size where next != 0 {
                        guard let raw = r.ue() else { throw ParseError.truncated }
                        let delta = raw % 2 == 1 ? Int32((raw + 1) / 2) : -Int32(raw / 2)
                        next = (last + delta + 256) % 256
                        if next != 0 { last = next }
                    }
                }
            }
        }
        _ = try ue() // log2_max_frame_num_minus4
        let pocType = try ue()
        if pocType == 0 {
            _ = try ue()
        } else if pocType == 1 {
            _ = try u(1)
            try se(); try se()
            let cycle = try ue()
            guard cycle < 256 else { throw ParseError.unsupported }
            for _ in 0..<cycle { try se() }
        }
        let refFrames = try ue()
        _ = try u(1) // gaps_in_frame_num_value_allowed_flag
        _ = try ue(); _ = try ue() // picture size in macroblocks
        if try u(1) == 0 { _ = try u(1) } // frame_mbs_only_flag, mb_adaptive_frame_field_flag
        _ = try u(1) // direct_8x8_inference_flag
        if try u(1) == 1 { for _ in 0..<4 { _ = try ue() } } // frame cropping
        let vuiFlagAt = r.position
        guard try u(1) == 1 else { return Parsed(keepBits: vuiFlagAt, hadVUI: false, maxNumRefFrames: refFrames) }

        if try u(1) == 1 { if try u(8) == 255 { _ = try u(16); _ = try u(16) } } // aspect ratio
        if try u(1) == 1 { _ = try u(1) } // overscan
        if try u(1) == 1 { // video signal type
            _ = try u(4)
            if try u(1) == 1 { _ = try u(24) }
        }
        if try u(1) == 1 { _ = try ue(); _ = try ue() } // chroma location
        if try u(1) == 1 { _ = try u(32); _ = try u(32); _ = try u(1) } // timing
        func hrd() throws {
            let count = try ue() + 1
            guard count <= 32 else { throw ParseError.unsupported }
            _ = try u(8)
            for _ in 0..<count { _ = try ue(); _ = try ue(); _ = try u(1) }
            _ = try u(20)
        }
        let nal = try u(1) == 1
        if nal { try hrd() }
        let vcl = try u(1) == 1
        if vcl { try hrd() }
        if nal || vcl { _ = try u(1) } // low_delay_hrd_flag
        _ = try u(1) // pic_struct_present_flag
        // Whatever restriction was there is replaced.
        return Parsed(keepBits: r.position, hadVUI: true, maxNumRefFrames: refFrames)
    }

    /// Drop emulation prevention bytes (`00 00 03` → `00 00`).
    static func unescape(_ b: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(b.count)
        var zeros = 0
        for x in b {
            if zeros >= 2 && x == 3 { zeros = 0; continue }
            out.append(x)
            zeros = x == 0 ? zeros + 1 : 0
        }
        return out
    }

    /// Insert emulation prevention bytes where two zeros precede a byte ≤ 3.
    static func escape(_ b: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(b.count + 4)
        var zeros = 0
        for x in b {
            if zeros >= 2 && x <= 3 { out.append(3); zeros = 0 }
            out.append(x)
            zeros = x == 0 ? zeros + 1 : 0
        }
        return out
    }

    struct BitReader {
        let data: [UInt8]
        private(set) var position = 0
        init(_ data: [UInt8]) { self.data = data }

        mutating func bit() -> UInt8? {
            guard position < data.count * 8 else { return nil }
            let v = (data[position / 8] >> (7 - UInt8(position % 8))) & 1
            position += 1
            return v
        }

        mutating func bits(_ n: Int) -> UInt32? {
            var v: UInt32 = 0
            for _ in 0..<n { guard let b = bit() else { return nil }; v = v << 1 | UInt32(b) }
            return v
        }

        mutating func ue() -> UInt32? {
            var zeros = 0
            while true {
                guard let b = bit() else { return nil }
                if b == 1 { break }
                zeros += 1
                if zeros > 31 { return nil }
            }
            guard let rest = bits(zeros) else { return nil }
            return (UInt32(1) << zeros) - 1 + rest
        }
    }

    struct BitWriter {
        private(set) var bytes: [UInt8] = []
        private var count = 0

        mutating func bit(_ b: UInt8) {
            if count % 8 == 0 { bytes.append(0) }
            if b & 1 == 1 { bytes[bytes.count - 1] |= 1 << (7 - UInt8(count % 8)) }
            count += 1
        }

        mutating func ue(_ v: UInt32) {
            let x = UInt64(v) + 1
            let len = 64 - x.leadingZeroBitCount
            for _ in 0..<(len - 1) { bit(0) }
            for i in stride(from: len - 1, through: 0, by: -1) { bit(UInt8((x >> UInt64(i)) & 1)) }
        }

        /// rbsp_trailing_bits: a one, then zeros to the byte.
        mutating func trailing() {
            bit(1)
            while count % 8 != 0 { bit(0) }
        }
    }
}
