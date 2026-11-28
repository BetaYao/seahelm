//! The choices of an approval prompt drawn on screen.
//!
//! Ported from `ChoiceOptionParser.swift`. Claude's permission prompt,
//! Codex's approval dialog and Claude's AskUserQuestion box all render as a
//! consecutive numbered list near the bottom:
//!
//! ```text
//! Do you want to proceed?
//! ❯ 1. Yes
//!   2. Yes, and don't ask again for bash commands
//!   3. No, and tell Claude what to do differently
//! ```
//!
//! A pane showing one is waiting on the user whatever the text rules made of
//! it, and its options become a question card.

use std::sync::OnceLock;

use regex::Regex;

use crate::manifest::trim_ws;

/// How far up from the bottom a dialog is looked for.
pub const DEFAULT_BOTTOM_LINES: usize = 25;

/// Lines of text a picker may draw between its list and its footer and still
/// be live: Claude Code's `/model` puts a "↓ 4 more" row, its effort control
/// and a tip there.
const MENU_FOOTER_GAP: usize = 6;

/// One numbered choice.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ChoiceOption {
    /// 1-based: the number key that selects it.
    pub index: usize,
    pub label: String,
    /// The `❯`/`›` cursor is on this row.
    pub selected: bool,
}

fn line_pattern() -> &'static Regex {
    static R: OnceLock<Regex> = OnceLock::new();
    // Cursor markers: ❯ (U+276F), › (U+203A), >, •, *.
    R.get_or_init(|| Regex::new(r"^\s*([❯›>•*]?)\s*(\d+)\.\s+(.+?)\s*$").expect("choice regex"))
}

/// The last `bottom_lines` lines with text below them, so a fresh pane whose
/// TUI fills only the top of the screen is read where its dialog is.
fn bottom(screen: &str, bottom_lines: usize) -> impl Iterator<Item = &str> {
    let mut lines: Vec<&str> = screen.split('\n').collect();
    while lines.last().is_some_and(|l| trim_ws(l).is_empty()) {
        lines.pop();
    }
    let skip = lines.len().saturating_sub(bottom_lines);
    lines.into_iter().skip(skip)
}

/// The last numbered choice list in the bottom `bottom_lines` of the screen.
///
/// Empty unless there are at least two options numbered consecutively from 1
/// with a cursor on one of them (stray "1. foo" prose is not a dialog).
/// Wrapped labels are joined; a footer after the list ends it without
/// discarding it; real output after a finished list makes it stale.
pub fn parse(screen: &str, bottom_lines: usize) -> Vec<ChoiceOption> {
    let mut current: Vec<ChoiceOption> = Vec::new();
    let mut last_valid: Vec<ChoiceOption> = Vec::new();
    let mut continuation_column = usize::MAX;
    // Lines of real content since the last finished list. Any makes that list
    // stale, unless a picker's footer follows them closely.
    let mut since_list = 0usize;

    fn finish(current: &mut Vec<ChoiceOption>, last_valid: &mut Vec<ChoiceOption>, column: &mut usize, since: &mut usize) {
        if current.len() >= 2 && current.iter().any(|o| o.selected) {
            *last_valid = std::mem::take(current);
            *since = 0;
        }
        current.clear();
        *column = usize::MAX;
    }

    for s in bottom(screen, bottom_lines) {
        if let Some(caps) = line_pattern().captures(s) {
            if let Ok(idx) = caps[2].parse::<usize>() {
                if idx == 1 {
                    finish(&mut current, &mut last_valid, &mut continuation_column, &mut since_list);
                }
                if idx != current.len() + 1 {
                    finish(&mut current, &mut last_valid, &mut continuation_column, &mut since_list);
                    continue;
                }
                let label = caps.get(3).expect("group 3");
                current.push(ChoiceOption { index: idx, label: label.as_str().to_string(), selected: !caps[1].is_empty() });
                continuation_column = s[..label.start()].chars().count();
                continue;
            }
        }

        let trimmed = trim_ws(s);
        if current.is_empty() {
            // Only harmless chrome may trail a completed run. Any real content
            // means an older list in the viewport is stale — unless it is a
            // picker's own text, which its footer closes.
            if trimmed.is_empty() {
                continue;
            }
            if is_menu_footer(trimmed) && since_list <= MENU_FOOTER_GAP {
                since_list = 0;
            } else if !is_trailing_chrome(trimmed) {
                since_list += 1;
            }
            continue;
        }
        let leading = s.chars().take_while(|&c| c == ' ' || c == '\t').count();
        if !trimmed.is_empty() && leading >= continuation_column {
            if let Some(previous) = current.last_mut() {
                previous.label = format!("{} {}", previous.label, trimmed);
            }
        } else {
            // A footer (Codex's "Press enter to confirm") ends the list but
            // must not discard the options above it.
            finish(&mut current, &mut last_valid, &mut continuation_column, &mut since_list);
        }
    }
    finish(&mut current, &mut last_valid, &mut continuation_column, &mut since_list);
    if since_list > 0 {
        last_valid.clear();
    }
    if last_valid.is_empty() {
        let menu = unnumbered(screen, bottom_lines);
        if !menu.is_empty() {
            return menu;
        }
        return checklist(screen).map(|c| c.options).unwrap_or_default();
    }
    last_valid
}

/// A line drawn inside a box (`│ … │`) with its frame taken off, and the
/// box's own top and bottom edges as blank lines. Cursor Agent draws its
/// questions in a box; anything else is returned as it is.
pub fn unbox_line(line: &str) -> &str {
    let t = trim_ws(line);
    if t.starts_with(['┌', '╭', '└', '╰']) && t.ends_with(['┐', '╮', '┘', '╯']) {
        return "";
    }
    match line.trim_start().strip_prefix('│').map(str::trim_end).and_then(|inner| inner.strip_suffix('│')) {
        Some(inner) => inner,
        None => line,
    }
}

/// A question Cursor Agent asks (its AskQuestion tool), drawn in a box:
///
/// ```text
/// ┌──────────────────────────────────────────────┐
/// │ Pick the CLIs to add                         │
/// │                                              │
/// │ Question 1 of 1                              │
/// │                                              │
/// │ 1. Which first? (multi-select)               │
/// │                                              │
/// │   › [ ] session: list and read sessions,     │
/// │         send messages                        │
/// │     [x] knowledge: search the knowledge base │
/// │     [ ] Other: (type to answer)              │
/// │                                              │
/// │ ↑/↓ option · ←/→ question · Space select ·   │
/// │ Enter next/submit · Esc to skip              │
/// └──────────────────────────────────────────────┘
/// ```
///
/// Every row is a checkbox, single choice or not. Return takes the row under
/// the cursor (in a multi-select it only ever adds it) and goes on to the
/// next question or submits; Space ticks and unticks.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Checklist {
    /// The box's heading.
    pub title: String,
    /// The question, without its number and "(multi-select)".
    pub prompt: String,
    pub multi: bool,
    /// The rows a card offers, cursor marked; the free-text "Other:" row is
    /// left out, since a button cannot type its answer.
    pub options: Vec<ChoiceOption>,
    /// Rows ticked (0-based).
    pub checked: Vec<usize>,
    /// The row the cursor is on (0-based), "Other:" counted.
    pub cursor: usize,
}

fn checkbox_pattern() -> &'static Regex {
    static R: OnceLock<Regex> = OnceLock::new();
    R.get_or_init(|| Regex::new(r"^(\s*)(›\s*)?\[([ xX✓])\]\s+(.*?)\s*$").expect("checkbox regex"))
}

/// Either half of the footer under Cursor Agent's question, which wraps
/// between them in a narrow pane.
fn is_checklist_footer(text: &str) -> bool {
    let lower = text.to_lowercase();
    lower.contains("space select") || lower.contains("enter next/submit")
}

/// The Cursor Agent question at the bottom of the screen, if one is up.
pub fn checklist(screen: &str) -> Option<Checklist> {
    let lines: Vec<&str> = screen.split('\n').map(unbox_line).collect();
    let last = lines.iter().rposition(|l| is_checklist_footer(l))?;
    // The box must be what the screen ends with: after its footer, nothing
    // but the footer's wrapped end and the box's bottom edge.
    if lines[last + 1..].iter().filter(|l| !trim_ws(l).is_empty()).count() > 2 {
        return None;
    }
    let mut footer = last;
    while footer > 0 && is_checklist_footer(lines[footer - 1]) {
        footer -= 1;
    }
    // The rows above the footer, with the wrapped parts of their labels.
    let mut start = None;
    let mut column = usize::MAX;
    for at in (footer.saturating_sub(80)..footer).rev() {
        let l = lines[at];
        if trim_ws(l).is_empty() {
            continue;
        }
        if let Some(c) = checkbox_pattern().captures(l) {
            column = column.min(l[..c.get(4).expect("group 4").start()].chars().count());
            start = Some(at);
            continue;
        }
        // A wrapped label's rest: as deep as the labels, or, under the last
        // row before any row is seen, indented at all.
        let indent = l.chars().take_while(|c| c.is_whitespace()).count();
        let continues = if start.is_none() { indent >= 4 } else { indent >= column };
        if !continues {
            break;
        }
    }
    let start = start?;
    let mut rows: Vec<(String, bool, bool)> = Vec::new();
    for l in &lines[start..footer] {
        if let Some(c) = checkbox_pattern().captures(l) {
            rows.push((c[4].to_string(), c.get(2).is_some(), &c[3] != " "));
        } else if let (Some(row), t) = (rows.last_mut(), trim_ws(l)) {
            if !t.is_empty() {
                row.0 = join_wrapped(&row.0, t);
            }
        }
    }
    if rows.len() < 2 {
        return None;
    }
    let cursor = rows.iter().position(|r| r.1).unwrap_or(0);
    if rows.last().is_some_and(|r| r.0.starts_with("Other:")) {
        rows.pop();
    }
    let checked = rows.iter().enumerate().filter(|(_, r)| r.2).map(|(i, _)| i).collect();
    let options = rows.into_iter().enumerate().map(|(i, (label, selected, _))| ChoiceOption { index: i + 1, label, selected }).collect();

    // Above the rows: the numbered question (wrapped over a few lines), then
    // "Question n of m", then the heading under the box's top edge.
    static NUMBERED: OnceLock<Regex> = OnceLock::new();
    let numbered = NUMBERED.get_or_init(|| Regex::new(r"^\d+\.\s+(.*)$").expect("numbered regex"));
    let mut prompt_lines: Vec<&str> = Vec::new();
    let mut prompt_start = start;
    for at in (start.saturating_sub(8)..start).rev() {
        let t = trim_ws(lines[at]);
        if t.is_empty() {
            if prompt_lines.is_empty() {
                continue;
            }
            break;
        }
        prompt_lines.insert(0, t);
        prompt_start = at;
        if numbered.is_match(t) {
            break;
        }
    }
    let mut prompt = prompt_lines.iter().fold(String::new(), |acc, l| join_wrapped(&acc, l));
    if let Some(c) = numbered.captures(&prompt) {
        prompt = c[1].to_string();
    }
    let multi = prompt.ends_with("(multi-select)");
    if multi {
        prompt = prompt.trim_end_matches("(multi-select)").trim_end().to_string();
    }
    static PROGRESS: OnceLock<Regex> = OnceLock::new();
    let progress = PROGRESS.get_or_init(|| Regex::new(r"^Question \d+ of \d+$").expect("progress regex"));
    let raw: Vec<&str> = screen.split('\n').collect();
    let mut title = String::new();
    for at in (prompt_start.saturating_sub(8)..prompt_start).rev() {
        if trim_ws(raw[at]).starts_with(['┌', '╭']) {
            break;
        }
        let t = trim_ws(lines[at]);
        if !t.is_empty() && !progress.is_match(t) {
            title = t.to_string();
        }
    }
    Some(Checklist { title, prompt, multi, options, checked, cursor })
}

/// Two parts of a label a TUI wrapped, joined: with a space between words,
/// with none inside a run of CJK text.
fn join_wrapped(a: &str, b: &str) -> String {
    if a.is_empty() {
        return b.to_string();
    }
    let ascii_end = a.chars().last().is_some_and(|c| c.is_ascii());
    let ascii_start = b.chars().next().is_some_and(|c| c.is_ascii());
    if ascii_end || ascii_start {
        format!("{a} {b}")
    } else {
        format!("{a}{b}")
    }
}


/// A selection menu without numbers, as Claude Code draws its folder-trust
/// dialog: rows at one indent, the cursor `❯` on exactly one, and "Enter to
/// confirm" right under them. Strict on purpose (the footer, one cursor, at
/// least two rows, nothing between them): ordinary output must not read as a
/// menu. `index` is the row's place (1-based); it is answered with arrows.
fn unnumbered(screen: &str, bottom_lines: usize) -> Vec<ChoiceOption> {
    let lines: Vec<&str> = bottom(screen, bottom_lines).collect();
    let Some(footer) = lines.iter().rposition(|l| trim_ws(l).to_lowercase().starts_with("enter to confirm")) else { return Vec::new() };
    let mut rows: Vec<(String, bool, usize)> = Vec::new();
    for l in lines[..footer].iter().rev() {
        let indent = l.chars().take_while(|c| c.is_whitespace()).count();
        let rest: String = l.chars().skip(indent).collect();
        let (selected, label, column) = match rest.chars().next() {
            Some(c @ ('❯' | '›')) => {
                let label = rest[c.len_utf8()..].trim_start();
                (true, label.to_string(), indent + 1 + (rest[c.len_utf8()..].len() - label.len()))
            }
            _ => (false, rest.trim_end().to_string(), indent),
        };
        let label = label.trim_end().to_string();
        if label.is_empty() || rows.first().is_some_and(|r| r.2 != column) {
            break;
        }
        rows.insert(0, (label, selected, column));
    }
    if rows.len() < 2 || rows.iter().filter(|r| r.1).count() != 1 {
        return Vec::new();
    }
    rows.into_iter().enumerate().map(|(i, (label, selected, _))| ChoiceOption { index: i + 1, label, selected }).collect()
}

/// The footer a selection menu draws under itself: Claude Code's pickers
/// ("Enter to set as default · … · Esc to cancel"), its permission prompt
/// ("Esc to cancel · Tab to amend").
fn is_menu_footer(text: &str) -> bool {
    let lower = text.to_lowercase();
    lower.starts_with("enter ") || lower.contains("esc to cancel") || lower.contains("esc to exit")
}

/// The title of a picker, for its card, when the screen ends in a picker's
/// footer (`is_picker_footer`): the first line under the rule Claude Code
/// draws over it ("Select model"), or, with no rule (Codex), the first line
/// of the text above the list ("Select Model and Effort"). None for a permission prompt,
/// whose card keeps saying what it is waiting for.
pub fn menu_title(screen: &str, bottom_lines: usize) -> Option<String> {
    let lines: Vec<&str> = bottom(screen, bottom_lines).collect();
    let last = lines.iter().rposition(|l| !trim_ws(l).is_empty())?;
    if !is_picker_footer(trim_ws(lines[last])) {
        return None;
    }
    // The list the footer closes: its first row.
    let first = lines[..last].iter().rposition(|l| line_pattern().captures(l).is_some_and(|c| &c[2] == "1"))?;
    let rule = lines[..first].iter().rposition(|l| is_rule(l)).filter(|&r| first - r <= 8);
    let title = match rule {
        Some(r) => lines[r + 1..first].iter().map(|l| trim_ws(l)).find(|t| !t.is_empty())?,
        // The first line of the block of text above the list (blank rows may
        // sit between): Codex's update prompt is a title then its notes.
        None => {
            let mut at = first;
            while at > 0 && first - at < 4 && trim_ws(lines[at - 1]).is_empty() {
                at -= 1;
            }
            let end = at;
            while at > 0 && end - at < 4 && !trim_ws(lines[at - 1]).is_empty() {
                at -= 1;
            }
            if at == end {
                return None;
            }
            trim_ws(lines[at])
        }
    };
    if line_pattern().is_match(title) || title.starts_with(['❯', '›', '│', '╰', '╭', '└', '┌']) {
        return None;
    }
    Some(title.to_string())
}

/// A picker's own footer ("Enter to set as default · …", "enter select ·
/// esc back", "enter continue · esc skip"), as against a permission
/// prompt's ("Esc to cancel · …", Codex's "Press enter to confirm …").
fn is_picker_footer(text: &str) -> bool {
    text.to_lowercase().starts_with("enter ")
}

/// A picker's option as a card shows it: the columns it is drawn in
/// ("Opus 5.5 ✔             For complex work") joined by " · ".
pub fn tidy_menu_label(label: &str) -> String {
    label.split("  ").map(str::trim).filter(|p| !p.is_empty()).collect::<Vec<_>>().join(" · ")
}

/// The key a picker offers for "this session only" (Claude Code's `/model`:
/// "… · s to use this session only · …", Codex's reasoning level: "enter
/// default · s session · esc back"), read off its footer. A card answers
/// with it rather than Return, which would also change the user's default.
pub fn session_only_key(screen: &str, bottom_lines: usize) -> Option<String> {
    static R: OnceLock<Regex> = OnceLock::new();
    let re = R.get_or_init(|| Regex::new(r"(?i)(?:^|·)\s*(\S) (?:to use (?:it )?(?:for )?this session only|session)\s*(?:·|$)").expect("session key regex"));
    let lines: Vec<&str> = bottom(screen, bottom_lines).collect();
    let last = lines.iter().rposition(|l| !trim_ws(l).is_empty())?;
    re.captures(trim_ws(lines[last])).map(|c| c[1].to_string())
}

fn is_rule(line: &str) -> bool {
    let t = trim_ws(line);
    t.chars().count() >= 10 && t.chars().all(|c| matches!(c, '▔' | '▁' | '─' | '━' | '═'))
}

/// What a permission dialog says around its choices, read off the screen
/// so a card can say what it is asking without the terminal.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Dialog {
    /// Its first line ("Bash command", "Edit file").
    pub title: String,
    /// The line right above the choices when it asks ("Do you want to proceed?").
    pub question: String,
    /// What is between: the description, the command, the warnings.
    pub body: String,
}

/// Lines of a dialog body kept for a card, and characters in all.
const DIALOG_BODY_LINES: usize = 14;
const DIALOG_BODY_CHARS: usize = 1500;

/// The dialog the choice list at the bottom belongs to: everything from the
/// rule Claude Code draws over it down to the list, on the whole screen (a
/// long command makes it taller than the choice scan's window). None when
/// there is no list or no rule above it.
pub fn dialog(screen: &str) -> Option<Dialog> {
    let lines: Vec<&str> = screen.split('\n').collect();
    let first = lines.iter().rposition(|l| line_pattern().captures(l).is_some_and(|c| &c[2] == "1"))?;
    let start = match lines[..first].iter().rposition(|l| is_rule(l)).filter(|&r| first - r <= 80) {
        Some(rule) => rule + 1,
        None => unruled_start(&lines, first)?,
    };
    let mut kept: Vec<String> = Vec::new();
    for l in &lines[start..first] {
        let t = trim_ws(l).trim_matches(|c| c == '│' || c == '┃').trim();
        // Dotted rules inside the box, blank lines, the countdown to an
        // automatic refusal (it changes every second), and Claude Code's own
        // tips ("Tip: auto mode handles…"), which are not about this request.
        if t.is_empty() || is_dotted_rule(t) || t.contains("will automatically block") || t.starts_with("Tip:") {
            continue;
        }
        kept.push(t.to_string());
    }
    if kept.is_empty() {
        return None;
    }
    let mut title = kept.remove(0);
    let mut question = if kept.last().is_some_and(|l| l.ends_with('?')) { kept.pop().unwrap_or_default() } else { String::new() };
    // Codex asks first ("Would you like to run the following command?") and
    // shows what after: that opening line is the question.
    if question.is_empty() && title.ends_with('?') {
        question = std::mem::take(&mut title);
    }
    let mut cut = kept.len() > DIALOG_BODY_LINES;
    kept.truncate(DIALOG_BODY_LINES);
    let mut body = kept.join("\n");
    if body.chars().count() > DIALOG_BODY_CHARS {
        body = body.chars().take(DIALOG_BODY_CHARS).collect();
        cut = true;
    }
    if cut {
        body.push('…');
    }
    Some(Dialog { title, question, body })
}

/// Where a dialog drawn without a rule starts (Codex's approvals): the
/// first line of the text over the list, which ends going up at a gap of 3
/// blank rows, at the conversation (`›` the user's prompt, `•` Codex's own
/// lines), or 30 rows up. None when there is no text over the list.
fn unruled_start(lines: &[&str], first: usize) -> Option<usize> {
    let mut start = None;
    let mut blank = 0;
    for at in (first.saturating_sub(30)..first).rev() {
        let t = trim_ws(lines[at]);
        if t.is_empty() {
            blank += 1;
            if blank >= 3 {
                break;
            }
            continue;
        }
        if t.starts_with(['›', '•', '╰', '└']) {
            break;
        }
        blank = 0;
        start = Some(at);
    }
    start
}

fn is_dotted_rule(t: &str) -> bool {
    t.chars().count() >= 10 && t.chars().all(|c| matches!(c, '┄' | '┈' | '╌' | '╍' | '┅' | '-' | ' ' | '·'))
}

/// Whether the screen is Claude's AskUserQuestion dialog (a question, or its
/// "Review your answers" page) rather than a permission prompt. Its hook has
/// already raised a card with the real options; a second one scraped off the
/// screen reads "[ ] Apple Apple", changes every tick, and used to retire the
/// hook card's buttons.
pub fn is_agent_question_dialog(screen: &str, bottom_lines: usize) -> bool {
    bottom(screen, bottom_lines).any(|l| trim_ws(l).ends_with(". Chat about this")) || is_question_review(screen)
}

/// Whether the screen shows AskUserQuestion's "Review your answers" page,
/// which waits for Return on "Submit answers". Claude Code used to put
/// "Ready to submit your answers?" over the list; 2.1.3xx draws only the
/// heading and the list.
pub fn is_question_review(screen: &str) -> bool {
    let lines: Vec<&str> = screen.lines().map(trim_ws).collect();
    if lines.iter().any(|l| *l == "Ready to submit your answers?") {
        return true;
    }
    let heading = lines.iter().position(|l| *l == "Review your answers");
    heading.is_some_and(|at| lines[at..].iter().any(|l| l.trim_start_matches(['❯', '>', ' ']) == "1. Submit answers"))
}

/// Chrome that may sit below a live choice list without making it stale.
/// Agent TUIs pin a composer and a status line under the dialog (Codex draws
/// `› <composer>` and `<model> · <cwd>`); reading those as new output is why
/// Codex approvals never reached the island.
fn is_trailing_chrome(text: &str) -> bool {
    let lower = text.to_lowercase();
    if lower.contains("press enter") && (lower.contains("confirm") || lower.contains("cancel")) {
        return true;
    }
    if text.chars().next().is_some_and(|c| "›❯>".contains(c)) {
        return true;
    }
    text.contains(" · ")
}
