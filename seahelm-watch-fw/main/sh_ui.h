// sh_ui.h — screen manager: nav stack, status ring, screen builders, input.
#pragma once
#include "lvgl.h"
#include "sh_data.h"

#ifdef __cplusplus
extern "C" {
#endif

// nav levels (a frame in the stack)
typedef enum { SH_V_HOME, SH_V_REPOS, SH_V_WORKTREES, SH_V_PANES, SH_V_DETAIL } sh_view_t;

typedef struct {
    sh_view_t view;
    int repo_i;   // valid at WORKTREES/PANES/DETAIL
    int wt_i;     // valid at PANES/DETAIL
    int pane_i;   // valid at DETAIL
} sh_frame_t;

// overlay events (suggest / question / notification), pop over any screen
typedef enum { SH_OV_NONE, SH_OV_SUGGEST, SH_OV_QUESTION, SH_OV_NOTIFY } sh_ov_type_t;

// Call once after LVGL + display are up. Builds the boot screen, then the UI.
void sh_ui_init(void);

// ── input actions (wired from buttons/touch in main.cpp) ──────────────────────
void sh_ui_scroll(int delta);   // crown / BtnA: move list selection
void sh_ui_select(void);        // BtnB / tap: drill in, or confirm overlay
void sh_ui_back(void);          // swipe-right / long BtnA: pop
void sh_ui_voice_start(void);   // hold BtnB in detail: begin recording
void sh_ui_voice_end(void);     // release: send (mock pane.send_text)

// M2: called by the MQTT layer when a pane/{id}/event arrives.
void sh_ui_overlay(sh_ov_type_t type, const char *pane_id,
                   const char *ref_id, const char *prompt,
                   const char *const *options, int n_options);

#ifdef __cplusplus
}
#endif
