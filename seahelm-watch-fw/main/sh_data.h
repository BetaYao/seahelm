// sh_data.h — the model the UI renders: repos → worktrees → panes.
// M1 = static mock (sh_data.c). M2 = filled from MQTT retained snapshots.
#pragma once
#include <stdbool.h>
#include <stdint.h>
#include "sh_theme.h"

#define SH_MAX_HISTORY 8

typedef enum { SH_MSG_YOU, SH_MSG_AGENT, SH_MSG_ASK, SH_MSG_RUN, SH_MSG_STATUS } sh_msg_kind_t;

typedef struct {
    const char   *t;      // relative time label ("now", "2m")
    sh_msg_kind_t kind;
    const char   *text;
    bool          voice;  // was a voice → text message
} sh_msg_t;

typedef struct {
    const char *id;         // pane id, e.g. "p3"
    const char *agent;      // "claude" / "codex" / ...
    sh_status_t status;
    const char *brief;      // one-line summary (dt-title)
    bool        has_suggest;
    bool        has_question;
    const sh_msg_t *history;
    int         history_len;
} sh_pane_t;

typedef struct {
    const char *id;         // worktree id
    const char *branch;
    const char *ago;        // "2m" / "刚刚"
    const char *last;       // last activity line
    const sh_pane_t *panes;
    int         pane_count;
} sh_worktree_t;

typedef struct {
    const char *id;
    const char *name;
    const sh_worktree_t *worktrees;
    int         worktree_count;
} sh_repo_t;

typedef struct {
    int running, waiting, failed, done, idle;
} sh_roll_t;

typedef struct {
    int repos, worktrees, panes, running, waiting, failed;
} sh_counts_t;

// model access
const sh_repo_t *sh_repos(int *out_count);
sh_counts_t      sh_counts(void);
sh_roll_t        sh_roll_panes(const sh_pane_t *panes, int n);
sh_roll_t        sh_roll_worktree(const sh_worktree_t *w);
sh_roll_t        sh_roll_repo(const sh_repo_t *r);

// agent glyph (2-char mono badge + accent color) for the detail header
typedef struct { const char *mono; lv_color_t color; } sh_agent_t;
sh_agent_t sh_agent(const char *name);
