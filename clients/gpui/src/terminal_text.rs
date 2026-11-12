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

/// The path-like word at column `col` of a row (one entry per column, a
/// wide character's spacer empty): the run of non-blank characters around
/// it, without the brackets and quotes prose puts round a path, and without
/// a `:line` or `:line:col` suffix.
pub fn token_at(cells: &[String], col: usize) -> Option<String> {
    let text: Vec<char> = cells.iter().map(|c| c.chars().next().unwrap_or(' ')).collect();
    let blank = |c: char| c.is_whitespace();
    if col >= text.len() || blank(text[col]) {
        return None;
    }
    let mut a = col;
    while a > 0 && !blank(text[a - 1]) {
        a -= 1;
    }
    let mut b = col + 1;
    while b < text.len() && !blank(text[b]) {
        b += 1;
    }
    let word: String = text[a..b].iter().collect();
    let frame: &[char] = &['"', '\'', '`', '(', ')', '[', ']', '<', '>', '{', '}', ',', ';'];
    // Brackets and quotes, and a sentence's full stop, in any order.
    let mut word = word;
    loop {
        let trimmed = word.trim_matches(frame).trim_end_matches(['.', ':']).to_string();
        if trimmed == word {
            break;
        }
        word = trimmed;
    }
    // file.rs:12 or file.rs:12:3
    for _ in 0..2 {
        if let Some((head, tail)) = word.rsplit_once(':') {
            if !tail.is_empty() && tail.chars().all(|c| c.is_ascii_digit()) {
                word = head.to_string();
            }
        }
    }
    (!word.is_empty()).then_some(word)
}

/// An agent's `::seahelm-suggest:: a | b` line, as its suggestion card
/// becomes clickable on it (the macOS app's `SuggestLineLocator`).
pub const SUGGEST_MARKER: &str = "::seahelm-suggest::";

/// A row as text, and for each char the columns it covers.
pub struct RowText {
    chars: Vec<char>,
    cols: Vec<usize>,
    ends: Vec<usize>,
}

impl RowText {
    /// From a row's cells: (text, wide) per column; a wide character's
    /// tail is `None`, a blank cell empty text.
    pub fn from_cells<'a>(cells: impl IntoIterator<Item = Option<(&'a str, bool)>>) -> RowText {
        let mut row = RowText { chars: Vec::new(), cols: Vec::new(), ends: Vec::new() };
        for (c, cell) in cells.into_iter().enumerate() {
            let Some((text, wide)) = cell else { continue };
            let text = if text.is_empty() { " " } else { text };
            for ch in text.chars() {
                row.chars.push(ch);
                row.cols.push(c);
                row.ends.push(c + if wide { 2 } else { 1 });
            }
        }
        row
    }

    pub fn contains_marker(&self) -> bool {
        let m: Vec<char> = SUGGEST_MARKER.chars().collect();
        find(&self.chars, &m, 0).is_some()
    }
}

/// Columns on screen: `row`, from `col`, `width` columns wide.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Span {
    pub row: usize,
    pub col: usize,
    pub width: usize,
}

/// The marker and each option of the card on the lowest line that says
/// exactly what the card says: every option in order, one `|` between
/// them, nothing after the last, following a hard wrap up to 3 rows.
/// Anything else (an older line, other options, an option cut by a wrap)
/// gets nothing.
pub fn locate_suggestion(options: &[String], rows: &[RowText]) -> Option<(Span, Vec<Span>)> {
    if options.is_empty() || options.iter().any(|o| o.is_empty()) {
        return None;
    }
    let marker: Vec<char> = SUGGEST_MARKER.chars().collect();
    for r in (0..rows.len()).rev() {
        if let Some(at) = find(&rows[r].chars, &marker, 0) {
            if let Some(spans) = place(options, rows, r, at + marker.len()) {
                return Some((span(&rows[r], r, at, at + marker.len()), spans));
            }
        }
    }
    None
}

fn place(options: &[String], rows: &[RowText], marker_row: usize, after: usize) -> Option<Vec<Span>> {
    let last = (marker_row + 3).min(rows.len() - 1);
    let (mut row, mut cursor) = (marker_row, after);
    let mut spans = Vec::new();
    for (i, option) in options.iter().enumerate() {
        let want = usize::from(i > 0);
        let option: Vec<char> = option.chars().collect();
        let mut seen = 0;
        loop {
            let line = &rows[row].chars;
            if let Some(hit) = find(line, &option, cursor) {
                if bars(&line[cursor..hit]).is_some_and(|g| seen + g == want) {
                    spans.push(span(&rows[row], row, hit, hit + option.len()));
                    cursor = hit + option.len();
                    break;
                }
            }
            let gap = bars(&line[cursor.min(line.len())..])?;
            if seen + gap > want || row >= last {
                return None;
            }
            seen += gap;
            row += 1;
            cursor = 0;
        }
    }
    rows[row].chars[cursor..].iter().all(|c| c.is_whitespace()).then_some(spans)
}

fn span(row: &RowText, r: usize, from: usize, to: usize) -> Span {
    Span { row: r, col: row.cols[from], width: row.ends[to - 1] - row.cols[from] }
}

/// How many `|` a stretch of separator holds; None if it holds anything else.
fn bars(s: &[char]) -> Option<usize> {
    s.iter().all(|c| c.is_whitespace() || *c == '|').then(|| s.iter().filter(|c| **c == '|').count())
}

fn find(hay: &[char], needle: &[char], from: usize) -> Option<usize> {
    if needle.is_empty() || hay.len() < needle.len() {
        return None;
    }
    (from..=hay.len() - needle.len()).find(|&i| hay[i..i + needle.len()] == *needle)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn rows(lines: &[&str]) -> Vec<RowText> {
        lines
            .iter()
            .map(|l| {
                let mut cells = Vec::new();
                for ch in l.chars() {
                    let wide = ch as u32 >= 0x2E80;
                    cells.push(Some((ch.to_string(), wide)));
                    if wide {
                        cells.push(None);
                    }
                }
                RowText::from_cells(cells.iter().map(|c| c.as_ref().map(|(t, w)| (t.as_str(), *w))))
            })
            .collect()
    }

    fn opts(o: &[&str]) -> Vec<String> {
        o.iter().map(|s| s.to_string()).collect()
    }

    #[test]
    fn the_word_under_the_pointer_is_a_path_without_its_frame() {
        let cells = |s: &str| s.chars().map(|c| c.to_string()).collect::<Vec<_>>();
        let row = cells("see (src/main.rs:12:3), then `docs/a.md`.");
        assert_eq!(token_at(&row, 8).as_deref(), Some("src/main.rs"));
        assert_eq!(token_at(&row, 30).as_deref(), Some("docs/a.md"));
        assert_eq!(token_at(&row, 3), None, "a blank");
    }

    #[test]
    fn a_suggest_line_is_found_in_columns_on_the_lowest_match() {
        let r = rows(&["  ::seahelm-suggest:: old | other", "", "  ::seahelm-suggest:: 做原型 | Ship it", ""]);
        let (marker, spans) = locate_suggestion(&opts(&["做原型", "Ship it"]), &r).unwrap();
        assert_eq!(marker, Span { row: 2, col: 2, width: 19 });
        assert_eq!(spans, vec![Span { row: 2, col: 22, width: 6 }, Span { row: 2, col: 31, width: 7 }]);
    }

    #[test]
    fn a_wrapped_suggest_line_is_followed() {
        let r = rows(&["::seahelm-suggest:: merge it |", "  run the tests"]);
        let (_, spans) = locate_suggestion(&opts(&["merge it", "run the tests"]), &r).unwrap();
        assert_eq!(spans, vec![Span { row: 0, col: 20, width: 8 }, Span { row: 1, col: 2, width: 13 }]);
    }

    #[test]
    fn a_line_that_differs_from_the_card_gets_nothing() {
        for line in ["::seahelm-suggest:: a | b | c", "::seahelm-suggest:: b | a", "::seahelm-suggest:: a b", "::seahelm-suggest:: x a | b", "::seahelm-suggest:: a || b", "a | b"] {
            assert!(locate_suggestion(&opts(&["a", "b"]), &rows(&[line])).is_none(), "{line}");
        }
        assert!(locate_suggestion(&opts(&["merge it"]), &rows(&["::seahelm-suggest:: mer", "ge it"])).is_none());
    }
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
