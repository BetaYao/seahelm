// protocol-test.js — exhaustive §15 protocol conformance test, client role.
// Runs against broker.js + mock-seahelm.js (the Seahelm-side executable spec),
// exercising every outbound topic and every inbound command exactly as the web
// client does (payload reply_to/corr, MQTT 3.1.1). Exits 0 only if ALL pass.
const mqtt = require('mqtt');
const B = 'seahelm/testmac';
const URL = process.env.BROKER || 'ws://localhost:8083/mqtt';

const rx = [];                       // {topic, raw, obj}
let corrN = 0, passed = 0, failed = 0;
const c = mqtt.connect(URL, { clientId: 'proto-test', clean: true });

function log(ok, name, extra='') {
  console.log(`  ${ok ? '✓' : '✗ FAIL'} ${name}${extra ? ' — ' + extra : ''}`);
  ok ? passed++ : failed++;
}
const sleep = ms => new Promise(r => setTimeout(r, ms));
const found = pred => rx.filter(m => pred(m));
const last  = pred => found(pred).slice(-1)[0];

// send a command, await its reply (matched by corr) or timeout
function command(method, params) {
  const corr = 'c' + (++corrN), reply_to = `${B}/reply/proto/${corr}`;
  c.subscribe(reply_to, { qos: 1 });
  return new Promise((resolve) => {
    const started = Date.now();
    const iv = setInterval(() => {
      const r = last(m => m.topic === reply_to && m.obj && m.obj.corr === corr);
      if (r) { clearInterval(iv); resolve(r.obj); }
      else if (Date.now() - started > 4000) { clearInterval(iv); resolve(null); }
    }, 40);
    c.publish(`${B}/command`, JSON.stringify({ method, params, reply_to, corr }), { qos: 1 });
  });
}
function historyReq(params) {
  const corr = 'h' + (++corrN), reply_to = `${B}/reply/proto/${corr}`;
  c.subscribe(reply_to, { qos: 1 });
  return new Promise((resolve) => {
    const started = Date.now();
    const iv = setInterval(() => {
      const r = last(m => m.topic === reply_to && m.obj && m.obj.corr === corr);
      if (r) { clearInterval(iv); resolve(r.obj); }
      else if (Date.now() - started > 4000) { clearInterval(iv); resolve(null); }
    }, 40);
    c.publish(`${B}/history/request`, JSON.stringify({ ...params, reply_to, corr }), { qos: 1 });
  });
}
const waitFor = async (pred, ms = 3000) => {
  const started = Date.now();
  while (Date.now() - started < ms) { if (last(pred)) return last(pred); await sleep(40); }
  return null;
};

c.on('message', (topic, buf) => {
  const raw = buf.toString();
  let obj = null; try { obj = raw ? JSON.parse(raw) : null; } catch {}
  rx.push({ topic, raw, obj });
});

c.on('connect', async () => {
  c.subscribe(`${B}/#`, { qos: 1 });
  await sleep(700);   // let retained snapshot arrive

  console.log('\n── Outbound: retained snapshot (上线即得) ──');
  const presence = last(m => m.topic === `${B}/presence`);
  log(!!presence && presence.obj.online === true, 'presence retained online=true');

  const st = id => last(m => m.topic === `${B}/pane/${id}/status`);
  const p1 = st('seahelm-main-p1'), p3 = st('seahelm-feat-p3'), p8 = st('claw-p8');
  log(!!p1 && !!p3 && !!p8, 'pane/+/status retained (p1,p3,p8)',
      `statuses ${p1&&p1.obj.status}/${p3&&p3.obj.status}/${p8&&p8.obj.status}`);
  log(!!p1 && ['pane_id','pane_session_key','worktree_path','branch','project','agent_type','status','last_message','seq']
        .every(k => k in p1.obj), 'PaneSnapshot.dict full field set (§15.4)');

  const wt = last(m => m.topic === `${B}/worktree/main/status`);
  log(!!wt && wt.obj.worktree_id === 'main' && !!wt.obj.status, 'worktree/{id}/status retained');

  const focus = last(m => m.topic === `${B}/focus`);
  const okFocus = !!focus && focus.obj.counts &&
    ['running','waiting','failed','total'].every(k => k in focus.obj.counts) &&
    focus.obj.pane_id === 'p3' && focus.obj.kind === 'blocked';
  log(okFocus, 'focus retained (single-focus=p3/blocked + counts)',
      focus ? JSON.stringify(focus.obj.counts) : '');

  const dnd0 = last(m => m.topic === `${B}/dnd/state`);
  log(!!dnd0 && dnd0.obj.on === false, 'dnd/state retained (initial on=false)');

  console.log('\n── Inbound: commands (payload reply_to/corr) ──');
  const ping = await command('ping', {});
  log(!!ping && ping.ok && ping.result.pong === true, 'ping → {pong:true}');

  // question event + answer
  const eq = await command('mock.emit_question', {});
  log(!!eq && eq.ok, 'emit question event');
  const qev = await waitFor(m => m.topic === `${B}/pane/seahelm-feat-p3/event` && m.obj && m.obj.type === 'question');
  log(!!qev && Array.isArray(qev.obj.options) && !!qev.obj.question_id, 'question event delivered (options+id)');
  const before = rx.length;
  const ans = await command('question.answer', { question_id: 'q-p3-1', index: 0 });
  log(!!ans && ans.ok && ans.result.answered === true, 'question.answer → {answered:true}');
  const flip = await waitFor(m => m.topic === `${B}/pane/seahelm-feat-p3/status` && m.obj && m.obj.status === 'Running');
  log(!!flip, 'question.answer flips p3 → Running (retained update)');
  const cleared = found(m => m.topic === `${B}/pane/seahelm-feat-p3/event` && m.raw === '').length > 0;
  log(cleared, 'question event cleared (empty payload)');

  // suggest event + pick
  const es = await command('mock.emit_suggest', {});
  log(!!es && es.ok, 'emit suggest event');
  const sev = await waitFor(m => m.topic === `${B}/pane/seahelm-main-p1/event` && m.obj && m.obj.type === 'suggest');
  log(!!sev && !!sev.obj.suggest_id && Array.isArray(sev.obj.options), 'suggest event delivered (options+id)');
  const pick = await command('suggest.pick', { suggest_id: 's-p1-1', index: 0 });
  log(!!pick && pick.ok && pick.result.picked === true, 'suggest.pick → {picked:true}');

  // send_text → reply + echoed message
  const sendt = await command('pane.send_text', { pane_session_key: 'seahelm-main-p1', text: '跑测试', enter: true });
  log(!!sendt && sendt.ok && sendt.result.sent === true, 'pane.send_text → {sent:true}');
  const echoed = await waitFor(m => m.topic === `${B}/pane/seahelm-main-p1/message` && m.obj && m.obj.text === '跑测试');
  log(!!echoed, 'pane/{id}/message echoed (feed)');

  // dnd.set → reply + dnd/state update
  const dset = await command('dnd.set', { on: true, minutes: 25 });
  log(!!dset && dset.ok && dset.result.on === true, 'dnd.set → {on:true}');
  const dnd1 = await waitFor(m => m.topic === `${B}/dnd/state` && m.obj && m.obj.on === true);
  log(!!dnd1 && dnd1.obj.ends_at_epoch > 0, 'dnd/state retained updated (on=true, ends_at set)');

  // unknown method → error
  const bogus = await command('bogus.method', {});
  log(!!bogus && bogus.ok === false && bogus.error.code === -32601, 'unknown method → error -32601');

  console.log('\n── History (JSONL buffer, paging) ──');
  const hAll = await historyReq({ pane_session_key: 'seahelm-main-p1', limit: 50 });
  log(!!hAll && hAll.ok && hAll.result.messages.length === 5 && hAll.result.has_more === false,
      'history full (5 msgs, has_more=false)');
  const hPage = await historyReq({ pane_session_key: 'seahelm-main-p1', limit: 2, before_seq: 4 });
  const seqs = hPage && hPage.result.messages.map(m => m.seq);
  log(!!hPage && JSON.stringify(seqs) === JSON.stringify([2, 3]) && hPage.result.has_more === true,
      'history paging (before_seq=4,limit=2 → [2,3], has_more=true)', seqs ? JSON.stringify(seqs) : '');

  console.log(`\n${failed === 0 ? '✅ ALL PROTOCOL TESTS PASS' : '❌ ' + failed + ' FAILED'}  (${passed} passed, ${failed} failed)`);
  c.end();
  process.exit(failed === 0 ? 0 : 1);
});

setTimeout(() => { console.error('HARD TIMEOUT'); process.exit(2); }, 25000);
