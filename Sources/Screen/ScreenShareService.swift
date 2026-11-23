import AppKit
import ImageIO
@preconcurrency import ScreenCaptureKit
import UniformTypeIdentifiers

/// Provides the remote screen to seahelm-gateway
/// (docs/superpowers/specs/2026-11-22-remote-screen-design.md, phases 1–2).
///
/// The app holds the Screen Recording and Accessibility permissions, so it
/// captures and injects; the gateway authorises pages and relays. The app
/// stays connected to the gateway's `screen.sock` and captures only while the
/// gateway says someone watches (`watch` with fps > 0), in the codec it names:
/// `h264` — a `ScreenVideoStream` (SCStream + VideoToolbox), key frames on
/// `key_frame` — or `jpeg`, stills one after another at the asked rate, for a
/// page that cannot decode H.264. Input from the pages comes back on the same
/// socket. It also tells the gateway which displays there are (a page may
/// pick one; `watch`'s `display`) and, while anyone watches, the clipboard's
/// text whenever it changes; a page's `clipboard` goes onto it.
///
/// Wire: `[u32 BE length][u8 type][payload]` both ways, the length counting
/// the type byte; type 1 JSON, type 2 a frame (`[u8 codec][u8 flags]
/// [u16 BE width][u16 BE height]` then the JPEG or the Annex B access unit;
/// codec 1 JPEG, 2 H.264, flags bit 0 key frame).
final class ScreenShareService: @unchecked Sendable {
    static let shared = ScreenShareService()

    /// Labels of the devices watching now; told on main when they change.
    private(set) var viewers: [String] = []
    var onViewersChange: (() -> Void)?

    private let lock = NSLock()
    private let writeLock = NSLock()
    private var started = false
    private var fd: Int32 = -1
    private var fps = 0
    private var maxShort = 1080
    private var quality = 0.6
    private var codec = "jpeg"
    private var kbps = 3000
    private var video: ScreenVideoStream?
    private var videoFailure: String?
    private var capturing = false
    private var lastError: String?
    private let injector = ScreenInputInjector()
    private var statusItem: NSStatusItem?
    /// The display a page picked; nil: the main one.
    private var chosenDisplay: CGDirectDisplayID?
    /// The display last reported as captured.
    private var reportedDisplay: CGDirectDisplayID = 0
    private var clipboardTimer: Timer?
    private var clipboardSeen = -1
    private let keepAwake = ScreenKeepAwake()

    static let codecJPEG: UInt8 = 1
    static let codecH264: UInt8 = 2

    /// `$SEAHELM_GATEWAY_SCREEN_SOCKET`, else `screen.sock` in the gateway's
    /// directory (`$SEAHELM_GATEWAY_DIR`, else ~/.config/seahelm/gateway).
    static var socketPath: String {
        let env = ProcessInfo.processInfo.environment
        if let p = env["SEAHELM_GATEWAY_SCREEN_SOCKET"], !p.isEmpty { return p }
        if env["XCTestConfigurationFilePath"] != nil { return "/nonexistent/screen.sock" }
        if let dir = env["SEAHELM_GATEWAY_DIR"], !dir.isEmpty { return (dir as NSString).appendingPathComponent("screen.sock") }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/seahelm/gateway/screen.sock").path
    }

    static var canCapture: Bool { CGPreflightScreenCaptureAccess() }

    static var screenLocked: Bool {
        let session = CGSessionCopyCurrentDictionary() as? [String: Any]
        return (session?["CGSSessionScreenIsLocked"] as? NSNumber)?.boolValue ?? false
    }

    static var activeDisplayCount: UInt32 {
        var n: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &n)
        return n
    }
    static var canInject: Bool { ScreenInputInjector.trusted }

    /// Ask macOS for both permissions; each prompt appears once.
    static func requestPermissions() {
        if !canCapture { _ = CGRequestScreenCaptureAccess() }
        if !canInject { ScreenInputInjector.requestTrust() }
    }

    /// Keep a connection to the gateway. Main thread; once.
    func start() {
        guard !started else { return }
        started = true
        let t = Thread { [weak self] in self?.run() }
        t.name = "seahelm-screen"
        t.qualityOfService = .utility
        t.start()
    }

    /// End every remote session (the island's or the menu's Stop).
    func stopAll() {
        send(json: ["type": "stop"])
    }

    // MARK: - Connection

    private func run() {
        while true {
            if let fd = CoreSocketClient.open(path: Self.socketPath, timeout: 0) {
                lock.lock(); self.fd = fd; lock.unlock()
                DispatchQueue.main.async { [weak self] in self?.reportDisplays() }
                follow(fd)
                lock.lock(); self.fd = -1; fps = 0; lock.unlock()
                close(fd)
                setViewers([])
            }
            Thread.sleep(forTimeInterval: 3)
        }
    }

    private func follow(_ fd: Int32) {
        while true {
            guard let header = readFully(fd, 5) else { return }
            let len = Int(header[0]) << 24 | Int(header[1]) << 16 | Int(header[2]) << 8 | Int(header[3])
            guard len >= 1, len <= 1 << 20 else { return }
            guard let body = len > 1 ? readFully(fd, len - 1) : Data() else { return }
            guard header[4] == 1,
                  let msg = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else { continue }
            handle(msg)
        }
    }

    private func readFully(_ fd: Int32, _ n: Int) -> Data? {
        var out = Data(count: n)
        var got = 0
        while got < n {
            let r = out.withUnsafeMutableBytes { read(fd, $0.baseAddress! + got, n - got) }
            if r < 0, errno == EINTR { continue }
            guard r > 0 else { return nil }
            got += r
        }
        return out
    }

    private func handle(_ msg: [String: Any]) {
        switch msg["type"] as? String {
        case "watch":
            let newFPS = (msg["fps"] as? NSNumber)?.intValue ?? 0
            lock.lock()
            fps = newFPS
            maxShort = max(240, (msg["max_short"] as? NSNumber)?.intValue ?? 1080)
            quality = min(max((msg["quality"] as? NSNumber)?.doubleValue ?? 0.6, 0.2), 0.95)
            codec = msg["codec"] as? String == "h264" ? "h264" : "jpeg"
            kbps = min(max((msg["kbps"] as? NSNumber)?.intValue ?? 3000, 300), 20000)
            chosenDisplay = (msg["display"] as? NSNumber).map { CGDirectDisplayID($0.uint32Value) }
            // A page's pick is also the default next time.
            if let picked = chosenDisplay { ScreenDisplays.remember(picked) }
            let begin = newFPS > 0 && !capturing
            if begin { capturing = true; lastError = nil }
            lock.unlock()
            setViewers(msg["viewers"] as? [String] ?? [])
            if begin { Task.detached(priority: .userInitiated) { [weak self] in await self?.captureLoop() } }
        case "key_frame":
            lock.lock(); let v = video; lock.unlock()
            v?.requestKeyFrame()
        case "clipboard":
            guard let text = msg["text"] as? String else { return }
            DispatchQueue.main.async { [weak self] in
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.setString(text, forType: .string)
                // Ours: not news to send back.
                self?.clipboardSeen = pb.changeCount
            }
        case "pointer", "scroll", "key", "text":
            DispatchQueue.main.async { [weak self] in
                guard let self, let error = self.injector.handle(msg) else { return }
                self.report(error)
            }
        default:
            break
        }
    }

    private func setViewers(_ list: [String]) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.viewers != list else { return }
            self.viewers = list
            self.updateStatusItem()
            self.followClipboard(!list.isEmpty)
            self.onViewersChange?()
        }
    }

    /// An error the pages should show, once until it changes.
    private func report(_ message: String) {
        lock.lock()
        let fresh = lastError != message
        lastError = message
        lock.unlock()
        if fresh { send(json: ["type": "error", "message": message]) }
    }

    // MARK: - Capture

    private func captureLoop() async {
        DispatchQueue.main.async { [keepAwake] in keepAwake.hold() }
        defer {
            stopVideo()
            lock.lock(); capturing = false; reportedDisplay = 0; lock.unlock()
            DispatchQueue.main.async { [keepAwake] in keepAwake.release() }
        }
        var content: SCShareableContent?
        var contentAt = Date.distantPast
        var virtual = Set<CGDirectDisplayID>()
        var remembered: CGDirectDisplayID?
        while true {
            lock.lock()
            let (fps, maxShort, quality, connected, codec, kbps) = (self.fps, self.maxShort, self.quality, self.fd >= 0, self.codec, self.kbps)
            lock.unlock()
            guard fps > 0, connected else { return }
            if codec != "h264" { stopVideo() }
            let began = Date()
            // A locked Mac's login window takes no synthesized input, and a
            // sleeping display has nothing to capture: say so plainly.
            let asleep = Self.activeDisplayCount == 0
            if asleep { DispatchQueue.main.async { [keepAwake] in keepAwake.wake() } }
            if Self.screenLocked || asleep {
                report("This Mac is locked or its display is asleep. Unlock it at the Mac to share the screen.")
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                continue
            }
            guard Self.canCapture else {
                report("seahelm on the Mac lacks the Screen Recording permission. Grant it in System Settings ▸ Privacy & Security.")
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                continue
            }
            do {
                // Displays come and go rarely; asking costs tens of ms.
                if content == nil || began.timeIntervalSince(contentAt) > 5 {
                    content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                    contentAt = began
                    let ids = content?.displays.map(\.displayID) ?? []
                    virtual = ScreenDisplays.virtualDisplays(ids)
                    remembered = ScreenDisplays.remembered(among: ids)
                }
                guard let displays = content?.displays, !displays.isEmpty else { throw CaptureError.noDisplay }
                lock.lock(); let chosen = chosenDisplay; lock.unlock()
                let ids = displays.map(\.displayID)
                let pickedID = ScreenDisplays.pick(online: ids, chosen: chosen, remembered: remembered,
                                                   virtual: virtual, main: CGMainDisplayID())
                let display = displays.first { $0.displayID == pickedID } ?? displays[0]
                let changed: Bool = {
                    lock.lock(); defer { lock.unlock() }
                    guard reportedDisplay != display.displayID else { return false }
                    reportedDisplay = display.displayID
                    return true
                }()
                DispatchQueue.main.async { [weak self] in
                    self?.injector.displayID = display.displayID
                    if changed { self?.reportDisplays() }
                }
                if codec == "h264" {
                    try await keepVideo(display, fps: fps, kbps: kbps, maxShort: maxShort)
                    // The stream runs by itself; look again for changes.
                    try? await Task.sleep(nanoseconds: 300_000_000)
                    continue
                }
                let frame = try await capture(display, maxShort: maxShort, quality: quality)
                sendFrame(codec: Self.codecJPEG, key: true, width: frame.width, height: frame.height, data: frame.jpeg)
                lock.lock(); lastError = nil; lock.unlock()
            } catch {
                report("Capture failed: \(error.localizedDescription)")
                content = nil
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
            // Stills cost a capture and an encode each: 10 a second at most.
            let wait = 1.0 / Double(min(fps, 10)) - Date().timeIntervalSince(began)
            if wait > 0 { try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) }
        }
    }

    /// Keep an H.264 stream of `display` running at the asked settings:
    /// start one, retune it, or replace it when the size or display changed.
    private func keepVideo(_ display: SCDisplay, fps: Int, kbps: Int, maxShort: Int) async throws {
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let size = Self.outputSize(points: CGSize(width: display.width, height: display.height),
                                   scale: CGFloat(filter.pointPixelScale), maxShort: maxShort, even: true)
        let want = ScreenVideoStream.Settings(width: Int(size.width), height: Int(size.height), fps: fps, kbps: kbps)
        lock.lock()
        let current = video
        let failure = videoFailure
        videoFailure = nil
        lock.unlock()
        if let failure { report("The screen stream stopped: \(failure)") }
        if let current, failure == nil, current.displayID == display.displayID,
           current.settings.width == want.width, current.settings.height == want.height {
            if current.settings.fps != want.fps || current.settings.kbps != want.kbps {
                current.retune(fps: want.fps, kbps: want.kbps)
            }
            return
        }
        stopVideo()
        let stream = try ScreenVideoStream(display: display, settings: want)
        stream.onFrame = { [weak self] data, key, w, h in
            self?.sendFrame(codec: Self.codecH264, key: key, width: w, height: h, data: data)
        }
        stream.onStopped = { [weak self] why in
            guard let self else { return }
            self.lock.lock()
            if self.video === stream { self.video = nil; self.videoFailure = why }
            self.lock.unlock()
        }
        try await stream.start()
        lock.lock(); video = stream; lastError = nil; lock.unlock()
    }

    private func stopVideo() {
        lock.lock()
        let v = video
        video = nil
        lock.unlock()
        v?.stop()
    }

    private enum CaptureError: LocalizedError {
        case noDisplay, encode
        var errorDescription: String? {
            switch self {
            case .noDisplay: return "no display to capture"
            case .encode: return "JPEG encoding failed"
            }
        }
    }

    private struct EncodedFrame {
        let width: Int
        let height: Int
        let jpeg: Data
    }

    /// Output size: the display's pixels, shrunk so the short side is at
    /// most `maxShort`; `even` for H.264, whose chroma is half size.
    static func outputSize(points: CGSize, scale: CGFloat, maxShort: Int, even: Bool = false) -> CGSize {
        let px = CGSize(width: points.width * scale, height: points.height * scale)
        let short = min(px.width, px.height)
        let k = short > CGFloat(maxShort) ? CGFloat(maxShort) / short : 1
        var w = (px.width * k).rounded(), h = (px.height * k).rounded()
        if even {
            w -= w.truncatingRemainder(dividingBy: 2)
            h -= h.truncatingRemainder(dividingBy: 2)
        }
        return CGSize(width: w, height: h)
    }

    private func capture(_ display: SCDisplay, maxShort: Int, quality: Double) async throws -> EncodedFrame {
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let config = SCStreamConfiguration()
        let size = Self.outputSize(points: CGSize(width: display.width, height: display.height),
                                   scale: CGFloat(filter.pointPixelScale), maxShort: maxShort)
        config.width = Int(size.width)
        config.height = Int(size.height)
        config.showsCursor = true
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { throw CaptureError.encode }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw CaptureError.encode }
        return EncodedFrame(width: image.width, height: image.height, jpeg: data as Data)
    }

    // MARK: - Displays and clipboard

    /// Every display, for a page to pick from, and the one captured. Main.
    private func reportDisplays() {
        let main = CGMainDisplayID()
        let virtual = ScreenDisplays.virtualDisplays(ScreenDisplays.online)
        let list: [[String: Any]] = NSScreen.screens.compactMap { screen in
            guard let n = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
            let id = CGDirectDisplayID(n.uint32Value)
            return ["id": Int(id), "name": screen.localizedName, "width": Int(screen.frame.width),
                    "height": Int(screen.frame.height), "main": id == main, "virtual": virtual.contains(id)]
        }
        lock.lock()
        let current = reportedDisplay != 0 ? reportedDisplay : (chosenDisplay ?? main)
        lock.unlock()
        send(json: ["type": "displays", "list": list, "current": Int(current)])
    }

    /// While anyone watches, send the clipboard's text when it changes (the
    /// current one first). Main.
    private func followClipboard(_ on: Bool) {
        clipboardTimer?.invalidate()
        clipboardTimer = nil
        guard on else { return }
        clipboardSeen = -1
        if displayObserver == nil {
            displayObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
            ) { [weak self] _ in self?.reportDisplays() }
        }
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in self?.checkClipboard() }
        RunLoop.main.add(timer, forMode: .common)
        clipboardTimer = timer
        checkClipboard()
    }

    private var displayObserver: NSObjectProtocol?

    private func checkClipboard() {
        let pb = NSPasteboard.general
        guard pb.changeCount != clipboardSeen else { return }
        clipboardSeen = pb.changeCount
        // Password managers mark what they copy; it stays on the Mac.
        let types = pb.types ?? []
        if types.contains(NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
            || types.contains(NSPasteboard.PasteboardType("org.nspasteboard.TransientType")) { return }
        guard let text = pb.string(forType: .string), !text.isEmpty, text.utf8.count <= Self.maxClipboard else { return }
        send(json: ["type": "clipboard", "text": text])
    }

    /// The gateway's cap (`screen::MAX_CLIPBOARD`).
    static let maxClipboard = 256 << 10

    // MARK: - Sending

    private func sendFrame(codec: UInt8, key: Bool, width: Int, height: Int, data: Data) {
        var body = Data([2, codec, key ? 1 : 0])
        body.append(UInt8(width >> 8 & 0xFF)); body.append(UInt8(width & 0xFF))
        body.append(UInt8(height >> 8 & 0xFF)); body.append(UInt8(height & 0xFF))
        body.append(data)
        write(body)
    }

    private func send(json: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: json) else { return }
        var body = Data([1])
        body.append(data)
        write(body)
    }

    /// One message: length prefix, then `body` (its first byte the type).
    private func write(_ body: Data) {
        lock.lock()
        let fd = self.fd
        lock.unlock()
        guard fd >= 0 else { return }
        let n = UInt32(body.count)
        var msg = Data([UInt8(n >> 24 & 0xFF), UInt8(n >> 16 & 0xFF), UInt8(n >> 8 & 0xFF), UInt8(n & 0xFF)])
        msg.append(body)
        writeLock.lock()
        defer { writeLock.unlock() }
        msg.withUnsafeBytes { raw in
            var off = 0
            while off < raw.count {
                let w = Darwin.write(fd, raw.baseAddress! + off, raw.count - off)
                if w < 0, errno == EINTR { continue }
                guard w > 0 else { return }
                off += w
            }
        }
    }

    // MARK: - Menu bar

    /// While anyone watches, a menu bar item says who, with a way to stop it.
    private func updateStatusItem() {
        guard !viewers.isEmpty else {
            if let item = statusItem { NSStatusBar.system.removeStatusItem(item) }
            statusItem = nil
            return
        }
        let item = statusItem ?? NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem = item
        item.button?.image = NSImage(systemSymbolName: "rectangle.on.rectangle", accessibilityDescription: "Screen shared")
        item.button?.imagePosition = .imageLeading
        item.button?.title = " SCREEN"
        let menu = NSMenu()
        let who = viewers.joined(separator: ", ")
        let header = NSMenuItem(title: "Watched and controlled by \(who)", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())
        let stop = NSMenuItem(title: "Stop sharing", action: #selector(stopClicked), keyEquivalent: "")
        stop.target = self
        menu.addItem(stop)
        item.menu = menu
    }

    @objc private func stopClicked() { stopAll() }
}
