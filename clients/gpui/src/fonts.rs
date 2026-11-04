//! The terminal font: this client's own setting
//! (`~/.config/seahelm/gpui.json`: `{"font_family": …, "font_size": …}`),
//! else the bundled JetBrains Mono at 13.

use serde::Deserialize;

#[derive(Default, Deserialize)]
struct Settings {
    font_family: Option<String>,
    font_size: Option<f32>,
}

fn settings() -> Settings {
    std::fs::read_to_string(crate::platform::config_dir().join("gpui.json"))
        .ok()
        .and_then(|t| serde_json::from_str(&t).ok())
        .unwrap_or_default()
}

pub fn terminal_family() -> String {
    settings().font_family.filter(|f| !f.trim().is_empty()).unwrap_or_else(|| crate::tokens::MONO.into())
}

pub fn terminal_size() -> f32 {
    settings().font_size.filter(|s| (6.0..=72.0).contains(s)).unwrap_or(13.0)
}

#[cfg(test)]
mod tests {
    #[test]
    fn settings_parse_and_default() {
        let s: super::Settings = serde_json::from_str(r#"{"font_family": "Sarasa Term SC", "font_size": 14}"#).unwrap();
        assert_eq!(s.font_family.as_deref(), Some("Sarasa Term SC"));
        assert_eq!(s.font_size, Some(14.0));
        let empty: super::Settings = serde_json::from_str("{}").unwrap();
        assert!(empty.font_family.is_none());
    }
}
