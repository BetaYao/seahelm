// mock-seahelm.js — stand-in for the Seahelm Mac publisher, over MQTT.
// Executable spec of what the real Swift MqttChannel must do (§15 of the design):
//   • publish retained pane/worktree/focus/presence snapshot on connect
//   • subscribe `command` → run trivially, reply on payload `reply_to` with `corr`
//   • subscribe `history/request` → reply from an in-memory buffer
// Run: node mock-seahelm.js   (after broker.js). Web client then fully interactive.
const mqtt = require('mqtt');

const URL = process.env.BROKER || 'ws://localhost:8083/mqtt';
const MAC = process.env.MAC || 'testmac';
const B = `seahelm/${MAC}`;
let seq = 100;
const nextSeq = () => ++seq;

const c = mqtt.connect(URL, {
  clientId: 'seahelm-mock',
  username: process.env.USER_MQTT, password: process.env.PASS_MQTT,
  will: { topic: `${B}/presence`, payload: JSON.stringify({ online: false, seq: 0 }), qos: 1, retain: true },
});

// ── mock state (mirrors sh_data.c) ───────────────────────────────────────────
const panes = {
  p1: { pane_id:'p1', session_name:'seahelm-main-p1', worktree_path:'/repo/seahelm', branch:'main',
        project:'seahelm', agent_type:'claude', status:'running', last_message:'重排灵动岛卡片间距' },
  p3: { pane_id:'p3', session_name:'seahelm-feat-p3', worktree_path:'/repo/seahelm-feat', branch:'feat-island',
        project:'seahelm', agent_type:'claude', status:'waiting', last_message:'等你答:覆盖已有分支?' },
  p8: { pane_id:'p8', session_name:'claw-p8', worktree_path:'/repo/claw', branch:'refactor-gateway',
        project:'claw-api', agent_type:'gemini', status:'failed', last_message:'npm test 3 处断言未过' },
};
const history = {
  p1: [
    { kind:'status', text:'● 开始运行 · 已读取 3 个文件' },
    { kind:'you',    text:'灵动岛展开时卡片挤太紧,松一点' },
    { kind:'agent',  text:'已把间距从 8 调到 12,顶部分隔线透明度降到 30%' },
  ],
  p3: [
    { kind:'you', text:'基于 main 开一个 feat-island 实验分支' },
    { kind:'ask', text:'目标目录已存在 worktree,要覆盖重拉吗?' },
  ],
  p8: [ { kind:'status', text:'✕ 失败 · npm test 退出码 1' } ],
};
const pub = (t, o, retain=false) => c.publish(`${B}/${t}`, JSON.stringify({ ...o, seq: nextSeq() }), { qos:1, retain });

function publishSnapshot() {
  pub('presence', { online:true }, true);
  for (const p of Object.values(panes)) pub(`pane/${p.pane_id}/status`, p, true);
  pub('worktree/main/status', { worktree_id:'main', worktree_path:'/repo/seahelm', branch:'main',
    project:'seahelm', status:'running', pane_count:1 }, true);
  publishFocus();
  // an open decision on p3 (question) — drives the 2FA/overlay path
  pub('pane/p3/event', { type:'question', question_id:'q-p3-1', pane_id:'p3',
    prompt:'覆盖已有分支?会丢弃未提交改动', options:['批准','拒绝'], danger:true });
}
function publishFocus() {
  const running = Object.values(panes).filter(p=>p.status==='running').length;
  const waiting = Object.values(panes).filter(p=>p.status==='waiting').length;
  const failed  = Object.values(panes).filter(p=>p.status==='failed').length;
  // single-focus selection: blocked(waiting) > running > idle
  const focusP = Object.values(panes).find(p=>p.status==='waiting')
              || Object.values(panes).find(p=>p.status==='running');
  pub('focus', { pane_id: focusP?.pane_id, kind: focusP?.status==='waiting'?'blocked':'working',
    headline: focusP?.agent_type||'', line: focusP?.last_message||'',
    counts: { running, waiting, failed, total: Object.keys(panes).length } }, true);
}

// ── command / history handlers (= ControlRouter surface) ──────────────────────
function reply(req, ok, extra) {
  if (!req.reply_to) return;
  const body = ok ? { ok:true, result: extra||{}, corr: req.corr }
                  : { ok:false, error: extra, corr: req.corr };
  c.publish(req.reply_to, JSON.stringify(body), { qos:1 });
}
function onCommand(req) {
  const { method, params={} } = req;
  switch (method) {
    case 'pane.send_text': {
      const p = panes[params.pane_id];
      if (!p) return reply(req, false, { code:-32004, message:'pane not found' });
      // echo user text into the feed, then a mock agent ack
      pub(`pane/${p.pane_id}/message`, { type:'pane.updated', pane_id:p.pane_id, kind:'you', text:params.text });
      setTimeout(()=> pub(`pane/${p.pane_id}/message`,
        { type:'pane.updated', pane_id:p.pane_id, last_message:`收到:${params.text}` }), 600);
      return reply(req, true, { sent:true });
    }
    case 'question.answer': {
      // clear the event, flip p3 running
      pub('pane/p3/event', '');                        // (client treats non-json/empty as clear)
      panes.p3.status = 'running'; panes.p3.last_message = `已${params.index===0?'批准':'拒绝'},继续`;
      pub('pane/p3/status', panes.p3, true);
      publishFocus();
      return reply(req, true, { answered:true });
    }
    case 'suggest.pick':
      return reply(req, true, { picked:true });
    case 'dnd.set':
      pub('dnd/state', { on:!!params.on, ends_at_epoch: Math.floor(Date.now()/1000)+ (params.minutes||25)*60,
        blocked_count:0 }, true);
      return reply(req, true, { on:!!params.on });
    default:
      return reply(req, false, { code:-32601, message:`unknown method: ${method}` });
  }
}
function onHistory(req) {
  const msgs = history[req.pane_id] || [];
  reply(req, true, { messages: msgs, has_more:false });
}

c.on('connect', () => {
  console.log(`[mock-seahelm] connected ${URL} as ${B}`);
  c.subscribe([`${B}/command`, `${B}/history/request`], { qos:1 });
  publishSnapshot();
  console.log('[mock-seahelm] snapshot published (retained). Ready.');
});
c.on('message', (t, buf) => {
  let m; try { m = JSON.parse(buf.toString()); } catch { return; }
  if (t === `${B}/command`) { console.log('[mock-seahelm] cmd', m.method); onCommand(m); }
  else if (t === `${B}/history/request`) { console.log('[mock-seahelm] history', m.pane_id); onHistory(m); }
});
c.on('error', e => console.error('[mock-seahelm] error', e.message));
