// sh_theme.h — Sumi 墨 palette + fonts + status color mapping.
// Colors mirror the design's watch theme (near-black physical dial).
#pragma once
#include "lvgl.h"

// ── palette ──────────────────────────────────────────────────────────────────
#define SH_NIGHT  lv_color_hex(0x141210)  // dial background
#define SH_LAMP   lv_color_hex(0x221F1B)  // card / bubble
#define SH_STONE  lv_color_hex(0x39342E)  // hairline / track / dim text
#define SH_ASH    lv_color_hex(0x7C7368)  // secondary text / idle
#define SH_BONE   lv_color_hex(0xEBE5D8)  // primary text
#define SH_EMBER  lv_color_hex(0xD86B53)  // focus / selected / the pick
#define SH_GREEN  lv_color_hex(0x6E9159)  // running / done
#define SH_AMBER  lv_color_hex(0xC6993F)  // waiting on you
#define SH_RED    lv_color_hex(0x9A3B2B)  // failed / error

// ── fonts ────────────────────────────────────────────────────────────────────
// Subset CJK+Latin fonts generated from SourceHanSansSC (main/fonts/README.md,
// Option A). Digits-only Montserrat 96 for the glance hero. Sized up for the
// 466 px round dial — the built-in Montserrat tiers read too small there.
LV_FONT_DECLARE(sh_font_cn_20)
LV_FONT_DECLARE(sh_font_cn_26)
LV_FONT_DECLARE(sh_font_cn_34)
LV_FONT_DECLARE(sh_font_num_96)

#ifndef SH_FONT_HERO      // big glance number (digits only)
#define SH_FONT_HERO   (&sh_font_num_96)
#endif
#ifndef SH_FONT_TITLE     // deck / worktree titles, home wordmark
#define SH_FONT_TITLE  (&sh_font_cn_34)
#endif
#ifndef SH_FONT_BODY      // rows, bubbles, primary content
#define SH_FONT_BODY   (&sh_font_cn_26)
#endif
#ifndef SH_FONT_META      // captions, pane ids, counts, status lines
#define SH_FONT_META   (&sh_font_cn_20)
#endif

// ── device geometry (466 round) ──────────────────────────────────────────────
#define SH_W        466
#define SH_H        466
#define SH_CX       233
#define SH_CY       233
#define SH_RING_R   214

// ── pane status ──────────────────────────────────────────────────────────────
typedef enum {
    SH_ST_RUNNING = 0,
    SH_ST_WAITING,
    SH_ST_DONE,
    SH_ST_FAILED,
    SH_ST_IDLE,
    SH_ST_UNKNOWN,
} sh_status_t;

static inline lv_color_t sh_status_color(sh_status_t s) {
    switch (s) {
        case SH_ST_RUNNING: return SH_GREEN;
        case SH_ST_WAITING: return SH_AMBER;
        case SH_ST_DONE:    return SH_GREEN;
        case SH_ST_FAILED:  return SH_RED;
        default:            return SH_ASH;
    }
}
static inline bool sh_status_breathe(sh_status_t s) {
    return s == SH_ST_RUNNING || s == SH_ST_WAITING;
}
// M2: parse the raw SailorStatus string from pane/{id}/status into sh_status_t.
sh_status_t sh_status_from_str(const char *raw);
