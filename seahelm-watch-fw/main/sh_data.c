// sh_data.c — mock SRP/MQTT snapshot, grounded in seahelm field names.
// Mirrors seahelm-watch-data.jsx. M2 replaces this with live MQTT state.
#include "sh_data.h"
#include <string.h>

// ── seahelm / main / p1 ──────────────────────────────────────────────────────
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
    { "p1", "claude", SH_ST_RUNNING, "重排灵动岛展开态的卡片间距与阴影层级", false, false, p1_hist, 4 },
    { "p2", "codex",  SH_ST_IDLE,    "空闲 · 等待指令",                         false, false, p2_hist, 2 },
};

// ── seahelm / feat-island / p3 (waiting + question) ──────────────────────────
static const sh_msg_t p3_hist[] = {
    { "now", SH_MSG_ASK, "目标目录已存在 feat-island 的 worktree。要覆盖重新从 main 拉一份吗?覆盖会丢弃那边未提交改动。", false },
    { "30s", SH_MSG_RUN, "执行 git worktree add -b feat-island,检测到路径冲突。", false },
    { "1m",  SH_MSG_YOU, "基于 main 开一个 feat-island 实验分支,拿来试灵动岛新交互。", false },
};
static const sh_pane_t island_panes[] = {
    { "p3", "claude", SH_ST_WAITING, "等你答:覆盖已有分支?", false, true, p3_hist, 3 },
};

// ── seahelm / fix-socket / p4 (running + suggest), p5 (done) ──────────────────
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
    { "p4", "claude", SH_ST_RUNNING, "修复控制 socket 断线后不自动重连", true,  false, p4_hist, 3 },
    { "p5", "aider",  SH_ST_DONE,    "已完成 · 补了回归测试",             false, false, p5_hist, 2 },
};

static const sh_worktree_t seahelm_wts[] = {
    { "main",        "main",        "2m",  "改 island 布局 · 提交并推送", main_panes,   2 },
    { "feat-island", "feat-island", "刚刚", "覆盖已有分支?",              island_panes, 1 },
    { "fix-socket",  "fix-socket",  "12m", "控制 socket 重连逻辑",       socket_panes, 2 },
};

// ── claw-api ─────────────────────────────────────────────────────────────────
static const sh_msg_t p6_hist[] = { { "20m", SH_MSG_STATUS, "○ idle", false } };
static const sh_pane_t claw_main_panes[] = {
    { "p6", "claude", SH_ST_IDLE, "空闲", false, false, p6_hist, 1 },
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
    { "p7", "codex",  SH_ST_RUNNING, "重构统一网关 · 按协议拆分路由",       false, false, p7_hist, 2 },
    { "p8", "gemini", SH_ST_FAILED,  "失败 · npm test 3 处断言未过",        false, false, p8_hist, 3 },
};
static const sh_worktree_t claw_wts[] = {
    { "main",              "main",              "20m", "模型路由聚合",           claw_main_panes, 1 },
    { "refactor-gateway",  "refactor-gateway",  "1m",  "npm test 失败 · 3 处断言", gateway_panes,   2 },
};

static const sh_repo_t g_repos[] = {
    { "seahelm",  "seahelm",  seahelm_wts, 3 },
    { "claw-api", "claw-api", claw_wts,    2 },
};

const sh_repo_t *sh_repos(int *out_count) {
    if (out_count) *out_count = (int)(sizeof(g_repos) / sizeof(g_repos[0]));
    return g_repos;
}

sh_roll_t sh_roll_panes(const sh_pane_t *panes, int n) {
    sh_roll_t r = {0};
    for (int i = 0; i < n; i++) {
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
    return SH_ST_UNKNOWN;
}
