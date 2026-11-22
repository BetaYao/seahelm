import AppKit
import ApplicationServices

/// Turns a remote page's screen input into real events on this Mac
/// (docs/superpowers/specs/2026-11-22-remote-screen-design.md). Coordinates
/// arrive normalised to the shared display (0–1); events are posted at the
/// HID level, so they land wherever the user's own mouse and keyboard would.
/// Needs the Accessibility permission; without it macOS drops the events.
final class ScreenInputInjector {
    /// The display the picture shows; set by the capture.
    var displayID: CGDirectDisplayID = CGMainDisplayID()

    private let source = CGEventSource(stateID: .hidSystemState)
    private var leftDown = false
    /// The last press, to count a quick second one as a double click the
    /// way the HID system would (a desktop browser sends plain downs and ups).
    private var lastPress: (time: TimeInterval, point: CGPoint, count: Int64)?
    private var pressCount: Int64 = 1

    static var trusted: Bool { AXIsProcessTrusted() }

    /// Ask macOS for the Accessibility permission (opens its prompt once).
    static func requestTrust() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    /// Apply one message from the gateway. Returns an error to show on the
    /// page, or nil.
    func handle(_ msg: [String: Any]) -> String? {
        guard Self.trusted else {
            return "seahelm on the Mac lacks the Accessibility permission, so input cannot be applied."
        }
        switch msg["type"] as? String {
        case "pointer":
            guard let p = point(msg) else { return nil }
            pointer(msg["action"] as? String ?? "", at: p)
        case "scroll":
            guard let p = point(msg) else { return nil }
            post(mouse: .mouseMoved, at: p, button: .left)
            let dx = (msg["dx"] as? NSNumber)?.doubleValue ?? 0
            let dy = (msg["dy"] as? NSNumber)?.doubleValue ?? 0
            scroll(dx: dx, dy: dy)
        case "key":
            if let chord = msg["key"] as? String { key(chord) }
        case "text":
            if let text = msg["text"] as? String { type(text) }
        default:
            break
        }
        return nil
    }

    // MARK: - Pointer

    private func point(_ msg: [String: Any]) -> CGPoint? {
        guard let x = (msg["x"] as? NSNumber)?.doubleValue, let y = (msg["y"] as? NSNumber)?.doubleValue else { return nil }
        return Self.globalPoint(x: x, y: y, in: CGDisplayBounds(displayID))
    }

    /// A normalised point on a display, in the global top-left coordinates
    /// CGEvent uses.
    static func globalPoint(x: Double, y: Double, in bounds: CGRect) -> CGPoint {
        let cx = min(max(x, 0), 1), cy = min(max(y, 0), 1)
        return CGPoint(x: bounds.minX + cx * (bounds.width - 1), y: bounds.minY + cy * (bounds.height - 1))
    }

    private func pointer(_ action: String, at p: CGPoint) {
        switch action {
        case "move":
            post(mouse: leftDown ? .leftMouseDragged : .mouseMoved, at: p, button: .left)
        case "down":
            post(mouse: .mouseMoved, at: p, button: .left)
            pressCount = nextPressCount(at: p)
            post(mouse: .leftMouseDown, at: p, button: .left, clicks: pressCount)
            leftDown = true
        case "up":
            post(mouse: .leftMouseUp, at: p, button: .left, clicks: pressCount)
            leftDown = false
        case "click":
            post(mouse: .mouseMoved, at: p, button: .left)
            let n = nextPressCount(at: p)
            post(mouse: .leftMouseDown, at: p, button: .left, clicks: n)
            post(mouse: .leftMouseUp, at: p, button: .left, clicks: n)
            leftDown = false
        case "double":
            post(mouse: .mouseMoved, at: p, button: .left)
            for clicks in 1...2 {
                post(mouse: .leftMouseDown, at: p, button: .left, clicks: Int64(clicks))
                post(mouse: .leftMouseUp, at: p, button: .left, clicks: Int64(clicks))
            }
            lastPress = nil
            leftDown = false
        case "right":
            post(mouse: .mouseMoved, at: p, button: .right)
            post(mouse: .rightMouseDown, at: p, button: .right, clicks: 1)
            post(mouse: .rightMouseUp, at: p, button: .right, clicks: 1)
        default:
            break
        }
    }

    private func nextPressCount(at p: CGPoint) -> Int64 {
        let now = ProcessInfo.processInfo.systemUptime
        var n: Int64 = 1
        if let last = lastPress, now - last.time < NSEvent.doubleClickInterval,
           hypot(p.x - last.point.x, p.y - last.point.y) < 5 {
            n = min(last.count + 1, 3)
        }
        lastPress = (now, p, n)
        return n
    }

    private func post(mouse type: CGEventType, at p: CGPoint, button: CGMouseButton, clicks: Int64 = 0) {
        guard let e = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: p, mouseButton: button) else { return }
        if clicks > 0 { e.setIntegerValueField(.mouseEventClickState, value: clicks) }
        e.post(tap: .cghidEventTap)
    }

    /// Pixel deltas as the finger moved: content follows the finger.
    private func scroll(dx: Double, dy: Double) {
        guard let e = CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 2,
                              wheel1: Int32(dy.rounded()), wheel2: Int32(dx.rounded()), wheel3: 0) else { return }
        e.post(tap: .cghidEventTap)
    }

    // MARK: - Keyboard

    /// `cmd+shift+t`, `return`, `esc`, `left`, `f5`, `a`.
    private func key(_ chord: String) {
        guard let (code, flags) = Self.parse(chord) else { return }
        for down in [true, false] {
            guard let e = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down) else { continue }
            e.flags = flags
            e.post(tap: .cghidEventTap)
        }
    }

    static func parse(_ chord: String) -> (CGKeyCode, CGEventFlags)? {
        var parts = chord.lowercased().split(separator: "+").map(String.init)
        guard let last = parts.popLast(), !last.isEmpty else { return nil }
        var flags: CGEventFlags = []
        for m in parts {
            switch m {
            case "cmd", "command", "meta", "super": flags.insert(.maskCommand)
            case "shift": flags.insert(.maskShift)
            case "alt", "opt", "option": flags.insert(.maskAlternate)
            case "ctrl", "control": flags.insert(.maskControl)
            case "": continue
            default: return nil
            }
        }
        guard let code = keyCodes[last] else { return nil }
        return (code, flags)
    }

    /// US ANSI virtual key codes.
    static let keyCodes: [String: CGKeyCode] = {
        var m: [String: CGKeyCode] = [
            "return": 36, "enter": 36, "tab": 48, "space": 49, "backspace": 51, "delete": 51,
            "esc": 53, "escape": 53, "forwarddelete": 117, "del": 117,
            "home": 115, "end": 119, "pageup": 116, "pagedown": 121,
            "left": 123, "right": 124, "down": 125, "up": 126,
            "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96, "f6": 97, "f7": 98, "f8": 100,
            "f9": 101, "f10": 109, "f11": 103, "f12": 111,
        ]
        let chars: [(String, CGKeyCode)] = [
            ("a", 0), ("s", 1), ("d", 2), ("f", 3), ("h", 4), ("g", 5), ("z", 6), ("x", 7), ("c", 8), ("v", 9),
            ("b", 11), ("q", 12), ("w", 13), ("e", 14), ("r", 15), ("y", 16), ("t", 17), ("1", 18), ("2", 19),
            ("3", 20), ("4", 21), ("6", 22), ("5", 23), ("=", 24), ("9", 25), ("7", 26), ("-", 27), ("8", 28),
            ("0", 29), ("]", 30), ("o", 31), ("u", 32), ("[", 33), ("i", 34), ("p", 35), ("l", 37), ("j", 38),
            ("'", 39), ("k", 40), (";", 41), ("\\", 42), (",", 43), ("/", 44), ("n", 45), ("m", 46), (".", 47),
            ("`", 50),
        ]
        for (c, k) in chars { m[c] = k }
        return m
    }()

    /// Text as typed characters, whatever the keyboard layout; newlines as Return.
    private func type(_ text: String) {
        for (i, line) in text.components(separatedBy: "\n").enumerated() {
            if i > 0 { key("return") }
            let units = Array(line.utf16)
            var start = 0
            // CGEventKeyboardSetUnicodeString takes at most 20 units per event.
            while start < units.count {
                let end = min(start + 20, units.count)
                let chunk = Array(units[start..<end])
                for down in [true, false] {
                    guard let e = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: down) else { continue }
                    e.flags = []
                    chunk.withUnsafeBufferPointer { e.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: $0.baseAddress) }
                    e.post(tap: .cghidEventTap)
                }
                start = end
            }
        }
    }
}
