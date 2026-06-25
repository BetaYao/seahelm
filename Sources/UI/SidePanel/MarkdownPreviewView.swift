import AppKit
import WebKit

/// WebView-backed preview for Markdown and HTML files. Markdown is converted to
/// styled HTML via a compact dependency-free renderer; HTML is loaded as-is.
final class PreviewWebView: NSView {
    private let webView = WKWebView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    private func setup() {
        webView.translatesAutoresizingMaskIntoConstraints = false
        webView.setValue(false, forKey: "drawsBackground") // transparent until HTML paints
        addSubview(webView)
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: topAnchor),
            webView.leadingAnchor.constraint(equalTo: leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    /// Render the given markdown, themed for the current appearance.
    func render(markdown: String) {
        let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let body = MarkdownHTMLRenderer.html(from: markdown)
        webView.loadHTMLString(Self.page(body: body, dark: isDark), baseURL: nil)
    }

    /// Render a raw HTML document as-is. `baseURL` (the file's directory) lets
    /// relative resources and links resolve.
    func renderHTML(_ html: String, baseURL: URL?) {
        webView.loadHTMLString(html, baseURL: baseURL)
    }

    private static func page(body: String, dark: Bool) -> String {
        let bg = dark ? "#0f1011" : "#ffffff"
        let fg = dark ? "#e6e6e6" : "#1f2328"
        let muted = dark ? "#8b949e" : "#656d76"
        let border = dark ? "#30363d" : "#d0d7de"
        let codeBg = dark ? "#161b22" : "#f6f8fa"
        let link = dark ? "#4eb0cc" : "#0969da"
        return """
        <!doctype html><html><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <style>
          body { font: 14px/1.6 -apple-system, system-ui, sans-serif; color: \(fg);
                 background: \(bg); margin: 0; padding: 16px 20px; }
          h1,h2,h3,h4,h5,h6 { font-weight: 600; line-height: 1.25; margin: 20px 0 12px; }
          h1 { font-size: 1.7em; border-bottom: 1px solid \(border); padding-bottom: .3em; }
          h2 { font-size: 1.4em; border-bottom: 1px solid \(border); padding-bottom: .3em; }
          h3 { font-size: 1.2em; } h4 { font-size: 1em; }
          p, ul, ol, blockquote, pre, table { margin: 0 0 12px; }
          a { color: \(link); text-decoration: none; }
          a:hover { text-decoration: underline; }
          code { font-family: ui-monospace, SFMono-Regular, Menlo, monospace; font-size: .88em;
                 background: \(codeBg); padding: .15em .35em; border-radius: 4px; }
          pre { background: \(codeBg); padding: 12px 14px; border-radius: 6px; overflow: auto; }
          pre code { background: none; padding: 0; }
          blockquote { color: \(muted); border-left: 3px solid \(border); padding: 0 12px; }
          hr { border: 0; border-top: 1px solid \(border); margin: 20px 0; }
          ul, ol { padding-left: 24px; }
          li { margin: 3px 0; }
          img { max-width: 100%; }
          table { border-collapse: collapse; }
          th, td { border: 1px solid \(border); padding: 5px 10px; }
        </style></head><body>\(body)</body></html>
        """
    }
}

// MARK: - Renderer

enum MarkdownHTMLRenderer {
    /// Convert markdown text into an HTML body fragment.
    static func html(from markdown: String) -> String {
        let lines = markdown.components(separatedBy: "\n")
        var out: [String] = []
        var i = 0
        var listStack: [String] = [] // "ul" / "ol"

        func closeLists() {
            while let tag = listStack.popLast() { out.append("</\(tag)>") }
        }

        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Fenced code block.
            if trimmed.hasPrefix("```") {
                closeLists()
                var code: [String] = []
                i += 1
                while i < lines.count, !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    code.append(escape(lines[i]))
                    i += 1
                }
                out.append("<pre><code>\(code.joined(separator: "\n"))</code></pre>")
                i += 1
                continue
            }

            // Blank line.
            if trimmed.isEmpty { closeLists(); i += 1; continue }

            // Horizontal rule.
            if trimmed == "---" || trimmed == "***" || trimmed == "___" {
                closeLists(); out.append("<hr>"); i += 1; continue
            }

            // Heading.
            if let h = heading(trimmed) {
                closeLists(); out.append(h); i += 1; continue
            }

            // Blockquote.
            if trimmed.hasPrefix(">") {
                closeLists()
                let content = String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)
                out.append("<blockquote>\(inline(content))</blockquote>")
                i += 1; continue
            }

            // Unordered list.
            if let item = unorderedItem(trimmed) {
                if listStack.last != "ul" { closeLists(); listStack.append("ul"); out.append("<ul>") }
                out.append("<li>\(inline(item))</li>")
                i += 1; continue
            }

            // Ordered list.
            if let item = orderedItem(trimmed) {
                if listStack.last != "ol" { closeLists(); listStack.append("ol"); out.append("<ol>") }
                out.append("<li>\(inline(item))</li>")
                i += 1; continue
            }

            // Paragraph.
            closeLists()
            out.append("<p>\(inline(trimmed))</p>")
            i += 1
        }
        closeLists()
        return out.joined(separator: "\n")
    }

    private static func heading(_ s: String) -> String? {
        var level = 0
        for ch in s { if ch == "#" { level += 1 } else { break } }
        guard level >= 1, level <= 6, s.count > level,
              s[s.index(s.startIndex, offsetBy: level)] == " " else { return nil }
        let text = String(s.dropFirst(level)).trimmingCharacters(in: .whitespaces)
        return "<h\(level)>\(inline(text))</h\(level)>"
    }

    private static func unorderedItem(_ s: String) -> String? {
        for marker in ["- ", "* ", "+ "] where s.hasPrefix(marker) {
            return String(s.dropFirst(2))
        }
        return nil
    }

    private static func orderedItem(_ s: String) -> String? {
        guard let dot = s.firstIndex(of: ".") else { return nil }
        let numPart = s[s.startIndex..<dot]
        guard !numPart.isEmpty, numPart.allSatisfy(\.isNumber),
              s.index(after: dot) < s.endIndex, s[s.index(after: dot)] == " " else { return nil }
        return String(s[s.index(dot, offsetBy: 2)...])
    }

    /// Inline formatting: escape HTML, then apply code/links/images/emphasis.
    private static func inline(_ raw: String) -> String {
        var s = escape(raw)
        // Inline code first (protect its contents from further substitution).
        s = replace(s, pattern: "`([^`]+)`") { "<code>\($0)</code>" }
        // Images then links.
        s = replace(s, pattern: "!\\[([^\\]]*)\\]\\(([^)]+)\\)", groups: 2) { g in
            "<img alt=\"\(g[0])\" src=\"\(g[1])\">"
        }
        s = replace(s, pattern: "\\[([^\\]]+)\\]\\(([^)]+)\\)", groups: 2) { g in
            "<a href=\"\(g[1])\">\(g[0])</a>"
        }
        s = replace(s, pattern: "\\*\\*([^*]+)\\*\\*") { "<strong>\($0)</strong>" }
        s = replace(s, pattern: "__([^_]+)__") { "<strong>\($0)</strong>" }
        s = replace(s, pattern: "\\*([^*]+)\\*") { "<em>\($0)</em>" }
        s = replace(s, pattern: "_([^_]+)_") { "<em>\($0)</em>" }
        return s
    }

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    // Single capture group convenience.
    private static func replace(_ s: String, pattern: String, _ transform: (String) -> String) -> String {
        replace(s, pattern: pattern, groups: 1) { transform($0[0]) }
    }

    private static func replace(_ s: String, pattern: String, groups: Int, _ transform: ([String]) -> String) -> String {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return s }
        let ns = s as NSString
        var result = ""
        var last = 0
        for m in re.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            result += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            var caps: [String] = []
            for g in 1...groups { caps.append(ns.substring(with: m.range(at: g))) }
            result += transform(caps)
            last = m.range.location + m.range.length
        }
        result += ns.substring(from: last)
        return result
    }
}
