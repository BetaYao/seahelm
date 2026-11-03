//! Lexical path handling on the strings hook payloads carry.
//!
//! Hook `cwd`s, `cd` targets and worktree paths arrive as text and go back
//! out as text (map keys, JSON), so they are kept as `String`s and only the
//! operations Foundation's `NSString` path methods performed are rebuilt
//! here: join, parent, `.`/`..` collapsing and `~`. They are lexical on
//! purpose — the directory an agent is about to create does not exist yet,
//! so nothing here may depend on it being on disk. `/` always separates;
//! on Windows `\` does too, and a drive prefix counts as a root.

use std::path::Path;

fn is_sep(c: char) -> bool {
    c == '/' || (cfg!(windows) && c == '\\')
}

/// The separator to put between components: the one the path already uses.
fn sep_for(p: &str) -> char {
    if cfg!(windows) && p.contains('\\') && !p.contains('/') {
        '\\'
    } else {
        '/'
    }
}

/// The root a path starts from (`/`, `C:\`, `\\`), or "" for a relative one.
fn root_of(p: &str) -> &str {
    if cfg!(windows) {
        let b = p.as_bytes();
        if b.len() >= 3 && b[0].is_ascii_alphabetic() && b[1] == b':' && is_sep(b[2] as char) {
            return &p[..3];
        }
        if p.starts_with("\\\\") {
            return &p[..2];
        }
    }
    if p.starts_with('/') || (cfg!(windows) && p.starts_with('\\')) {
        return &p[..1];
    }
    ""
}

pub(crate) fn is_absolute(p: &str) -> bool {
    p.starts_with('/') || Path::new(p).is_absolute()
}

/// `NSString.appendingPathComponent`: one separator between the two.
pub(crate) fn join(base: &str, rel: &str) -> String {
    if base.is_empty() {
        return rel.to_string();
    }
    let sep = sep_for(base);
    let trimmed = base.trim_end_matches(is_sep);
    let rel = rel.trim_start_matches(is_sep);
    if trimmed.is_empty() {
        return format!("{sep}{rel}");
    }
    format!("{trimmed}{sep}{rel}")
}

/// `NSString.deletingLastPathComponent`.
pub(crate) fn parent(p: &str) -> String {
    let root = root_of(p);
    let trimmed = p.trim_end_matches(is_sep);
    match trimmed.rfind(is_sep) {
        None => root.to_string(),
        // The last separator is part of the root (`/x`, `C:\x`): the root.
        Some(i) if i < root.len() => root.to_string(),
        Some(i) => {
            let head = trimmed[..i].trim_end_matches(is_sep);
            if head.len() < root.len() {
                root.to_string()
            } else {
                head.to_string()
            }
        }
    }
}

/// `NSString.standardizingPath`, lexically: empty and `.` components
/// dropped, `..` resolved against what precedes it, no trailing separator.
pub(crate) fn standardize(p: &str) -> String {
    let root = root_of(p);
    let sep = sep_for(p);
    let mut parts: Vec<&str> = Vec::new();
    for part in p[root.len()..].split(is_sep) {
        match part {
            "" | "." => {}
            ".." => {
                if parts.last().is_some_and(|l| *l != "..") {
                    parts.pop();
                } else if root.is_empty() {
                    parts.push("..");
                }
                // `..` above an absolute root stays at the root.
            }
            other => parts.push(other),
        }
    }
    let body = parts.join(&sep.to_string());
    if root.is_empty() {
        body
    } else {
        format!("{root}{body}")
    }
}

/// `~` and `~/…` against `home`; anything else unchanged.
pub(crate) fn expand_tilde(p: &str, home: &str) -> String {
    if p == "~" {
        home.to_string()
    } else if let Some(rest) = p.strip_prefix("~/") {
        join(home, rest)
    } else {
        p.to_string()
    }
}

/// `path` as given, or resolved against `base` when relative, standardized.
pub(crate) fn resolve(path: &str, base: &str, home: &str) -> String {
    let expanded = expand_tilde(path, home);
    let joined = if expanded != path || is_absolute(&expanded) {
        expanded
    } else {
        join(base, &expanded)
    };
    standardize(&joined)
}

/// Symlinks resolved as far as the path exists, the rest appended
/// lexically: the Swift `resolvingSymlinksInPath` the provider relied on to
/// make `/var/…` and `/private/var/…` (or a symlinked workspace) compare
/// equal, without needing the whole path to exist.
pub(crate) fn resolve_existing(p: &str) -> String {
    let path = Path::new(p);
    if !path.is_absolute() && !p.starts_with('/') {
        return p.to_string();
    }
    for ancestor in path.ancestors() {
        if ancestor.as_os_str().is_empty() {
            break;
        }
        if let Ok(real) = std::fs::canonicalize(ancestor) {
            let rest = path.strip_prefix(ancestor).unwrap_or(Path::new(""));
            let joined = if rest.as_os_str().is_empty() { real } else { real.join(rest) };
            let s = joined.to_string_lossy().into_owned();
            // Windows hands back verbatim paths; nothing else spells them so.
            return s.strip_prefix(r"\\?\").map(str::to_string).unwrap_or(s);
        }
    }
    p.to_string()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn lexical_operations_match_nsstring() {
        assert_eq!(standardize("/r/repo/../repo-x"), "/r/repo-x");
        assert_eq!(standardize("/r//a/./b/"), "/r/a/b");
        assert_eq!(standardize("/.."), "/");
        assert_eq!(parent("/r/wt/src/a.swift"), "/r/wt/src");
        assert_eq!(parent("/a"), "/");
        assert_eq!(join("/r/repo", ".claude/worktrees/x"), "/r/repo/.claude/worktrees/x");
        assert_eq!(join("/", "x"), "/x");
        assert_eq!(resolve("../wt", "/r/other", "/h"), "/r/wt");
        assert_eq!(resolve("~/x", "/r", "/h"), "/h/x");
    }
}
