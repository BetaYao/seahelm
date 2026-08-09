// vt-test.js — end-to-end check of the VT terminal channel, headless.
// Stands in for the browser: opens a stream on a real zmx session, verifies the
// snapshot arrives, types a command, and confirms the echo comes back through
// MQTT. Also prints the throughput numbers this PoC exists to produce.
//
// Run:  node broker.js  |  ZMX_PANES=1 node mock-seahelm.js  |  node vt-test.js
'use strict';

const mqtt = require('mqtt');
const { execFileSync } = require('child_process');
const { resolveZmx } = require('./zmx-vt');

const URL = process.env.BROKER || 'ws://localhost:28083/mqtt';
const MAC = process.env.MAC || 'testmac';
const B = `seahelm/${MAC}`;
const SESSION = process.env.VT_SESSION || 'vtpoc';
const MARKER = `VT_OK_${Date.now().toString(36)}`;

let pass = 0, fail = 0;
const check = (ok, name, extra = '') => {
  (ok ? pass++ : fail++);
  console.log(`${ok ? '✓' : '✗'} ${name}${extra ? '  ' + extra : ''}`);
};

// Make sure the session exists before we ask for a stream on it.
const liveSessions = () =>
  String(execFileSync(resolveZmx(), ['list', '--short'])).split('\n').map((s) => s.trim());
try {
  if (!liveSessions().includes(SESSION)) {
    // `zmx run <name> -d` with no command spawns the session's login shell — which
    // is exactly the interactive PTY this test types into — but then exits 1
    // complaining the command is missing. The session is created regardless, so
    // trust `list`, not the exit status.
    try { execFileSync(resolveZmx(), ['run', SESSION, '-d'], { stdio: 'ignore' }); } catch { /* see above */ }
    if (!liveSessions().includes(SESSION)) throw new Error(`could not create session ${SESSION}`);
    console.log(`(created throwaway session ${SESSION})`);
  }
} catch (e) {
  console.error('cannot reach zmx:', e.message);
  process.exit(1);
}

const c = mqtt.connect(URL, { clientId: 'vt-test' });
let corr = 0;
const replies = new Map();
function call(method, params) {
  return new Promise((resolve) => {
    const id = 'vt' + ++corr;
    const reply_to = `${B}/reply/vt-test/${id}`;
    replies.set(id, resolve);
    c.subscribe(reply_to, { qos: 1 }, () => {
      c.publish(`${B}/command`, JSON.stringify({ method, params, reply_to, corr: id }), { qos: 1 });
    });
  });
}

let snapshotBytes = 0, liveBytes = 0, liveMsgs = 0;
let stream = '';

c.on('message', (topic, buf) => {
  const seg = topic.split('/').slice(2);
  if (seg[0] === 'pane' && seg[2] === 'vt' && seg[1] === SESSION) {
    const m = JSON.parse(buf.toString());
    const bytes = Buffer.from(m.b64, 'base64');
    if (m.type === 'vt.snapshot') snapshotBytes += bytes.length;
    else { liveBytes += bytes.length; liveMsgs++; }
    stream += bytes.toString('utf8');
    return;
  }
  if (seg[0] === 'reply') {
    const id = seg[seg.length - 1];
    const fn = replies.get(id);
    if (fn) { replies.delete(id); fn(JSON.parse(buf.toString())); }
  }
});

const wait = (ms) => new Promise((r) => setTimeout(r, ms));

c.on('connect', async () => {
  c.subscribe(`${B}/pane/${SESSION}/vt`, { qos: 1 });
  c.subscribe(`${B}/pane/${SESSION}/status`, { qos: 1 });
  await wait(300);

  const opened = await call('pane.vt_open', { pane_session_key: SESSION, cols: 120, rows: 32 });
  check(opened && opened.ok, 'pane.vt_open accepted',
    opened && opened.result ? `geometry=${opened.result.cols}x${opened.result.rows}` : JSON.stringify(opened));
  await wait(900);            // outlast SNAPSHOT_MS (350) plus the attach replay
  check(snapshotBytes > 0, 'vt.snapshot delivered', `${snapshotBytes}B`);

  // Type a marker command the way a browser would: base64 of UTF-8 keystrokes.
  const keys = (s) => ({ pane_session_key: SESSION, b64: Buffer.from(s, 'utf8').toString('base64') });
  const sent = await call('pane.send_keys', keys(`echo ${MARKER}\r`));
  check(sent && sent.ok, 'pane.send_keys accepted');
  await wait(1200);
  check(stream.includes(MARKER), 'keystrokes reached the PTY and echoed back',
    `marker=${MARKER}`);
  check(liveMsgs > 0, 'live vt.data streamed', `${liveBytes}B in ${liveMsgs} msg`);

  // Ordering: one command per keystroke, fired without awaiting, is exactly the
  // shape that raced before sends were serialized ("VT_OK" arrived as "V_TOK").
  const ORDER = `ORDER_${Math.random().toString(36).slice(2, 8)}_END`;
  const before2 = stream.length;
  await call('pane.send_keys', keys('echo '));
  for (const ch of ORDER) call('pane.send_keys', keys(ch));   // deliberately not awaited
  await wait(900);
  await call('pane.send_keys', keys('\r'));
  await wait(1200);
  const tail = stream.slice(before2);
  check(tail.includes(ORDER), 'rapid per-character sends keep their order',
    tail.includes(ORDER) ? ORDER : `got: ${(tail.match(/ORDER_\S*/) || ['?'])[0]}`);

  // The regression that made the web terminal unreadable: `zmx tail` and
  // `zmx history --vt` keep colour but strip cursor motion, so a TUI repainting
  // in place (Codex, Claude Code) arrived as N stacked copies of its frame.
  // The live source has to stay `zmx attach`. If this fails, someone swapped it back.
  const beforeRepaint = stream.length;
  await call('pane.send_keys',
    keys("printf 'RP1\\nRP2\\nRP3\\n'; printf '\\033[3A'; printf 'RP-REDRAW\\n'\r"));
  await wait(1500);
  const repaintSeg = stream.slice(beforeRepaint);
  const keptMotion = /\x1b\[3A/.test(repaintSeg);
  check(keptMotion, 'in-place repaint keeps its cursor motion (ESC[3A)',
    keptMotion ? 'present' : 'STRIPPED — live source linearized again?');

  // Control bytes must survive the send path into the PTY.
  await call('pane.send_keys', keys('sleep 5\r'));
  await wait(500);
  await call('pane.send_keys', keys('\x03'));      // Ctrl-C
  await wait(800);
  check(/\^C/.test(stream), 'control byte (Ctrl-C) survived the round trip');

  // A throughput sample under a redraw-heavy command.
  const before = { b: liveBytes, m: liveMsgs };
  const t0 = Date.now();
  await call('pane.send_keys', keys('for i in $(seq 1 200); do echo "line $i padding padding padding"; done\r'));
  await wait(2500);
  const dt = (Date.now() - t0) / 1000;
  console.log(`\n  burst: ${liveBytes - before.b}B in ${liveMsgs - before.m} msgs `
    + `over ${dt.toFixed(1)}s → ${Math.round((liveBytes - before.b) / dt)}B/s, `
    + `${((liveMsgs - before.m) / dt).toFixed(1)} msg/s`);

  const stats = await call('mock.vt_stats', {});
  if (stats && stats.result) console.log('  bridge stats:', JSON.stringify(stats.result));

  await call('pane.vt_close', { pane_session_key: SESSION });
  console.log(`\n${fail ? '✗' : '✓'} ${pass} passed, ${fail} failed`);
  c.end(true);
  process.exit(fail ? 1 : 0);
});

c.on('error', (e) => { console.error('mqtt error', e.message); process.exit(1); });
setTimeout(() => { console.error('timeout'); process.exit(1); }, 30000).unref();
