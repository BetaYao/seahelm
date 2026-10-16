// Which pane a worktree opens on, and what a worktree row says about itself.
//
// The fleet list stops at the worktree: panes are chosen in the detail, from
// the tabs above the timeline or terminal. So opening a worktree has to land on
// one of its panes without being told which — and the useful answer is the one
// that wants you. A Codex pane waiting on a permission prompt beside a Claude
// that is happily running is why you tapped the row; opening on the Claude
// would make you hunt for it.
//
// Order: waiting on you, then failed, then running, then the pane you last
// looked at here, then whatever comes first. "Last looked at" ranks below the
// live states on purpose — it is a memory of the past, they are the present.
//
// Nothing here knows about the DOM; statuses are whatever normStatus produced.
(function (root, factory) {
  const api = factory();
  if (typeof module === 'object' && module.exports) module.exports = api;
  else root.SeahelmPanePick = api;
})(typeof self !== 'undefined' ? self : this, function () {
  'use strict';

  const RANK = { waiting: 0, failed: 1, running: 2 };

  /**
   * @param {Array<[string, {status:string}]>} panes  [key, pane] in display order
   * @param {string|null} lastKey  the pane last shown for this worktree
   * @returns {string|null} the key to open on
   */
  function pickPane(panes, lastKey) {
    if (!Array.isArray(panes) || !panes.length) return null;
    let best = null, bestRank = 99;
    for (const [key, pane] of panes) {
      const rank = RANK[pane && pane.status];
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

  return { pickPane, statusLabel, STATUS_LABEL };
});
