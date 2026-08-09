// zmx-vt.js — bridge a live zmx session to a VT byte stream.
//
// This is the PoC seam for remote terminal rendering (docs: custom-io Ghostty
// evaluation). It uses nothing but the `zmx` CLI that Seahelm already ships in
// its app bundle, so the Mac side needs no libghostty change.
//
//   screen + live  `zmx attach <name>`      real VT stream, via zmx-attach.py
//   input          `zmx send <name> <text>` fallback when not attached
//
// IMPORTANT — do not "simplify" this back to `zmx tail` / `zmx history --vt`.
// Both of those are linearized: they keep SGR colour but drop every cursor
// motion, so a TUI that repaints in place (Codex, Claude Code) arrives as N
// stacked copies of its frame. Measured on one workload emitting five ESC[3A
// repaints: attach carried 5 cursor-ups, tail carried 0. attach is also what
// Seahelm itself renders through, which is why it is the faithful one.
//
// Bytes are handed to `onData` already coalesced — a terminal emits many tiny
// writes (one per redraw) and publishing each as its own message is what would
// melt a broker. Coalescing is also where the throughput numbers come from:
// `stats()` reports raw bytes in vs messages out.
'use strict';

const { spawn, execFile } = require('child_process');
const fs = require('fs');
const path = require('path');
const os = require('os');

// Flush at most this often; a terminal redraw storm collapses into one message.
const FLUSH_MS = 16;
// Hard cap per published chunk. Above this we flush early rather than grow.
const MAX_CHUNK = 48 * 1024;
// The snapshot window: how long the first burst after attaching is held back
// and published as one message. A fixed window was wrong — on a cold bridge the
// replay can arrive later than any figure worth waiting, and the window then
// closed on an empty buffer. Instead: close it once the replay goes quiet, and
// cap it so a chatty pane cannot hold the screen back forever.
const SNAPSHOT_IDLE_MS = 160;
const SNAPSHOT_MAX_MS = 2500;
// Node has no pty and `zmx attach` needs a controlling terminal, so a small
// python3 relay stands in as one. See its docstring for the two traps.
const ATTACH_HELPER = path.join(__dirname, 'zmx-attach.py');
// How long a stream survives without the client renewing it. Comfortably more
// than the client's heartbeat, so a slow round trip never drops a live viewer.
const LEASE_TTL_MS = 60000;

/** Locate the zmx binary: $ZMX, then Seahelm's bundled copy, then $PATH. */
function resolveZmx() {
  const fromEnv = process.env.ZMX;
  if (fromEnv && fs.existsSync(fromEnv)) return fromEnv;

  // clients/seahelm-web/devbroker → repo root
  const repoRoot = path.resolve(__dirname, '..', '..', '..');
  const bundled = [
    '.build/Build/Products/Debug/Seahelm.app/Contents/Resources/bin/zmx',
    '.build/Build/Products/Release/Seahelm.app/Contents/Resources/bin/zmx',
  ].map((p) => path.join(repoRoot, p));
  bundled.push('/Applications/Seahelm.app/Contents/Resources/bin/zmx');
  bundled.push(path.join(os.homedir(), '.local/bin/zmx'));
  for (const p of bundled) if (fs.existsSync(p)) return p;

  return 'zmx'; // fall back to $PATH; spawn will surface ENOENT
}

class ZmxVT {
  /**
   * @param {object} opts
   * @param {string} [opts.zmx]      path to the zmx binary
   * @param {(name: string, chunk: Buffer) => void} opts.onData  coalesced VT bytes
   * @param {(name: string, chunk: Buffer, size: {rows:number,cols:number}) => void} [opts.onSnapshot]
   *        first burst after attaching — the current screen, plus its geometry
   * @param {(name: string, reason: string) => void} [opts.onClose]
   */
  constructor(opts = {}) {
    this.zmx = opts.zmx || resolveZmx();
    this.onData = opts.onData || (() => {});
    this.onSnapshot = opts.onSnapshot || (() => {});
    this.onClose = opts.onClose || (() => {});
    /** @type {Map<string, {proc: import('child_process').ChildProcess, buf: Buffer[], len: number, timer: NodeJS.Timeout|null}>} */
    this.streams = new Map();
    /** @type {Map<string, Promise<boolean>>} per-session tail of the send chain */
    this._sendQueue = new Map();
    this._bytesIn = 0;
    this._msgsOut = 0;
    this._started = Date.now();
  }

  /**
   * Every live zmx session as `{ name, pid, clients, start_dir }`.
   * `zmx list` (verbose) is tab-separated `k=v`; `--short` would only give names
   * and we want start_dir to label the pane.
   */
  listSessions() {
    return new Promise((resolve) => {
      execFile(this.zmx, ['list'], { timeout: 5000 }, (err, stdout) => {
        if (err) return resolve([]);
        const rows = [];
        for (const line of String(stdout).split('\n')) {
          const kv = {};
          // zmx prefixes the session you are *inside* with "→ ". Left in place it
          // parses as the key "→ name" and that row silently vanishes — and since
          // the bridge is normally launched from a Seahelm pane, the vanishing one
          // is the pane you were most likely about to test with.
          for (const field of line.replace(/^\s*→\s*/, '').trim().split('\t')) {
            const i = field.indexOf('=');
            if (i > 0) kv[field.slice(0, i)] = field.slice(i + 1);
          }
          if (kv.name) rows.push(kv);
        }
        resolve(rows);
      });
    });
  }

  /**
   * The session's real PTY geometry as `{ rows, cols }`, or null.
   *
   * zmx reports no size and has no resize verb, but the session's shell has a
   * controlling tty we can interrogate from outside: pid → tty → `stty size`.
   * This matters more than it looks — replaying a snapshot into a terminal with
   * a different row count puts every absolute cursor move (ESC[r;cH) on the
   * wrong line, and new output lands in the middle of the scrollback.
   */
  sessionSize(name) {
    return this.listSessions().then((rows) => new Promise((resolve) => {
      const pid = (rows.find((r) => r.name === name) || {}).pid;
      if (!pid) return resolve(null);
      execFile('ps', ['-o', 'tty=', '-p', pid], { timeout: 5000 }, (e2, out2) => {
        const tty = String(out2 || '').trim();
        if (e2 || !tty || tty === '??') return resolve(null);
        execFile('stty', ['-f', `/dev/${tty}`, 'size'], { timeout: 5000 }, (e3, out3) => {
          const m = String(out3 || '').trim().match(/^(\d+)\s+(\d+)$/);
          resolve(e3 || !m ? null : { rows: Number(m[1]), cols: Number(m[2]) });
        });
      });
    }));
  }

  /** True once an attach client is running for this session. */
  isOpen(name) { return this.streams.has(name); }

  /**
   * Start following a session. Idempotent. Resolves with the session geometry.
   *
   * Attaching is not a read-only act — a client whose window size differs can
   * resize the session and reflow what the Mac is showing — so the measured
   * size goes in and the relay pins the pty to it before exec.
   */
  async open(name) {
    // NOT idempotent, deliberately. Returning early on an already-open stream
    // means the caller gets no snapshot, so it never learns the geometry and
    // renders the session at the wrong grid — which is what a leaked stream from
    // a previous viewer did. Every open re-attaches and re-snapshots; use
    // `renew()` for the heartbeat.
    if (this.streams.has(name)) this.close(name, 'reopened');
    const size = (await this.sessionSize(name)) || { rows: 24, cols: 80 };
    if (this.streams.has(name)) this.close(name, 'reopened');          // raced while measuring

    const env = { ...process.env, ZMX: this.zmx };
    // Inherited from a Seahelm pane this hijacks attach onto *that* session and
    // the stream comes back silently empty. The relay scrubs it too; belt and braces.
    delete env.ZMX_SESSION;

    const proc = spawn('python3', [ATTACH_HELPER, name, String(size.rows), String(size.cols)],
                       { stdio: ['pipe', 'pipe', 'ignore'], env });
    const st = { proc, size, buf: [], len: 0, timer: null, phase: 'snapshot', snapTimer: null,
                 lastSeen: Date.now() };
    this.streams.set(name, st);

    // attach replays the current screen on connect, and that first burst *is*
    // the snapshot — a real frame, unlike `history --vt`'s flattened transcript
    // of every frame ever drawn. Hold it back so it publishes as one message
    // carrying the geometry, which the client must apply before replaying it.
    const closeSnapshot = () => {
      if (st.phase !== 'snapshot') return;
      if (st.snapTimer) { clearTimeout(st.snapTimer); st.snapTimer = null; }
      if (st.snapCap) { clearTimeout(st.snapCap); st.snapCap = null; }
      st.phase = 'live';
      const chunk = st.len ? Buffer.concat(st.buf, st.len) : Buffer.alloc(0);
      st.buf = []; st.len = 0;
      this._msgsOut += 1;
      this.onSnapshot(name, chunk, size);
    };
    // Publish once the replay stops arriving, not after a fixed wait. The cap is
    // the backstop for a pane that never falls quiet.
    st.snapTimer = setTimeout(closeSnapshot, SNAPSHOT_IDLE_MS);
    st.snapCap = setTimeout(closeSnapshot, SNAPSHOT_MAX_MS);

    proc.stdout.on('data', (chunk) => {
      this._bytesIn += chunk.length;
      st.buf.push(chunk);
      st.len += chunk.length;
      if (st.phase === 'snapshot') {
        // Still replaying — push the idle deadline out so the whole screen lands
        // in one snapshot rather than being split across snapshot and data.
        if (st.snapTimer) clearTimeout(st.snapTimer);
        st.snapTimer = setTimeout(closeSnapshot, SNAPSHOT_IDLE_MS);
        return;
      }
      if (st.len >= MAX_CHUNK) return this._flush(name);
      if (!st.timer) st.timer = setTimeout(() => this._flush(name), FLUSH_MS);
    });
    // Both handlers must check that the stream they belong to is still the
    // registered one. Reopening kills the previous client, whose `exit` lands
    // asynchronously — by then the map holds the *new* stream, and an unguarded
    // close() would tear down the replacement, leaving a terminal that never
    // receives its snapshot and so renders at the wrong grid.
    proc.on('error', (e) => {
      if (this.streams.get(name) === st) this.close(name, `spawn failed: ${e.message}`);
    });
    proc.on('exit', () => {
      if (this.streams.get(name) === st) this.close(name, 'attach exited');
    });
    return size;
  }

  _flush(name) {
    const st = this.streams.get(name);
    if (!st || !st.len) return;
    if (st.timer) { clearTimeout(st.timer); st.timer = null; }
    const chunk = Buffer.concat(st.buf, st.len);
    st.buf = []; st.len = 0;
    this._msgsOut += 1;
    this.onData(name, chunk);
  }

  /** Stop following a session. */
  close(name, reason = 'closed') {
    const st = this.streams.get(name);
    if (!st) return;
    if (st.timer) clearTimeout(st.timer);
    if (st.snapTimer) clearTimeout(st.snapTimer);
    if (st.snapCap) clearTimeout(st.snapCap);
    this.streams.delete(name);
    this._sendQueue.delete(name);
    try { st.proc.kill('SIGTERM'); } catch { /* already gone */ }
    this.onClose(name, reason);
  }

  closeAll() { for (const name of [...this.streams.keys()]) this.close(name, 'shutdown'); }

  /** Renew a stream's lease. The heartbeat path — never restarts anything. */
  renew(name) {
    const st = this.streams.get(name);
    if (!st) return false;
    st.lastSeen = Date.now();
    return true;
  }

  /**
   * Drop streams whose watcher stopped renewing. A browser that is closed or
   * crashes never sends `vt_close`, and an abandoned attach client is not inert:
   * it stays a client of the session. `vt_close` handles the tidy path; this
   * handles every other one.
   */
  sweep(ttlMs = LEASE_TTL_MS) {
    const now = Date.now();
    for (const [name, st] of this.streams) {
      if (now - st.lastSeen > ttlMs) this.close(name, 'lease expired');
    }
  }

  /**
   * Deliver keystrokes. `text` is what xterm.js's onData produced, so it is a
   * UTF-8 string; Node re-encodes argv as UTF-8, making this byte-exact.
   * NUL cannot travel through argv — the one input byte this drops.
   *
   * Serialized per session. Each send is its own `zmx send` process, and firing
   * them concurrently lets a later keystroke's process win the race — typing
   * "VT_OK" fast arrives as "V_TOK". The queue is the fix; do not make this
   * fire-and-forget.
   */
  send(name, text) {
    if (!text) return Promise.resolve(true);

    // Attached: write straight into the pty. A stream write is ordered by
    // construction, so this needs no queue, spawns nothing per keystroke, and
    // carries bytes argv cannot (NUL). The `zmx send` path below stays for
    // panes nobody is watching.
    const st = this.streams.get(name);
    if (st && st.proc.stdin && st.proc.stdin.writable) {
      return new Promise((resolve) => {
        st.proc.stdin.write(text, 'utf8', (err) => resolve(!err));
      });
    }

    const prev = this._sendQueue.get(name) || Promise.resolve(true);
    const next = prev.then(() => new Promise((resolve) => {
      execFile(this.zmx, ['send', name, text], { timeout: 5000 }, (err) => resolve(!err));
    }));
    this._sendQueue.set(name, next.catch(() => false));   // a failed send must not stall the chain
    return next;
  }

  /**
   * Cumulative throughput since the bridge started — the number this PoC exists
   * to produce. Deliberately non-destructive: the periodic `[vt]` log and the
   * `mock.vt_stats` command both read this, and a reset-on-read counter lets
   * whichever fires first zero out the other's reading. Callers wanting a rate
   * over a window keep their own previous sample and subtract.
   */
  stats() {
    const secs = Math.max(0.001, (Date.now() - this._started) / 1000);
    return {
      bytes_in: this._bytesIn,
      msgs_out: this._msgsOut,
      seconds: Math.round(secs * 10) / 10,
      bytes_per_sec: Math.round(this._bytesIn / secs),
      msgs_per_sec: Math.round((this._msgsOut / secs) * 10) / 10,
      open_streams: this.streams.size,
    };
  }
}

module.exports = { ZmxVT, resolveZmx, SNAPSHOT_IDLE_MS, SNAPSHOT_MAX_MS, FLUSH_MS, LEASE_TTL_MS };
