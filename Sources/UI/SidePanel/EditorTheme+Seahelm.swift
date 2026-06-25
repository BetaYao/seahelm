import AppKit
import CodeEditSourceEditor

// Light / dark syntax themes for the embedded code editor. Values mirror the
// CodeEditSourceEditor example (Xcode default light / Civic dark) so highlighting
// reads naturally in either appearance.
extension EditorTheme {
    static var seahelmLight: EditorTheme {
        EditorTheme(
            text: Attribute(color: NSColor(hex: 0x000000)),
            insertionPoint: NSColor(hex: 0x000000),
            invisibles: Attribute(color: NSColor(hex: 0xD6D6D6)),
            background: NSColor(hex: 0xFFFFFF),
            lineHighlight: NSColor(hex: 0xECF5FF),
            selection: NSColor(hex: 0xB2D7FF),
            keywords: Attribute(color: NSColor(hex: 0x9B2393), bold: true),
            commands: Attribute(color: NSColor(hex: 0x326D74)),
            types: Attribute(color: NSColor(hex: 0x0B4F79)),
            attributes: Attribute(color: NSColor(hex: 0x815F03)),
            variables: Attribute(color: NSColor(hex: 0x0F68A0)),
            values: Attribute(color: NSColor(hex: 0x6C36A9)),
            numbers: Attribute(color: NSColor(hex: 0x1C00CF)),
            strings: Attribute(color: NSColor(hex: 0xC41A16)),
            characters: Attribute(color: NSColor(hex: 0x1C00CF)),
            comments: Attribute(color: NSColor(hex: 0x267507))
        )
    }

    static var seahelmDark: EditorTheme {
        EditorTheme(
            text: Attribute(color: NSColor(hex: 0xFFFFFF)),
            insertionPoint: NSColor(hex: 0x007AFF),
            invisibles: Attribute(color: NSColor(hex: 0x53606E)),
            background: NSColor(hex: 0x292A30),
            lineHighlight: NSColor(hex: 0x2F3239),
            selection: NSColor(hex: 0x646F83),
            keywords: Attribute(color: NSColor(hex: 0xFF7AB2), bold: true),
            commands: Attribute(color: NSColor(hex: 0x78C2B3)),
            types: Attribute(color: NSColor(hex: 0x6BDFFF)),
            attributes: Attribute(color: NSColor(hex: 0xCC9768)),
            variables: Attribute(color: NSColor(hex: 0x4EB0CC)),
            values: Attribute(color: NSColor(hex: 0xB281EB)),
            numbers: Attribute(color: NSColor(hex: 0xD9C97C)),
            strings: Attribute(color: NSColor(hex: 0xFF8170)),
            characters: Attribute(color: NSColor(hex: 0xD9C97C)),
            comments: Attribute(color: NSColor(hex: 0x7F8C98))
        )
    }
}
