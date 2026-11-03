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
