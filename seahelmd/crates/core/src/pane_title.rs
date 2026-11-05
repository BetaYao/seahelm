//! What a pane is called, from its terminal title: the rule the Mac's pane
//! header uses (`PaneTitleResolver.displayOscTitle`), so every client that
//! reads `pane.list` names a pane the same way. Claude Code titles its
//! terminal with the conversation's summary behind a spinner glyph; shells
//! park their cwd there, which is not a name.

/// The title to show for a pane, or None when the terminal's title is only
/// where it is (a path, `~/…`, a directory name, a `user@host:/path` prompt).
pub fn display_osc_title(raw: &str, worktree: &str, pwd: &str, home: &str) -> Option<String> {
    // Drop the spinner and any other leading glyph that is not a word.
    let stripped = raw.trim_start_matches(|c: char| c.is_whitespace() || !(c.is_alphanumeric() || is_punctuation(c)));
    let title = single_line(stripped);
    if title.is_empty() {
        return None;
    }
    if is_directory_title(&title, worktree, home)
        || is_directory_title(&title, pwd, home)
        || is_shell_prompt_title(&title, worktree, home)
    {
        return None;
    }
    Some(title)
}

fn single_line(s: &str) -> String {
    s.split_whitespace().collect::<Vec<_>>().join(" ")
}

/// ASCII punctuation and the CJK and full-width punctuation blocks: a title
/// may open with `[`, `(`, `「` or `【`, which are words' company, not glyphs.
fn is_punctuation(c: char) -> bool {
    c.is_ascii_punctuation() || ('\u{3000}'..='\u{303F}').contains(&c) || ('\u{FF00}'..='\u{FFEF}').contains(&c)
}

fn shorten(path: &str, home: &str) -> String {
    if home.is_empty() {
        return path.to_string();
    }
    if path == home {
        return "~".into();
    }
    match path.strip_prefix(home).filter(|rest| rest.starts_with('/')) {
        Some(rest) => format!("~{rest}"),
        None => path.to_string(),
    }
}

/// `title` is just `path`: spelled out, `~`-shortened, or its last component.
fn is_directory_title(title: &str, path: &str, home: &str) -> bool {
    if path.is_empty() {
        return false;
    }
    let leaf = path.trim_end_matches('/').rsplit('/').next().unwrap_or("");
    title == path || title == shorten(path, home) || (!leaf.is_empty() && title == leaf)
}

/// A shell announcing its cwd: the title names the worktree's path.
fn is_shell_prompt_title(title: &str, worktree: &str, home: &str) -> bool {
    !worktree.is_empty() && (title.contains(worktree) || title.contains(&shorten(worktree, home)))
}

#[cfg(test)]
mod tests {
    use super::*;

    const HOME: &str = "/Users/me";
    const WT: &str = "/Users/me/work/repo";

    fn t(raw: &str) -> Option<String> {
        display_osc_title(raw, WT, "", HOME)
    }

    #[test]
    fn claudes_spinner_is_dropped() {
        assert_eq!(t("✳ 项目流程图.drawio HTML 版本").as_deref(), Some("项目流程图.drawio HTML 版本"));
        assert_eq!(t("⠂ Fix the login bug").as_deref(), Some("Fix the login bug"));
        assert_eq!(t("当前分支 PR 状态").as_deref(), Some("当前分支 PR 状态"));
    }

    #[test]
    fn leading_brackets_stay() {
        assert_eq!(t("[WIP] refactor").as_deref(), Some("[WIP] refactor"));
        assert_eq!(t("「交付验收」检查").as_deref(), Some("「交付验收」检查"));
    }

    #[test]
    fn where_the_shell_is_is_not_a_name() {
        assert_eq!(t("me@host:/Users/me/work/repo"), None);
        assert_eq!(t("me@host:~/work/repo"), None);
        assert_eq!(t("~/work/repo"), None);
        assert_eq!(t("repo"), None);
        assert_eq!(display_osc_title("sub", WT, "/Users/me/work/repo/sub", HOME), None);
        assert_eq!(t("   "), None);
        assert_eq!(t("✳"), None);
    }

    #[test]
    fn whitespace_folds_to_one_line() {
        assert_eq!(t("two\n  lines").as_deref(), Some("two lines"));
    }
}
