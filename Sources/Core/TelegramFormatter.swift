import Foundation

/// Turns the light markdown the bridge emits — `**bold**`, `` `code` ``,
/// fenced blocks — into what Telegram will render, and cuts it to size.
///
/// Telegram's HTML flavour rather than MarkdownV2: MarkdownV2 demands that
/// every `.`, `-`, `(` and a dozen other characters be escaped, which agent
/// output is made of. HTML needs three entities and is otherwise literal.
enum TelegramFormatter {
    /// Bot API limit per message, in characters after entity parsing. We count
    /// scalars of the *marked-up* text, which over-counts, so the cut is
    /// always on the safe side.
    static let maxMessageLength = 4096

    // MARK: - Markup

    static func escapeHTML(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    /// Fenced blocks become `<pre>`; inside prose, `**x**` is bold, `` `x` ``
    /// is code, and a line that is entirely `_x_` is italic. Inline markers
    /// never span a newline, so `chunk` can split on any line boundary.
    static func html(from markdown: String) -> String {
        let segments = markdown.components(separatedBy: "```")
        var out = ""
        for (index, segment) in segments.enumerated() {
            if index % 2 == 1 {
                out += "<pre>" + escapeHTML(stripFenceLanguage(segment)) + "</pre>"
            } else {
                out += inline(escapeHTML(segment))
            }
        }
        return out
    }

    /// The markers stripped instead of rendered — for a channel format of
    /// `.text`, and for the retry after Telegram rejects the HTML.
    static func plain(from markdown: String) -> String {
        let segments = markdown.components(separatedBy: "```")
        var out = ""
        for (index, segment) in segments.enumerated() {
            if index % 2 == 1 {
                out += stripFenceLanguage(segment)
            } else {
                out += segment
                    .replacingOccurrences(of: "**", with: "")
                    .replacingOccurrences(of: "`", with: "")
            }
        }
        return out
    }

    /// The plain text an HTML message rendered as — used to resend a chunk
    /// flat after a 400, so the fallback carries exactly the same words.
    static func stripHTML(_ html: String) -> String {
        html.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&amp;", with: "&")
    }

    private static func inline(_ s: String) -> String {
        s.replacingOccurrences(of: "\\*\\*([^\\n*]+?)\\*\\*", with: "<b>$1</b>", options: .regularExpression)
            .replacingOccurrences(of: "`([^`\\n]+?)`", with: "<code>$1</code>", options: .regularExpression)
            .replacingOccurrences(of: "(?m)^_([^\\n_][^\\n]*?)_$", with: "<i>$1</i>", options: .regularExpression)
    }

    /// ```` ```swift ```` puts the language on the first line; drop it, and the
    /// newline that separated it from the code.
    private static func stripFenceLanguage(_ block: String) -> String {
        guard let newline = block.firstIndex(of: "\n") else { return block }
        let head = block[block.startIndex..<newline]
        let isLanguage = !head.isEmpty && head.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "+" }
        return isLanguage ? String(block[block.index(after: newline)...]) : block
    }

    // MARK: - Chunking

    /// Splits at line boundaries so no message exceeds `limit`. A `<pre>` open
    /// at the cut is closed and reopened, so each chunk parses on its own. A
    /// single line longer than the limit is cut hard.
    static func chunk(_ text: String, limit: Int = maxMessageLength) -> [String] {
        guard text.unicodeScalars.count > limit else { return [text] }

        let overhead = "<pre></pre>".count + 1
        let budget = max(limit - overhead, 16)
        var chunks: [String] = []
        var current = ""
        var inPre = false

        func flush() {
            guard !current.isEmpty, current != "<pre>" else { return }
            chunks.append(inPre ? current + "</pre>" : current)
            current = inPre ? "<pre>" : ""
        }

        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var i = 0
        while i < lines.count {
            var line = lines[i]
            if line.unicodeScalars.count > budget {
                let scalars = Array(line.unicodeScalars)
                let head = String(String.UnicodeScalarView(scalars[..<budget]))
                let tail = String(String.UnicodeScalarView(scalars[budget...]))
                lines[i] = head
                lines.insert(tail, at: i + 1)
                line = head
            }

            let joiner = (current.isEmpty || current == "<pre>") ? "" : "\n"
            let candidate = current + joiner + line
            if candidate.unicodeScalars.count > budget {
                flush()
                current += line
            } else {
                current = candidate
            }
            inPre = preState(after: line, was: inPre)
            i += 1
        }
        if !current.isEmpty, current != "<pre>" { chunks.append(current) }
        return chunks
    }

    /// Whether a `<pre>` is open once this line has been emitted.
    private static func preState(after line: String, was open: Bool) -> Bool {
        let lastOpen = line.range(of: "<pre>", options: .backwards)
        let lastClose = line.range(of: "</pre>", options: .backwards)
        switch (lastOpen, lastClose) {
        case (nil, nil): return open
        case (.some, nil): return true
        case (nil, .some): return false
        case (.some(let o), .some(let c)): return o.lowerBound > c.lowerBound
        }
    }
}
