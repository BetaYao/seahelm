// Keep the terminal's hidden textarea as the caret, even when chrome is clicked.
//
// A browser <button> takes focus on mousedown. The pane highlight does not
// move, so the page looks selected while Esc / IME / ordinary keys go
// nowhere. preventDefault on chrome mousedown leaves the existing focus
// alone; a trailing restore covers the case where nothing held it yet.
(function (root, factory) {
  const api = factory();
  if (typeof module === 'object' && module.exports) module.exports = api;
  else root.SeahelmTermFocus = api;
})(typeof self !== 'undefined' ? self : this, function () {
  'use strict';

  const KEEP = { INPUT: 1, TEXTAREA: 1, SELECT: 1 };
  const CHROME_INPUT = { hidden: 1, button: 1, submit: 1, reset: 1, checkbox: 1, radio: 1, file: 1, image: 1 };

  /** True when the caret is not in a field the user is actually typing into. */
  function shouldRestoreTerminal(el) {
    if (!el || !el.tagName) return true;
    if (el.isContentEditable) return false;
    const tag = el.tagName;
    if (!KEEP[tag]) return true;
    if (tag === 'INPUT' && CHROME_INPUT[el.type]) return true;
    return false;
  }

  /**
   * @param {Document} doc
   * @param {()=>void} restore
   * @param {{setTimer?: Function}} [opts]
   */
  function install(doc, restore, opts) {
    if (!doc || typeof doc.addEventListener !== 'function') return;
    const setTimer = (opts && opts.setTimer) || ((fn, ms) => setTimeout(fn, ms));

    doc.addEventListener('mousedown', (e) => {
      const t = e && e.target;
      const btn = t && t.closest && t.closest('button, [role="button"]');
      if (!btn) return;
      if (typeof btn.setAttribute === 'function') btn.setAttribute('tabindex', '-1');
      if (typeof e.preventDefault === 'function') e.preventDefault();
    }, true);

    doc.addEventListener('click', () => {
      setTimer(() => {
        if (shouldRestoreTerminal(doc.activeElement)) restore();
      }, 0);
    });
  }

  return { shouldRestoreTerminal, install };
});
