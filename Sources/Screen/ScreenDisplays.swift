import AppKit
import IOKit
import IOKit.pwr_mgt

/// Which display the remote screen shows when no page has picked one, and
/// keeping it awake while it is watched.
///
/// A Mac kept unlocked for remote viewing is safest with its picture on a
/// virtual display (BetterDisplay, or anything built on `CGVirtualDisplay`)
/// and its physical monitor dark: so a virtual display comes first, after
/// the display a page picked last (remembered across sessions by UUID).
enum ScreenDisplays {
    /// The display to capture: the one a page picked now, else the one picked
    /// last time, else a virtual display, else the main one, else the first.
    static func pick(online: [CGDirectDisplayID], chosen: CGDirectDisplayID?, remembered: CGDirectDisplayID?,
                     virtual: Set<CGDirectDisplayID>, main: CGDirectDisplayID) -> CGDirectDisplayID? {
        for candidate in [chosen, remembered] {
            if let c = candidate, online.contains(c) { return c }
        }
        return online.first { virtual.contains($0) } ?? online.first { $0 == main } ?? online.first
    }

    /// Displays no framebuffer drives: a display's vendor and model, as
    /// CoreGraphics reports them, match its panel's EDID in the IORegistry
    /// (`DisplayAttributes.ProductAttributes`); a virtual display has no
    /// panel there. Empty when the registry shows no panels at all (an Intel
    /// Mac keeps them elsewhere): nothing is taken for virtual then.
    static func virtualDisplays(_ ids: [CGDirectDisplayID]) -> Set<CGDirectDisplayID> {
        let panels = framebufferPanels()
        guard !panels.isEmpty else { return [] }
        return Set(ids.filter { id in
            CGDisplayIsBuiltin(id) == 0 && !panels.contains(panelKey(vendor: CGDisplayVendorNumber(id), model: CGDisplayModelNumber(id)))
        })
    }

    static func panelKey(vendor: UInt32, model: UInt32) -> UInt64 { UInt64(vendor) << 32 | UInt64(model) }

    private static func framebufferPanels() -> Set<UInt64> {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOMobileFramebuffer"), &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }
        var out = Set<UInt64>()
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            guard let attrs = IORegistryEntryCreateCFProperty(service, "DisplayAttributes" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? [String: Any],
                  let product = attrs["ProductAttributes"] as? [String: Any],
                  let vendor = (product["LegacyManufacturerID"] as? NSNumber)?.uint32Value,
                  let model = (product["ProductID"] as? NSNumber)?.uint32Value else { continue }
            out.insert(panelKey(vendor: vendor, model: model))
        }
        return out
    }

    static func uuid(of id: CGDirectDisplayID) -> String? {
        guard let u = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue() else { return nil }
        return CFUUIDCreateString(nil, u) as String?
    }

    static func display(withUUID string: String, among ids: [CGDirectDisplayID]) -> CGDirectDisplayID? {
        ids.first { uuid(of: $0) == string }
    }

    static var online: [CGDirectDisplayID] {
        var n: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &n) == .success, n > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(n))
        guard CGGetOnlineDisplayList(n, &ids, &n) == .success else { return [] }
        return Array(ids.prefix(Int(n)))
    }

    private static let rememberedKey = "screenShareDisplayUUID"

    /// The display a page picked last, while it is online.
    static func remembered(among ids: [CGDirectDisplayID]) -> CGDirectDisplayID? {
        guard let s = UserDefaults.standard.string(forKey: rememberedKey) else { return nil }
        return display(withUUID: s, among: ids)
    }

    static func remember(_ id: CGDirectDisplayID) {
        guard let s = uuid(of: id), UserDefaults.standard.string(forKey: rememberedKey) != s else { return }
        UserDefaults.standard.set(s, forKey: rememberedKey)
    }
}

/// While someone watches: displays do not sleep for idleness (a sleeping
/// display has nothing to capture), and a display that already slept is
/// woken. Waking lights every display, the physical monitor too, unless
/// it is switched off or disconnected in software (BetterDisplay).
final class ScreenKeepAwake {
    private var assertion: IOPMAssertionID = 0
    private var lastWake = Date.distantPast

    var holding: Bool { assertion != 0 }

    func hold() {
        guard assertion == 0 else { return }
        var id: IOPMAssertionID = 0
        let reason = "Someone is watching this screen through seahelm" as CFString
        if IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                                       IOPMAssertionLevel(kIOPMAssertionLevelOn), reason, &id) == kIOReturnSuccess {
            assertion = id
        }
    }

    func release() {
        guard assertion != 0 else { return }
        IOPMAssertionRelease(assertion)
        assertion = 0
    }

    /// Wake the displays, at most every 10 s.
    func wake() {
        guard Date().timeIntervalSince(lastWake) > 10 else { return }
        lastWake = Date()
        var id: IOPMAssertionID = 0
        if IOPMAssertionDeclareUserActivity("seahelm remote screen" as CFString, kIOPMUserActiveLocal, &id) == kIOReturnSuccess {
            // A user-activity assertion lapses by itself; releasing it at
            // once keeps nothing held.
            IOPMAssertionRelease(id)
        }
    }

    deinit { release() }
}
