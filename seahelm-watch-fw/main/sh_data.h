// sh_data.h — the model the UI renders: repos → worktrees → panes.
// M1 = static mock (sh_data.c). M2 = filled from MQTT retained snapshots.
// Both share the same struct definitions; sh_data_m2_* functions update
// the dynamic store that replaces the static mock at runtime.
#pragma once
#include <stdbool.h>
#include <stdint.h>
#include "sh_theme.h"

#define SH_MAX_HISTORY 12
#define SH_MAX_PANES 32
#define SH_MAX_WORKTREES 12
#define SH_MAX_REPOS 8

typedef enum { SH_MSG_YOU, SH_MSG_AGENT, SH_MSG_ASK, SH_MSG_RUN, SH_MSG_STATUS } sh_msg_kind_t;

typedef struct {
    const char   *t;      // relative time label ("now", "2m")
    sh_msg_kind_t kind;
    const char   *text;
    bool          voice;  // was a voice → text message
} sh_msg_t;

typedef struct {
    const char *id;              // pane session key (slot)
    const char *pane_id;         // per-instance UUID
    const char *agent;           // "claude" / "codex" / ...
    sh_status_t status;
    const char *brief;           // one-line summary (dt-title)
    const char *project;         // repo / project name
    const char *worktree_path;
    const char *branch;
    bool        has_suggest;
    bool        has_question;
    const char *question_id;
    const char *question_prompt;
    const char *const *question_options;
    int         question_noptions;
    const char *suggest_id;
    const char *suggest_message;
    const char *const *suggest_options;
    int         suggest_noptions;
    const sh_msg_t *history;   // pointer to history array (M1: static; M2: internal buffer)
    int         history_len;
} sh_pane_t;

typedef struct {
    const char *id;         // worktree path
    const char *branch;
    const char *ago;        // "2m" / "刚刚"
    const char *last;       // last activity line
    const sh_pane_t *panes; // pointer to pane array (M1: static; M2: internal buffer)
    int         pane_count;
} sh_worktree_t;

typedef struct {
    const char *id;
    const char *name;
    sh_worktree_t worktrees[SH_MAX_WORKTREES];
    int         worktree_count;
} sh_repo_t;

typedef struct {
    int running, waiting, failed, done, idle;
} sh_roll_t;

typedef struct {
    int repos, worktrees, panes, running, waiting, failed;
} sh_counts_t;

// ── model access (returns merged M1 + M2 state) ─────────────────────────────
const sh_repo_t *sh_repos(int *out_count);
sh_counts_t      sh_counts(void);
sh_roll_t        sh_roll_panes(const sh_pane_t *panes, int n);
sh_roll_t        sh_roll_worktree(const sh_worktree_t *w);
sh_roll_t        sh_roll_repo(const sh_repo_t *r);

// agent glyph (2-char mono badge + accent color) for the detail header
typedef struct { const char *mono; lv_color_t color; } sh_agent_t;
sh_agent_t sh_agent(const char *name);
sh_status_t sh_status_from_str(const char *raw);

// ── M2: MQTT-driven slot management ────────────────────────────────────────
// These replace the static mock at runtime. Call from MQTT callbacks.

// Reset the M2 store (e.g. on reconnect, to clear stale retained state).
void sh_data_m2_reset(void);

// Update or remove a pane from retained pane/{slot}/status.
// payload_json: JSON string from the status topic, NULL = tombstone (pane closed).
void sh_data_m2_update_pane(const char *slot, const char *payload_json);

// Update or remove a pane event from pane/{slot}/event.
// payload_json: JSON string from the event topic, NULL = resolved.
void sh_data_m2_update_event(const char *slot, const char *payload_json);

// Set Mac presence (online/offline).
void sh_data_m2_set_presence(bool online);
bool sh_data_m2_is_presence(void);

// Set focus pane data (for glance).
void sh_data_m2_set_focus(const char *payload_json);

// Set DND state.
void sh_data_m2_set_dnd(const char *payload_json);

// Is the M2 store active (has any data from MQTT)?
bool sh_data_m2_active(void);
