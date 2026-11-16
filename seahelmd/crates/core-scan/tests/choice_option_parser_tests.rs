//! Port of Tests/ChoiceOptionParserTests.swift.

use seahelm_core_scan::choices::{self, ChoiceOption, DEFAULT_BOTTOM_LINES};

fn parse(screen: &str) -> Vec<ChoiceOption> {
    choices::parse(screen, DEFAULT_BOTTOM_LINES)
}

fn indices(opts: &[ChoiceOption]) -> Vec<usize> {
    opts.iter().map(|o| o.index).collect()
}

fn lines(l: &[&str]) -> String {
    l.join("\n")
}

#[test]
fn parses_permission_prompt() {
    let screen = lines(&[
        "Bash command",
        "gh pr checks 4552 --watch",
        "",
        "Do you want to proceed?",
        "❯ 1. Yes",
        "  2. Yes, and don't ask again for bash commands",
        "  3. No, and tell Claude what to do differently",
    ]);
    let opts = parse(&screen);
    assert_eq!(opts.len(), 3);
    assert_eq!(opts[0].index, 1);
    assert_eq!(opts[0].label, "Yes");
    assert!(opts[0].selected);
    assert!(!opts[1].selected);
    assert_eq!(opts[2].label, "No, and tell Claude what to do differently");
}

#[test]
fn parses_ask_user_question() {
    let opts = parse(&lines(&["Which auth method?", "  1. OAuth", "❯ 2. JWT"]));
    assert_eq!(indices(&opts), [1, 2]);
    assert_eq!(opts[1].label, "JWT");
    assert!(opts[1].selected);
}

#[test]
fn parses_codex_approval_with_wrapped_option_and_footer() {
    let screen = lines(&[
        "Would you like to run the following command?",
        "",
        "Environment: local",
        "",
        "Reason: Allow me to rebase the PR branch onto the latest main and",
        "resolve its conflicts?",
        "",
        "$ git rebase origin/main",
        "",
        "❯ 1. Yes, proceed (y)",
        "  2. Yes, and don't ask again for commands that start with `git rebase",
        "     origin/main` (p)",
        "  3. No, and tell Codex what to do differently (esc)",
        "",
        "Press enter to confirm or esc to cancel",
    ]);
    let opts = parse(&screen);
    assert_eq!(indices(&opts), [1, 2, 3]);
    assert_eq!(opts[1].label, "Yes, and don't ask again for commands that start with `git rebase origin/main` (p)");
    assert!(opts[0].selected);
}

/// Codex pins a composer and a `model · cwd` line under its dialog.
#[test]
fn keeps_codex_options_above_composer_and_status_footer() {
    let screen = lines(&[
        "Would you like to make the following edits?",
        "",
        "› 1. Yes, proceed (y)",
        "  2. Yes, and don't ask again for these files (a)",
        "  3. No, and tell Codex what to do differently (esc)",
        "",
        "  Press enter to confirm or esc to cancel",
        "",
        "",
        "› Write tests for @filename",
        "",
        "  gpt-5.6-terra medium · /Volumes/openbeta/workspace/seahelm",
    ]);
    let opts = parse(&screen);
    assert_eq!(indices(&opts), [1, 2, 3]);
    assert_eq!(opts[0].label, "Yes, proceed (y)");
    assert!(opts[0].selected);
}

#[test]
fn keeps_codex_options_above_status_footer_only() {
    let screen = lines(&[
        "Would you like to make the following edits?",
        "",
        "› 1. Yes, proceed (y)",
        "  2. Yes, and don't ask again for these files (a)",
        "  3. No, and tell Codex what to do differently (esc)",
        "",
        "  Press enter to confirm or esc to cancel",
        "",
        "  gpt-5.6-terra medium · /Volumes/openbeta/workspace/seahelm",
    ]);
    assert_eq!(indices(&parse(&screen)), [1, 2, 3]);
}

#[test]
fn ignores_non_consecutive_prose() {
    let screen = lines(&["Here's the plan:", "1. First do this", "Then some explanation text.", "2. Then do that"]);
    assert!(parse(&screen).is_empty());
}

#[test]
fn ignores_single_option() {
    assert!(parse("1. Only one").is_empty());
}

#[test]
fn does_not_return_stale_choice_above_new_output() {
    let screen = lines(&["❯ 1. Approve", "  2. Reject", "", "The command completed successfully."]);
    assert!(parse(&screen).is_empty());
}

#[test]
fn empty_screen() {
    assert!(parse("").is_empty());
}

#[test]
fn recognises_the_ask_user_question_dialog() {
    let question = lines(&[
        "←  ☐ Fruits  ✔ Submit  →",
        "Pick fruits",
        "❯ 1. [ ] Apple",
        "         Apple",
        "  2. [ ] Banana",
        "  3. [ ] Type something",
        "     Submit",
        "────────────────────────────",
        "  4. Chat about this",
        "Enter to select · ↑/↓ to navigate · Esc to cancel",
    ]);
    assert!(choices::is_agent_question_dialog(&question, DEFAULT_BOTTOM_LINES));
    let review = lines(&[
        "Review your answers",
        " ● Pick fruits",
        "   → Apple",
        "Ready to submit your answers?",
        "❯ 1. Submit answers",
        "  2. Cancel",
    ]);
    assert!(choices::is_agent_question_dialog(&review, DEFAULT_BOTTOM_LINES));
}

#[test]
fn permission_prompt_is_not_the_question_dialog() {
    let prompt = lines(&[
        "Do you want to proceed?",
        "❯ 1. Yes",
        "  2. Yes, and don't ask again for bash commands",
        "  3. No, and tell Claude what to do differently",
        "Esc to cancel",
    ]);
    assert!(!choices::is_agent_question_dialog(&prompt, DEFAULT_BOTTOM_LINES));
}

#[test]
fn parses_claudes_unnumbered_folder_trust_menu() {
    let screen = [
        " Quick safety check: Is this a project you created or one you trust? (Like your",
        " own code, a well-known open source project, or work from your team).",
        " Claude Code'll be able to read, edit, and execute files here.",
        " Security guide",
        " ❯ No, exit",
        "   Yes, I trust this folder",
        " Enter to confirm · Esc to cancel",
    ]
    .join("\n");
    let o = parse(&screen);
    assert_eq!(o.iter().map(|o| o.label.as_str()).collect::<Vec<_>>(), vec!["No, exit", "Yes, I trust this folder"]);
    assert_eq!(o.iter().map(|o| o.selected).collect::<Vec<_>>(), vec![true, false]);
    assert_eq!(o[1].index, 2);
}

#[test]
fn unnumbered_menus_need_the_footer_and_one_cursor() {
    // No "Enter to confirm": ordinary output, not a menu.
    assert!(parse(" ❯ No, exit\n   Yes, I trust this folder\n").is_empty());
    // Two cursors.
    assert!(parse(" ❯ a\n ❯ b\n Enter to confirm\n").is_empty());
    // One row.
    assert!(parse(" ❯ only\n Enter to confirm\n").is_empty());
    // A row at another indent ends the menu above it.
    let o = parse("some text\n ❯ a\n   b\n Enter to confirm · Esc to cancel");
    assert_eq!(o.len(), 2);
}

/// Claude Code 2.1's `/model`: its effort row and a tip sit between the list
/// and the footer, and must not make the list stale.
const MODEL_PICKER: &[&str] = &[
    " ▐▛███▛█   Claude Code v2.1.326",
    "",
    "▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔",
    "   Select model",
    "   Switch between Claude models. Your pick becomes the default for new sessions. For other or older models, use ",
    "   --model.",
    "",
    "     1.  Default (recommended)  Opus 5.5 · Best for everyday, complex tasks",
    "   ❯ 2.  Opus 5.5 ✔             For complex work and everyday tasks",
    "     3.  Fable 5.2              For your toughest challenges",
    "     ▸   More models             ",
    "",
    "   ◐ Medium effort (default) ←/→ to adjust",
    "",
    "   Use /fast to turn on fast mode (Opus 5.5).",
    "",
    "   Enter to set as default · s to use this session only · Esc to cancel",
];

#[test]
fn parses_a_slash_command_picker_with_text_under_its_list() {
    let screen = lines(MODEL_PICKER);
    let opts = parse(&screen);
    assert_eq!(indices(&opts), [1, 2, 3]);
    assert!(opts[1].selected);
    assert_eq!(choices::menu_title(&screen, DEFAULT_BOTTOM_LINES).as_deref(), Some("Select model"));
    assert_eq!(choices::tidy_menu_label(&opts[1].label), "Opus 5.5 ✔ · For complex work and everyday tasks");
    assert_eq!(choices::tidy_menu_label(&opts[0].label), "Default (recommended) · Opus 5.5 · Best for everyday, complex tasks");
    assert_eq!(choices::session_only_key(&screen, DEFAULT_BOTTOM_LINES).as_deref(), Some("s"));
}

#[test]
fn a_picker_list_is_stale_once_its_footer_is_gone() {
    // Closed: the list is in the scrollback, the agent's reply under it.
    let mut l: Vec<&str> = MODEL_PICKER[..MODEL_PICKER.len() - 2].to_vec();
    l.extend(["", "⎿  Set model to Fable 5.2", "", "> ", "  ? for shortcuts"]);
    let screen = lines(&l);
    assert!(parse(&screen).is_empty());
    assert_eq!(choices::menu_title(&screen, DEFAULT_BOTTOM_LINES), None);
}

#[test]
fn a_footer_far_below_an_old_list_does_not_revive_it() {
    let mut l = vec!["❯ 1. Yes", "  2. No"];
    let filler = ["output a", "output b", "output c", "output d", "output e", "output f", "output g", "output h"];
    l.extend(filler);
    l.push("Esc to cancel");
    assert!(parse(&lines(&l)).is_empty());
}

#[test]
fn a_permission_prompt_has_no_menu_title() {
    let screen = lines(&[
        "────────────────────────────────",
        " Bash command",
        "   ls",
        " Do you want to proceed?",
        " ❯ 1. Yes",
        "   2. No",
        "",
        " Esc to cancel · Tab to amend",
    ]);
    assert_eq!(parse(&screen).len(), 2);
    assert_eq!(choices::menu_title(&screen, DEFAULT_BOTTOM_LINES), None);
    assert_eq!(choices::session_only_key(&screen, DEFAULT_BOTTOM_LINES), None);
}
