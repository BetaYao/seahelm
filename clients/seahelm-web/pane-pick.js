// Which pane a worktree opens on, and what a worktree row says about itself.
//
// The fleet list stops at the worktree: panes are chosen in the detail, from
// the tabs above the timeline or terminal. So opening a worktree has to land on
// one of its panes without being told which — and the useful answer is the one
// that wants you. A Codex pane waiting on a permission prompt beside a Claude
// that is happily running is why you tapped the row; opening on the Claude
// would make you hunt for it.
//
// Order: an open decision (a question to answer, or suggested next steps to
// pick from), then waiting on you, then failed, then running, then the pane you
// last looked at here, then whatever comes first. A decision outranks every
// status because a suggestion arrives as the agent finishes — its pane reads
// idle, and ranking by status alone opened the worktree on a busy neighbour
// with the card nowhere in sight. "Last looked at" ranks below the live states
// on purpose — it is a memory of the past, they are the present.
//
// Nothing here knows about the DOM; statuses are whatever normStatus produced.
(function (root, factory) {
  const api = factory();
  if (typeof module === 'object' && module.exports) module.exports = api;
  else root.SeahelmPanePick = api;
})(typeof self !== 'undefined' ? self : this, function () {
  'use strict';

  const RANK = { waiting: 1, failed: 2, running: 3 };

  /**
   * @param {Array<[string, {status:string, decision?:boolean}]>} panes  [key, pane] in display order
   * @param {string|null} lastKey  the pane last shown for this worktree
   * @returns {string|null} the key to open on
   */
  function pickPane(panes, lastKey) {
    if (!Array.isArray(panes) || !panes.length) return null;
    let best = null, bestRank = 99;
    for (const [key, pane] of panes) {
      const rank = pane && pane.decision ? 0 : RANK[pane && pane.status];
      if (rank !== undefined && rank < bestRank) { best = key; bestRank = rank; }
    }
    if (best !== null) return best;
    if (lastKey && panes.some(([key]) => key === lastKey)) return lastKey;
    return panes[0][0];
  }

  // What the row spells out beside its dot, so the state is never colour alone.
  const STATUS_LABEL = {
    running: 'Running', waiting: 'Needs you', failed: 'Error',
    done: 'Exited', idle: 'Idle', unknown: '',
  };

  function statusLabel(status) {
    return STATUS_LABEL[status] ?? '';
  }

  /** What a row or tab says when one of its panes holds an open decision —
   *  which speaks louder than its status. `null` when there is none. */
  function decisionLabel(kind) {
    if (kind === 'question') return 'Needs you';
    if (kind === 'suggest') return 'Suggestion';
    return null;
  }

  /** Panes a `?pane=` share link is allowed to show. No key means the whole
   *  fleet. A key keeps the pane whose session key or id matches, and nothing
   *  else — the shared page is that pane alone. */
  function panesMatchingShare(panes, shareKey) {
    if (!shareKey) return panes || [];
    return (panes || []).filter((p) => {
      const key = p.pane_session_key || p.pane_id;
      return key === shareKey || p.pane_id === shareKey;
    });
  }

  return { pickPane, statusLabel, decisionLabel, STATUS_LABEL, panesMatchingShare };
});
