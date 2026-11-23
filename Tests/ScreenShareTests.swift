import CoreGraphics
import CoreVideo
import XCTest
@testable import seahelm

final class ScreenShareTests: XCTestCase {
    func testChordsParse() {
        let t = ScreenInputInjector.parse("cmd+shift+t")
        XCTAssertEqual(t?.0, 17)
        XCTAssertEqual(t?.1, [.maskCommand, .maskShift])
        XCTAssertEqual(ScreenInputInjector.parse("return")?.0, 36)
        XCTAssertEqual(ScreenInputInjector.parse("Ctrl+Alt+Left")?.1, [.maskControl, .maskAlternate])
        XCTAssertNil(ScreenInputInjector.parse("hyper+a"))
        XCTAssertNil(ScreenInputInjector.parse("cmd+"))
        XCTAssertNil(ScreenInputInjector.parse("nosuchkey"))
    }

    func testNormalisedPointsLandOnTheDisplay() {
        let second = CGRect(x: 1512, y: -200, width: 2560, height: 1440)
        XCTAssertEqual(ScreenInputInjector.globalPoint(x: 0, y: 0, in: second), CGPoint(x: 1512, y: -200))
        XCTAssertEqual(ScreenInputInjector.globalPoint(x: 1, y: 1, in: second), CGPoint(x: 1512 + 2559, y: -200 + 1439))
        XCTAssertEqual(ScreenInputInjector.globalPoint(x: 2, y: -1, in: second), CGPoint(x: 1512 + 2559, y: -200))
    }

    func testAVCCBecomesAnnexB() {
        let avcc = Data([0, 0, 0, 2, 0x65, 0xAA, 0, 0, 0, 1, 0x41])
        XCTAssertEqual(H264Encoder.avccToAnnexB(avcc), Data([0, 0, 0, 1, 0x65, 0xAA, 0, 0, 0, 1, 0x41]))
        // A unit claiming more bytes than are there ends the conversion.
        XCTAssertEqual(H264Encoder.avccToAnnexB(Data([0, 0, 0, 1, 0x41, 0, 0, 0, 9, 0x41])), Data([0, 0, 0, 1, 0x41]))
        XCTAssertEqual(H264Encoder.avccToAnnexB(Data()), Data())
    }

    func testHardwareEncoderMakesAnnexBKeyFrames() throws {
        let settings = ScreenVideoStream.Settings(width: 640, height: 360, fps: 30, kbps: 1500)
        let encoder = try H264Encoder(settings: settings)
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(nil, 640, 360, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pb)
        let buffer = try XCTUnwrap(pb)
        var units: [(Data, Bool)] = []
        let lock = NSLock()
        let done = expectation(description: "frames")
        done.expectedFulfillmentCount = 3
        for i in 0..<3 {
            CVPixelBufferLockBaseAddress(buffer, [])
            let y = CVPixelBufferGetBaseAddressOfPlane(buffer, 0)!
            memset(y, Int32(40 + i * 60), CVPixelBufferGetBytesPerRowOfPlane(buffer, 0) * 360)
            let uv = CVPixelBufferGetBaseAddressOfPlane(buffer, 1)!
            memset(uv, 128, CVPixelBufferGetBytesPerRowOfPlane(buffer, 1) * 180)
            CVPixelBufferUnlockBaseAddress(buffer, [])
            encoder.encode(buffer, forceKey: i == 0) { data, key in
                lock.lock(); units.append((data, key)); lock.unlock()
                done.fulfill()
            }
            Thread.sleep(forTimeInterval: 0.034)
        }
        wait(for: [done], timeout: 5)
        encoder.invalidate()
        let first = try XCTUnwrap(units.first)
        XCTAssertTrue(first.1, "the first frame is a key frame")
        // Annex B, opening with the SPS (NAL type 7), then the PPS.
        XCTAssertEqual(Array(first.0.prefix(4)), [0, 0, 0, 1])
        XCTAssertEqual(first.0[4] & 0x1F, 7)
        XCTAssertTrue(units.dropFirst().allSatisfy { !$0.1 && Array($0.0.prefix(4)) == [0, 0, 0, 1] })
        // The SPS went out marked as never reordering: rewriting it again
        // changes nothing.
        let spsEnd = try XCTUnwrap((5..<first.0.count - 3).first { first.0[$0..<$0 + 4] == Data([0, 0, 0, 1]) })
        let sps = first.0.subdata(in: 4..<spsEnd)
        XCTAssertEqual(SPSRewriter.lowLatency(sps), sps)
        if let out = ProcessInfo.processInfo.environment["SCREEN_H264_DUMP"] {
            try units.reduce(Data()) { $0 + $1.0 }.write(to: URL(fileURLWithPath: out))
        }
    }

    func testEmulationPreventionRoundTrips() {
        let raw: [UInt8] = [0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x03, 0xFF, 0x00, 0x00]
        let escaped = SPSRewriter.escape(raw)
        XCTAssertEqual(escaped, [0x00, 0x00, 0x03, 0x01, 0x00, 0x00, 0x03, 0x00, 0x00, 0x03, 0x03, 0xFF, 0x00, 0x00])
        XCTAssertEqual(SPSRewriter.unescape(escaped), raw)
    }

    func testRewriterRefusesWhatIsNotAnSPS() {
        XCTAssertNil(SPSRewriter.lowLatency(Data([0x68, 0xEE, 0x3C, 0x80, 0x00])))
        XCTAssertNil(SPSRewriter.lowLatency(Data([0x67, 0x64])))
    }

    func testThePickedDisplayThenTheRememberedThenAVirtualOne() {
        let (main, panel, virt): (CGDirectDisplayID, CGDirectDisplayID, CGDirectDisplayID) = (1, 2, 5)
        let online = [main, panel, virt]
        func pick(_ chosen: CGDirectDisplayID?, _ remembered: CGDirectDisplayID?, _ virtual: Set<CGDirectDisplayID> = [virt]) -> CGDirectDisplayID? {
            ScreenDisplays.pick(online: online, chosen: chosen, remembered: remembered, virtual: virtual, main: main)
        }
        XCTAssertEqual(pick(panel, virt), panel)
        XCTAssertEqual(pick(nil, panel), panel)
        XCTAssertEqual(pick(nil, nil), virt)
        // Gone displays are passed over.
        XCTAssertEqual(pick(9, 8), virt)
        XCTAssertEqual(pick(nil, nil, []), main)
        XCTAssertNil(ScreenDisplays.pick(online: [], chosen: 1, remembered: nil, virtual: [], main: 1))
    }

    func testH264SizesAreEven() {
        let s = ScreenShareService.outputSize(points: CGSize(width: 1511, height: 983), scale: 1, maxShort: 2000, even: true)
        XCTAssertEqual(s, CGSize(width: 1510, height: 982))
    }

    func testOutputKeepsTheShortSideUnderTheCap() {
        let retina = ScreenShareService.outputSize(points: CGSize(width: 1512, height: 982), scale: 2, maxShort: 1080)
        XCTAssertEqual(retina.height, 1080)
        XCTAssertEqual(retina.width, (3024.0 * 1080 / 1964).rounded())
        let small = ScreenShareService.outputSize(points: CGSize(width: 1280, height: 800), scale: 1, maxShort: 1080)
        XCTAssertEqual(small, CGSize(width: 1280, height: 800))
    }
}
