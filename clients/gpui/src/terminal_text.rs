//! Text the terminal pane works out from what it shows or is handed: the
//! link under the pointer, and what dropping files types.

/// The URL that covers column `col` of a row, given the row's cells' text
/// (one entry per column; a wide character's spacer is empty). A URL that
/// fills the row to its last column is continued from `next`, the row
/// below, as a soft-wrapped one would be.
pub fn url_at(cells: &[String], col: usize, next: Option<&[String]>) -> Option<String> {
    // The row as text, and for each char the column it came from.
    let mut text = String::new();
    let mut cols = Vec::new();
    for (c, cell) in cells.iter().enumerate() {
        let s = if cell.is_empty() { " " } else { cell.as_str() };
        // A wide character's spacer adds nothing of its own.
        if cell.is_empty() && c > 0 && cells[c - 1].chars().count() == 1 && is_wide(&cells[c - 1]) {
            continue;
        }
        for ch in s.chars() {
            text.push(ch);
            cols.push(c);
        }
    }
    let chars: Vec<char> = text.chars().collect();
    let at = cols.iter().position(|c| *c >= col)?;
    for (start, end) in url_spans(&chars) {
        if start <= at && at < end {
            let mut url: String = chars[start..end].iter().collect();
            // Filled to the edge: the rest is on the next row.
            if end == chars.len() && cols.last().is_some_and(|c| *c + 1 >= cells.len()) {
                if let Some(next) = next {
                    let more: String = next.iter().map(|c| if c.is_empty() { " " } else { c.as_str() }).collect();
                    let more: String = more.chars().take_while(|c| is_url_char(*c)).collect();
                    url.push_str(&more);
                }
            }
            return Some(trim_url(&url));
        }
    }
    None
}

fn is_wide(s: &str) -> bool {
    s.chars().next().is_some_and(|c| {
        let u = c as u32;
        (0x1100..=0x115F).contains(&u) || (0x2E80..=0xA4CF).contains(&u) || (0xAC00..=0xD7A3).contains(&u) || (0xF900..=0xFAFF).contains(&u)
            || (0xFE30..=0xFE4F).contains(&u) || (0xFF00..=0xFF60).contains(&u) || (0xFFE0..=0xFFE6).contains(&u) || (0x1F300..=0x1FAFF).contains(&u)
    })
}

fn is_url_char(c: char) -> bool {
    c.is_ascii_alphanumeric() || "-._~:/?#[]@!$&'()*+,;=%".contains(c)
}

/// Where `http://`, `https://` and `file://` URLs run in the text.
fn url_spans(chars: &[char]) -> Vec<(usize, usize)> {
    let mut out = Vec::new();
    let mut from = 0;
    while from < chars.len() {
        let rest: String = chars[from..].iter().collect();
        let hit = ["https://", "http://", "file://"].iter().filter_map(|s| rest.find(s)).min();
        let Some(byte) = hit else { break };
        let start = from + rest[..byte].chars().count();
        let mut end = start;
        while end < chars.len() && is_url_char(chars[end]) {
            end += 1;
        }
        out.push((start, end));
        from = end.max(start + 1);
    }
    out
}

/// Punctuation that ends a sentence rather than the URL, and a closing
/// bracket the URL never opened.
fn trim_url(url: &str) -> String {
    let mut u = url.to_string();
    while let Some(last) = u.chars().last() {
        let unbalanced = |open: char, close: char| last == close && u.matches(open).count() < u.matches(close).count();
        if ".,;:!?'\"".contains(last) || unbalanced('(', ')') || unbalanced('[', ']') {
            u.pop();
        } else {
            break;
        }
    }
    u
}

/// What dropping `paths` on a pane types: each path escaped for the shell,
/// separated and followed by a space (as Ghostty does, so the next word
/// can follow). Backslash escapes on Unix; double quotes where needed on
/// Windows.
pub fn drop_text(paths: &[std::path::PathBuf], windows: bool) -> String {
    let mut out = String::new();
    for p in paths {
        let s = p.to_string_lossy();
        if windows {
            if s.contains(' ') || s.contains('&') || s.contains('(') || s.contains(')') {
                out.push('"');
                out.push_str(&s);
                out.push('"');
            } else {
                out.push_str(&s);
            }
        } else {
            for ch in s.chars() {
                if " \\'\"()[]{}&;|<>*?$`!#~=".contains(ch) {
                    out.push('\\');
                }
                out.push(ch);
            }
        }
        out.push(' ');
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::PathBuf;

    fn cells(s: &str) -> Vec<String> {
        s.chars().map(|c| if c == ' ' { String::new() } else { c.to_string() }).collect()
    }

    #[test]
    fn finds_the_url_under_a_column() {
        let row = cells("see https://example.com/a?b=1, then more");
        assert_eq!(url_at(&row, 10, None).as_deref(), Some("https://example.com/a?b=1"));
        assert_eq!(url_at(&row, 1, None), None);
        assert_eq!(url_at(&row, 35, None), None);
    }

    #[test]
    fn trims_sentence_punctuation_and_unopened_brackets() {
        let row = cells("(docs at https://x.dev/p_(1)).");
        assert_eq!(url_at(&row, 12, None).as_deref(), Some("https://x.dev/p_(1)"));
    }

    #[test]
    fn a_url_at_the_edge_continues_on_the_next_row() {
        let row = cells("go https://example.com/long/pa");
        let next = cells("th/to/page and more");
        assert_eq!(url_at(&row, 5, Some(&next)).as_deref(), Some("https://example.com/long/path/to/page"));
    }

    #[test]
    fn wide_characters_keep_columns_aligned() {
        // "链接" takes four columns: two cells and their spacers.
        let mut row: Vec<String> = vec!["链".into(), String::new(), "接".into(), String::new(), String::new()];
        row.extend(cells("http://a.b/c"));
        assert_eq!(url_at(&row, 6, None).as_deref(), Some("http://a.b/c"));
    }

    #[test]
    fn dropped_paths_are_escaped_for_the_shell() {
        let p = vec![PathBuf::from("/tmp/my file (1).png"), PathBuf::from("/tmp/a.txt")];
        assert_eq!(drop_text(&p, false), "/tmp/my\\ file\\ \\(1\\).png /tmp/a.txt ");
        let w = vec![PathBuf::from(r"C:\Users\me\My File.txt"), PathBuf::from(r"C:\a.txt")];
        assert_eq!(drop_text(&w, true), "\"C:\\Users\\me\\My File.txt\" C:\\a.txt ");
    }
}
