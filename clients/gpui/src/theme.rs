//! The terminal palette: Catppuccin Mocha, as Ghostty ships it — what the
//! macOS app's panes paint with in dark mode.

pub const BG: [u8; 3] = [0x1e, 0x1e, 0x2e];
pub const FG: [u8; 3] = [0xcd, 0xd6, 0xf4];
pub const CURSOR: [u8; 3] = [0xf5, 0xe0, 0xdc];
pub const SELECTION_BG: [u8; 3] = [0x58, 0x5b, 0x70];

const ANSI: [u32; 16] = [
    0x45475a, 0xf38ba8, 0xa6e3a1, 0xf9e2af, 0x89b4fa, 0xf5c2e7, 0x94e2d5, 0xbac2de, //
    0x585b70, 0xf38ba8, 0xa6e3a1, 0xf9e2af, 0x89b4fa, 0xf5c2e7, 0x94e2d5, 0xa6adc8,
];

/// All 256: the theme's 16, then xterm's colour cube and grey ramp.
pub fn palette() -> Vec<[u8; 3]> {
    let mut out: Vec<[u8; 3]> = ANSI.iter().map(|&c| [(c >> 16) as u8, (c >> 8) as u8, c as u8]).collect();
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

/// `SEAHELMD_FACTS`, so the daemon answers colour questions the same way
/// while no client is attached.
pub fn facts_env() -> String {
    let hex = |c: [u8; 3]| format!("{:02x}{:02x}{:02x}", c[0], c[1], c[2]);
    format!("fg={} bg={} cursor={} dark=1", hex(FG), hex(BG), hex(CURSOR))
}

pub fn rgb(c: [u8; 3]) -> gpui::Rgba {
    gpui::Rgba { r: c[0] as f32 / 255.0, g: c[1] as f32 / 255.0, b: c[2] as f32 / 255.0, a: 1.0 }
}

#[cfg(test)]
mod tests {
    #[test]
    fn palette_is_complete() {
        let p = super::palette();
        assert_eq!(p.len(), 256);
        assert_eq!(p[16], [0, 0, 0]);
        assert_eq!(p[231], [255, 255, 255]);
        assert_eq!(p[255], [238, 238, 238]);
    }
}
