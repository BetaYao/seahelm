// Per-pane MessageStream list kept by the text-mode timeline.
//
// On every authentication the gateway replays each pane's ring, and a live
// `pane.message` can land on either side of that replay. Appending blindly
// doubled the timeline on every reconnect — which on a phone is every screen
// lock or WiFi→cellular hand-off. `seq` is the identity; the caller still drops
// the lists when a new socket opens, so a Mac whose history was cleared cannot
// leave stale numbers behind.
//
// Display order is when things happened, not `seq`. A tool call is stamped when
// its hook arrives; the prose that introduces it is stamped when the agent wrote
// it but reaches the Mac later, once the transcript is flushed — so by `seq` it
// would sit below the call it explains.
(function (root, factory) {
  const api = factory();
  if (typeof module === 'object' && module.exports) module.exports = api;
  else root.SeahelmMessageTimeline = api;
})(typeof self !== 'undefined' ? self : this, function () {
  'use strict';

  function before(a, b) {
    const ta = Number(a.ts), tb = Number(b.ts);
    if (Number.isFinite(ta) && Number.isFinite(tb) && ta !== tb) return ta < tb;
    return Number(a.seq) < Number(b.seq);
  }

  /**
   * Insert `msg` into `list` in time order, once, keeping the newest `cap`.
   * @returns {boolean} false when `msg` was already present
   */
  function appendMessage(list, msg, cap) {
    const seq = Number(msg.seq);
    if (list.some(m => Number(m.seq) === seq)) return false;
    let i = list.length;
    while (i > 0 && before(msg, list[i - 1])) i--;
    list.splice(i, 0, msg);
    if (list.length > cap) list.splice(0, list.length - cap);
    return true;
  }

  /** The cursor for the page before `list`: its lowest `seq`, wherever it sits. */
  function oldestSeq(list) {
    return list.reduce((min, m) => Math.min(min, Number(m.seq)), Infinity);
  }

  return { appendMessage, oldestSeq };
});
