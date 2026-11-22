import AppKit
import CoreMedia
@preconcurrency import ScreenCaptureKit
import VideoToolbox

/// The remote screen as H.264 (docs/superpowers/specs/2026-11-22-remote-screen-design.md,
/// phase 2): an `SCStream` of one display, encoded in hardware by
/// VideoToolbox, each access unit handed out as Annex B (parameter sets
/// ahead of every key frame), ready for WebCodecs' `VideoDecoder` without a
/// `description`.
///
/// SCStream delivers only when the screen changes, so a still screen sends
/// nothing; a key frame asked for then (a viewer joined, or lost frames) is
/// made from the last picture again.
final class ScreenVideoStream: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    struct Settings: Equatable {
        var width: Int
        var height: Int
        var fps: Int
        var kbps: Int
    }

    /// Annex B access unit, key frame or not, coded size.
    var onFrame: ((Data, Bool, Int, Int) -> Void)?
    /// The stream stopped by itself (display gone, permission revoked).
    var onStopped: ((String) -> Void)?

    let displayID: CGDirectDisplayID
    private(set) var settings: Settings
    private let stream: SCStream
    private let queue = DispatchQueue(label: "seahelm.screen.video", qos: .userInteractive)
    private var encoder: H264Encoder
    private var lastPicture: CVPixelBuffer?
    private var forceKey = true
    private var stopped = false

    init(display: SCDisplay, settings: Settings) throws {
        displayID = display.displayID
        self.settings = settings
        encoder = try H264Encoder(settings: settings)
        let filter = SCContentFilter(display: display, excludingWindows: [])
        stream = SCStream(filter: filter, configuration: Self.configuration(settings), delegate: nil)
        super.init()
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
    }

    static func configuration(_ s: Settings) -> SCStreamConfiguration {
        let c = SCStreamConfiguration()
        c.width = s.width
        c.height = s.height
        c.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(max(1, s.fps)))
        c.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        c.queueDepth = 4
        c.showsCursor = true
        return c
    }

    func start() async throws {
        try await stream.startCapture()
    }

    func stop() {
        queue.sync { stopped = true }
        Task { [stream] in try? await stream.stopCapture() }
        encoder.invalidate()
    }

    /// Frame rate and bitrate change in place; a new size needs a new stream.
    func retune(fps: Int, kbps: Int) {
        queue.async { [weak self] in
            guard let self, !self.stopped else { return }
            if fps != self.settings.fps {
                self.stream.updateConfiguration(Self.configuration(Settings(width: self.settings.width, height: self.settings.height, fps: fps, kbps: kbps))) { _ in }
            }
            self.settings.fps = fps
            self.settings.kbps = kbps
            self.encoder.retune(fps: fps, kbps: kbps)
        }
    }

    func requestKeyFrame() {
        queue.async { [weak self] in
            guard let self, !self.stopped else { return }
            self.forceKey = true
            // A still screen sends nothing more: make the key frame from what
            // is on screen now.
            if let pb = self.lastPicture { self.encode(pb) }
        }
    }

    // MARK: - SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, !stopped, sampleBuffer.isValid,
              let info = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = info.first?[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete,
              let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        lastPicture = pb
        encode(pb)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        queue.async { [weak self] in
            guard let self, !self.stopped else { return }
            self.stopped = true
            self.onStopped?(error.localizedDescription)
        }
    }

    private func encode(_ pb: CVPixelBuffer) {
        let key = forceKey
        forceKey = false
        let (w, h) = (settings.width, settings.height)
        encoder.encode(pb, forceKey: key) { [weak self] data, isKey in
            self?.onFrame?(data, isKey, w, h)
        }
    }
}

/// A hardware H.264 compression session tuned for a screen: real time, no
/// frame reordering (so every frame decodes as it arrives), High profile.
final class H264Encoder: @unchecked Sendable {
    private var session: VTCompressionSession?

    enum Failure: LocalizedError {
        case create(OSStatus)
        var errorDescription: String? {
            switch self {
            case .create(let s): return "the H.264 encoder could not start (\(s))"
            }
        }
    }

    init(settings: ScreenVideoStream.Settings) throws {
        var s: VTCompressionSession?
        let spec = [kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder: true] as CFDictionary
        let status = VTCompressionSessionCreate(allocator: nil, width: Int32(settings.width), height: Int32(settings.height),
                                                codecType: kCMVideoCodecType_H264, encoderSpecification: spec,
                                                imageBufferAttributes: nil, compressedDataAllocator: nil,
                                                outputCallback: nil, refcon: nil, compressionSessionOut: &s)
        guard status == noErr, let s else { throw Failure.create(status) }
        session = s
        set(kVTCompressionPropertyKey_RealTime, kCFBooleanTrue)
        set(kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_H264_High_AutoLevel)
        set(kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse)
        set(kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, 5 as CFNumber)
        retune(fps: settings.fps, kbps: settings.kbps)
        VTCompressionSessionPrepareToEncodeFrames(s)
    }

    deinit { invalidate() }

    func invalidate() {
        guard let s = session else { return }
        VTCompressionSessionCompleteFrames(s, untilPresentationTimeStamp: .invalid)
        VTCompressionSessionInvalidate(s)
        session = nil
    }

    private func set(_ key: CFString, _ value: CFTypeRef) {
        guard let s = session else { return }
        VTSessionSetProperty(s, key: key, value: value)
    }

    func retune(fps: Int, kbps: Int) {
        let bps = max(300, kbps) * 1000
        set(kVTCompressionPropertyKey_ExpectedFrameRate, fps as CFNumber)
        set(kVTCompressionPropertyKey_MaxKeyFrameInterval, max(1, fps * 5) as CFNumber)
        set(kVTCompressionPropertyKey_AverageBitRate, bps as CFNumber)
        // A burst (a window opening) may run to 1.5× for a second, no more.
        set(kVTCompressionPropertyKey_DataRateLimits, [bps * 3 / 16, 1] as CFArray)
    }

    func encode(_ pb: CVPixelBuffer, forceKey: Bool, done: @escaping (Data, Bool) -> Void) {
        guard let s = session else { return }
        let pts = CMTime(seconds: CACurrentMediaTime(), preferredTimescale: 1_000_000)
        let props = forceKey ? [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary : nil
        VTCompressionSessionEncodeFrame(s, imageBuffer: pb, presentationTimeStamp: pts, duration: .invalid,
                                        frameProperties: props, infoFlagsOut: nil) { status, _, sample in
            guard status == noErr, let sample, CMSampleBufferDataIsReady(sample),
                  let out = Self.annexB(sample) else { return }
            done(out.data, out.key)
        }
    }

    /// An encoded sample as Annex B: SPS and PPS first when it is a key frame.
    static func annexB(_ sample: CMSampleBuffer) -> (data: Data, key: Bool)? {
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]]
        let key = !((attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool) ?? false)
        var out = Data()
        if key, let fmt = CMSampleBufferGetFormatDescription(sample) {
            var count = 0
            var nalHeader: Int32 = 0
            CMVideoFormatDescriptionGetH264ParameterSetAtIndex(fmt, parameterSetIndex: 0, parameterSetPointerOut: nil,
                                                               parameterSetSizeOut: nil, parameterSetCountOut: &count,
                                                               nalUnitHeaderLengthOut: &nalHeader)
            for i in 0..<count {
                var ptr: UnsafePointer<UInt8>?
                var size = 0
                guard CMVideoFormatDescriptionGetH264ParameterSetAtIndex(fmt, parameterSetIndex: i, parameterSetPointerOut: &ptr,
                                                                         parameterSetSizeOut: &size, parameterSetCountOut: nil,
                                                                         nalUnitHeaderLengthOut: nil) == noErr,
                      let ptr else { continue }
                var unit = Data(bytes: ptr, count: size)
                // Decoders otherwise hold frames back (`SPSRewriter`).
                if let first = unit.first, first & 0x1F == 7, let low = SPSRewriter.lowLatency(unit) { unit = low }
                out.append(contentsOf: startCode)
                out.append(unit)
            }
        }
        guard let block = CMSampleBufferGetDataBuffer(sample) else { return nil }
        let length = CMBlockBufferGetDataLength(block)
        var avcc = Data(count: length)
        let copied = avcc.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: $0.baseAddress!) }
        guard copied == noErr else { return nil }
        out.append(avccToAnnexB(avcc))
        return (out, key)
    }

    static let startCode: [UInt8] = [0, 0, 0, 1]

    /// 4-byte big-endian length prefixes → start codes. A truncated unit ends
    /// the conversion rather than reading past the buffer.
    static func avccToAnnexB(_ avcc: Data) -> Data {
        var out = Data(capacity: avcc.count + 16)
        let bytes = [UInt8](avcc)
        var i = 0
        while i + 4 <= bytes.count {
            let n = Int(bytes[i]) << 24 | Int(bytes[i + 1]) << 16 | Int(bytes[i + 2]) << 8 | Int(bytes[i + 3])
            i += 4
            guard n > 0, i + n <= bytes.count else { break }
            out.append(contentsOf: startCode)
            out.append(contentsOf: bytes[i..<(i + n)])
            i += n
        }
        return out
    }
}
