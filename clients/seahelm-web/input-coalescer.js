// Keystroke coalescing for the pane → Mac direction.
//
// The naive version arms a timer on the first keystroke and sends when it
// fires, which makes every burst start with a full window of latency for no
// gain: there was nothing to coalesce it with. The Mac already avoids that in
// the other direction — ZmxVTAttachManager tracks time since its last flush so
// an idle pane answers immediately — and this is the same policy pointing the
// other way, which is the direction a person actually feels.
//
// Leading edge, then trailing: an idle pane sends at once; a second keystroke
// inside the window is what starts coalescing, and it goes out when the window
// closes.
//
// Pure, with time and timers injected, so the latency it produces can be
// measured without a browser.
(function (root, factory) {
  const api = factory();
  if (typeof module === 'object' && module.exports) module.exports = api;
  else root.SeahelmInput = api;
})(typeof self !== 'undefined' ? self : this, function () {
  'use strict';

  /**
   * @param {object} o
   * @param {number} o.windowMs      coalescing window
   * @param {(payload:string)=>void} o.send
   * @param {()=>number} [o.now]
   * @param {(fn:Function, ms:number)=>any} [o.setTimer]
   * @param {(handle:any)=>void} [o.clearTimer]
   */
  function createKeystrokeCoalescer(o) {
    const windowMs = o.windowMs;
    const send = o.send;
    const now = o.now || (() => Date.now());
    const setTimer = o.setTimer || ((fn, ms) => setTimeout(fn, ms));
    const clearTimer = o.clearTimer || ((h) => clearTimeout(h));

    let pending = '';
    let timer = null;
    // -Infinity, not 0: the very first keystroke of a session is idle by
    // definition and must not wait out a window measured from the epoch.
    let lastSentAt = -Infinity;

    function flush() {
      timer = null;
      if (!pending) return;
      const payload = pending;
      pending = '';
      lastSentAt = now();
      send(payload);
    }

    return {
      push(data) {
        if (!data) return;
        pending += data;
        if (timer !== null) return;             // a flush is already scheduled
        const since = now() - lastSentAt;
        if (since >= windowMs) { flush(); return; }
        timer = setTimer(flush, windowMs - since);
      },
      /** Send whatever is buffered right now (pane teardown, blur). */
      flushNow() {
        if (timer !== null) { clearTimer(timer); timer = null; }
        flush();
      },
      /** Drop buffered input and any pending timer. */
      cancel() {
        if (timer !== null) { clearTimer(timer); timer = null; }
        pending = '';
      },
      get hasPending() { return pending.length > 0 || timer !== null; },
    };
  }

  return { createKeystrokeCoalescer };
});
