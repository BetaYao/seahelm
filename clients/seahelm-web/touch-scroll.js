// One-finger vertical swipe → the same delta a mouse wheel would have sent.
//
// xterm.js (and ghostty-web) scroll on wheel, not touch. The WebGL canvas
// sits on top of the viewport and eats the gesture, so a phone has no way
// to read scrollback. This turns a swipe into that wheel delta; the
// terminal then either moves its own buffer or, in mouse mode, reports the
// wheel to the TUI.
//
// Horizontal stays untouched: a TUI that wants a drag still gets one, and
// a tap that never clears `slop` is left for focus / selection.
(function (root, factory) {
  const api = factory();
  if (typeof module === 'object' && module.exports) module.exports = api;
  else root.SeahelmTouchScroll = api;
})(typeof self !== 'undefined' ? self : this, function () {
  'use strict';

  /**
   * @param {object} o
   * @param {(deltaY:number)=>void} o.scroll   wheel convention: + toward live
   * @param {number} [o.slop=10]               px before the axis locks
   */
  function createTouchScroller(o) {
    const scroll = o.scroll;
    const slop = o.slop == null ? 10 : o.slop;

    let originX = 0, originY = 0, lastY = 0;
    let lock = null;          // null | 'vert' | 'horiz'
    let active = false;

    function reset() {
      lock = null;
      active = false;
    }

    return {
      start(p) {
        if (!p || p.touches !== 1) { reset(); return; }
        originX = p.x; originY = p.y; lastY = p.y;
        lock = null;
        active = true;
      },
      move(p) {
        if (!active) return { consume: false };
        if (!p || p.touches !== 1) { reset(); return { consume: false }; }

        if (!lock) {
          const dx = p.x - originX;
          const dy = p.y - originY;
          if (Math.max(Math.abs(dx), Math.abs(dy)) < slop) return { consume: false };
          lock = Math.abs(dy) >= Math.abs(dx) ? 'vert' : 'horiz';
        }

        if (lock === 'vert') {
          const dy = p.y - lastY;
          lastY = p.y;
          if (dy) scroll(-dy);
          return { consume: true };
        }
        lastY = p.y;
        return { consume: false };
      },
      end() { reset(); },
    };
  }

  /**
   * Bind the scroller to a pane host. Returns a detach function.
   * Dispatches a wheel event onto xterm's viewport (or the host, for
   * ghostty-web) so mouse-tracking TUIs still see the scroll.
   */
  function attach(element, opts) {
    if (!element) return function () {};
    const targetOf = (opts && opts.target) || function () {
      return element.querySelector('.xterm-viewport') || element;
    };
    const scroller = createTouchScroller({
      slop: opts && opts.slop,
      scroll(deltaY) {
        const target = targetOf();
        if (!target || typeof target.dispatchEvent !== 'function') return;
        target.dispatchEvent(new WheelEvent('wheel', {
          deltaY,
          deltaMode: 0,
          bubbles: true,
          cancelable: true,
        }));
      },
    });

    function point(e) {
      const t = e.changedTouches && e.changedTouches[0];
      if (!t) return null;
      const n = e.touches ? e.touches.length : 0;
      return { x: t.pageX, y: t.pageY, touches: n };
    }

    function onStart(e) {
      const p = point(e);
      if (p) scroller.start(p);
    }
    function onMove(e) {
      const p = point(e);
      if (!p) return;
      // touchmove reports currently-down fingers in `touches`; a 1→2
      // transition would otherwise still look like a one-finger move.
      p.touches = e.touches ? e.touches.length : p.touches;
      const r = scroller.move(p);
      if (r && r.consume) e.preventDefault();
    }
    function onEnd() { scroller.end(); }

    element.addEventListener('touchstart', onStart, { passive: true });
    element.addEventListener('touchmove', onMove, { passive: false });
    element.addEventListener('touchend', onEnd);
    element.addEventListener('touchcancel', onEnd);

    return function detach() {
      element.removeEventListener('touchstart', onStart);
      element.removeEventListener('touchmove', onMove);
      element.removeEventListener('touchend', onEnd);
      element.removeEventListener('touchcancel', onEnd);
    };
  }

  return { createTouchScroller, attach };
});
