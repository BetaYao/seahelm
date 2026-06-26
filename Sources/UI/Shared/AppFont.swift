import AppKit
import CoreText

/// Bare-TUI typography. The cockpit redesign uses JetBrains Mono everywhere a
/// monospaced face is wanted. The .ttf files are bundled under Resources/Fonts
/// and registered at launch; every accessor degrades to the system monospaced
/// font if registration ever fails, so the UI never renders blank.
enum AppFont {

    private static let familyName = "JetBrains Mono"
    private static var registered = false

    /// Register the bundled JetBrains Mono faces. Idempotent; call once at launch.
    static func registerBundledFonts() {
        guard !registered else { return }
        registered = true
        for name in ["JetBrainsMono-Regular", "JetBrainsMono-Medium", "JetBrainsMono-Bold"] {
            guard let url = Bundle.main.url(forResource: name, withExtension: "ttf") else { continue }
            var error: Unmanaged<CFError>?
            if !CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error) {
                NSLog("[AppFont] failed to register %@: %@", name,
                      String(describing: error?.takeRetainedValue()))
            }
        }
    }

    /// JetBrains Mono at the given size/weight, falling back to the system
    /// monospaced font when the family is unavailable.
    static func mono(size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        let descriptor = NSFontDescriptor(fontAttributes: [
            .family: familyName,
            .traits: [NSFontDescriptor.TraitKey.weight: weight],
        ])
        if let font = NSFont(descriptor: descriptor, size: size) {
            return font
        }
        return NSFont.monospacedSystemFont(ofSize: size, weight: weight)
    }
}
