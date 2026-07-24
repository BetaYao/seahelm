// sh_ui.c — LVGL 9 implementation of the Seahelm watch design.
// Boot → Home(glance) → repos → worktrees → panes → detail(feed), with a
// status ring and suggest/question/notify overlays. M1 renders mock data.
#include "sh_ui.h"
#include "sh_wifi.h"
#include "sh_mqtt.h"
#include "sh_crypto.h"
#include "sh_data.h"
#include <string.h>
#include <stdio.h>

// ── global UI state ───────────────────────────────────────────────────────────
#define SH_STACK_MAX 6
static struct {
    lv_obj_t *scr;         // active screen
    lv_obj_t *ring;        // status arc
    lv_obj_t *center;      // rebuilt per view
    lv_obj_t *overlay;     // NULL unless an event is up
    lv_obj_t *toast;

    sh_frame_t stack[SH_STACK_MAX];
    int        depth;      // top = stack[depth]
    int        sel;        // selection in current list view
    bool       booting;

    // overlay
    sh_ov_type_t ov_type;
    char         ov_pane[16];
    char         ov_ref[32];
    char         ov_prompt[96];
    const char  *ov_opts[6];
    char         ov_opt_buf[6][48];
    int          ov_n;
    int          ov_sel;

    bool       voice;      // recording in detail
} g;

static sh_frame_t *top(void) { return &g.stack[g.depth]; }

// ── helpers ───────────────────────────────────────────────────────────────────
static const sh_repo_t *cur_repo(void) {
    int n; const sh_repo_t *r = sh_repos(&n);
    return &r[top()->repo_i];
}
static const sh_worktree_t *cur_wt(void) { return &cur_repo()->worktrees[top()->wt_i]; }
static const sh_pane_t *cur_pane(void) { return &cur_wt()->panes[top()->pane_i]; }

static int list_len(void) {
    switch (top()->view) {
        case SH_V_REPOS:     { int n; sh_repos(&n); return n; }
        case SH_V_WORKTREES: return cur_repo()->worktree_count;
        case SH_V_PANES:     return cur_wt()->pane_count;
        default:             return 0;   // home / detail have no list nav
    }
}

// ── status ring ───────────────────────────────────────────────────────────────
static void ring_anim_opa(void *obj, int32_t v) {
    lv_obj_set_style_arc_opa((lv_obj_t *)obj, (lv_opa_t)v, LV_PART_INDICATOR);
}
static void ring_set(lv_color_t color, bool breathe, bool soft) {
    lv_obj_set_style_arc_color(g.ring, color, LV_PART_INDICATOR);
    lv_anim_delete(g.ring, ring_anim_opa);
    if (breathe || soft) {
        lv_anim_t a; lv_anim_init(&a);
        lv_anim_set_var(&a, g.ring);
        lv_anim_set_exec_cb(&a, ring_anim_opa);
        lv_anim_set_values(&a, breathe ? 242 : 140, breathe ? 110 : 82);
        lv_anim_set_duration(&a, breathe ? 1500 : 4200);
        lv_anim_set_playback_duration(&a, breathe ? 1500 : 4200);
        lv_anim_set_repeat_count(&a, LV_ANIM_REPEAT_INFINITE);
        lv_anim_start(&a);
    } else {
        lv_obj_set_style_arc_opa(g.ring, 242, LV_PART_INDICATOR);
    }
}
// pick ring color/mode for the current context
static void ring_refresh(void) {
    if (g.booting) { ring_set(SH_ASH, false, true); return; }
    if (g.overlay) {
        lv_color_t c = g.ov_type == SH_OV_SUGGEST ? SH_EMBER
                     : g.ov_type == SH_OV_QUESTION ? SH_AMBER : SH_RED;
        ring_set(c, false, true); return;
    }
    switch (top()->view) {
        case SH_V_HOME: {
            sh_counts_t ct = sh_counts();
            if (ct.running > 0) ring_set(SH_GREEN, true, false);
            else ring_set(SH_ASH, false, true);
            break;
        }
        case SH_V_DETAIL: {
            sh_status_t s = cur_pane()->status;
            ring_set(sh_status_color(s), sh_status_breathe(s), false);
            break;
        }
        default: ring_set(SH_ASH, false, true); break;
    }
}

// ── small builders ────────────────────────────────────────────────────────────
static lv_obj_t *mk_label(lv_obj_t *p, const char *txt, const lv_font_t *font, lv_color_t col) {
    lv_obj_t *l = lv_label_create(p);
    lv_label_set_text(l, txt);
    lv_obj_set_style_text_font(l, font, 0);
    lv_obj_set_style_text_color(l, col, 0);
    return l;
}
static lv_obj_t *mk_dot(lv_obj_t *p, lv_color_t col, int d) {
    lv_obj_t *o = lv_obj_create(p);
    lv_obj_remove_style_all(o);
    lv_obj_set_size(o, d, d);
    lv_obj_set_style_radius(o, LV_RADIUS_CIRCLE, 0);
    lv_obj_set_style_bg_color(o, col, 0);
    lv_obj_set_style_bg_opa(o, LV_OPA_COVER, 0);
    return o;
}

// clear + get a fresh flex-column center container
static lv_obj_t *center_reset(lv_flex_align_t main) {
    lv_obj_clean(g.center);
    lv_obj_set_flex_flow(g.center, LV_FLEX_FLOW_COLUMN);
    lv_obj_set_flex_align(g.center, main, LV_FLEX_ALIGN_CENTER, LV_FLEX_ALIGN_CENTER);
    lv_obj_set_style_pad_row(g.center, 12, 0);
    return g.center;
}

// ── HOME ──────────────────────────────────────────────────────────────────────
// Connection pipeline status — shown instead of falling back to M1 mock data
// when no live MQTT panes have arrived yet. Surfaces exactly which stage the
// device is stuck at (WiFi → MQTT → E2EE → data) so failures are visible.
static void build_status(void) {
    lv_obj_t *c = center_reset(LV_FLEX_ALIGN_CENTER);
    mk_label(c, "seahelm", SH_FONT_TITLE, SH_BONE);

    const char *stage;
    lv_color_t  col = SH_AMBER;
    sh_mqtt_state_t ms = sh_mqtt_state();
    if (!sh_wifi_is_connected()) {
        stage = "WiFi 连接中…";
    } else if (ms == SH_MQTT_CONNECTING) {
        stage = "连接 broker…";
    } else if (ms != SH_MQTT_CONNECTED) {
        stage = "broker 连接失败"; col = SH_RED;
    } else if (!sh_crypto_active()) {
        stage = "E2EE 未初始化"; col = SH_RED;
    } else {
        stage = "已连接 · 等待数据";
    }
    mk_label(c, stage, SH_FONT_BODY, col);

    // tiny checklist of the three gates
    char line[48];
    snprintf(line, sizeof line, "WiFi %s  MQTT %s  E2EE %s",
             sh_wifi_is_connected() ? "OK" : "…",
             ms == SH_MQTT_CONNECTED ? "OK" : (ms == SH_MQTT_CONNECTING ? "…" : "X"),
             sh_crypto_active() ? "OK" : "X");
    mk_label(c, line, SH_FONT_BODY, SH_ASH);
}

static void build_home(void) {
    if (!sh_data_m2_active()) { build_status(); return; }

    lv_obj_t *c = center_reset(LV_FLEX_ALIGN_CENTER);
    sh_counts_t ct = sh_counts();
    mk_label(c, "seahelm", SH_FONT_TITLE, SH_BONE);
    if (ct.running > 0) {
        char buf[16]; snprintf(buf, sizeof buf, "%d", ct.running);
        lv_obj_t *n = mk_label(c, buf, SH_FONT_HERO, SH_BONE);
        lv_obj_set_style_text_color(n, SH_BONE, 0);
        mk_label(c, "running", SH_FONT_BODY, SH_ASH);   // M2: 个 Sailor 在跑
    } else {
        // idle "spirit": a soft ember-flecked disc stand-in
        lv_obj_t *sp = mk_dot(c, SH_STONE, 120);
        lv_obj_set_style_bg_grad_color(sp, SH_LAMP, 0);
        lv_obj_set_style_bg_grad_dir(sp, LV_GRAD_DIR_VER, 0);
        lv_obj_t *ember = mk_dot(sp, SH_EMBER, 9);
        lv_obj_align(ember, LV_ALIGN_CENTER, 8, -18);
    }
    if (ct.waiting > 0 || ct.failed > 0) {
        lv_obj_t *row = lv_obj_create(c);
        lv_obj_remove_style_all(row);
        lv_obj_set_size(row, LV_SIZE_CONTENT, LV_SIZE_CONTENT);
        lv_obj_set_flex_flow(row, LV_FLEX_FLOW_ROW);
        lv_obj_set_style_pad_column(row, 18, 0);
        lv_obj_set_flex_align(row, LV_FLEX_ALIGN_CENTER, LV_FLEX_ALIGN_CENTER, LV_FLEX_ALIGN_CENTER);
        if (ct.waiting > 0) {
            char b[24]; snprintf(b, sizeof b, "%d waiting", ct.waiting);
            mk_label(row, b, SH_FONT_BODY, SH_AMBER);
        }
        if (ct.failed > 0) {
            char b[24]; snprintf(b, sizeof b, "%d failed", ct.failed);
            mk_label(row, b, SH_FONT_BODY, SH_RED);
        }
    }
}

// ── LIST (repos / worktrees / panes) ──────────────────────────────────────────
static void status_dots(lv_obj_t *p, sh_roll_t roll) {
    lv_obj_t *row = lv_obj_create(p);
    lv_obj_remove_style_all(row);
    lv_obj_set_size(row, LV_SIZE_CONTENT, LV_SIZE_CONTENT);
    lv_obj_set_flex_flow(row, LV_FLEX_FLOW_ROW);
    lv_obj_set_style_pad_column(row, 8, 0);
    lv_obj_set_flex_align(row, LV_FLEX_ALIGN_END, LV_FLEX_ALIGN_CENTER, LV_FLEX_ALIGN_CENTER);
    struct { int n; lv_color_t c; } items[3] = {
        { roll.running, SH_GREEN }, { roll.waiting, SH_AMBER }, { roll.failed, SH_RED } };
    for (int i = 0; i < 3; i++) if (items[i].n) {
        lv_obj_t *cell = lv_obj_create(row);
        lv_obj_remove_style_all(cell);
        lv_obj_set_size(cell, LV_SIZE_CONTENT, LV_SIZE_CONTENT);
        lv_obj_set_flex_flow(cell, LV_FLEX_FLOW_ROW);
        lv_obj_set_style_pad_column(cell, 3, 0);
        lv_obj_set_flex_align(cell, LV_FLEX_ALIGN_START, LV_FLEX_ALIGN_CENTER, LV_FLEX_ALIGN_CENTER);
        mk_dot(cell, items[i].c, 6);
        char b[8]; snprintf(b, sizeof b, "%d", items[i].n);
        mk_label(cell, b, SH_FONT_META, SH_ASH);
    }
}

static void build_list(void) {
    lv_obj_t *c = center_reset(LV_FLEX_ALIGN_START);
    lv_obj_set_style_pad_row(c, 6, 0);

    const char *title; const char *kind;
    sh_view_t v = top()->view;
    if (v == SH_V_REPOS)      { title = "Decks";  kind = "DECKS"; }
    else if (v == SH_V_WORKTREES) { title = cur_repo()->name; kind = "CABINS"; }
    else                      { title = cur_wt()->branch; kind = "SAILORS"; }

    char head[48]; snprintf(head, sizeof head, "%s  ·  %d %s", title, list_len(), kind);
    lv_obj_t *hl = mk_label(c, head, SH_FONT_META, SH_ASH);
    lv_obj_set_style_pad_bottom(hl, 4, 0);

    int n = list_len();
    for (int i = 0; i < n; i++) {
        lv_obj_t *row = lv_obj_create(c);
        lv_obj_remove_style_all(row);
        lv_obj_set_width(row, 336);
        lv_obj_set_height(row, LV_SIZE_CONTENT);
        lv_obj_set_flex_flow(row, LV_FLEX_FLOW_ROW);
        lv_obj_set_flex_align(row, LV_FLEX_ALIGN_START, LV_FLEX_ALIGN_CENTER, LV_FLEX_ALIGN_CENTER);
        lv_obj_set_style_pad_hor(row, 17, 0);
        lv_obj_set_style_pad_ver(row, 14, 0);
        lv_obj_set_style_radius(row, 16, 0);
        lv_obj_set_style_pad_column(row, 8, 0);
        bool on = (i == g.sel);
        lv_obj_set_style_bg_opa(row, on ? LV_OPA_COVER : LV_OPA_TRANSP, 0);
        lv_obj_set_style_bg_color(row, on ? lv_color_mix(SH_EMBER, SH_LAMP, 60) : SH_LAMP, 0);

        if (v == SH_V_PANES) {
            const sh_pane_t *p = &cur_wt()->panes[i];
            lv_obj_t *name = lv_obj_create(row);
            lv_obj_remove_style_all(name);
            lv_obj_set_flex_grow(name, 1);
            lv_obj_set_height(name, LV_SIZE_CONTENT);
            lv_obj_set_flex_flow(name, LV_FLEX_FLOW_ROW);
            lv_obj_set_style_pad_column(name, 7, 0);
            lv_obj_set_flex_align(name, LV_FLEX_ALIGN_START, LV_FLEX_ALIGN_CENTER, LV_FLEX_ALIGN_CENTER);
            mk_label(name, p->id, SH_FONT_BODY, SH_EMBER);
            mk_label(name, p->agent, SH_FONT_BODY, SH_BONE);
            if (p->has_suggest) mk_label(name, "[s]", SH_FONT_META, SH_EMBER);
            if (p->has_question) mk_label(name, "[?]", SH_FONT_META, SH_AMBER);
            mk_dot(row, sh_status_color(p->status), 9);
        } else {
            const char *label; sh_roll_t roll;
            if (v == SH_V_REPOS) {
                int rn; const sh_repo_t *rs = sh_repos(&rn);
                label = rs[i].name; roll = sh_roll_repo(&rs[i]);
            } else {
                const sh_worktree_t *w = &cur_repo()->worktrees[i];
                label = w->branch; roll = sh_roll_worktree(w);
            }
            lv_obj_t *nm = mk_label(row, label, SH_FONT_BODY, SH_BONE);
            lv_obj_set_flex_grow(nm, 1);
            status_dots(row, roll);
        }
    }
    // keep selection roughly centered
    if (n > 0) {
        lv_obj_t *sel_row = lv_obj_get_child(c, g.sel + 1); // +1: header
        if (sel_row) lv_obj_scroll_to_view(sel_row, LV_ANIM_ON);
    }
}

// ── DETAIL (message feed) ─────────────────────────────────────────────────────
static void build_detail(void) {
    const sh_pane_t *p = cur_pane();
    lv_obj_clean(g.center);
    lv_obj_set_flex_flow(g.center, LV_FLEX_FLOW_COLUMN);
    lv_obj_set_flex_align(g.center, LV_FLEX_ALIGN_START, LV_FLEX_ALIGN_CENTER, LV_FLEX_ALIGN_CENTER);
    lv_obj_set_style_pad_row(g.center, 8, 0);

    if (g.voice) {
        lv_obj_set_flex_align(g.center, LV_FLEX_ALIGN_CENTER, LV_FLEX_ALIGN_CENTER, LV_FLEX_ALIGN_CENTER);
        char e[24]; snprintf(e, sizeof e, "REC · %s", p->id);
        mk_label(g.center, e, SH_FONT_META, SH_EMBER);
        mk_label(g.center, "00:01", SH_FONT_TITLE, SH_BONE);
        mk_label(g.center, "release to send", SH_FONT_META, SH_ASH);
        return;
    }

    // header
    lv_obj_t *head = lv_obj_create(g.center);
    lv_obj_remove_style_all(head);
    lv_obj_set_width(head, lv_pct(100));
    lv_obj_set_height(head, LV_SIZE_CONTENT);
    lv_obj_set_flex_flow(head, LV_FLEX_FLOW_ROW);
    lv_obj_set_flex_align(head, LV_FLEX_ALIGN_CENTER, LV_FLEX_ALIGN_CENTER, LV_FLEX_ALIGN_CENTER);
    lv_obj_set_style_pad_column(head, 9, 0);
    sh_agent_t ag = sh_agent(p->agent);
    lv_obj_t *av = lv_obj_create(head);
    lv_obj_remove_style_all(av);
    lv_obj_set_size(av, 34, 34);
    lv_obj_set_style_radius(av, 9, 0);
    lv_obj_set_style_bg_opa(av, LV_OPA_COVER, 0);
    lv_obj_set_style_bg_color(av, lv_color_mix(ag.color, SH_LAMP, 56), 0);
    lv_obj_t *avm = mk_label(av, ag.mono, SH_FONT_META, ag.color);
    lv_obj_center(avm);
    lv_obj_t *htxt = lv_obj_create(head);
    lv_obj_remove_style_all(htxt);
    lv_obj_set_flex_grow(htxt, 1);
    lv_obj_set_height(htxt, LV_SIZE_CONTENT);
    lv_obj_set_flex_flow(htxt, LV_FLEX_FLOW_COLUMN);
    char deck[48]; snprintf(deck, sizeof deck, "%s  %s", cur_repo()->name, p->id);
    mk_label(htxt, deck, SH_FONT_BODY, SH_BONE);
    lv_obj_t *bl = mk_label(htxt, p->brief, SH_FONT_META, SH_ASH);
    lv_label_set_long_mode(bl, LV_LABEL_LONG_DOT);
    lv_obj_set_width(bl, 214);

    // feed (scrollable, oldest→newest)
    lv_obj_t *feed = lv_obj_create(g.center);
    lv_obj_remove_style_all(feed);
    lv_obj_set_width(feed, lv_pct(100));
    lv_obj_set_flex_grow(feed, 1);
    lv_obj_set_flex_flow(feed, LV_FLEX_FLOW_COLUMN);
    lv_obj_set_style_pad_row(feed, 11, 0);
    lv_obj_set_style_pad_hor(feed, 14, 0);
    lv_obj_set_scroll_dir(feed, LV_DIR_VER);

    for (int i = p->history_len - 1; i >= 0; i--) {   // history is newest-first → reverse
        const sh_msg_t *m = &p->history[i];
        if (m->kind == SH_MSG_STATUS) {
            lv_obj_t *s = mk_label(feed, m->text, SH_FONT_META, SH_ASH);
            lv_obj_set_style_text_align(s, LV_TEXT_ALIGN_CENTER, 0);
            lv_obj_set_width(s, lv_pct(100));
            continue;
        }
        bool you = (m->kind == SH_MSG_YOU);
        bool ask = (m->kind == SH_MSG_ASK);
        lv_obj_t *bub = lv_obj_create(feed);
        lv_obj_remove_style_all(bub);
        lv_obj_set_width(bub, LV_SIZE_CONTENT);
        lv_obj_set_style_max_width(bub, 298, 0);
        lv_obj_set_height(bub, LV_SIZE_CONTENT);
        lv_obj_set_style_pad_all(bub, 13, 0);
        lv_obj_set_style_radius(bub, 16, 0);
        lv_obj_set_style_bg_opa(bub, LV_OPA_COVER, 0);
        lv_obj_set_style_bg_color(bub,
            you ? lv_color_mix(SH_EMBER, SH_LAMP, 60)
                : ask ? lv_color_mix(SH_AMBER, SH_LAMP, 50) : SH_LAMP, 0);
        lv_obj_set_style_align(bub, you ? LV_ALIGN_RIGHT_MID : LV_ALIGN_LEFT_MID, 0);
        lv_obj_t *t = mk_label(bub, m->text, SH_FONT_BODY, SH_BONE);
        lv_label_set_long_mode(t, LV_LABEL_LONG_WRAP);
        lv_obj_set_width(t, 268);
    }
    lv_obj_scroll_to_y(feed, LV_COORD_MAX, LV_ANIM_OFF);
}

// ── OVERLAY ───────────────────────────────────────────────────────────────────
static void overlay_close(void) {
    if (g.overlay) { lv_obj_delete(g.overlay); g.overlay = NULL; }
    g.ov_type = SH_OV_NONE;
    ring_refresh();
}
static void build_overlay(void) {
    lv_color_t ac = g.ov_type == SH_OV_SUGGEST ? SH_EMBER
                  : g.ov_type == SH_OV_QUESTION ? SH_AMBER : SH_RED;
    g.overlay = lv_obj_create(g.scr);
    lv_obj_remove_style_all(g.overlay);
    lv_obj_set_size(g.overlay, SH_W, SH_H);
    lv_obj_center(g.overlay);
    lv_obj_set_style_radius(g.overlay, LV_RADIUS_CIRCLE, 0);
    lv_obj_set_style_bg_color(g.overlay, SH_NIGHT, 0);
    lv_obj_set_style_bg_opa(g.overlay, LV_OPA_COVER, 0);
    lv_obj_set_flex_flow(g.overlay, LV_FLEX_FLOW_COLUMN);
    lv_obj_set_flex_align(g.overlay, LV_FLEX_ALIGN_CENTER, LV_FLEX_ALIGN_CENTER, LV_FLEX_ALIGN_CENTER);
    lv_obj_set_style_pad_all(g.overlay, 46, 0);
    lv_obj_set_style_pad_row(g.overlay, 13, 0);

    char pane[24]; snprintf(pane, sizeof pane, "%s", g.ov_pane[0] ? g.ov_pane : "");
    mk_label(g.overlay, pane, SH_FONT_META, SH_ASH);
    const char *eb = g.ov_type == SH_OV_SUGGEST ? "NEXT"
                   : g.ov_type == SH_OV_QUESTION ? "ANSWER" : "ERROR";
    mk_label(g.overlay, eb, SH_FONT_META, ac);
    if (g.ov_prompt[0]) {
        lv_obj_t *pr = mk_label(g.overlay, g.ov_prompt, SH_FONT_TITLE, SH_BONE);
        lv_label_set_long_mode(pr, LV_LABEL_LONG_WRAP);
        lv_obj_set_width(pr, 300);
        lv_obj_set_style_text_align(pr, LV_TEXT_ALIGN_CENTER, 0);
    }
    if (g.ov_type == SH_OV_NOTIFY) return;

    for (int i = 0; i < g.ov_n; i++) {
        lv_obj_t *opt = lv_obj_create(g.overlay);
        lv_obj_remove_style_all(opt);
        lv_obj_set_width(opt, 296);
        lv_obj_set_height(opt, LV_SIZE_CONTENT);
        lv_obj_set_flex_flow(opt, LV_FLEX_FLOW_ROW);
        lv_obj_set_flex_align(opt, LV_FLEX_ALIGN_START, LV_FLEX_ALIGN_CENTER, LV_FLEX_ALIGN_CENTER);
        lv_obj_set_style_pad_all(opt, 13, 0);
        lv_obj_set_style_pad_column(opt, 13, 0);
        lv_obj_set_style_radius(opt, 14, 0);
        lv_obj_set_style_bg_opa(opt, LV_OPA_COVER, 0);
        bool on = (i == g.ov_sel);
        lv_obj_set_style_bg_color(opt, on ? lv_color_mix(ac, SH_LAMP, 60) : SH_LAMP, 0);
        char num[4]; snprintf(num, sizeof num, "%d", i);
        lv_obj_t *n = lv_obj_create(opt);
        lv_obj_remove_style_all(n);
        lv_obj_set_size(n, 26, 26);
        lv_obj_set_style_radius(n, 6, 0);
        lv_obj_set_style_bg_opa(n, LV_OPA_COVER, 0);
        lv_obj_set_style_bg_color(n, on ? ac : lv_color_hex(0x100E0C), 0);
        lv_obj_t *nl = mk_label(n, num, SH_FONT_META, on ? SH_NIGHT : SH_ASH);
        lv_obj_center(nl);
        mk_label(opt, g.ov_opts[i], SH_FONT_BODY, SH_BONE);
    }
}

// ── toast ─────────────────────────────────────────────────────────────────────
static void toast_close_cb(lv_timer_t *t) {
    if (g.toast) { lv_obj_delete(g.toast); g.toast = NULL; }
    lv_timer_delete(t);
}
static void toast(const char *txt) {
    if (g.toast) lv_obj_delete(g.toast);
    g.toast = lv_label_create(g.scr);
    lv_label_set_text(g.toast, txt);
    lv_obj_set_style_text_font(g.toast, SH_FONT_META, 0);
    lv_obj_set_style_text_color(g.toast, SH_GREEN, 0);
    lv_obj_set_style_bg_color(g.toast, lv_color_hex(0x0A0908), 0);
    lv_obj_set_style_bg_opa(g.toast, LV_OPA_90, 0);
    lv_obj_set_style_pad_hor(g.toast, 12, 0);
    lv_obj_set_style_pad_ver(g.toast, 6, 0);
    lv_obj_set_style_radius(g.toast, 8, 0);
    lv_obj_align(g.toast, LV_ALIGN_BOTTOM_MID, 0, -46);
    lv_timer_create(toast_close_cb, 1600, NULL);
}

// ── render dispatch ───────────────────────────────────────────────────────────
static void render(void) {
    if (g.booting) return;
    switch (top()->view) {
        case SH_V_HOME:   build_home();   break;
        case SH_V_DETAIL: build_detail(); break;
        default:          build_list();   break;
    }
    ring_refresh();
}

void sh_ui_refresh(void) {
    // Re-render the current view from latest sh_data.
    // Called from main when MQTT delivers new data.
    if (g.booting) return;
    // Don't re-render if an overlay is showing (keeps the decision visible)
    if (g.overlay) return;
    render();
}

// ── nav ───────────────────────────────────────────────────────────────────────
static void push(sh_frame_t f) {
    if (g.depth + 1 >= SH_STACK_MAX) return;
    g.stack[++g.depth] = f;
    g.sel = 0;
    render();
}
void sh_ui_back(void) {
    if (g.overlay) { overlay_close(); return; }
    if (g.depth == 0) return;
    g.depth--;
    g.sel = 0;
    render();
}
void sh_ui_scroll(int delta) {
    if (g.overlay) {
        if (g.ov_type == SH_OV_NOTIFY || g.ov_n == 0) return;
        g.ov_sel = (g.ov_sel + delta + g.ov_n) % g.ov_n;
        lv_obj_delete(g.overlay); build_overlay();
        return;
    }
    int n = list_len();
    if (n == 0) return;
    g.sel = (g.sel + delta + n) % n;
    render();
}
void sh_ui_select(void) {
    if (g.overlay) {
        char m[64];
        if (g.ov_type == SH_OV_SUGGEST)
            snprintf(m, sizeof m, "suggest.pick {%s, %d}", g.ov_ref, g.ov_sel);
        else if (g.ov_type == SH_OV_QUESTION)
            snprintf(m, sizeof m, "question.answer {%s, %d}", g.ov_ref, g.ov_sel);
        else m[0] = 0;
        overlay_close();
        if (m[0]) toast(m);   // M2: publish to `command` topic
        return;
    }
    sh_frame_t f = *top();
    switch (top()->view) {
        case SH_V_HOME:      f.view = SH_V_REPOS; push(f); break;
        case SH_V_REPOS:     f.view = SH_V_WORKTREES; f.repo_i = g.sel; push(f); break;
        case SH_V_WORKTREES: f.view = SH_V_PANES; f.wt_i = g.sel; push(f); break;
        case SH_V_PANES:     f.view = SH_V_DETAIL; f.pane_i = g.sel; push(f); break;
        case SH_V_DETAIL:    break;
    }
}
void sh_ui_voice_start(void) {
    if (top()->view != SH_V_DETAIL || g.overlay) return;
    g.voice = true; render();
}
void sh_ui_voice_end(void) {
    if (!g.voice) return;
    g.voice = false; render();
    char m[48]; snprintf(m, sizeof m, "pane.send_text {%s}", cur_pane()->id);
    toast(m);   // M2: publish voice→text to `command`
}

void sh_ui_overlay(sh_ov_type_t type, const char *pane_id, const char *ref_id,
                   const char *prompt, const char *const *options, int n) {
    if (g.overlay) overlay_close();
    g.ov_type = type; g.ov_sel = 0;
    snprintf(g.ov_pane, sizeof g.ov_pane, "%s", pane_id ? pane_id : "");
    snprintf(g.ov_ref, sizeof g.ov_ref, "%s", ref_id ? ref_id : "");
    snprintf(g.ov_prompt, sizeof g.ov_prompt, "%s", prompt ? prompt : "");
    g.ov_n = n > 6 ? 6 : n;
    for (int i = 0; i < g.ov_n; i++) {
        snprintf(g.ov_opt_buf[i], sizeof g.ov_opt_buf[i], "%s", options[i]);
        g.ov_opts[i] = g.ov_opt_buf[i];
    }
    build_overlay();
    ring_refresh();
}

// ── boot → home ───────────────────────────────────────────────────────────────
static void boot_done_cb(lv_timer_t *t) {
    g.booting = false;
    render();
    lv_timer_delete(t);
}
void sh_ui_init(void) {
    memset(&g, 0, sizeof g);
    g.scr = lv_screen_active();
    lv_obj_set_style_bg_color(g.scr, SH_NIGHT, 0);
    lv_obj_set_style_bg_opa(g.scr, LV_OPA_COVER, 0);
    lv_obj_remove_flag(g.scr, LV_OBJ_FLAG_SCROLLABLE);

    // status ring (full-circle arc in the outer band)
    g.ring = lv_arc_create(g.scr);
    lv_obj_set_size(g.ring, SH_RING_R * 2, SH_RING_R * 2);
    lv_obj_center(g.ring);
    lv_arc_set_rotation(g.ring, 270);
    lv_arc_set_bg_angles(g.ring, 0, 360);
    lv_arc_set_angles(g.ring, 0, 360);
    lv_obj_remove_style(g.ring, NULL, LV_PART_KNOB);
    lv_obj_remove_flag(g.ring, LV_OBJ_FLAG_CLICKABLE);
    lv_obj_set_style_arc_width(g.ring, 3, LV_PART_MAIN);
    lv_obj_set_style_arc_color(g.ring, SH_STONE, LV_PART_MAIN);
    lv_obj_set_style_arc_opa(g.ring, LV_OPA_50, LV_PART_MAIN);
    lv_obj_set_style_arc_width(g.ring, 6, LV_PART_INDICATOR);

    // center content region (inset from the ring)
    g.center = lv_obj_create(g.scr);
    lv_obj_remove_style_all(g.center);
    lv_obj_set_size(g.center, SH_W - 92, SH_H - 92);
    lv_obj_center(g.center);
    lv_obj_set_scroll_dir(g.center, LV_DIR_VER);
    lv_obj_set_style_bg_opa(g.center, LV_OPA_TRANSP, 0);

    // boot screen
    g.booting = true;
    g.stack[0] = (sh_frame_t){ .view = SH_V_HOME };
    g.depth = 0;
    lv_obj_t *c = center_reset(LV_FLEX_ALIGN_CENTER);
    mk_label(c, "seahelm", SH_FONT_TITLE, SH_BONE);
    mk_label(c, "connecting...", SH_FONT_META, SH_ASH);
    ring_set(SH_ASH, false, true);

    lv_timer_create(boot_done_cb, 2100, NULL);
}
