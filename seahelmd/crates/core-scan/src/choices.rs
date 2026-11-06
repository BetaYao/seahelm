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

fn bottom(screen: &str, bottom_lines: usize) -> impl Iterator<Item = &str> {
    let lines: Vec<&str> = screen.split('\n').collect();
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

    fn finish(current: &mut Vec<ChoiceOption>, last_valid: &mut Vec<ChoiceOption>, column: &mut usize) {
        if current.len() >= 2 && current.iter().any(|o| o.selected) {
            *last_valid = std::mem::take(current);
        }
        current.clear();
        *column = usize::MAX;
    }

    for s in bottom(screen, bottom_lines) {
        if let Some(caps) = line_pattern().captures(s) {
            if let Ok(idx) = caps[2].parse::<usize>() {
                if idx == 1 {
                    finish(&mut current, &mut last_valid, &mut continuation_column);
                }
                if idx != current.len() + 1 {
                    finish(&mut current, &mut last_valid, &mut continuation_column);
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
            // means an older list in the viewport is stale.
            if !trimmed.is_empty() && !is_trailing_chrome(trimmed) {
                last_valid.clear();
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
            finish(&mut current, &mut last_valid, &mut continuation_column);
        }
    }
    finish(&mut current, &mut last_valid, &mut continuation_column);
    if last_valid.is_empty() {
        return unnumbered(screen, bottom_lines);
    }
    last_valid
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

/// Whether the screen is Claude's AskUserQuestion dialog (a question, or its
/// "Review your answers" page) rather than a permission prompt. Its hook has
/// already raised a card with the real options; a second one scraped off the
/// screen reads "[ ] Apple Apple", changes every tick, and used to retire the
/// hook card's buttons.
pub fn is_agent_question_dialog(screen: &str, bottom_lines: usize) -> bool {
    bottom(screen, bottom_lines).any(|l| {
        let line = trim_ws(l);
        line.ends_with(". Chat about this") || line == "Ready to submit your answers?"
    })
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
