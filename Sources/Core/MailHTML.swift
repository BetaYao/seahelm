import Foundation

/// Renders an outbound mail body — the same markdown the chat surfaces emit —
/// as HTML.
///
/// Written for mail clients, not browsers, which sets the rules: every rule that
/// must survive is an inline `style` attribute, because Gmail drops `<style>`
/// blocks. The block that is present carries only the dark-mode overrides, which
/// clients that honour it (Apple Mail) apply and the rest safely ignore.
///
/// The content itself is monospaced on purpose. The listings are aligned trees —
/// project, worktree, numbered panes — and a proportional font throws that
/// alignment away, which is the one thing the reply's numbering depends on.
enum MailHTML {
    private enum Palette {
        static let page = "#eef3f9"
        static let card = "#ffffff"
        static let border = "#d3dde8"
        static let text = "#1f232b"
        static let muted = "#636b78"
        static let accent = "#0e9bb5"
        static let codeBg = "#eef3f8"
    }

    private static let mono = "ui-monospace, SFMono-Regular, 'SF Mono', Menlo, Consolas, monospace"
    private static let sans = "-apple-system, BlinkMacSystemFont, 'Segoe UI', Helvetica, Arial, sans-serif"

    static func document(body: String) -> String {
        """
        <!doctype html>
        <html>
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width,initial-scale=1">
        <meta name="color-scheme" content="light dark">
        <style>
        @media (prefers-color-scheme: dark) {
          .sh-page { background: #08222a !important; }
          .sh-card { background: #0e2d37 !important; border-color: rgba(150,215,225,.22) !important; }
          .sh-text, .sh-text strong { color: #cfe0e0 !important; }
          .sh-muted { color: #7fa0a3 !important; }
          .sh-accent { color: #1fc8da !important; }
          .sh-code { background: #0a2630 !important; color: #cfe0e0 !important; }
          .sh-rule { border-color: rgba(150,215,225,.22) !important; }
        }
        </style>
        </head>
        <body class="sh-page" style="margin:0;padding:20px 12px;background:\(Palette.page);">
        <table role="presentation" cellpadding="0" cellspacing="0" border="0" width="100%" style="border-collapse:collapse;">
        <tr><td align="center">
        <table role="presentation" cellpadding="0" cellspacing="0" border="0" width="640" class="sh-card" style="border-collapse:collapse;max-width:640px;width:100%;background:\(Palette.card);border:1px solid \(Palette.border);border-radius:12px;">
          <tr><td style="padding:22px 26px 0 26px;">
            \(wordmark)
          </td></tr>
          <tr><td class="sh-text" style="padding:16px 26px 4px 26px;font-family:\(mono);font-size:13.5px;line-height:1.62;color:\(Palette.text);white-space:pre-wrap;word-break:break-word;">\(render(markdown: body))</td></tr>
          <tr><td style="padding:18px 26px 22px 26px;">
            \(signature)
          </td></tr>
        </table>
        </td></tr>
        </table>
        </body>
        </html>
        """
    }

    private static var wordmark: String {
        """
        <div class="sh-muted" style="font-family:\(sans);font-size:11px;font-weight:600;letter-spacing:.14em;text-transform:uppercase;color:\(Palette.muted);">
        <span class="sh-accent" style="color:\(Palette.accent);">&#9673;</span>&nbsp;&nbsp;Seahelm
        </div>
        """
    }

    private static var signature: String {
        let rows = MailSignature.entries.map { entry in
            """
            <tr>
              <td style="padding:2px 14px 2px 0;font-family:\(mono);font-size:12px;white-space:nowrap;" class="sh-accent"><span style="color:\(Palette.accent);">\(escape(entry.command))</span></td>
              <td class="sh-muted" style="padding:2px 0;font-family:\(sans);font-size:12px;color:\(Palette.muted);">\(escape(entry.detail))</td>
            </tr>
            """
        }.joined(separator: "\n")
        return """
        <div class="sh-rule" style="border-top:1px solid \(Palette.border);padding-top:14px;">
        <table role="presentation" cellpadding="0" cellspacing="0" border="0" style="border-collapse:collapse;">
        \(rows)
        </table>
        <div class="sh-muted" style="margin-top:12px;font-family:\(sans);font-size:12px;color:\(Palette.muted);">\(escape(MailSignature.closing))</div>
        </div>
        """
    }

    /// The small markdown subset `BridgeCommandFormatter` actually emits.
    /// Escaping runs first, so nothing in agent output can inject markup.
    static func render(markdown: String) -> String {
        var out = escape(markdown)
        out = replacePairs(in: out, marker: "**", open: "<strong>", close: "</strong>")
        out = replacePairs(in: out, marker: "`",
                           open: "<code class=\"sh-code\" style=\"background:\(Palette.codeBg);border-radius:4px;padding:1px 5px;font-size:12.5px;\">",
                           close: "</code>")
        return out
    }

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    /// Rewrites balanced `marker`-delimited spans. An unpaired trailing marker is
    /// left as text — agent output is full of stray backticks and asterisks, and
    /// swallowing the rest of the mail over one of them is the worse failure.
    private static func replacePairs(in text: String, marker: String, open: String, close: String) -> String {
        let segments = text.components(separatedBy: marker)
        guard segments.count > 2 else { return text }
        var out = segments[0]
        var index = 1
        while index < segments.count {
            // A pair needs both halves; without a closing marker, put it back.
            if index + 1 < segments.count {
                out += open + segments[index] + close + segments[index + 1]
                index += 2
            } else {
                out += marker + segments[index]
                index += 1
            }
        }
        return out
    }
}
