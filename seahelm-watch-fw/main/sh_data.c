// sh_data.c — M1 static mock + M2 MQTT-driven slot store.
// M1 mock lives at compile time; M2 store is populated by sh_data_m2_* calls.
// When M2 has data, sh_repos merges M2 into the tree and returns that.
#include "sh_data.h"
#include <string.h>
#include <stdio.h>
#include <stdlib.h>
#include "esp_log.h"
#include "esp_heap_caps.h"   // PSRAM pool allocation
#include "cJSON.h"

static const char *TAG = "sh_data";

// ══════════════════════════════════════════════════════════════════════════════
// M1: STATIC MOCK DATA
// ══════════════════════════════════════════════════════════════════════════════

static const sh_msg_t p1_hist[] = {
    { "now", SH_MSG_RUN,    "正在编辑 IslandView.swift,调整展开态卡片的堆叠约束与阴影层级。", false },
    { "40s", SH_MSG_AGENT,  "已把展开态卡片间距从 8 调到 12,并给最外层加了 2pt 安全边距;顶部分隔线透明度降到 30%,更透气。要不要连收起态也一起调。", false },
    { "1m",  SH_MSG_YOU,    "灵动岛展开时几张卡片挤太紧,帮我展开时松一点,收起态先别动。", false },
    { "2m",  SH_MSG_STATUS, "● 开始运行 · 已读取 IslandView 相关 3 个文件", false },
};
static const sh_msg_t p2_hist[] = {
    { "5m", SH_MSG_STATUS, "○ 空闲 · 上一轮已结束,等待下一步指令", false },
    { "6m", SH_MSG_AGENT,  "已为 WorkspaceManager 生成单测骨架,覆盖 tab 增删与去重命名,留了 TODO 占位。", false },
};
static const sh_pane_t main_panes[] = {
    { .id="p1", .agent="claude", .status=SH_ST_RUNNING, .brief="重排灵动岛展开态的卡片间距与阴影层级", .has_suggest=false, .has_question=false, .history=p1_hist, .history_len=4 },
    { .id="p2", .agent="codex",  .status=SH_ST_IDLE,    .brief="空闲 · 等待指令",                     .has_suggest=false, .has_question=false, .history=p2_hist, .history_len=2 },
};

static const sh_msg_t p3_hist[] = {
    { "now", SH_MSG_ASK, "目标目录已存在 feat-island 的 worktree。要覆盖重新从 main 拉一份吗?覆盖会丢弃那边未提交改动。", false },
    { "30s", SH_MSG_RUN, "执行 git worktree add -b feat-island,检测到路径冲突。", false },
    { "1m",  SH_MSG_YOU, "基于 main 开一个 feat-island 实验分支,拿来试灵动岛新交互。", false },
};
static const sh_pane_t island_panes[] = {
    { .id="p3", .agent="claude", .status=SH_ST_WAITING, .brief="等你答:覆盖已有分支?", .has_suggest=false, .has_question=true, .history=p3_hist, .history_len=3 },
};

static const sh_msg_t p4_hist[] = {
    { "now", SH_MSG_RUN,   "给 ControlSocketServer 重连加指数退避,初始 200ms、上限 5s,每次重试打印退避间隔。", false },
    { "3m",  SH_MSG_AGENT, "定位到了:socket 掉线后旧 fd 没关,重连每次新建,断几次就把 fd 耗光,之后全部失败。先补关闭再加退避。", false },
    { "12m", SH_MSG_YOU,   "控制 socket 掉线后一直不自动重连,得手动重启 app,排查下原因。", false },
};
static const sh_msg_t p5_hist[] = {
    { "8m",  SH_MSG_STATUS, "✓ 已完成 · 全部测试通过,工作区干净", false },
    { "10m", SH_MSG_AGENT,  "新增 SocketReconnectTests 共 4 例:正常重连、连续掉线、fd 不泄漏、退避封顶,跑三遍稳定通过。要提 PR 吗?", false },
};
static const sh_pane_t socket_panes[] = {
    { .id="p4", .agent="claude", .status=SH_ST_RUNNING, .brief="修复控制 socket 断线后不自动重连", .has_suggest=true,  .has_question=false, .history=p4_hist, .history_len=3 },
    { .id="p5", .agent="aider",  .status=SH_ST_DONE,    .brief="已完成 · 补了回归测试",             .has_suggest=false, .has_question=false, .history=p5_hist, .history_len=2 },
};

static const sh_pane_t claw_main_panes[] = {
    { .id="p6", .agent="claude", .status=SH_ST_IDLE, .brief="空闲", .history=NULL, .history_len=0 },
};
static const sh_msg_t p7_hist[] = {
    { "now", SH_MSG_RUN, "把 GatewayRouter 按协议拆成 OpenAIRoute / ClaudeRoute / GeminiRoute,共用一层参数归一化中间件。", false },
    { "4m",  SH_MSG_YOU, "网关把三家转换全塞在一个大 switch,太难维护,帮我各自拆开。", false },
};
static const sh_msg_t p8_hist[] = {
    { "1m", SH_MSG_STATUS, "✕ 失败 · npm test 退出码 1", false },
    { "1m", SH_MSG_RUN,    "npm test 跑完,3 个断言未过,集中在流式响应拼接:分片边界偶尔吞掉最后一个 token。", false },
    { "5m", SH_MSG_YOU,    "拆完先跑完整测试,确认没改坏原行为。", false },
};
static const sh_pane_t gateway_panes[] = {
    { .id="p7", .agent="codex",  .status=SH_ST_RUNNING, .brief="重构统一网关 · 按协议拆分路由",       .history=p7_hist, .history_len=2 },
    { .id="p8", .agent="gemini", .status=SH_ST_FAILED,  .brief="失败 · npm test 3 处断言未过",         .history=p8_hist, .history_len=3 },
};

// M1 mock repos — shown as a placeholder until live MQTT (M2) slots arrive.
// worktrees is an inline array field (sh_repo_t.worktrees[SH_MAX_WORKTREES]),
// so the worktree literals are brace-initialized directly here; array names
// (main_panes, …) decay to the const sh_pane_t * that .panes expects.
static const sh_repo_t g_m1_repos[] = {
    { "seahelm", "seahelm", {
        { "main",        "main",        "2m",  "改 island 布局 · 提交并推送", main_panes,   2 },
        { "feat-island", "feat-island", "刚刚", "覆盖已有分支?",              island_panes, 1 },
        { "fix-socket",  "fix-socket",  "12m", "控制 socket 重连逻辑",       socket_panes, 2 },
    }, 3 },
    { "claw-api", "claw-api", {
        { "main",             "main",             "20m", "模型路由聚合",           claw_main_panes, 1 },
        { "refactor-gateway", "refactor-gateway", "1m",  "npm test 失败 · 3 处断言", gateway_panes,   2 },
    }, 2 },
};

// ══════════════════════════════════════════════════════════════════════════════
// M2: DYNAMIC SLOT STORE
// ══════════════════════════════════════════════════════════════════════════════

// Max number of slots (panes) we track
#define M2_MAX_SLOTS 48

// Storage for pane strings (allocated, freed on reset)
typedef struct {
    char slot_key[48];           // pane_session_key
    char pane_id[48];
    char agent[24];
    sh_status_t status;
    char brief[192];
    char project[64];
    char worktree_path[128];
    char branch[64];
    bool has_suggest;
    bool has_question;
    char question_id[48];
    char question_prompt[256];
    char suggest_id[48];
    char suggest_message[256];
    sh_msg_t history[SH_MAX_HISTORY];
    int history_len;
    uint32_t seq;                // for ordering
    bool valid;                  // slot is active
} m2_slot_t;

static struct {
    m2_slot_t slots[M2_MAX_SLOTS];
    int       slot_count;        // number of valid slots
    bool      presence;          // Mac online
    bool      presence_set;      // presence has been received
    bool      active;            // M2 has data (at least one pane status received)
    char      focus_json[512];   // raw focus JSON
    bool      has_focus;
    char      dnd_json[256];     // raw DND JSON
    bool      has_dnd;
} s_m2;

void sh_data_m2_reset(void) {
    memset(&s_m2, 0, sizeof(s_m2));
    ESP_LOGI(TAG, "M2 store reset");
}

bool sh_data_m2_active(void) { return s_m2.active; }

static m2_slot_t *find_slot(const char *slot) {
    for (int i = 0; i < M2_MAX_SLOTS; i++) {
        if (s_m2.slots[i].valid && strcmp(s_m2.slots[i].slot_key, slot) == 0)
            return &s_m2.slots[i];
    }
    return NULL;
}

static m2_slot_t *alloc_slot(const char *slot) {
    m2_slot_t *existing = find_slot(slot);
    if (existing) return existing;

    for (int i = 0; i < M2_MAX_SLOTS; i++) {
        if (!s_m2.slots[i].valid) {
            memset(&s_m2.slots[i], 0, sizeof(m2_slot_t));
            strncpy(s_m2.slots[i].slot_key, slot, sizeof(s_m2.slots[i].slot_key) - 1);
            s_m2.slots[i].valid = true;
            s_m2.slot_count++;
            return &s_m2.slots[i];
        }
    }
    ESP_LOGW(TAG, "M2 slot table full!");
    return NULL;
}

static void free_slot(const char *slot) {
    m2_slot_t *s = find_slot(slot);
    if (s) {
        memset(s, 0, sizeof(m2_slot_t));
        s_m2.slot_count--;
    }
}

// Count valid slots
__attribute__((unused)) static int count_slots(void) {
    int n = 0;
    for (int i = 0; i < M2_MAX_SLOTS; i++) {
        if (s_m2.slots[i].valid) n++;
    }
    return n;
}

void sh_data_m2_update_pane(const char *slot, const char *payload_json) {
    if (!slot || !slot[0]) return;

    if (!payload_json) {
        // Tombstone: remove the pane
        ESP_LOGI(TAG, "pane tombstone: %s", slot);
        free_slot(slot);
        return;
    }

    cJSON *j = cJSON_Parse(payload_json);
    if (!j) {
        ESP_LOGW(TAG, "invalid pane JSON for %s", slot);
        return;
    }

    m2_slot_t *m2 = alloc_slot(slot);
    if (!m2) { cJSON_Delete(j); return; }

    // Parse fields
    cJSON *f;
    if ((f = cJSON_GetObjectItem(j, "pane_id")) && cJSON_IsString(f))
        strncpy(m2->pane_id, f->valuestring, sizeof(m2->pane_id) - 1);
    if ((f = cJSON_GetObjectItem(j, "pane_session_key")) && cJSON_IsString(f))
        strncpy(m2->slot_key, f->valuestring, sizeof(m2->slot_key) - 1);
    if ((f = cJSON_GetObjectItem(j, "agent_type")) && cJSON_IsString(f))
        strncpy(m2->agent, f->valuestring, sizeof(m2->agent) - 1);
    if ((f = cJSON_GetObjectItem(j, "status")) && cJSON_IsString(f))
        m2->status = sh_status_from_str(f->valuestring);
    if ((f = cJSON_GetObjectItem(j, "project")) && cJSON_IsString(f))
        strncpy(m2->project, f->valuestring, sizeof(m2->project) - 1);
    if ((f = cJSON_GetObjectItem(j, "worktree_path")) && cJSON_IsString(f))
        strncpy(m2->worktree_path, f->valuestring, sizeof(m2->worktree_path) - 1);
    if ((f = cJSON_GetObjectItem(j, "branch")) && cJSON_IsString(f))
        strncpy(m2->branch, f->valuestring, sizeof(m2->branch) - 1);
    if ((f = cJSON_GetObjectItem(j, "seq")) && cJSON_IsNumber(f))
        m2->seq = (uint32_t)f->valuedouble;

    // Brief = title ?: last_message
    const char *title = "";
    if ((f = cJSON_GetObjectItem(j, "title")) && cJSON_IsString(f))
        title = f->valuestring;
    const char *last_msg = "";
    if ((f = cJSON_GetObjectItem(j, "last_message")) && cJSON_IsString(f))
        last_msg = f->valuestring;
    const char *brief = (title && title[0]) ? title : last_msg;
    strncpy(m2->brief, brief, sizeof(m2->brief) - 1);

    cJSON_Delete(j);
    s_m2.active = true;
}

void sh_data_m2_update_event(const char *slot, const char *payload_json) {
    if (!slot || !slot[0]) return;

    m2_slot_t *m2 = find_slot(slot);
    if (!m2) {
        // Event for unknown pane — create a minimal slot
        m2 = alloc_slot(slot);
    }
    if (!m2) return;

    if (!payload_json) {
        // Tombstone: clear events on this pane
        m2->has_suggest = false;
        m2->has_question = false;
        return;
    }

    cJSON *j = cJSON_Parse(payload_json);
    if (!j) return;

    cJSON *type_f = cJSON_GetObjectItem(j, "type");
    if (!type_f || !cJSON_IsString(type_f)) { cJSON_Delete(j); return; }
    const char *type = type_f->valuestring;

    if (strcmp(type, "question") == 0) {
        m2->has_question = true;
        m2->has_suggest = false;
        cJSON *f;
        if ((f = cJSON_GetObjectItem(j, "question_id")) && cJSON_IsString(f))
            strncpy(m2->question_id, f->valuestring, sizeof(m2->question_id) - 1);
        const char *prompt = "";
        if ((f = cJSON_GetObjectItem(j, "prompt")) && cJSON_IsString(f))
            prompt = f->valuestring;
        else if ((f = cJSON_GetObjectItem(j, "message")) && cJSON_IsString(f))
            prompt = f->valuestring;
        strncpy(m2->question_prompt, prompt, sizeof(m2->question_prompt) - 1);
        // options are parsed on-demand; store as text
        cJSON *opts = cJSON_GetObjectItem(j, "options");
        if (cJSON_IsArray(opts)) {
            // We don't store options inline; UI reads from the raw event if needed
        }
    } else if (strcmp(type, "suggest") == 0) {
        m2->has_suggest = true;
        m2->has_question = false;
        cJSON *f;
        if ((f = cJSON_GetObjectItem(j, "suggest_id")) && cJSON_IsString(f))
            strncpy(m2->suggest_id, f->valuestring, sizeof(m2->suggest_id) - 1);
        const char *msg = "";
        if ((f = cJSON_GetObjectItem(j, "message")) && cJSON_IsString(f))
            msg = f->valuestring;
        strncpy(m2->suggest_message, msg, sizeof(m2->suggest_message) - 1);
    }

    cJSON_Delete(j);
}

void sh_data_m2_set_presence(bool online) {
    s_m2.presence = online;
    s_m2.presence_set = true;
}

bool sh_data_m2_is_presence(void) {
    return s_m2.presence_set && s_m2.presence;
}

void sh_data_m2_set_focus(const char *payload_json) {
    if (payload_json) {
        strncpy(s_m2.focus_json, payload_json, sizeof(s_m2.focus_json) - 1);
        s_m2.has_focus = true;
    } else {
        s_m2.has_focus = false;
    }
}

void sh_data_m2_set_dnd(const char *payload_json) {
    if (payload_json) {
        strncpy(s_m2.dnd_json, payload_json, sizeof(s_m2.dnd_json) - 1);
        s_m2.has_dnd = true;
    } else {
        s_m2.has_dnd = false;
    }
}

// ══════════════════════════════════════════════════════════════════════════════
// MODEL ACCESS — returns M2 if active, else M1 mock
// ══════════════════════════════════════════════════════════════════════════════

const sh_repo_t *sh_repos(int *out_count) {
    if (!sh_data_m2_active()) {
        if (out_count) *out_count = sizeof(g_m1_repos) / sizeof(g_m1_repos[0]);
        return g_m1_repos;
    }

    // Build tree from M2 slots
    // Use global static pools so pointers remain valid between calls.
    // One pool entry per pane; total panes are bounded by M2_MAX_SLOTS (48), NOT
    // the theoretical repo×worktree×pane product (3072) — sizing to the product
    // overflowed DRAM by ~775 KB (s_hist_pool alone was 3072×12 sh_msg_t).
    #define M2_POOL_SIZE M2_MAX_SLOTS
    // Pools live in PSRAM (allocated once, pointers stay valid between calls) so
    // they don't sit in the scarce internal DRAM segment — with WiFi/lwip also
    // claiming DRAM, keeping these ~19 KB out of it avoids a dram0 overflow.
    static sh_pane_t  *s_pane_pool = NULL;
    static sh_msg_t  (*s_hist_pool)[SH_MAX_HISTORY] = NULL;
    static int        s_pool_used = 0;
    static sh_repo_t  s_m2_repos[SH_MAX_REPOS];
    if (!s_pane_pool) {
        s_pane_pool = heap_caps_malloc(sizeof(sh_pane_t) * M2_POOL_SIZE, MALLOC_CAP_SPIRAM);
        s_hist_pool = heap_caps_malloc(sizeof(sh_msg_t) * M2_POOL_SIZE * SH_MAX_HISTORY, MALLOC_CAP_SPIRAM);
    }

    memset(s_m2_repos, 0, sizeof(s_m2_repos));

    // Collect unique projects and their worktrees, counting panes per worktree
    char proj_names[SH_MAX_REPOS][64];
    int  nrepos = 0;
    char wt_paths[SH_MAX_REPOS][SH_MAX_WORKTREES][128];
    char wt_branches[SH_MAX_REPOS][SH_MAX_WORKTREES][64];
    int  wt_pane_cnt[SH_MAX_REPOS][SH_MAX_WORKTREES];
    int  nwts[SH_MAX_REPOS] = {0};

    memset(wt_pane_cnt, 0, sizeof(wt_pane_cnt));

    // First pass: count panes per worktree per repo
    for (int i = 0; i < M2_MAX_SLOTS; i++) {
        if (!s_m2.slots[i].valid) continue;
        m2_slot_t *m2 = &s_m2.slots[i];
        const char *proj = m2->project[0] ? m2->project : "—";
        const char *wtp  = m2->worktree_path[0] ? m2->worktree_path : (m2->branch[0] ? m2->branch : "—");

        // Find/create repo
        int ri;
        for (ri = 0; ri < nrepos; ri++) {
            if (strcmp(proj_names[ri], proj) == 0) break;
        }
        if (ri >= nrepos && nrepos < SH_MAX_REPOS) {
            strncpy(proj_names[nrepos], proj, 63);
            nrepos++;
        }
        if (ri >= nrepos) continue;

        // Find/create worktree
        int wi;
        for (wi = 0; wi < nwts[ri]; wi++) {
            if (strcmp(wt_paths[ri][wi], wtp) == 0) break;
        }
        if (wi >= nwts[ri] && nwts[ri] < SH_MAX_WORKTREES) {
            strncpy(wt_paths[ri][nwts[ri]], wtp, 127);
            strncpy(wt_branches[ri][nwts[ri]], m2->branch, 63);
            nwts[ri]++;
            wi = nwts[ri] - 1;
        }
        if (wi >= SH_MAX_WORKTREES) continue;
        wt_pane_cnt[ri][wi]++;
    }

    // Second pass: allocate pool space and fill pane data
    s_pool_used = 0;
    // Pre-allocate per-worktree: track first pool index for each worktree
    int wt_first_pi[SH_MAX_REPOS][SH_MAX_WORKTREES];
    memset(wt_first_pi, 0, sizeof(wt_first_pi));
    for (int ri = 0; ri < nrepos; ri++) {
        s_m2_repos[ri].id = proj_names[ri];
        s_m2_repos[ri].name = proj_names[ri];
        s_m2_repos[ri].worktree_count = nwts[ri];
        for (int wi = 0; wi < nwts[ri]; wi++) {
            if (s_pool_used + wt_pane_cnt[ri][wi] > M2_POOL_SIZE) continue;
            wt_first_pi[ri][wi] = s_pool_used;
            s_m2_repos[ri].worktrees[wi].id = wt_paths[ri][wi];
            s_m2_repos[ri].worktrees[wi].branch = wt_branches[ri][wi];
            s_m2_repos[ri].worktrees[wi].ago = "";
            s_m2_repos[ri].worktrees[wi].last = "";
            s_m2_repos[ri].worktrees[wi].panes = &s_pane_pool[s_pool_used];
            s_m2_repos[ri].worktrees[wi].pane_count = wt_pane_cnt[ri][wi];
            s_pool_used += wt_pane_cnt[ri][wi];
        }
    }

    // Third pass: fill pane data
    int pane_offset[SH_MAX_REPOS][SH_MAX_WORKTREES];
    memset(pane_offset, 0, sizeof(pane_offset));

    for (int i = 0; i < M2_MAX_SLOTS; i++) {
        if (!s_m2.slots[i].valid) continue;
        m2_slot_t *m2 = &s_m2.slots[i];
        const char *proj = m2->project[0] ? m2->project : "—";
        const char *wtp  = m2->worktree_path[0] ? m2->worktree_path : (m2->branch[0] ? m2->branch : "—");

        int ri, wi;
        for (ri = 0; ri < nrepos; ri++) {
            if (strcmp(proj_names[ri], proj) == 0) break;
        }
        if (ri >= nrepos) continue;
        for (wi = 0; wi < nwts[ri]; wi++) {
            if (strcmp(wt_paths[ri][wi], wtp) == 0) break;
        }
        if (wi >= nwts[ri]) continue;

        int pool_idx = wt_first_pi[ri][wi] + pane_offset[ri][wi];
        pane_offset[ri][wi]++;
        if (pool_idx >= M2_POOL_SIZE) continue;

        sh_pane_t *p = &s_pane_pool[pool_idx];
        memset(p, 0, sizeof(*p));
        p->id = m2->slot_key;
        p->pane_id = m2->pane_id;
        p->agent = m2->agent;
        p->status = m2->status;
        p->brief = m2->brief;
        p->project = m2->project;
        p->worktree_path = m2->worktree_path;
        p->branch = m2->branch;
        p->has_suggest = m2->has_suggest;
        p->has_question = m2->has_question;
        p->question_id = m2->question_id;
        p->question_prompt = m2->question_prompt;
        p->suggest_id = m2->suggest_id;
        p->suggest_message = m2->suggest_message;
        p->history_len = m2->history_len;
        if (m2->history_len > 0) {
            memcpy(s_hist_pool[pool_idx], m2->history, m2->history_len * sizeof(sh_msg_t));
            p->history = s_hist_pool[pool_idx];
        } else {
            p->history = NULL;
        }
    }

    if (out_count) *out_count = nrepos;
    return s_m2_repos;
}

sh_counts_t sh_counts(void) {
    sh_counts_t c = {0};
    int nr; const sh_repo_t *rs = sh_repos(&nr);
    c.repos = nr;
    for (int i = 0; i < nr; i++) {
        c.worktrees += rs[i].worktree_count;
        for (int j = 0; j < rs[i].worktree_count; j++) {
            const sh_worktree_t *w = &rs[i].worktrees[j];
            c.panes += w->pane_count;
            sh_roll_t roll = sh_roll_worktree(w);
            c.running += roll.running; c.waiting += roll.waiting; c.failed += roll.failed;
        }
    }
    return c;
}

sh_roll_t sh_roll_panes(const sh_pane_t *panes, int n) {
    sh_roll_t r = {0};
    for (int i = 0; i < n; i++) {
        if (!panes[i].id || !panes[i].id[0]) continue;
        switch (panes[i].status) {
            case SH_ST_RUNNING: r.running++; break;
            case SH_ST_WAITING: r.waiting++; break;
            case SH_ST_FAILED:  r.failed++;  break;
            case SH_ST_DONE:    r.done++;    break;
            default:            r.idle++;    break;
        }
    }
    return r;
}

sh_roll_t sh_roll_worktree(const sh_worktree_t *w) {
    return sh_roll_panes(w->panes, w->pane_count);
}

sh_roll_t sh_roll_repo(const sh_repo_t *r) {
    sh_roll_t acc = {0};
    for (int i = 0; i < r->worktree_count; i++) {
        sh_roll_t w = sh_roll_worktree(&r->worktrees[i]);
        acc.running += w.running; acc.waiting += w.waiting; acc.failed += w.failed;
        acc.done += w.done; acc.idle += w.idle;
    }
    return acc;
}

sh_agent_t sh_agent(const char *name) {
    if (!name) return (sh_agent_t){ "?", SH_ASH };
    if (!strcmp(name, "claude"))   return (sh_agent_t){ "C",  SH_EMBER };
    if (!strcmp(name, "codex"))    return (sh_agent_t){ "Cx", SH_BONE };
    if (!strcmp(name, "opencode")) return (sh_agent_t){ "oc", SH_GREEN };
    if (!strcmp(name, "aider"))    return (sh_agent_t){ "ai", SH_AMBER };
    if (!strcmp(name, "gemini"))   return (sh_agent_t){ "G",  lv_color_hex(0x8FA6C4) };
    return (sh_agent_t){ name, SH_ASH };
}

sh_status_t sh_status_from_str(const char *raw) {
    if (!raw) return SH_ST_UNKNOWN;
    if (!strcmp(raw, "running")) return SH_ST_RUNNING;
    if (!strcmp(raw, "waiting")) return SH_ST_WAITING;
    if (!strcmp(raw, "done"))    return SH_ST_DONE;
    if (!strcmp(raw, "failed"))  return SH_ST_FAILED;
    if (!strcmp(raw, "idle"))    return SH_ST_IDLE;
    // Also accept capitalized versions (SailorStatus rawValue)
    if (!strcmp(raw, "Running")) return SH_ST_RUNNING;
    if (!strcmp(raw, "Waiting")) return SH_ST_WAITING;
    if (!strcmp(raw, "Exited") || !strcmp(raw, "Done")) return SH_ST_DONE;
    if (!strcmp(raw, "Error"))   return SH_ST_FAILED;
    if (!strcmp(raw, "Idle"))    return SH_ST_IDLE;
    return SH_ST_UNKNOWN;
}
