// Folding a run of tool calls into one line.
//
// An agent's timeline is mostly tool calls, and read from a phone a working
// turn is a wall of them: twenty lines of `Bash`, `Read`, `Grep` between one
// thing it said and the next. The calls are worth keeping — they are how you
// check what it actually did — but not worth the whole screen by default, so a
// consecutive run folds to a single line you can open.
//
// Only runs are folded, and only from two calls up: one call is already one
// line, and making it a thing to click would cost a tap to learn nothing. A
// non-tool row between two calls ends the run, because what the agent said in
// the middle is the thing that explains the calls either side of it.
(function (root, factory) {
  const api = factory();
  if (typeof module === 'object' && module.exports) module.exports = api;
  else root.SeahelmToolGroup = api;
})(typeof self !== 'undefined' ? self : this, function () {
  'use strict';

  const MIN_GROUP = 2;

  /**
   * Fold each run of consecutive tool rows.
   * @returns {Array<{kind:'row',msg:object}|{kind:'tools',…}>} in display order
   */
  function fold(rows, minGroup) {
    const min = minGroup == null ? MIN_GROUP : minGroup;
    const out = [];
    let run = [];
    function flush() {
      if (!run.length) return;
      if (run.length < min) for (const m of run) out.push({ kind: 'row', msg: m });
      else out.push(summarize(run));
      run = [];
    }
    for (const m of rows) {
      if (m && m.kind === 'tool') { run.push(m); continue; }
      flush();
      out.push({ kind: 'row', msg: m });
    }
    flush();
    return out;
  }

  function summarize(run) {
    const last = run[run.length - 1];
    const names = new Set(run.map(m => m.tool || ''));
    // Tools without arguments report their own name as detail, which would only
    // repeat the label.
    const tail = last.detail && last.detail !== last.tool ? last.detail : '';
    // A run of one kind is labelled by it. A mixed run is labelled `Tools` and
    // carries the newest call's own name in the detail instead — naming one of
    // the kinds up front would say the run was all of that, and counting the
    // kinds there ("3 tools ×5") puts two different numbers on one line.
    const uniform = names.size === 1;
    return {
      kind: 'tools',
      rows: run.slice(),
      // Keyed by where the run *starts*. A run grows while the agent works, so
      // keying it by the last call would shut an opened group on the next one.
      key: Number(run[0].seq),
      // The fold sits where its newest call sits, which is what the scroll
      // keeper anchors to while it is closed.
      seq: Number(last.seq),
      tool: uniform ? (last.tool || '') : 'Tools',
      // The newest call, because while a run is still going that is the one
      // being run right now.
      detail: uniform ? tail : [last.tool, tail].filter(Boolean).join(' '),
      // Server-side coalescing already folded identical neighbours into a
      // `count`, so this is calls made, not rows on screen.
      count: run.reduce((n, m) => n + (Number(m.count) || 1), 0),
      // A failure inside must colour the line: folding is for saving room, not
      // for hiding that something broke.
      isError: run.some(m => !!m.is_error),
    };
  }

  return { fold };
});
