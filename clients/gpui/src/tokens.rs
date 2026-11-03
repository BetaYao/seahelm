//! The macOS app's semantic colours and type (`UI/Shared/SemanticColors.swift`,
//! `AppFont.swift`), dark appearance. See MACOS-SPEC.md.

use gpui::{rgb, rgba, Rgba};

pub const MONO: &str = "JetBrains Mono";
/// What AppKit's system font resolves to under GPUI on macOS.
pub const SYSTEM: &str = ".SystemUIFont";

pub fn ink() -> Rgba { rgb(0xcfe0e0) }
pub fn ink_dim() -> Rgba { rgb(0x7fa0a3) }
pub fn ink_faint() -> Rgba { rgb(0x7fa0a3) }
pub fn accent() -> Rgba { rgb(0x1fc8da) }
pub fn running() -> Rgba { rgb(0x1bb062) }
pub fn waiting() -> Rgba { rgb(0x5b93f0) }
pub fn idle() -> Rgba { rgb(0x557170) }
pub fn danger() -> Rgba { rgb(0xe84635) }
pub fn attention() -> Rgba { rgb(0xe0a458) }
pub fn diff_add() -> Rgba { rgb(0x5fb87a) }
pub fn diff_del() -> Rgba { rgb(0xe07a6a) }
pub fn merged() -> Rgba { rgb(0xa371f7) }
/// Toolbar glyph tint (`#888888`).
pub fn chrome_icon() -> Rgba { rgb(0x888888) }
// The AppKit fills are translucent over vibrancy; these are what they come
// to over the sidebar's colour as measured off the live app (#282d2f), so
// the window can be opaque and look the same on every platform.

/// The 1pt hairline under the fleet header: rgba(150,215,225,0.10).
pub fn hairline() -> Rgba { rgb(0x333e41) }
/// `NSColor.separatorColor`, dark.
pub fn separator() -> Rgba { rgb(0x3d4244) }
pub fn row_selected() -> Rgba { rgb(0x3d4244) }
pub fn row_hover() -> Rgba { rgb(0x333839) }
pub fn dock_hover() -> Rgba { rgb(0x353a3c) }
/// Line colour at 22% (the dock's rules).
pub fn dock_rule() -> Rgba { rgb(0x405256) }
/// The sidebar: `.underWindowBackground` vibrancy as it reads in the app.
pub fn sidebar_tint() -> Rgba { rgb(0x282d2f) }
/// Unfocused split panes are washed with white 8.5%.
pub fn inactive_wash() -> Rgba { rgba(0xffffff16) }

pub fn alpha(c: Rgba, a: f32) -> Rgba {
    Rgba { a, ..c }
}
