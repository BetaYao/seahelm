// Serialize VT application so a snapshot's reset() cannot land mid-write.
//
// Decode (inflate) can overlap; applying cannot. The page used to await the
// work function but not term.write(), so a later snapshot reset the terminal
// while the previous chunk was still draining — the TUI cursor then sat off
// the prompt. writeTerminal turns that callback into the thing the queue waits
// on.
(function (root, factory) {
  const api = factory();
  if (typeof module === 'object' && module.exports) module.exports = api;
  else root.SeahelmVTApply = api;
})(typeof self !== 'undefined' ? self : this, function () {
  'use strict';

  /**
   * Wait until `term.write` has finished. Empty payloads are a no-op so a
   * snapshot that is only a resize still fits the font afterwards.
   *
   * xterm.js and ghostty-web both take `(data, cb)`. ghostty fires the cb on
   * the next animation frame; xterm fires it when its parse buffer drains.
   */
  function writeTerminal(term, bytes) {
    return new Promise((resolve, reject) => {
      if (!bytes || !bytes.length) { resolve(); return; }
      if (!term || typeof term.write !== 'function') { resolve(); return; }
      let settled = false;
      const done = () => { if (!settled) { settled = true; resolve(); } };
      try {
        const ret = term.write(bytes, done);
        if (ret && typeof ret.then === 'function') ret.then(done, reject);
      } catch (e) {
        reject(e);
      }
    });
  }

  /**
   * @param {object} [o]
   * @param {number} [o.maxData=8]     drop further vt.data past this in-flight depth
   * @param {(key:string)=>void} [o.onDrop]
   * @param {(key:string, err:Error)=>void} [o.onError]
   */
  function createApplyQueue(o) {
    const maxData = o && o.maxData != null ? o.maxData : 8;
    const onDrop = (o && o.onDrop) || function () {};
    const onError = (o && o.onError) || function () {};
    const chains = new Map();
    const depth = new Map();

    function enqueue(key, type, work) {
      const d = depth.get(key) || 0;
      if (type === 'vt.data' && d >= maxData) {
        onDrop(key);
        return Promise.resolve();
      }
      depth.set(key, d + 1);
      const prior = chains.get(key) || Promise.resolve();
      const next = prior.then(async () => {
        try {
          await work();
        } catch (e) {
          onError(key, e);
        } finally {
          depth.set(key, Math.max(0, (depth.get(key) || 1) - 1));
        }
      });
      chains.set(key, next);
      return next;
    }

    function release(key) {
      chains.delete(key);
      depth.delete(key);
    }

    return { enqueue, release };
  }

  return { createApplyQueue, writeTerminal };
});
