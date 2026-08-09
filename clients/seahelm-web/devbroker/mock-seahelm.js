// mock-seahelm.js — stand-in for the Seahelm Mac publisher, over MQTT.
// Executable spec of what the real Swift MqttChannel does (§15 of the design):
//   • publish retained pane/worktree/focus/presence/dnd snapshot on connect
//   • subscribe `command` → run trivially, reply on payload `reply_to` with `corr`
//   • subscribe `history/request` → reply from an in-memory buffer (honors paging)
//   • events (question/suggest) are non-retained; emitted on demand via mock.emit.*
// Run: node mock-seahelm.js   (after broker.js). Web client then fully interactive.
//
// ZMX_PANES=1 additionally bridges *real* zmx sessions to the VT terminal channel
// (`npm run mock:zmx`). Off by default so the canned pane set — and therefore
// protocol-test.js's focus-count assertions — stay exactly as they were.
const mqtt = require('mqtt');
const crypto = require('crypto');
const path = require('path');
const { execFile } = require('child_process');
const { ZmxVT, resolveZmx } = require('./zmx-vt');

const URL = process.env.BROKER || 'ws://localhost:28083/mqtt';
const MAC = process.env.MAC || 'testmac';
const B = `seahelm/${MAC}`;
let seq = 100;
const nextSeq = () => ++seq;

// ── E2EE (matches e2ee.js / MqttCrypto.swift) ─────────────────────────────────
// ROOT_SECRET (base64url, 32B) → HKDF-SHA256 → hex password + AES-256-GCM key.
// Absent → plaintext (back-compat with USER_MQTT/PASS_MQTT).
const ROOT = process.env.ROOT_SECRET ? Buffer.from(process.env.ROOT_SECRET, 'base64url') : null;
let ENC_KEY = null;
let USER = process.env.USER_MQTT;
let PASS = process.env.PASS_MQTT;
if (ROOT) {
  const salt = Buffer.from('seahelm-pair-v1');
  PASS = Buffer.from(crypto.hkdfSync('sha256', ROOT, salt, Buffer.from('auth'), 32)).toString('hex');
  ENC_KEY = Buffer.from(crypto.hkdfSync('sha256', ROOT, salt, Buffer.from('e2ee'), 32));
  USER = MAC;
  console.log('[mock-seahelm] E2EE on (mac_id auth + AES-256-GCM payloads)');
}
function sealSync(topic, str) {
  if (!ENC_KEY || str === '' || str == null) return str;
  const iv = crypto.randomBytes(12);
  const ci = crypto.createCipheriv('aes-256-gcm', ENC_KEY, iv);
  ci.setAAD(Buffer.from(topic));
  const ct = Buffer.concat([ci.update(str, 'utf8'), ci.final()]);
  return Buffer.concat([Buffer.from([1]), iv, ct, ci.getAuthTag()]).toString('base64');
}
function openSync(topic, b64) {
  if (!ENC_KEY || b64 === '' || b64 == null) return b64;
  const env = Buffer.from(b64, 'base64');
  if (env[0] !== 1) throw new Error('bad envelope version');
  const iv = env.subarray(1, 13), tag = env.subarray(env.length - 16), ct = env.subarray(13, env.length - 16);
  const d = crypto.createDecipheriv('aes-256-gcm', ENC_KEY, iv);
  d.setAAD(Buffer.from(topic)); d.setAuthTag(tag);
  return Buffer.concat([d.update(ct), d.final()]).toString('utf8');
}

const c = mqtt.connect(URL, {
  clientId: 'seahelm-mock',
  username: USER, password: PASS,
  will: { topic: `${B}/presence`, payload: JSON.stringify({ online: false, seq: 0 }), qos: 1, retain: true },
});
// Transparently seal every string payload on the way out (topic = AES-GCM AAD).
const rawPublish = c.publish.bind(c);
c.publish = (t, p, opts, cb) => rawPublish(t, typeof p === 'string' ? sealSync(t, p) : p, opts || {}, cb);

// ── mock state (mirrors sh_data.c; status uses SailorStatus rawValue casing) ──
const panes = {
  p1: { pane_id:'p1', pane_session_key:'seahelm-main-p1', worktree_path:'/repo/seahelm', branch:'main',
        project:'seahelm', agent_type:'claude', status:'Running', last_message:'重排灵动岛卡片间距' },
  p3: { pane_id:'p3', pane_session_key:'seahelm-feat-p3', worktree_path:'/repo/seahelm-feat', branch:'feat-island',
        project:'seahelm', agent_type:'claude', status:'Waiting', last_message:'等你答:覆盖已有分支?' },
  p8: { pane_id:'p8', pane_session_key:'claw-p8', worktree_path:'/repo/claw', branch:'refactor-gateway',
        project:'claw-api', agent_type:'gemini', status:'Error', last_message:'npm test 3 处断言未过' },
};
const history = {
  'seahelm-main-p1': [
    { seq:1, kind:'status', text:'● 开始运行 · 已读取 3 个文件' },
    { seq:2, kind:'you',    text:'灵动岛展开时卡片挤太紧,松一点' },
    { seq:3, kind:'agent',  text:'已把间距从 8 调到 12,顶部分隔线透明度降到 30%' },
    { seq:4, kind:'status', text:'● 运行中' },
    { seq:5, kind:'agent',  text:'再给最外层加 2pt 安全边距' },
  ],
  'seahelm-feat-p3': [
    { seq:1, kind:'you', text:'基于 main 开一个 feat-island 实验分支' },
    { seq:2, kind:'ask', text:'目标目录已存在 worktree,要覆盖重拉吗?' },
  ],
  'claw-p8': [ { seq:1, kind:'status', text:'✕ 失败 · npm test 退出码 1' } ],
};
const pub = (t, o, retain=false) => c.publish(`${B}/${t}`, JSON.stringify({ ...o, seq: nextSeq() }), { qos:1, retain });

// ── VT terminal channel (real zmx sessions) ──────────────────────────────────
// Opt-in: the canned panes above are a fixture, these are live terminals.
// Payload is base64-in-JSON, not raw binary, because the E2EE envelope seals
// *strings* (e2ee.js) — a Buffer would sail past sealSync() in the clear.
// That is two base64 layers when E2EE is on (~1.8x). Known debt, see README.
const ZMX_ON = process.env.ZMX_PANES === '1';
const vtPanes = new Map();   // zmx session name → pane object
let vt = null;

function publishVT(name, chunk) {
  pub(`pane/${name}/vt`, { type: 'vt.data', b64: chunk.toString('base64') });
}

// ── git facts per worktree ───────────────────────────────────────────────────
// The First Mate list shows deck (repo), branch and a +adds −dels ↑ahead↓behind
// summary. These are real `git` reads, not fixtures — a fabricated diff count
// next to a real branch name is worse than no count at all. Cached, because
// four git processes per worktree on the 5s pane poll would be gratuitous.
const gitCache = new Map();   // worktree path → { at, info }
const GIT_TTL_MS = 30000;

function sh(cmd, args, cwd) {
  return new Promise((resolve) => {
    execFile(cmd, args, { cwd, timeout: 5000 }, (err, out) =>
      resolve(err ? null : String(out).trim()));
  });
}

async function gitInfo(dir) {
  const hit = gitCache.get(dir);
  if (hit && Date.now() - hit.at < GIT_TTL_MS) return hit.info;

  // `--git-common-dir` resolves to the *main* repo's .git even from a linked
  // worktree, so its grandparent is the deck name every worktree shares.
  // `--show-toplevel` is the worktree root, which is the identity a cabin has —
  // a session's start_dir is just wherever that shell happened to be launched,
  // and grouping by it split one worktree into a row per subdirectory.
  const [commonDir, top, branch, shortstat, aheadBehind] = await Promise.all([
    sh('git', ['rev-parse', '--path-format=absolute', '--git-common-dir'], dir),
    sh('git', ['rev-parse', '--show-toplevel'], dir),
    sh('git', ['rev-parse', '--abbrev-ref', 'HEAD'], dir),
    sh('git', ['diff', '--shortstat', 'HEAD'], dir),
    sh('git', ['rev-list', '--left-right', '--count', 'HEAD...@{u}'], dir),
  ]);

  const info = { project: '', root: top || dir, branch: branch || '',
                 added: 0, removed: 0, ahead: 0, behind: 0 };
  if (commonDir) info.project = path.basename(path.dirname(commonDir));
  if (shortstat) {
    info.added = Number((shortstat.match(/(\d+) insertion/) || [])[1] || 0);
    info.removed = Number((shortstat.match(/(\d+) deletion/) || [])[1] || 0);
  }
  // No upstream → the command fails and we simply report no divergence.
  if (aheadBehind) {
    const [a, b] = aheadBehind.split(/\s+/).map(Number);
    info.ahead = a || 0; info.behind = b || 0;
  }
  gitCache.set(dir, { at: Date.now(), info });
  return info;
}

/** Roll live zmx sessions up into the per-worktree records the First Mate shows. */
async function publishZmxWorktrees(rows) {
  // Keyed by worktree root, not by start_dir: sessions launched in different
  // subdirectories of one worktree are all sailors of the same cabin, which is
  // what the Mac shows. Grouping by start_dir listed `seahelm`, `seahelm-web`
  // and `devbroker` as three cabins that happened to share a branch and diff.
  const byRoot = new Map();
  for (const r of rows) {
    const dir = r.start_dir || '';
    if (!dir) continue;
    const info = await gitInfo(dir);
    const root = info.root || dir;
    if (!byRoot.has(root)) byRoot.set(root, { info, sessions: [] });
    byRoot.get(root).sessions.push(r);
  }

  const live = new Set();
  for (const [dir, entry] of byRoot) {
    const { info, sessions } = entry;
    const id = `zmx:${dir}`;
    live.add(id);
    // Elapsed ticks in the browser, so publish the origin instant rather than a
    // pre-rendered "8m24s" that would need republishing every second.
    const startedAt = Math.min(...sessions.map((s) => Number(s.created) || 0).filter(Boolean));
    const statuses = sessions.map((s) => (vtPanes.get(s.name) || {}).status || 'Idle');
    const rec = {
      worktree_id: id,
      worktree_path: dir,
      // Empty rather than a bogus deck name: the client renders "Unknown deck",
      // which is what the Mac shows for a worktree with no resolvable project.
      project: info.project || '',
      branch: info.branch || path.basename(dir),
      title: path.basename(dir),
      started_at: startedAt || null,
      pane_count: sessions.length,
      status: statuses.includes('Error') ? 'Error'
            : statuses.includes('Waiting') ? 'Waiting'
            : statuses.includes('Running') ? 'Running' : 'Idle',
      git: { added: info.added, removed: info.removed, ahead: info.ahead, behind: info.behind },
      panes: sessions.map((s) => s.name),
    };
    // Retained records only need republishing when they actually change; the 5s
    // poll would otherwise reissue all of them forever and bury the message log.
    const fingerprint = JSON.stringify(rec);
    if (wtFingerprints.get(id) === fingerprint) continue;
    wtFingerprints.set(id, fingerprint);
    pub(`worktree/${encodeURIComponent(id)}/status`, rec, true);
  }

  // Retained-delete worktrees whose last session went away.
  for (const gone of [...zmxWorktrees].filter((id) => !live.has(id))) {
    c.publish(`${B}/worktree/${encodeURIComponent(gone)}/status`, '', { qos: 1, retain: true });
    wtFingerprints.delete(gone);
  }
  zmxWorktrees = live;
}
let zmxWorktrees = new Set();
const wtFingerprints = new Map();

async function refreshZmxPanes() {
  const rows = await vt.listSessions();
  const names = rows.map((r) => r.name);
  // Tombstone sessions that went away so clients drop them (empty = retained-delete).
  for (const gone of [...vtPanes.keys()].filter((n) => !names.includes(n))) {
    vtPanes.delete(gone);
    vt.close(gone, 'session gone');
    c.publish(`${B}/pane/${gone}/status`, '', { qos: 1, retain: true });
  }
  for (const r of rows) {
    if (vtPanes.has(r.name)) continue;
    const dir = r.start_dir || '';
    const info = await gitInfo(dir);
    const p = { pane_id: r.name, pane_session_key: r.name,
                // Without a title the tree falls back to shortId(), which collapses
                // every `seahelm-*` session to the same label. The name is the label.
                title: r.name,
                // The worktree root, so the client groups panes into the same
                // cabins the worktree records describe.
                worktree_path: info.root || dir, branch: info.branch || path.basename(dir),
                // Empty, not a placeholder deck: a session whose start_dir has been
                // deleted has no deck, and the client renders that as "Unknown deck".
                project: info.project || '', agent_type: 'shell', status: 'Idle',
                last_message: '终端', has_vt: true };
    vtPanes.set(r.name, p);
    pub(`pane/${r.name}/status`, p, true);
  }
  await publishZmxWorktrees(rows);
}

function publishSnapshot() {
  pub('presence', { online:true }, true);
  // With the zmx bridge on you are looking at real panes, and mixing the canned
  // fixture in makes the list lie — it showed cabins the Mac does not have.
  // Protocol tests run with the bridge off, so their fixture is untouched; the
  // 「发 mock 快照」 button and `mock.emit.*` still inject it on demand.
  if (!ZMX_ON) {
    for (const p of Object.values(panes)) pub(`pane/${p.pane_session_key}/status`, p, true);
    pub('worktree/main/status', { worktree_id:'main', worktree_path:'/repo/seahelm', branch:'main',
      project:'seahelm', status:'Running', pane_count:1 }, true);
  } else {
    // Clear a fixture left retained by an earlier bridge-off run.
    for (const p of Object.values(panes)) c.publish(`${B}/pane/${p.pane_session_key}/status`, '', { qos:1, retain:true });
    c.publish(`${B}/worktree/main/status`, '', { qos:1, retain:true });
  }
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
  pub(`pane/${panes.p3.pane_session_key}/event`, { type:'question', question_id:'q-p3-1', pane_id:'p3',
    prompt:'覆盖已有分支?会丢弃未提交改动', options:['批准','拒绝'], danger:true });
}
function emitSuggest() {
  pub(`pane/${panes.p1.pane_session_key}/event`, { type:'suggest', suggest_id:'s-p1-1', pane_id:'p1',
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

    // ── VT terminal ──────────────────────────────────────────────────────────
    // vt_open replays a snapshot before the live stream, so a client that
    // connects mid-session still gets a correct screen. Ordering matters: the
    // tail is spawned first, then the snapshot publishes, then buffered live
    // bytes follow — anything else can interleave a redraw into stale scrollback.
    case 'pane.vt_open': {
      const name = params.pane_session_key || params.pane_id;
      if (!vt) return reply(req, false, { code:-32005, message:'zmx bridge off (ZMX_PANES=1)' });
      if (!name) return reply(req, false, { code:-32602, message:'pane_session_key required' });
      // No separate history fetch: attaching replays the current screen itself,
      // and that arrives as the `vt.snapshot` message (see ZmxVT.onSnapshot).
      // Geometry rides inside that message rather than this reply, because the
      // snapshot lands first — a client that resized on the reply would already
      // have replayed at the wrong row count, putting every absolute cursor
      // move (ESC[r;cH) on the wrong line.
      vt.open(name).then((size) => {
        reply(req, true, { opened:true, cols: size ? size.cols : null, rows: size ? size.rows : null });
      }).catch((e) => reply(req, false, { code:-32003, message:String(e && e.message || e) }));
      return;
    }
    case 'pane.vt_close': {
      const name = params.pane_session_key || params.pane_id;
      if (vt && name) vt.close(name, 'client closed');
      return reply(req, true, { closed:true });
    }
    // Heartbeat. Separate from vt_open because opening must always re-snapshot,
    // and a heartbeat must never restart the stream.
    case 'pane.vt_keepalive': {
      const name = params.pane_session_key || params.pane_id;
      return reply(req, true, { alive: !!(vt && name && vt.renew(name)) });
    }
    case 'pane.send_keys': {
      const name = params.pane_session_key || params.pane_id;
      if (!vt) return reply(req, false, { code:-32005, message:'zmx bridge off (ZMX_PANES=1)' });
      if (!name) return reply(req, false, { code:-32602, message:'pane_session_key required' });
      const text = params.b64 ? Buffer.from(params.b64, 'base64').toString('utf8') : (params.text || '');
      return vt.send(name, text).then((ok) => reply(req, ok, ok ? { sent:true }
        : { code:-32003, message:'zmx send failed' }));
    }
    case 'mock.vt_stats':
      return reply(req, true, vt ? vt.stats() : { code:'off' });

    case 'pane.send_text': case 'pane.run': {
      const name = params.pane_session_key || params.pane_id;
      // A live zmx pane takes the real path; the canned panes keep the fixture path.
      if (vt && vtPanes.has(name)) {
        const text = params.text + (params.enter === false ? '' : '\r');
        return vt.send(name, text).then((ok) => reply(req, ok, ok ? { sent:true }
          : { code:-32003, message:'zmx send failed' }));
      }
      const p = params.pane_id ? panes[params.pane_id]
              : Object.values(panes).find(x => x.pane_session_key === params.pane_session_key);
      if (!p) return reply(req, false, { code:-32004, message:'pane not found' });
      pub(`pane/${p.pane_session_key}/message`, { type:'pane.updated', pane_id:p.pane_id, kind:'you', text:params.text });
      setTimeout(()=> pub(`pane/${p.pane_session_key}/message`,
        { type:'pane.updated', pane_id:p.pane_id, last_message:`收到:${params.text}` }), 200);
      return reply(req, true, { sent:true });
    }
    case 'question.answer': {
      c.publish(`${B}/pane/${panes.p3.pane_session_key}/event`, '', {qos:1});                          // clear event (empty payload)
      panes.p3.status = 'Running'; panes.p3.last_message = `已${params.index===0?'批准':'拒绝'},继续`;
      pub(`pane/${panes.p3.pane_session_key}/status`, panes.p3, true);
      publishFocus();
      return reply(req, true, { answered:true });
    }
    case 'suggest.pick':
      c.publish(`${B}/pane/${panes.p1.pane_session_key}/event`, '', {qos:1});                          // clear suggest
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
  let msgs = history[req.pane_session_key] || history[req.pane_id] || [];
  if (typeof req.before_seq === 'number') msgs = msgs.filter(m => m.seq < req.before_seq);
  const limit = req.limit || 50;
  const window = msgs.slice(Math.max(0, msgs.length - limit));
  reply(req, true, { messages: window, has_more: msgs.length > window.length });
}

c.on('connect', () => {
  console.log(`[mock-seahelm] connected ${URL} as ${B}`);
  c.subscribe([`${B}/command`, `${B}/history/request`], { qos:1 });
  // See the handler below: this is how we learn about retained worktree records
  // a previous run of this process published.
  if (ZMX_ON) c.subscribe(`${B}/worktree/+/status`, { qos:1 });
  publishSnapshot();
  console.log('[mock-seahelm] snapshot published (retained). Ready.');
  if (!ZMX_ON) return;
  vt = new ZmxVT({
    onData: publishVT,
    onSnapshot: (name, chunk, size) => {
      pub(`pane/${name}/vt`, { type:'vt.snapshot', b64: chunk.toString('base64'),
                               cols: size.cols, rows: size.rows });
    },
    onClose: (name, reason) => console.log(`[mock-seahelm] vt closed ${name}: ${reason}`),
  });
  console.log(`[mock-seahelm] zmx bridge on → ${resolveZmx()}`);
  refreshZmxPanes();
  setInterval(refreshZmxPanes, 5000).unref();
  // Reap attach clients whose watcher went away without saying so.
  setInterval(() => vt.sweep(), 15000).unref();
  // Throughput readout — the measurement this PoC is for. `stats()` is cumulative,
  // so the per-window rate is ours to compute; that is what keeps this log and the
  // `mock.vt_stats` command from consuming each other's numbers.
  let lastVt = { bytes_in: 0, msgs_out: 0, seconds: 0 };
  setInterval(() => {
    const s = vt.stats();
    const dB = s.bytes_in - lastVt.bytes_in;
    const dM = s.msgs_out - lastVt.msgs_out;
    const dT = Math.max(0.001, s.seconds - lastVt.seconds);
    lastVt = s;
    if (dB || dM) {
      console.log(`[vt] ${dB}B in · ${dM} msgs · ${Math.round(dB / dT)}B/s · `
        + `${(dM / dT).toFixed(1)} msg/s · ${s.open_streams} open`);
    }
  }, 10000).unref();
});
for (const sig of ['SIGINT', 'SIGTERM']) {
  process.on(sig, () => { if (vt) vt.closeAll(); process.exit(0); });
}
c.on('message', (t, buf) => {
  let raw; try { raw = openSync(t, buf.toString()); } catch { return; }
  let m; try { m = JSON.parse(raw); } catch { return; }
  if (t === `${B}/command`) { console.log('[mock-seahelm] cmd', m.method); onCommand(m); }
  else if (t === `${B}/history/request`) { console.log('[mock-seahelm] history', m.pane_id); onHistory(m); }
  else if (ZMX_ON && /\/worktree\/[^/]+\/status$/.test(t) && m && typeof m.worktree_id === 'string'
           && m.worktree_id.startsWith('zmx:')) {
    // Retained records outlive the process that published them. Adopt whatever a
    // previous run left behind so the sweep below can tombstone the ones we no
    // longer own — otherwise a restart (or a change in how they are keyed, which
    // is exactly what moving from start_dir to worktree root was) strands them
    // on the broker forever.
    zmxWorktrees.add(m.worktree_id);
  }
});
c.on('error', e => console.error('[mock-seahelm] error', e.message));
