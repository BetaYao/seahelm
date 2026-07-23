// mock-seahelm.js — stand-in for the Seahelm Mac publisher, over MQTT.
// Executable spec of what the real Swift MqttChannel does (§15 of the design):
//   • publish retained pane/worktree/focus/presence/dnd snapshot on connect
//   • subscribe `command` → run trivially, reply on payload `reply_to` with `corr`
//   • subscribe `history/request` → reply from an in-memory buffer (honors paging)
//   • events (question/suggest) are non-retained; emitted on demand via mock.emit.*
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

// ── mock state (mirrors sh_data.c; status uses SailorStatus rawValue casing) ──
const panes = {
  p1: { pane_id:'p1', session_name:'seahelm-main-p1', worktree_path:'/repo/seahelm', branch:'main',
        project:'seahelm', agent_type:'claude', status:'Running', last_message:'重排灵动岛卡片间距' },
  p3: { pane_id:'p3', session_name:'seahelm-feat-p3', worktree_path:'/repo/seahelm-feat', branch:'feat-island',
        project:'seahelm', agent_type:'claude', status:'Waiting', last_message:'等你答:覆盖已有分支?' },
  p8: { pane_id:'p8', session_name:'claw-p8', worktree_path:'/repo/claw', branch:'refactor-gateway',
        project:'claw-api', agent_type:'gemini', status:'Error', last_message:'npm test 3 处断言未过' },
};
const history = {
  p1: [
    { seq:1, kind:'status', text:'● 开始运行 · 已读取 3 个文件' },
    { seq:2, kind:'you',    text:'灵动岛展开时卡片挤太紧,松一点' },
    { seq:3, kind:'agent',  text:'已把间距从 8 调到 12,顶部分隔线透明度降到 30%' },
    { seq:4, kind:'status', text:'● 运行中' },
    { seq:5, kind:'agent',  text:'再给最外层加 2pt 安全边距' },
  ],
  p3: [
    { seq:1, kind:'you', text:'基于 main 开一个 feat-island 实验分支' },
    { seq:2, kind:'ask', text:'目标目录已存在 worktree,要覆盖重拉吗?' },
  ],
  p8: [ { seq:1, kind:'status', text:'✕ 失败 · npm test 退出码 1' } ],
};
const pub = (t, o, retain=false) => c.publish(`${B}/${t}`, JSON.stringify({ ...o, seq: nextSeq() }), { qos:1, retain });

function publishSnapshot() {
  pub('presence', { online:true }, true);
  for (const p of Object.values(panes)) pub(`pane/${p.pane_id}/status`, p, true);
  pub('worktree/main/status', { worktree_id:'main', worktree_path:'/repo/seahelm', branch:'main',
    project:'seahelm', status:'Running', pane_count:1 }, true);
  pub('dnd/state', { on:false, ends_at_epoch:0, blocked_count:0 }, true);
  publishFocus();
}
function publishFocus() {
  const by = (s) => Object.values(panes).filter(p=>p.status===s).length;
  const focusP = Object.values(panes).find(p=>p.status==='Waiting')
              || Object.values(panes).find(p=>p.status==='Running');
  pub('focus', { pane_id: focusP?.pane_id, kind: focusP?.status==='Waiting'?'blocked':'working',
    headline: focusP?.agent_type||'', line: focusP?.last_message||'',
    counts: { running: by('Running'), waiting: by('Waiting'), failed: by('Error'),
              total: Object.keys(panes).length } }, true);
}
function emitQuestion() {
  pub('pane/p3/event', { type:'question', question_id:'q-p3-1', pane_id:'p3',
    prompt:'覆盖已有分支?会丢弃未提交改动', options:['批准','拒绝'], danger:true });
}
function emitSuggest() {
  pub('pane/p1/event', { type:'suggest', suggest_id:'s-p1-1', pane_id:'p1',
    options:['跑测试','提交并推送','开姊妹 pane'], message:'改好 3 处文案' });
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
    case 'ping': return reply(req, true, { pong:true });
    case 'pane.send_text': case 'pane.run': {
      const p = panes[params.pane_id];
      if (!p) return reply(req, false, { code:-32004, message:'pane not found' });
      pub(`pane/${p.pane_id}/message`, { type:'pane.updated', pane_id:p.pane_id, kind:'you', text:params.text });
      setTimeout(()=> pub(`pane/${p.pane_id}/message`,
        { type:'pane.updated', pane_id:p.pane_id, last_message:`收到:${params.text}` }), 200);
      return reply(req, true, { sent:true });
    }
    case 'question.answer': {
      c.publish(`${B}/pane/p3/event`, '', {qos:1});                          // clear event (empty payload)
      panes.p3.status = 'Running'; panes.p3.last_message = `已${params.index===0?'批准':'拒绝'},继续`;
      pub('pane/p3/status', panes.p3, true);
      publishFocus();
      return reply(req, true, { answered:true });
    }
    case 'suggest.pick':
      c.publish(`${B}/pane/p1/event`, '', {qos:1});                          // clear suggest
      return reply(req, true, { picked:true });
    case 'dnd.set':
      pub('dnd/state', { on:!!params.on, ends_at_epoch: Math.floor(Date.now()/1000)+(params.minutes||25)*60,
        blocked_count:0 }, true);
      return reply(req, true, { on:!!params.on });
    // test hooks to emit non-retained events on demand
    case 'mock.emit_question': emitQuestion(); return reply(req, true, { emitted:'question' });
    case 'mock.emit_suggest':  emitSuggest();  return reply(req, true, { emitted:'suggest' });
    default:
      return reply(req, false, { code:-32601, message:`unknown method: ${method}` });
  }
}
function onHistory(req) {
  let msgs = history[req.pane_id] || [];
  if (typeof req.before_seq === 'number') msgs = msgs.filter(m => m.seq < req.before_seq);
  const limit = req.limit || 50;
  const window = msgs.slice(Math.max(0, msgs.length - limit));
  reply(req, true, { messages: window, has_more: msgs.length > window.length });
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
