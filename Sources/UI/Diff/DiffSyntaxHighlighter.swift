import AppKit

enum DiffSyntaxHighlighter {
    private enum Language {
        case swift
        case script
        case json
        case rust
        case python
    }

    private enum TokenKind {
        case keyword
        case string
        case comment
        case number
        case type
        case function
    }

    static func attributedString(
        for code: String,
        filePath: String,
        font: NSFont,
        baseColor: NSColor
    ) -> NSAttributedString {
        let attributed = NSMutableAttributedString(string: code, attributes: [
            .font: font,
            .foregroundColor: baseColor,
        ])

        guard let language = language(for: filePath), !code.isEmpty else {
            return attributed
        }

        let fullRange = NSRange(location: 0, length: (code as NSString).length)
        var protectedRanges: [NSRange] = []

        let stringRanges = ranges(
            matching: #""(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'|`(?:\\.|[^`\\])*`"#,
            in: code,
            range: fullRange
        )
        apply(.string, to: stringRanges, in: attributed, baseColor: baseColor)
        protectedRanges.append(contentsOf: stringRanges)

        let commentRanges = commentRanges(in: code, language: language, excluding: protectedRanges)
        apply(.comment, to: commentRanges, in: attributed, baseColor: baseColor)
        protectedRanges.append(contentsOf: commentRanges)

        var occupiedRanges = protectedRanges
        let keywordRanges = ranges(
            matching: keywordPattern(for: language),
            in: code,
            range: fullRange,
            excluding: occupiedRanges
        )
        apply(.keyword, to: keywordRanges, in: attributed, baseColor: baseColor)
        occupiedRanges.append(contentsOf: keywordRanges)

        let numberRanges = ranges(
            matching: #"(?<![\w.])(?:0x[0-9A-Fa-f]+|\d+(?:\.\d+)?)(?![\w.])"#,
            in: code,
            range: fullRange,
            excluding: occupiedRanges
        )
        apply(.number, to: numberRanges, in: attributed, baseColor: baseColor)
        occupiedRanges.append(contentsOf: numberRanges)

        let typeRanges = ranges(
            matching: #"\b[A-Z][A-Za-z0-9_]*\b"#,
            in: code,
            range: fullRange,
            excluding: occupiedRanges
        )
        apply(.type, to: typeRanges, in: attributed, baseColor: baseColor)
        occupiedRanges.append(contentsOf: typeRanges)

        let functionRanges = ranges(
            matching: #"\b[A-Za-z_$][A-Za-z0-9_$]*(?=\s*\()"#,
            in: code,
            range: fullRange,
            excluding: occupiedRanges
        )
        apply(.function, to: functionRanges, in: attributed, baseColor: baseColor)

        return attributed
    }

    private static func language(for filePath: String) -> Language? {
        let ext = (filePath as NSString).pathExtension.lowercased()
        switch ext {
        case "swift":
            return .swift
        case "js", "jsx", "ts", "tsx", "mjs", "cjs":
            return .script
        case "json", "jsonc":
            return .json
        case "rs":
            return .rust
        case "py":
            return .python
        default:
            return nil
        }
    }

    private static func keywordPattern(for language: Language) -> String {
        let keywords: [String]
        switch language {
        case .swift:
            keywords = [
                "actor", "as", "async", "await", "break", "case", "catch", "class", "continue", "defer",
                "deinit", "do", "else", "enum", "extension", "false", "final", "for", "func", "guard",
                "if", "import", "in", "init", "let", "nil", "open", "override", "private", "protocol",
                "public", "return", "self", "static", "struct", "switch", "throw", "throws", "true",
                "try", "var", "where", "while",
            ]
        case .script, .json:
            keywords = [
                "as", "async", "await", "break", "case", "catch", "class", "const", "continue", "default",
                "do", "else", "enum", "export", "extends", "false", "finally", "for", "from", "function",
                "if", "implements", "import", "in", "interface", "keyof", "let", "new", "null", "private",
                "protected", "public", "readonly", "return", "satisfies", "static", "super", "switch",
                "this", "throw", "true", "try", "type", "typeof", "undefined", "var", "while",
            ]
        case .rust:
            keywords = [
                "as", "async", "await", "break", "const", "continue", "crate", "else", "enum", "extern",
                "false", "fn", "for", "if", "impl", "in", "let", "loop", "match", "mod", "move", "mut",
                "pub", "ref", "return", "self", "static", "struct", "super", "trait", "true", "type",
                "unsafe", "use", "where", "while",
            ]
        case .python:
            keywords = [
                "and", "as", "async", "await", "break", "class", "continue", "def", "del", "elif", "else",
                "except", "False", "finally", "for", "from", "global", "if", "import", "in", "is",
                "lambda", "None", "nonlocal", "not", "or", "pass", "raise", "return", "True", "try",
                "while", "with", "yield",
            ]
        }

        return #"\b("# + keywords.map(NSRegularExpression.escapedPattern(for:)).joined(separator: "|") + #")\b"#
    }

    private static func commentRanges(
        in code: String,
        language: Language,
        excluding excludedRanges: [NSRange]
    ) -> [NSRange] {
        let nsCode = code as NSString
        let fullRange = NSRange(location: 0, length: nsCode.length)
        let markers: [String]

        switch language {
        case .json:
            markers = []
        case .python:
            markers = ["#"]
        case .swift, .script, .rust:
            markers = ["//", "/*"]
        }

        var earliest: NSRange?
        for marker in markers {
            var searchRange = fullRange
            while searchRange.length > 0 {
                let found = nsCode.range(of: marker, options: [], range: searchRange)
                guard found.location != NSNotFound else { break }

                if !excludedRanges.contains(where: { rangesIntersect($0, found) }) {
                    if earliest == nil || found.location < earliest!.location {
                        earliest = NSRange(location: found.location, length: nsCode.length - found.location)
                    }
                    break
                }

                let nextLocation = found.location + max(found.length, 1)
                searchRange = NSRange(location: nextLocation, length: max(0, nsCode.length - nextLocation))
            }
        }

        return earliest.map { [$0] } ?? []
    }

    private static func ranges(
        matching pattern: String,
        in code: String,
        range: NSRange,
        excluding excludedRanges: [NSRange] = []
    ) -> [NSRange] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return []
        }

        return regex
            .matches(in: code, range: range)
            .map(\.range)
            .filter { matchedRange in
                !excludedRanges.contains(where: { rangesIntersect($0, matchedRange) })
            }
    }

    private static func apply(
        _ tokenKind: TokenKind,
        to ranges: [NSRange],
        in attributed: NSMutableAttributedString,
        baseColor: NSColor
    ) {
        let color = blendedColor(for: tokenKind, baseColor: baseColor)
        for range in ranges where range.length > 0 {
            attributed.addAttribute(.foregroundColor, value: color, range: range)
        }
    }

    private static func blendedColor(for tokenKind: TokenKind, baseColor: NSColor) -> NSColor {
        let tokenColor: NSColor
        switch tokenKind {
        case .keyword:
            tokenColor = NSColor(deviceRed: 0.52, green: 0.76, blue: 1.00, alpha: 1)
        case .string:
            tokenColor = NSColor(deviceRed: 0.96, green: 0.78, blue: 0.42, alpha: 1)
        case .comment:
            tokenColor = NSColor(deviceRed: 0.52, green: 0.61, blue: 0.66, alpha: 1)
        case .number:
            tokenColor = NSColor(deviceRed: 0.79, green: 0.70, blue: 1.00, alpha: 1)
        case .type:
            tokenColor = NSColor(deviceRed: 0.55, green: 0.86, blue: 0.69, alpha: 1)
        case .function:
            tokenColor = NSColor(deviceRed: 0.86, green: 0.78, blue: 1.00, alpha: 1)
        }

        return blend(baseColor: baseColor, tokenColor: tokenColor)
    }

    private static func blend(baseColor: NSColor, tokenColor: NSColor) -> NSColor {
        guard
            let base = baseColor.usingColorSpace(.deviceRGB),
            let token = tokenColor.usingColorSpace(.deviceRGB)
        else {
            return tokenColor
        }

        let baseWeight: CGFloat = 0.58
        let tokenWeight: CGFloat = 1 - baseWeight

        return NSColor(
            deviceRed: base.redComponent * baseWeight + token.redComponent * tokenWeight,
            green: base.greenComponent * baseWeight + token.greenComponent * tokenWeight,
            blue: base.blueComponent * baseWeight + token.blueComponent * tokenWeight,
            alpha: base.alphaComponent
        )
    }

    private static func rangesIntersect(_ lhs: NSRange, _ rhs: NSRange) -> Bool {
        NSIntersectionRange(lhs, rhs).length > 0
    }
}
