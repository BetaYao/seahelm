// Reconnect policy for the Host Gateway socket.
//
// The MQTT client this replaced reconnected on its own (mqtt.js, every 2s). The
// gateway socket did not: `onclose` set the status to offline and stopped, so a
// phone locking its screen, handing off WiFi→cellular, or simply being switched
// away from left a dead page that only a manual tap could revive. That is not an
// edge case for this client; it is the normal way a phone behaves.
//
// Two things it must not do:
//   • retry a credential the gateway rejected — a wrong or expired code will be
//     wrong forever, and hammering it burns the pairing rate limit
//   • retry after the user pressed 断开
//
// Pure, with its clock and timers injected, so the schedule can be asserted.
(function (root, factory) {
  const api = factory();
  if (typeof module === 'object' && module.exports) module.exports = api;
  else root.SeahelmReconnect = api;
})(typeof self !== 'undefined' ? self : this, function () {
  'use strict';

  const DEFAULTS = { baseMs: 500, maxMs: 15000, factor: 2, jitter: 0.25 };

  /**
   * @param {object} o
   * @param {()=>void} o.attempt        open a fresh socket
   * @param {(state:{retrying:boolean, attempt:number, delayMs:number})=>void} [o.onSchedule]
   */
  function createReconnector(o) {
    const cfg = Object.assign({}, DEFAULTS, o);
    const now = cfg.now || (() => Date.now());
    const setTimer = cfg.setTimer || ((fn, ms) => setTimeout(fn, ms));
    const clearTimer = cfg.clearTimer || ((h) => clearTimeout(h));
    const random = cfg.random || Math.random;

    let attempts = 0;
    let timer = null;
    let stopped = false;

    /** Exponential with full-width jitter, so N phones do not return in lockstep. */
    function delayFor(n) {
      const raw = Math.min(cfg.maxMs, cfg.baseMs * Math.pow(cfg.factor, n));
      const spread = raw * cfg.jitter;
      return Math.round(raw - spread + random() * 2 * spread);
    }

    return {
      /** The socket closed on its own. Schedule another try. */
      closed() {
        if (stopped || timer !== null) return;
        const delayMs = delayFor(attempts);
        attempts += 1;
        if (cfg.onSchedule) cfg.onSchedule({ retrying: true, attempt: attempts, delayMs });
        timer = setTimer(() => { timer = null; if (!stopped) cfg.attempt(); }, delayMs);
      },
      /** Authenticated. The next drop starts from the short delay again. */
      succeeded() {
        attempts = 0;
        stopped = false;
        if (cfg.onSchedule) cfg.onSchedule({ retrying: false, attempt: 0, delayMs: 0 });
      },
      /**
       * Give up until something changes: a rejected credential, or the user
       * pressing disconnect. `resume()` is the only way back.
       */
      stop() {
        stopped = true;
        if (timer !== null) { clearTimer(timer); timer = null; }
      },
      /** A new code was entered, or the page came back — try again now. */
      resume() {
        stopped = false;
        attempts = 0;
        if (timer !== null) { clearTimer(timer); timer = null; }
      },
      get isStopped() { return stopped; },
      get isPending() { return timer !== null; },
      get attempts() { return attempts; },
      delayFor,
    };
  }

  return { createReconnector, DEFAULTS };
});
