//! The light markdown the adapter writes (`**bold**`, `` `code` ``, fenced
//! blocks, a line of `_italic_`) turned into what Telegram renders, and cut
//! to size.
//!
//! Telegram's HTML flavour rather than MarkdownV2: MarkdownV2 wants every
//! `.`, `-`, `(` and a dozen more escaped, which agent output is made of.
//! HTML needs three entities and is otherwise literal.

use std::sync::OnceLock;

use regex::Regex;

/// The Bot API's limit per message, in characters after entities are parsed.
/// Counting the marked-up text over-counts, so a cut is always safe.
pub const MAX_MESSAGE_LENGTH: usize = 4096;

pub fn escape_html(s: &str) -> String {
    s.replace('&', "&amp;").replace('<', "&lt;").replace('>', "&gt;")
}

/// Fenced blocks become `<pre>`; in prose `**x**` is bold, `` `x` `` code,
/// and a line that is all `_x_` italic. Inline marks never span a newline,
/// so `chunk` can cut at any line.
pub fn html(markdown: &str) -> String {
    let mut out = String::new();
    for (i, segment) in markdown.split("```").enumerate() {
        if i % 2 == 1 {
            out.push_str("<pre>");
            out.push_str(&escape_html(strip_fence_language(segment)));
            out.push_str("</pre>");
        } else {
            out.push_str(&inline(&escape_html(segment)));
        }
    }
    out
}

/// The plain text an HTML message renders as: what a chunk is resent as
/// after Telegram refuses its HTML, so the fallback says the same words.
pub fn strip_html(html: &str) -> String {
    static TAG: OnceLock<Regex> = OnceLock::new();
    let tag = TAG.get_or_init(|| Regex::new(r"<[^>]+>").expect("regex"));
    tag.replace_all(html, "").replace("&lt;", "<").replace("&gt;", ">").replace("&amp;", "&")
}

fn inline(s: &str) -> String {
    static BOLD: OnceLock<Regex> = OnceLock::new();
    static CODE: OnceLock<Regex> = OnceLock::new();
    static ITALIC: OnceLock<Regex> = OnceLock::new();
    let bold = BOLD.get_or_init(|| Regex::new(r"\*\*([^\n*]+?)\*\*").expect("regex"));
    let code = CODE.get_or_init(|| Regex::new(r"`([^`\n]+?)`").expect("regex"));
    let italic = ITALIC.get_or_init(|| Regex::new(r"(?m)^_([^\n_][^\n]*?)_$").expect("regex"));
    let s = bold.replace_all(s, "<b>$1</b>");
    let s = code.replace_all(&s, "<code>$1</code>");
    italic.replace_all(&s, "<i>$1</i>").into_owned()
}

/// ```` ```rust ```` puts the language on the first line; drop it and the
/// newline after it.
fn strip_fence_language(block: &str) -> &str {
    let Some((head, rest)) = block.split_once('\n') else { return block };
    let is_language = !head.is_empty() && head.chars().all(|c| c.is_alphanumeric() || c == '-' || c == '+');
    if is_language {
        rest
    } else {
        block
    }
}

/// Split at line boundaries so no message exceeds `limit` characters. A
/// `<pre>` open at a cut is closed and reopened, so each chunk parses on its
/// own; a single line longer than the limit is cut hard.
pub fn chunk(text: &str, limit: usize) -> Vec<String> {
    if text.chars().count() <= limit {
        return vec![text.to_string()];
    }
    let overhead = "<pre></pre>".len() + 1;
    let budget = limit.saturating_sub(overhead).max(16);
    let mut chunks = Vec::new();
    let mut current = String::new();
    let mut in_pre = false;

    let mut lines: std::collections::VecDeque<String> = text.split('\n').map(str::to_string).collect();
    while let Some(mut line) = lines.pop_front() {
        if line.chars().count() > budget {
            let split: usize = line.char_indices().nth(budget).map(|(i, _)| i).unwrap_or(line.len());
            let tail = line.split_off(split);
            lines.push_front(tail);
        }
        let joiner = if current.is_empty() || current == "<pre>" { "" } else { "\n" };
        let candidate_len = current.chars().count() + joiner.len() + line.chars().count();
        if candidate_len > budget {
            if !current.is_empty() && current != "<pre>" {
                chunks.push(if in_pre { format!("{current}</pre>") } else { current.clone() });
                current = if in_pre { "<pre>".into() } else { String::new() };
            }
            current.push_str(&line);
        } else {
            current.push_str(joiner);
            current.push_str(&line);
        }
        in_pre = pre_state_after(&line, in_pre);
    }
    if !current.is_empty() && current != "<pre>" {
        chunks.push(current);
    }
    chunks
}

/// Whether a `<pre>` is open once this line has been written.
fn pre_state_after(line: &str, open: bool) -> bool {
    match (line.rfind("<pre>"), line.rfind("</pre>")) {
        (None, None) => open,
        (Some(_), None) => true,
        (None, Some(_)) => false,
        (Some(o), Some(c)) => o > c,
    }
}

/// A button label fit for a phone: one line, the front kept (where an option
/// says what it does), cut on a whole character.
pub fn trim_label(label: &str, limit: usize) -> String {
    let flat = label.replace('\n', " ");
    let flat = flat.trim();
    if flat.chars().count() <= limit {
        return flat.to_string();
    }
    flat.chars().take(limit - 1).collect::<String>() + "\u{2026}"
}

/// One line of at most `limit` characters.
pub fn truncated(text: &str, limit: usize) -> String {
    let flat = text.lines().collect::<Vec<_>>().join(" ");
    if flat.chars().count() <= limit {
        flat
    } else {
        flat.chars().take(limit - 1).collect::<String>() + "…"
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn renders_light_markdown() {
        assert_eq!(html("**done** in `a<b>` & more"), "<b>done</b> in <code>a&lt;b&gt;</code> &amp; more");
        assert_eq!(html("_quiet_\nnext"), "<i>quiet</i>\nnext");
        assert_eq!(html("see\n```rust\nlet x = 1 < 2;\n```\nend"), "see\n<pre>let x = 1 &lt; 2;\n</pre>\nend");
        // A fence whose first line is code, not a language, keeps it.
        assert_eq!(html("```\nfoo bar\n```"), "<pre>\nfoo bar\n</pre>");
        // Inline marks never cross a newline.
        assert_eq!(html("**a\nb**"), "**a\nb**");
    }

    #[test]
    fn strips_back_to_the_same_words() {
        let h = html("**x** <y> & `z`");
        assert_eq!(strip_html(&h), "x <y> & z");
    }

    #[test]
    fn short_text_is_one_chunk() {
        assert_eq!(chunk("hello", 4096), vec!["hello"]);
    }

    #[test]
    fn chunks_on_lines_and_reopens_pre() {
        let body: Vec<String> = (0..40).map(|i| format!("line {i:02} xxxxxxxxxx")).collect();
        let text = format!("<pre>{}</pre>", body.join("\n"));
        let chunks = chunk(&text, 120);
        assert!(chunks.len() > 1);
        for c in &chunks {
            assert!(c.chars().count() <= 120, "{c}");
            assert_eq!(c.matches("<pre>").count(), c.matches("</pre>").count(), "{c}");
        }
        let rejoined: String = chunks.iter().map(|c| c.replace("<pre>", "").replace("</pre>", "")).collect::<Vec<_>>().join("\n");
        assert_eq!(rejoined, body.join("\n"));
    }

    #[test]
    fn cuts_an_overlong_line_hard() {
        let line = "é".repeat(300);
        let chunks = chunk(&line, 100);
        assert!(chunks.iter().all(|c| c.chars().count() <= 100));
        assert_eq!(chunks.concat(), line);
    }

    #[test]
    fn labels_and_truncation() {
        assert_eq!(trim_label(" a\nb ", 48), "a b");
        assert_eq!(trim_label(&"x".repeat(60), 48).chars().count(), 48);
        assert_eq!(truncated("a\nb", 10), "a b");
        assert_eq!(truncated("abcdef", 4), "abc…");
    }
}
