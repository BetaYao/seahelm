//! The terminal palette: Catppuccin Mocha in the dark and Latte in the
//! light, as Ghostty ships them (`Resources/ghostty/themes`) — what the
//! macOS app's panes paint with. Which one is current is process-wide and
//! can change while running (the contrast button).

use std::sync::atomic::{AtomicBool, Ordering};

static DARK: AtomicBool = AtomicBool::new(true);

pub fn is_dark() -> bool {
    DARK.load(Ordering::Relaxed)
}

pub fn set_dark(dark: bool) {
    DARK.store(dark, Ordering::Relaxed);
}

fn pick<T>(dark: T, light: T) -> T {
    if is_dark() {
        dark
    } else {
        light
    }
}

pub fn bg() -> [u8; 3] {
    pick([0x1e, 0x1e, 0x2e], [0xef, 0xf1, 0xf5])
}

pub fn fg() -> [u8; 3] {
    pick([0xcd, 0xd6, 0xf4], [0x4c, 0x4f, 0x69])
}

pub fn cursor() -> [u8; 3] {
    pick([0xf5, 0xe0, 0xdc], [0xdc, 0x8a, 0x78])
}

pub fn selection_bg() -> [u8; 3] {
    pick([0x58, 0x5b, 0x70], [0xac, 0xb0, 0xbe])
}

const MOCHA: [u32; 16] = [
    0x45475a, 0xf38ba8, 0xa6e3a1, 0xf9e2af, 0x89b4fa, 0xf5c2e7, 0x94e2d5, 0xbac2de, //
    0x585b70, 0xf38ba8, 0xa6e3a1, 0xf9e2af, 0x89b4fa, 0xf5c2e7, 0x94e2d5, 0xa6adc8,
];

const LATTE: [u32; 16] = [
    0xbcc0cc, 0xd20f39, 0x40a02b, 0xdf8e1d, 0x1e66f5, 0xea76cb, 0x179299, 0x5c5f77, //
    0xacb0be, 0xe7103f, 0x46b02f, 0xe49931, 0x3878f6, 0xef95d7, 0x19a1a8, 0x6c6f85,
];

/// All 256: the theme's 16, then xterm's colour cube and grey ramp.
pub fn palette() -> Vec<[u8; 3]> {
    let ansi = pick(&MOCHA, &LATTE);
    let mut out: Vec<[u8; 3]> = ansi.iter().map(|&c| [(c >> 16) as u8, (c >> 8) as u8, c as u8]).collect();
    let level = |i: u8| if i == 0 { 0 } else { 55 + i * 40 };
    for r in 0..6 {
        for g in 0..6 {
            for b in 0..6 {
                out.push([level(r), level(g), level(b)]);
            }
        }
    }
    for i in 0..24u8 {
        let v = 8 + i * 10;
        out.push([v, v, v]);
    }
    out
}

/// What the grid answers colour questions with, standing in for the
/// terminal: the current theme.
pub fn facts() -> keep_vt::Facts {
    keep_vt::Facts {
        foreground: Some(fg()),
        background: Some(bg()),
        cursor: Some(cursor()),
        palette: Some(palette()),
        dark: Some(is_dark()),
        ..keep_vt::Facts::default()
    }
}

/// `SEAHELMD_FACTS`, so the daemon answers colour questions the same way
/// while no client is attached.
pub fn facts_env() -> String {
    let hex = |c: [u8; 3]| format!("{:02x}{:02x}{:02x}", c[0], c[1], c[2]);
    format!("fg={} bg={} cursor={} dark={}", hex(fg()), hex(bg()), hex(cursor()), is_dark() as u8)
}

pub fn rgb(c: [u8; 3]) -> gpui::Rgba {
    gpui::Rgba { r: c[0] as f32 / 255.0, g: c[1] as f32 / 255.0, b: c[2] as f32 / 255.0, a: 1.0 }
}

#[cfg(test)]
mod tests {
    #[test]
    fn both_themes_have_their_own_colours() {
        super::set_dark(false);
        assert_eq!(super::bg(), [0xef, 0xf1, 0xf5]);
        assert_eq!(super::palette()[1], [0xd2, 0x0f, 0x39]);
        assert!(super::facts_env().ends_with("dark=0"));
        super::set_dark(true);
        assert_eq!(super::bg(), [0x1e, 0x1e, 0x2e]);
    }

    #[test]
    fn palette_is_complete() {
        let p = super::palette();
        assert_eq!(p.len(), 256);
        assert_eq!(p[16], [0, 0, 0]);
        assert_eq!(p[231], [255, 255, 255]);
        assert_eq!(p[255], [238, 238, 238]);
    }
}
