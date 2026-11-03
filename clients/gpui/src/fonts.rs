//! The terminal font: the one the macOS app's panes use, read from the same
//! Ghostty config (`~/.config/seahelm/ghostty.conf`), else Menlo 13.

fn config_value(key: &str) -> Option<String> {
    let home = std::env::var_os("HOME")?;
    let text = std::fs::read_to_string(std::path::Path::new(&home).join(".config/seahelm/ghostty.conf")).ok()?;
    parse(&text, key)
}

/// The last `key = value` in a Ghostty config; Ghostty lets later lines win.
fn parse(text: &str, key: &str) -> Option<String> {
    text.lines()
        .filter_map(|line| {
            let line = line.trim();
            if line.starts_with('#') {
                return None;
            }
            let (k, v) = line.split_once('=')?;
            (k.trim() == key).then(|| v.trim().trim_matches('"').to_string())
        })
        .filter(|v| !v.is_empty())
        .last()
}

pub fn terminal_family() -> String {
    config_value("font-family").unwrap_or_else(|| "Menlo".into())
}

pub fn terminal_size() -> f32 {
    config_value("font-size").and_then(|v| v.parse().ok()).unwrap_or(13.0)
}

#[cfg(test)]
mod tests {
    #[test]
    fn later_lines_win_and_comments_do_not_count() {
        let conf = "font-family = A\n# font-family = B\nfont-family = \"C D\"\n";
        assert_eq!(super::parse(conf, "font-family").as_deref(), Some("C D"));
        assert_eq!(super::parse(conf, "font-size"), None);
    }
}
