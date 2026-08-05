import Foundation

/// The one page the loopback OAuth listener ever serves: the "you're done, go
/// back to the app" screen Google redirects to after consent.
///
/// It has to be a single self-contained response. The listener answers exactly
/// one request and `finish()` tears it down immediately after, so there is no
/// second round-trip available for a stylesheet, a webfont, or even a favicon —
/// hence the inline `<style>` and the data-URI icon. Colours mirror
/// `SemanticColors` so the tab reads as Seahelm rather than as a stray local
/// web server.
enum GmailOAuthCallbackPage {
    static func httpResponse(succeeded: Bool) -> Data {
        let body = html(succeeded: succeeded)
        let headers = [
            "HTTP/1.1 200 OK",
            "Content-Type: text/html; charset=utf-8",
            // Byte count, not character count — the page is ASCII today, but a
            // Content-Length in characters would truncate it the moment it isn't.
            "Content-Length: \(body.utf8.count)",
            // The request URL carries the authorization code, so keep the
            // rendered page out of every cache.
            "Cache-Control: no-store",
            "Connection: close",
        ].joined(separator: "\r\n")
        return Data("\(headers)\r\n\r\n\(body)".utf8)
    }

    static func html(succeeded: Bool) -> String {
        let mark = succeeded ? "var(--accent)" : "var(--danger)"
        let icon = succeeded
            ? #"<path d="M5 12.6l4.7 4.7L19 7.6"/>"#
            : #"<path d="M7.4 7.4l9.2 9.2M16.6 7.4l-9.2 9.2"/>"#
        // Roughly the path length, so the stroke draws itself in one pass.
        let dash = succeeded ? 23 : 26
        let heading = succeeded ? "Gmail connected" : "Authorization failed"
        let detail = succeeded
            ? "Seahelm can now read and send mail for this account."
            : "Google did not return a valid authorization."
        let hint = succeeded
            ? "You can close this tab and return to Seahelm."
            : "You can close this tab and try again from Seahelm."

        return """
        <!doctype html>
        <html lang="en">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width,initial-scale=1">
        <meta name="color-scheme" content="light dark">
        <title>Seahelm</title>
        <link rel="icon" href="data:image/svg+xml,<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 100 100'><g fill='none' stroke='rgb(31,200,218)' stroke-width='8' stroke-linecap='round'><circle cx='50' cy='50' r='28'/><circle cx='50' cy='50' r='8'/><path d='M50 4V22M50 78v18M4 50h18M78 50h18'/></g></svg>">
        <style>
          :root {
            --bg1: #0d2f39; --bg2: #08222a;
            --panel: rgba(14, 45, 55, .93);
            --line: rgba(150, 215, 225, .20);
            --text: #cfe0e0; --muted: #7fa0a3;
            --accent: #1fc8da; --danger: #e84635;
            --shadow: 0 24px 64px rgba(0, 0, 0, .46);
            --helm-opacity: .05;
          }
          @media (prefers-color-scheme: light) {
            :root {
              --bg1: #f4f9ff; --bg2: #e3ecf8;
              --panel: rgba(255, 255, 255, .95);
              --line: #d3dde8;
              --text: #1f232b; --muted: #636b78;
              --accent: #0e9bb5; --danger: #dc2626;
              --shadow: 0 20px 52px rgba(31, 58, 82, .14);
              /* Pale cyan on a near-white field needs more weight than the
                 same mark does against the dark navy. */
              --helm-opacity: .06;
            }
          }
          * { box-sizing: border-box; }
          html, body { height: 100%; }
          body {
            margin: 0;
            display: grid;
            place-items: center;
            padding: 24px;
            background:
              radial-gradient(1100px 620px at 50% -10%, var(--bg1), transparent 68%),
              var(--bg2);
            color: var(--text);
            font: 400 15px/1.55 -apple-system, BlinkMacSystemFont, "SF Pro Text", "Helvetica Neue", sans-serif;
            -webkit-font-smoothing: antialiased;
          }
          /* Ship's wheel — the app's namesake, kept at watermark strength so it
             sets the scene without competing with the message. Sized so the rim
             clears the card: any smaller and the card covers the rim and hub,
             leaving eight disconnected spokes that read as an artifact. */
          .helm {
            position: fixed;
            inset: 0;
            margin: auto;
            width: min(880px, 132vw);
            aspect-ratio: 1;
            color: var(--accent);
            opacity: var(--helm-opacity);
            pointer-events: none;
            animation: turn 90s linear infinite;
          }
          @keyframes turn { to { transform: rotate(360deg); } }
          .card {
            position: relative;
            width: min(420px, 100%);
            padding: 44px 40px 36px;
            text-align: center;
            background: var(--panel);
            border: 1px solid var(--line);
            border-radius: 16px;
            box-shadow: var(--shadow);
            -webkit-backdrop-filter: blur(18px);
            backdrop-filter: blur(18px);
            animation: rise .45s cubic-bezier(.2, .7, .3, 1) both;
          }
          @keyframes rise {
            from { opacity: 0; transform: translateY(10px); }
            to   { opacity: 1; transform: none; }
          }
          .badge {
            width: 58px; height: 58px;
            margin: 0 auto 22px;
            display: grid;
            place-items: center;
            color: \(mark);
            border-radius: 50%;
            background: color-mix(in srgb, currentColor 12%, transparent);
            box-shadow: 0 0 0 1px color-mix(in srgb, currentColor 26%, transparent),
                        0 0 34px -10px currentColor;
          }
          .badge svg { width: 27px; height: 27px; }
          .badge path {
            fill: none;
            stroke: currentColor;
            stroke-width: 2.4;
            stroke-linecap: round;
            stroke-linejoin: round;
            stroke-dasharray: \(dash);
            stroke-dashoffset: \(dash);
            animation: draw .55s cubic-bezier(.4, .8, .3, 1) .18s forwards;
          }
          @keyframes draw { to { stroke-dashoffset: 0; } }
          h1 {
            margin: 0 0 8px;
            font-size: 19px;
            font-weight: 600;
            letter-spacing: -.01em;
          }
          p { margin: 0; color: var(--muted); font-size: 14px; }
          .hint {
            margin-top: 26px;
            padding-top: 18px;
            border-top: 1px solid var(--line);
            color: var(--muted);
            font-size: 12.5px;
          }
          .wordmark {
            display: inline-flex;
            align-items: center;
            gap: 7px;
            margin-bottom: 20px;
            color: var(--muted);
            font-size: 11.5px;
            font-weight: 600;
            letter-spacing: .13em;
            text-transform: uppercase;
          }
          .wordmark svg { width: 15px; height: 15px; color: var(--accent); }
          @media (prefers-reduced-motion: reduce) {
            * { animation: none !important; }
            .badge path { stroke-dashoffset: 0; }
          }
        </style>
        </head>
        <body>
          <svg class="helm" viewBox="0 0 100 100" aria-hidden="true">
            <g fill="none" stroke="currentColor" stroke-width="2.4" stroke-linecap="round">
              <circle cx="50" cy="50" r="30"/>
              <circle cx="50" cy="50" r="9"/>
              <path d="M62 50h31M58.5 58.5l21.9 21.9M50 62v31M41.5 58.5L19.6 80.4M38 50H7M41.5 41.5L19.6 19.6M50 38V7M58.5 41.5L80.4 19.6"/>
            </g>
          </svg>
          <main class="card">
            <div class="wordmark">
              <svg viewBox="0 0 100 100" aria-hidden="true">
                <!-- No hub: at 15px a filled centre is a blob, not a wheel. -->
                <g fill="none" stroke="currentColor" stroke-width="8" stroke-linecap="round">
                  <circle cx="50" cy="50" r="26"/>
                  <path d="M50 6V20M50 80v14M6 50h14M80 50h14"/>
                </g>
              </svg>
              Seahelm
            </div>
            <div class="badge">
              <svg viewBox="0 0 24 24" aria-hidden="true">\(icon)</svg>
            </div>
            <h1>\(heading)</h1>
            <p>\(detail)</p>
            <div class="hint">\(hint)</div>
          </main>
        </body>
        </html>
        """
    }
}
