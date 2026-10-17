// Turning the timeline that is on screen into the one that should be, with as
// little DOM work as it takes.
//
// The timeline used to be rebuilt through `innerHTML` on every message: rows
// whose HTML was already cached still had to be parsed and laid out again, all
// ~200 of them, for the one line that changed. A busy agent sends several a
// second, and on a phone each rebuild was a visible stall.
//
// What changes between two paints is almost always the tail: a new row, or the
// last item rewritten — a tool call joining the run before it folds that run
// into one line (or grows its ×N), and the `live` breathing moves off the line
// that is no longer the newest. So the plan keeps the longest run of items both
// lists share from the top, drops the rest of the old list from the end, and
// appends the rest of the new one. That covers the cases that are not a tail
// too, just with more work: a late message the Mac flushed after the calls it
// introduces is inserted where its time puts it, so everything below that
// point is replaced.
//
// An item is `{ id, html }`, one per child element of the list. Two items are
// the same only if both match — the `id` says which row it is, the `html` that
// it has not changed. `null` means rebuild: nothing in common at the top (a
// different pane, history paged in above), or so little that tearing the list
// down piece by piece would cost more than drawing it once.
(function (root, factory) {
  const api = factory();
  if (typeof module === 'object' && module.exports) module.exports = api;
  else root.SeahelmTimelinePatch = api;
})(typeof self !== 'undefined' ? self : this, function () {
  'use strict';

  /**
   * @param {Array<{id:string, html:string}>} prev  what is on screen
   * @param {Array<{id:string, html:string}>} next  what should be
   * @returns {{dropFront:number, removeTail:number, append:Array}|null}
   *   remove `dropFront` children from the start and `removeTail` from the end,
   *   then append `append` — or null to rebuild
   */
  function plan(prev, next) {
    if (!prev.length || !next.length) return null;
    // The window can move down past rows that have scrolled away: line the two
    // lists up on where the new one starts.
    const drop = prev.findIndex(p => p.id === next[0].id);
    if (drop < 0) return null;
    let keep = 0;
    while (keep < next.length && drop + keep < prev.length
           && prev[drop + keep].id === next[keep].id
           && prev[drop + keep].html === next[keep].html) keep++;
    if (keep === 0) return null;
    const removeTail = prev.length - drop - keep;
    const append = next.slice(keep);
    if (removeTail + append.length > next.length / 2) return null;
    return { dropFront: drop, removeTail, append };
  }

  return { plan };
});
