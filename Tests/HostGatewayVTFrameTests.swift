import XCTest
@testable import seahelm

final class HostGatewayVTFrameTests: XCTestCase {
    /// Deterministic bytes deflate cannot shrink, so the encoder has to fall back
    /// to stored blocks — the case the output buffer has to be sized for.
    private func incompressible(_ count: Int) -> Data {
        var state: UInt64 = 0x9E37_79B9_7F4A_7C15
        var out = Data(capacity: count)
        for _ in 0..<count {
            state ^= state << 13
            state ^= state >> 7
            state ^= state << 17
            out.append(UInt8(truncatingIfNeeded: state))
        }
        return out
    }

    func testRoundTripsDataFrame() throws {
        let payload = Data(repeating: 0x41, count: 4096)
        let event = VTEvent(kind: .data, paneSessionKey: "pane-1", payload: payload)
        let frame = try XCTUnwrap(HostGatewayVTFrame.encode(event, allowDeflate: true))
        let decoded = try XCTUnwrap(HostGatewayVTFrame.decode(frame))
        XCTAssertEqual(decoded.kind, .data)
        XCTAssertEqual(decoded.paneSessionKey, "pane-1")
        XCTAssertEqual(decoded.payload, payload)
        XCTAssertTrue(decoded.wasCompressed)
    }

    func testSnapshotCarriesGeometry() throws {
        let event = VTEvent(kind: .snapshot, paneSessionKey: "p", payload: Data("hi".utf8),
                            cols: 120, rows: 32)
        let frame = try XCTUnwrap(HostGatewayVTFrame.encode(event, allowDeflate: true))
        let decoded = try XCTUnwrap(HostGatewayVTFrame.decode(frame))
        XCTAssertEqual(decoded.cols, 120)
        XCTAssertEqual(decoded.rows, 32)
        XCTAssertFalse(decoded.wasCompressed, "below the threshold, deflate is skipped")
    }

    /// A snapshot is bounded by time (`snapshotMax`), not by size, so multi-MB
    /// payloads are reachable. Compressible ones must still compress at that
    /// size — this is what the output buffer is actually sized for.
    func testDeflateHandlesMultiMegabyteCompressiblePayloads() throws {
        let payload = Data(repeating: 0x41, count: 1_500_000)
        let deflated = try XCTUnwrap(HostGatewayVTFrame.deflate(payload))
        XCTAssertLessThan(deflated.count, payload.count / 100)
        XCTAssertEqual(HostGatewayVTFrame.inflate(deflated), payload)
    }

    /// Incompressible input has no compressed form smaller than itself, so
    /// `deflate` declines rather than handing back something the caller would
    /// throw away. The buffer is sized to make that the same question.
    func testDeflateDeclinesWhenItCannotShrinkTheInput() {
        XCTAssertNil(HostGatewayVTFrame.deflate(incompressible(1_500_000)))
        XCTAssertNil(HostGatewayVTFrame.deflate(incompressible(2_048)))
    }

    /// Encoding stays correct either way: if deflate cannot help, the frame is
    /// sent raw and still decodes to the same bytes.
    func testLargeIncompressibleFrameStillRoundTrips() throws {
        let payload = incompressible(1_500_000)
        let event = VTEvent(kind: .snapshot, paneSessionKey: "big", payload: payload,
                            cols: 80, rows: 24)
        let frame = try XCTUnwrap(HostGatewayVTFrame.encode(event, allowDeflate: true))
        let decoded = try XCTUnwrap(HostGatewayVTFrame.decode(frame))
        XCTAssertEqual(decoded.payload, payload)
    }

    func testRejectsOverlongPaneKey() {
        let key = String(repeating: "k", count: HostGatewayVTFrame.maxKeyLength + 1)
        let event = VTEvent(kind: .data, paneSessionKey: key, payload: Data([0x41]))
        XCTAssertNil(HostGatewayVTFrame.encode(event, allowDeflate: false))
    }
}
