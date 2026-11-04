//! The macOS app's semantic colours and type (`UI/Shared/SemanticColors.swift`,
//! `AppFont.swift`), dark and light. See MACOS-SPEC.md.

use gpui::{rgb, rgba, Rgba};

pub const MONO: &str = "JetBrains Mono";
/// What AppKit's system font resolves to under GPUI on macOS.
pub const SYSTEM: &str = ".SystemUIFont";

pub fn ink() -> Rgba { rgb(pick(0xcfe0e0, 0x1f232b)) }
pub fn ink_dim() -> Rgba { rgb(pick(0x7fa0a3, 0x636b78)) }
pub fn ink_faint() -> Rgba { rgb(pick(0x7fa0a3, 0x717a88)) }
pub fn accent() -> Rgba { rgb(pick(0x1fc8da, 0x0e9bb5)) }
pub fn running() -> Rgba { rgb(pick(0x1bb062, 0x1f9d63)) }
pub fn waiting() -> Rgba { rgb(pick(0x5b93f0, 0x2563eb)) }
pub fn idle() -> Rgba { rgb(pick(0x557170, 0x8a93a1)) }
pub fn danger() -> Rgba { rgb(pick(0xe84635, 0xdc2626)) }
pub fn attention() -> Rgba { rgb(pick(0xe0a458, 0xd08706)) }
pub fn diff_add() -> Rgba { rgb(pick(0x5fb87a, 0x1f9d63)) }
pub fn diff_del() -> Rgba { rgb(pick(0xe07a6a, 0xdc2626)) }
/// Toolbar glyph tint (`#888888`).
pub fn chrome_icon() -> Rgba { rgb(pick(0x888888, 0x888888)) }
// The AppKit fills are translucent over vibrancy; these are what they come
// to over the sidebar's colour as measured off the live app (#282d2f), so
// the window can be opaque and look the same on every platform.

/// The 1pt hairline under the fleet header: rgba(150,215,225,0.10).
pub fn hairline() -> Rgba { rgb(pick(0x333e41, 0xdde2e8)) }
/// `NSColor.separatorColor`, dark.
pub fn separator() -> Rgba { rgb(pick(0x3d4244, 0xd3d8de)) }
pub fn row_selected() -> Rgba { rgb(pick(0x3d4244, 0xdadee4)) }
pub fn row_hover() -> Rgba { rgb(pick(0x333839, 0xe3e6ea)) }
/// The sidebar: `.underWindowBackground` vibrancy as it reads in the app.
pub fn sidebar_tint() -> Rgba { rgb(pick(0x282d2f, 0xeceef1)) }
/// Unfocused split panes are washed with white 8.5% (black 5.5% in light).
pub fn inactive_wash() -> Rgba { rgba(pick(0xffffff16, 0x0000000e)) }

/// The dark value or the light one, as the theme now is. The light fills
/// are not measured off the app as the dark ones were: they are the light
/// semantic colours over a light sidebar, by the same rule.
fn pick(dark: u32, light: u32) -> u32 {
    if crate::theme::is_dark() {
        dark
    } else {
        light
    }
}

pub fn alpha(c: Rgba, a: f32) -> Rgba {
    Rgba { a, ..c }
}
