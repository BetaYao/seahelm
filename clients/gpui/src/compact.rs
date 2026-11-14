//! Narrow-window compact mode — same rules as the macOS AppKit client.
//!
//! See `docs/superpowers/specs/2026-11-14-compact-pane-tabs-design.md`.

/// Enter compact when content width is strictly below this.
pub const ENTER_WIDTH: f32 = 760.0;
/// Leave compact when content width is at or above this.
pub const EXIT_WIDTH: f32 = 820.0;

/// Hysteresis: widths in `[ENTER_WIDTH, EXIT_WIDTH)` keep the current mode.
pub fn should_be_active(width: f32, currently_active: bool) -> bool {
    if currently_active {
        width < EXIT_WIDTH
    } else {
        width < ENTER_WIDTH
    }
}

/// Pane tab strip: compact only with 2+ leaves (edit/preview is separate).
pub fn should_show_pane_tabs(compact_active: bool, leaf_count: usize) -> bool {
    compact_active && leaf_count > 1
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn enter_below_threshold() {
        assert!(should_be_active(759.0, false));
        assert!(should_be_active(700.0, false));
    }

    #[test]
    fn stay_inactive_in_band() {
        assert!(!should_be_active(760.0, false));
        assert!(!should_be_active(819.0, false));
    }

    #[test]
    fn exit_at_or_above() {
        assert!(!should_be_active(820.0, true));
        assert!(!should_be_active(900.0, true));
    }

    #[test]
    fn stay_active_in_band() {
        assert!(should_be_active(760.0, true));
        assert!(should_be_active(819.0, true));
    }

    #[test]
    fn pane_tabs_need_compact_and_multiple_leaves() {
        assert!(!should_show_pane_tabs(true, 1));
        assert!(should_show_pane_tabs(true, 2));
        assert!(!should_show_pane_tabs(false, 2));
    }
}
