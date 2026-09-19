// What a keystroke in the timeline composer means — before the pane hears it.
//
// An IME owns the keyboard while it is composing: Enter commits the candidate
// a Pinyin/Kana user is still choosing, Escape abandons it. Acting on either
// sends half-typed text to the agent and eats the keystroke that was picking
// the word, which is what "中文输入法回车直接发送" looks like from the seat.
(function (root, factory) {
  const api = factory();
  if (typeof module === 'object' && module.exports) module.exports = api;
  else root.SeahelmComposerKeys = api;
})(typeof self !== 'undefined' ? self : this, function () {
  'use strict';

  /** True while an IME is mid-composition and the key is not ours to read. */
  function isComposing(ev) {
    if (!ev) return false;
    // `isComposing` is the standard signal. Safari and some Android keyboards
    // leave it false on the keydown that opens composition but still report
    // keyCode 229 — the "this went to the IME" sentinel — so honour both.
    return ev.isComposing === true || ev.keyCode === 229;
  }

  /**
   * 'send'  — submit the composer
   * 'esc'   — forward Escape to the pane
   * null    — let the field handle it (typing, IME composition, Shift+Enter)
   */
  function composerKeyAction(ev) {
    if (!ev || isComposing(ev)) return null;
    if (ev.key === 'Enter' && !ev.shiftKey) return 'send';
    if (ev.key === 'Escape') return 'esc';
    return null;
  }

  return { isComposing, composerKeyAction };
});
