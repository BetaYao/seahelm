import AppKit

/// Two quick taps of Control, nothing else in between: the gesture that calls
/// First Mate (⌘J is the same thing with a menu item behind it).
///
/// A tap is Control pressed and released on its own within `tapMax`; two taps
/// count when the second begins within `gapMax` of the first ending. Any key or
/// other modifier in between cancels it, so Ctrl-C, Ctrl-R, a tmux Ctrl-B and a
/// Control held for a chord never fire it. Pure, so it is driven by tests with
/// made-up times.
struct DoubleTapDetector {
    static let tapMax: TimeInterval = 0.3
    static let gapMax: TimeInterval = 0.35

    enum Input {
        /// The modifiers now down (device-independent, caps lock ignored).
        case flags(NSEvent.ModifierFlags)
        /// Any key press.
        case key
    }

    private var downAt: TimeInterval?
    private var lastTapEnd: TimeInterval?

    /// Feed an event; true when it completes a double tap.
    mutating func feed(_ input: Input, at time: TimeInterval) -> Bool {
        switch input {
        case .key:
            reset()
            return false
        case .flags(let raw):
            let flags = raw.subtracting(.capsLock)
            if flags == .control {
                // Control went down alone.
                if downAt == nil { downAt = time }
                return false
            }
            guard flags.isEmpty, let down = downAt else {
                // Another modifier joined, or nothing to release: not a tap.
                reset()
                return false
            }
            downAt = nil
            guard time - down <= Self.tapMax else {
                lastTapEnd = nil
                return false
            }
            if let previous = lastTapEnd, down - previous <= Self.gapMax {
                lastTapEnd = nil
                return true
            }
            lastTapEnd = time
            return false
        }
    }

    private mutating func reset() {
        downAt = nil
        lastTapEnd = nil
    }
}
