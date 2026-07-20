import AppKit
import UniformTypeIdentifiers
import WebKit

/// WebView-backed preview for Markdown and HTML files. Markdown is converted to
/// styled HTML via a compact dependency-free renderer; HTML is loaded as-is.
final class PreviewWebView: NSView {

    /// Markdown is loaded with a nil `baseURL`, and WKWebView refuses `file://`
    /// subresources from such a page regardless of what we put in `src`. Local
    /// images are therefore served through a custom scheme backed by
    /// `LocalResourceSchemeHandler`, scoped to the document's own directory.
    static let localScheme = "seahelm-local"

    private let webView: WKWebView
    private let resourceHandler = LocalResourceSchemeHandler()
    /// Identity of the last page handed to WebKit. Toggling the preview on an
    /// unchanged document should not pay for a full reload.
    private var lastRenderKey: Int?

    override init(frame frameRect: NSRect) {
        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(resourceHandler, forURLScheme: PreviewWebView.localScheme)
        webView = WKWebView(frame: .zero, configuration: config)
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

    /// Spins up the WebKit content process ahead of first use. Without this the
    /// process launch lands on the first preview toggle, which is exactly when
    /// it is most visible.
    func prewarm() {
        webView.loadHTMLString("<html><body></body></html>", baseURL: nil)
    }

    /// Render the given markdown, themed for the current appearance.
    /// `baseDirectory` is the document's folder, used to resolve relative images.
    func render(markdown: String, baseDirectory: URL?) {
        let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        var hasher = Hasher()
        hasher.combine(markdown)
        hasher.combine(isDark)
        hasher.combine(baseDirectory)
        let key = hasher.finalize()
        guard key != lastRenderKey else { return }
        lastRenderKey = key

        resourceHandler.rootDirectory = baseDirectory

        // Parsing is a few regex passes per line; on a long document that is
        // enough to stutter the toggle if it runs on the main thread.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let body = MarkdownHTMLRenderer.html(from: markdown, baseDirectory: baseDirectory)
            let page = PreviewWebView.page(body: body, dark: isDark)
            DispatchQueue.main.async {
                guard let self, self.lastRenderKey == key else { return }
                self.webView.loadHTMLString(page, baseURL: nil)
            }
        }
    }

    /// Render a raw HTML document as-is. `baseURL` (the file's directory) lets
    /// relative resources and links resolve.
    func renderHTML(_ html: String, baseURL: URL?) {
        var hasher = Hasher()
        hasher.combine(html)
        hasher.combine(baseURL)
        let key = hasher.finalize()
        guard key != lastRenderKey else { return }
        lastRenderKey = key
        webView.loadHTMLString(html, baseURL: baseURL)
    }

    private static func page(body: String, dark: Bool) -> String {
        let bg = dark ? "#0f1011" : "#ffffff"
        let fg = dark ? "#e6e6e6" : "#1f2328"
        let muted = dark ? "#8b949e" : "#656d76"
        let border = dark ? "#30363d" : "#d0d7de"
        let codeBg = dark ? "#161b22" : "#f6f8fa"
        let link = dark ? "#4eb0cc" : "#0969da"
        let headBg = dark ? "#161b22" : "#f6f8fa"
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
          /* Wide tables scroll inside their own box instead of widening the page. */
          .table-wrap { overflow-x: auto; margin: 0 0 12px; }
          table { border-collapse: collapse; margin: 0; }
          th, td { border: 1px solid \(border); padding: 5px 10px; }
          th { background: \(headBg); font-weight: 600; }
        </style></head><body>\(body)</body></html>
        """
    }
}

// MARK: - Local resource serving

/// Serves `seahelm-local://` requests from disk, refusing anything outside the
/// previewed document's directory so a crafted markdown file can't read the
/// wider filesystem.
private final class LocalResourceSchemeHandler: NSObject, WKURLSchemeHandler {

    var rootDirectory: URL?

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let url = task.request.url,
              let root = rootDirectory?.standardizedFileURL else {
            task.didFailWithError(URLError(.badURL))
            return
        }
        // The absolute file path travels as the URL path component.
        let fileURL = URL(fileURLWithPath: url.path).standardizedFileURL
        let rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"
        guard fileURL.path.hasPrefix(rootPath),
              let data = try? Data(contentsOf: fileURL) else {
            task.didFailWithError(URLError(.fileDoesNotExist))
            return
        }
        let mime = UTType(filenameExtension: fileURL.pathExtension)?.preferredMIMEType
            ?? "application/octet-stream"
        let response = URLResponse(url: url, mimeType: mime,
                                   expectedContentLength: data.count, textEncodingName: nil)
        task.didReceive(response)
        task.didReceive(data)
        task.didFinish()
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}
}

// MARK: - Renderer

enum MarkdownHTMLRenderer {
    /// Convert markdown text into an HTML body fragment. `baseDirectory` resolves
    /// relative image paths; pass nil to leave them untouched.
    static func html(from markdown: String, baseDirectory: URL? = nil) -> String {
        Renderer(baseDirectory: baseDirectory).render(markdown)
    }
}

/// Instance-based so the image base directory can be threaded through inline
/// parsing without static mutable state — `render` runs off the main thread and
/// two previews may overlap.
private struct Renderer {

    let baseDirectory: URL?

    func render(_ markdown: String) -> String {
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

            // GFM table: a header row followed by a `---|:--:|---` delimiter row.
            // Checked before the horizontal rule so `|---|---|` isn't eaten as one.
            if i + 1 < lines.count,
               let header = Renderer.tableCells(trimmed),
               let aligns = Renderer.tableAlignments(lines[i + 1]),
               aligns.count == header.count {
                closeLists()
                var rows: [[String]] = []
                var j = i + 2
                while j < lines.count {
                    let candidate = lines[j].trimmingCharacters(in: .whitespaces)
                    guard !candidate.isEmpty, let cells = Renderer.tableCells(candidate) else { break }
                    rows.append(cells)
                    j += 1
                }
                out.append(table(header: header, aligns: aligns, rows: rows))
                i = j
                continue
            }

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
            if let item = Renderer.unorderedItem(trimmed) {
                if listStack.last != "ul" { closeLists(); listStack.append("ul"); out.append("<ul>") }
                out.append("<li>\(inline(item))</li>")
                i += 1; continue
            }

            // Ordered list.
            if let item = Renderer.orderedItem(trimmed) {
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

    // MARK: Tables

    /// Splits a `| a | b |` row. Returns nil when the line isn't pipe-delimited.
    static func tableCells(_ s: String) -> [String]? {
        guard s.contains("|") else { return nil }
        var body = s
        if body.hasPrefix("|") { body.removeFirst() }
        if body.hasSuffix("|") { body.removeLast() }
        let cells = body.components(separatedBy: "|").map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        return cells.isEmpty ? nil : cells
    }

    /// Parses the `---|:---:|---:` separator into per-column CSS alignments.
    static func tableAlignments(_ line: String) -> [String]? {
        guard let cells = tableCells(line.trimmingCharacters(in: .whitespaces)) else { return nil }
        var aligns: [String] = []
        for cell in cells {
            let left = cell.hasPrefix(":")
            let right = cell.hasSuffix(":")
            let dashes = cell.trimmingCharacters(in: CharacterSet(charactersIn: ":"))
            guard !dashes.isEmpty, dashes.allSatisfy({ $0 == "-" }) else { return nil }
            switch (left, right) {
            case (true, true): aligns.append("center")
            case (false, true): aligns.append("right")
            default: aligns.append("left")
            }
        }
        return aligns.isEmpty ? nil : aligns
    }

    private func table(header: [String], aligns: [String], rows: [[String]]) -> String {
        func cell(_ tag: String, _ text: String, _ align: String) -> String {
            "<\(tag) style=\"text-align:\(align)\">\(inline(text))</\(tag)>"
        }
        var html = "<div class=\"table-wrap\"><table><thead><tr>"
        for (idx, head) in header.enumerated() {
            html += cell("th", head, aligns[idx])
        }
        html += "</tr></thead><tbody>"
        for row in rows {
            html += "<tr>"
            for idx in 0..<header.count {
                // Ragged rows are common in hand-written tables; pad them out.
                html += cell("td", idx < row.count ? row[idx] : "", aligns[idx])
            }
            html += "</tr>"
        }
        return html + "</tbody></table></div>"
    }

    // MARK: Blocks

    private func heading(_ s: String) -> String? {
        var level = 0
        for ch in s { if ch == "#" { level += 1 } else { break } }
        guard level >= 1, level <= 6, s.count > level,
              s[s.index(s.startIndex, offsetBy: level)] == " " else { return nil }
        let text = String(s.dropFirst(level)).trimmingCharacters(in: .whitespaces)
        return "<h\(level)>\(inline(text))</h\(level)>"
    }

    static func unorderedItem(_ s: String) -> String? {
        for marker in ["- ", "* ", "+ "] where s.hasPrefix(marker) {
            return String(s.dropFirst(2))
        }
        return nil
    }

    static func orderedItem(_ s: String) -> String? {
        guard let dot = s.firstIndex(of: ".") else { return nil }
        let numPart = s[s.startIndex..<dot]
        guard !numPart.isEmpty, numPart.allSatisfy(\.isNumber),
              s.index(after: dot) < s.endIndex, s[s.index(after: dot)] == " " else { return nil }
        return String(s[s.index(dot, offsetBy: 2)...])
    }

    // MARK: Inline

    /// Inline formatting: escape HTML, then apply code/links/images/emphasis.
    private func inline(_ raw: String) -> String {
        var s = escape(raw)
        // Inline code first (protect its contents from further substitution).
        s = replace(s, pattern: "`([^`]+)`") { "<code>\($0)</code>" }
        // Images then links.
        s = replace(s, pattern: "!\\[([^\\]]*)\\]\\(([^)]+)\\)", groups: 2) { g in
            "<img alt=\"\(attr(g[0]))\" src=\"\(attr(self.imageSource(g[1])))\">"
        }
        s = replace(s, pattern: "\\[([^\\]]+)\\]\\(([^)]+)\\)", groups: 2) { g in
            "<a href=\"\(attr(g[1]))\">\(g[0])</a>"
        }
        s = replace(s, pattern: "\\*\\*([^*]+)\\*\\*") { "<strong>\($0)</strong>" }
        s = replace(s, pattern: "__([^_]+)__") { "<strong>\($0)</strong>" }
        s = replace(s, pattern: "\\*([^*]+)\\*") { "<em>\($0)</em>" }
        s = replace(s, pattern: "_([^_]+)_") { "<em>\($0)</em>" }
        return s
    }

    /// Maps a markdown image target onto something the web view can actually
    /// fetch. Remote and data URLs pass through; relative and absolute paths
    /// become `seahelm-local://` so the scheme handler can serve them.
    private func imageSource(_ target: String) -> String {
        // Strip an optional title: ![alt](path "title")
        var path = target.trimmingCharacters(in: .whitespaces)
        if let range = path.range(of: " \"") {
            path = String(path[path.startIndex..<range.lowerBound])
        }
        path = path.trimmingCharacters(in: .whitespaces)

        if let scheme = URL(string: path)?.scheme, !scheme.isEmpty { return path }
        guard let baseDirectory else { return path }

        let absolute = path.hasPrefix("/")
            ? URL(fileURLWithPath: path)
            : baseDirectory.appendingPathComponent(path)
        let encoded = absolute.standardizedFileURL.path
            .addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? absolute.path
        return "\(PreviewWebView.localScheme)://local\(encoded)"
    }
}

// MARK: - Escaping / regex helpers

private func escape(_ s: String) -> String {
    s.replacingOccurrences(of: "&", with: "&amp;")
        .replacingOccurrences(of: "<", with: "&lt;")
        .replacingOccurrences(of: ">", with: "&gt;")
}

/// Attribute values additionally need quotes escaped, or a title/path
/// containing `"` terminates the attribute early.
private func attr(_ s: String) -> String {
    s.replacingOccurrences(of: "\"", with: "&quot;")
}

// Patterns are a fixed set; compiling per render() call paid ~10 regex
// compiles for every preview refresh.
private let regexCacheLock = NSLock()
private nonisolated(unsafe) var regexCache: [String: NSRegularExpression] = [:]

private func cachedRegex(_ pattern: String) -> NSRegularExpression? {
    // Rendering happens off the main thread, so the cache needs guarding.
    regexCacheLock.lock()
    defer { regexCacheLock.unlock() }
    if let re = regexCache[pattern] { return re }
    guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
    regexCache[pattern] = re
    return re
}

// Single capture group convenience.
private func replace(_ s: String, pattern: String, _ transform: (String) -> String) -> String {
    replace(s, pattern: pattern, groups: 1) { transform($0[0]) }
}

private func replace(_ s: String, pattern: String, groups: Int,
                     _ transform: ([String]) -> String) -> String {
    guard let re = cachedRegex(pattern) else { return s }
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
