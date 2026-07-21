import AppKit

/// Stable per-repo accent color, derived from the repo name so the same repo
/// always gets the same swatch without any stored state.
///
/// Survivor of the deleted mini-card UI — `BridgePanelViewController` still
/// tints rows with it.
enum DeckColor {
    static func color(for project: String) -> NSColor {
        let palette = [0xd97757, 0x10a37f, 0x8b7fd9, 0x4285f4, 0x6aa84f,
                       0xb07ad9, 0xe0a030, 0x4aa3a3, 0xd96f9a, 0x7a9bd9]
        var hash: UInt64 = 5381
        for byte in project.utf8 { hash = (hash &* 33) &+ UInt64(byte) }
        return NSColor(hex: palette[Int(hash % UInt64(palette.count))])
    }
}
