// Holding a place in the text-mode timeline across a repaint.
//
// Every event rebuilds the whole list through `innerHTML`, which empties the
// scroller for an instant and leaves `scrollTop` clamped to 0. A reader who had
// scrolled up was therefore thrown to the top of the history by the next tool
// call — and the frame-later probe that pages older messages in then fired on
// top of that. On a phone, where a working agent emits something every few
// seconds, the page never held still.
//
// So the position is read before the repaint and put back after it. The anchor
// is a *row*, not a raw `scrollTop`: history pages in above the reader, and the
// timeline orders by wall-clock time rather than `seq`, so a line the Mac
// flushed late can land anywhere in the list. Only "the row I was reading stays
// where it was" survives both.
//
// At the bottom there is nothing to hold: that reader wants whatever comes
// next, so the repaint follows them down. That is the whole rule — stick while
// at the bottom, hold still anywhere above it. It is deliberately read from the
// live scroll position rather than latched, so the gesture that ends at the
// bottom resumes following with no button to find.
(function (root, factory) {
  const api = factory();
  if (typeof module === 'object' && module.exports) module.exports = api;
  else root.SeahelmTimelineScroll = api;
})(typeof self !== 'undefined' ? self : this, function () {
  'use strict';

  /**
   * The last row starting at or above `scrollTop` — the one whose text is under
   * the top edge. Binary search because a full history is thousands of rows and
   * every `topAt` is a layout read.
   */
  function topmostVisible(rows, scrollTop) {
    if (!rows.length) return -1;
    let lo = 0, hi = rows.length - 1, best = 0;
    while (lo <= hi) {
      const mid = (lo + hi) >> 1;
      if (rows.topAt(mid) <= scrollTop) { best = mid; lo = mid + 1; }
      else hi = mid - 1;
    }
    return best;
  }

  /**
   * Read the reading position before the timeline is rebuilt.
   * @param {{scrollTop:number, scrollHeight:number, clientHeight:number}} view
   * @param {{length:number, seqAt:(i:number)=>number, topAt:(i:number)=>number}} rows
   * @param {number} slop  px short of the end still counted as "at the bottom"
   * @returns {{follow:boolean, seq:number|null, offset:number, fromBottom:number}}
   */
  function capture(view, rows, slop) {
    const fromBottom = view.scrollHeight - view.scrollTop;
    // Rubber-band overscroll on iOS drives this negative, which is still the
    // bottom — hence `<=`, not a window around zero.
    if (view.scrollHeight - view.scrollTop - view.clientHeight <= slop) {
      return { follow: true, seq: null, offset: 0, fromBottom };
    }
    const i = topmostVisible(rows, view.scrollTop);
    if (i < 0) return { follow: false, seq: null, offset: 0, fromBottom };
    return {
      follow: false,
      seq: rows.seqAt(i),
      offset: rows.topAt(i) - view.scrollTop,
      fromBottom,
    };
  }

  /**
   * Where `scrollTop` belongs once the rows are back.
   * @param {{scrollHeight:number}} view
   * @param {(seq:number)=>number|null} topOf  the row's new offset, null if gone
   */
  function restore(view, cap, topOf) {
    if (!cap || cap.follow) return view.scrollHeight;
    if (cap.seq != null) {
      const top = topOf(cap.seq);
      if (top != null && isFinite(top)) return Math.max(0, top - cap.offset);
    }
    // The anchor row aged out of the cap. Distance from the end is the next best
    // thing: wrong by whatever was appended, right about everything above.
    return Math.max(0, view.scrollHeight - cap.fromBottom);
  }

  return { capture, restore, topmostVisible };
});
