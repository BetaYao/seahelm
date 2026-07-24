// live-bridge.js — publish the RUNNING Seahelm's real state to the dev broker,
// without rebuilding the app. Polls the live control socket
// (~/.config/seahelm/seahelm.sock, session.snapshot) and republishes retained
// pane/worktree/focus/presence exactly as MqttChannel would (§15 topic tree).
//
// READ-ONLY by default: commands are NOT forwarded to your live agent panes.
// Set BRIDGE_ALLOW_WRITE=1 to also forward `command` → socket (types into real
// terminals — use with care).
//
// Run: node live-bridge.js   (after broker.js). Then the web client (mac=testmac)
// shows your real Seahelm panes.
const net = require('net');
const mqtt = require('mqtt');

const SOCK = (process.env.HOME || '') + '/.config/seahelm/seahelm.sock';
const B = `seahelm/${process.env.MAC || 'testmac'}`;
const URL = process.env.BROKER || 'ws://localhost:28083/mqtt';
const ALLOW_WRITE = process.env.BRIDGE_ALLOW_WRITE === '1';

let seq = 0;
const nextSeq = () => ++seq;
const PRI = { Waiting: 0, Error: 1, Running: 2, Exited: 3, Idle: 4, Unknown: 5 };
const pri = s => (s in PRI ? PRI[s] : 5);

// one request/response over the unix control socket (newline-delimited JSON-RPC)
function rpc(method, params) {
  return new Promise((resolve) => {
    const s = net.createConnection({ path: SOCK });
    let buf = '';
    const done = (v) => { try { s.end(); } catch {} resolve(v); };
    s.on('data', d => { buf += d.toString(); const nl = buf.indexOf('\n');
      if (nl >= 0) { try { resolve(JSON.parse(buf.slice(0, nl)).result); } catch { resolve(null); } try { s.end(); } catch {} } });
    s.on('error', () => resolve(null));
    s.on('connect', () => s.write(JSON.stringify({ id: '1', method, params: params || {} }) + '\n'));
    setTimeout(() => done(null), 2500);
  });
}

const m = mqtt.connect(URL, { clientId: 'live-bridge',
  will: { topic: `${B}/presence`, payload: JSON.stringify({ online: false, seq: 0 }), qos: 1, retain: true } });

let lastPaneIds = new Set();

async function tick() {
  const r = await rpc('session.snapshot');
  if (!r || !Array.isArray(r.panes)) return;
  const panes = r.panes;
  m.publish(`${B}/presence`, JSON.stringify({ online: true, seq: nextSeq() }), { qos: 1, retain: true });

  const now = new Set();
  for (const p of panes) {
    now.add(p.pane_id);
    m.publish(`${B}/pane/${p.pane_id}/status`, JSON.stringify({ ...p, seq: nextSeq() }), { qos: 1, retain: true });
  }
  // tombstone panes that disappeared since last tick
  for (const id of lastPaneIds) if (!now.has(id)) m.publish(`${B}/pane/${id}/status`, '', { qos: 1, retain: true });
  lastPaneIds = now;

  // worktree rollups
  const groups = {};
  for (const p of panes) (groups[p.worktree_path] ??= []).push(p);
  for (const [path, list] of Object.entries(groups)) {
    const id = path.split('/').pop() || path;
    const top = list.slice().sort((a, b) => pri(a.status) - pri(b.status))[0];
    m.publish(`${B}/worktree/${id}/status`, JSON.stringify({ worktree_id: id, worktree_path: path,
      branch: list[0].branch, project: list[0].project, status: top.status,
      pane_count: list.length, seq: nextSeq() }), { qos: 1, retain: true });
  }
  // single focus
  const top = panes.slice().sort((a, b) => pri(a.status) - pri(b.status))[0];
  const cnt = s => panes.filter(p => p.status === s).length;
  const kind = { Waiting: 'blocked', Error: 'blocked', Running: 'working', Exited: 'say' }[top.status] || 'idle';
  m.publish(`${B}/focus`, JSON.stringify({ pane_id: top.pane_id, kind, headline: top.agent_type,
    line: top.last_message, worktree: top.branch,
    counts: { running: cnt('Running'), waiting: cnt('Waiting'), failed: cnt('Error'), total: panes.length },
    seq: nextSeq() }), { qos: 1, retain: true });
}

m.on('connect', () => {
  console.log(`[live-bridge] broker=${URL} socket=${SOCK} write=${ALLOW_WRITE}`);
  if (ALLOW_WRITE) m.subscribe(`${B}/command`, { qos: 1 });
  tick();
  setInterval(tick, 2000);
});
m.on('message', async (t, buf) => {
  if (t !== `${B}/command` || !ALLOW_WRITE) return;
  let e; try { e = JSON.parse(buf.toString()); } catch { return; }
  const res = await rpc(e.method, e.params);
  if (e.reply_to) m.publish(e.reply_to, JSON.stringify(res != null
    ? { ok: true, result: res, corr: e.corr }
    : { ok: false, error: { code: -32004, message: 'socket error' }, corr: e.corr }), { qos: 1 });
});
m.on('error', e => console.error('[live-bridge] error', e.message));
