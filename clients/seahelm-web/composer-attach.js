// Files attached to the composer: a pasted screenshot, a picked or dropped
// file. The page runs on another device, so each one is sent to the gateway
// (`file.upload`) as soon as it is attached and kept on the machine the panes
// run on. The composer shows it as a thumbnail above the field, not as a path
// in the text; on send its path goes after the words — an agent opens a path
// it is given, a shell takes it as an argument. The gateway names the file so
// the path needs no quoting.
//
// Nothing here knows about the DOM or the socket.
(function (root, factory) {
  const api = factory();
  if (typeof module === 'object' && module.exports) module.exports = api;
  else root.SeahelmComposerAttach = api;
})(typeof self !== 'undefined' ? self : this, function () {
  'use strict';

  // What the gateway takes in one message (its `upload::MAX_BYTES`).
  const MAX_BYTES = 10 * 1024 * 1024;

  /** The files on a paste or drop: `DataTransfer.files`, else its file items
   *  (some browsers hand a pasted screenshot over only as an item). */
  function filesOf(dt) {
    if (!dt) return [];
    const files = Array.from(dt.files || []);
    if (files.length) return files;
    return Array.from(dt.items || [])
      .filter((i) => i && i.kind === 'file')
      .map((i) => i.getAsFile())
      .filter(Boolean);
  }

  const pad = (n) => String(n).padStart(2, '0');

  /** The name to keep a file under. A pasted screenshot arrives as
   *  `image.png` (every time), so it is named for when it was pasted. */
  function uploadName(file, now) {
    const name = (file && file.name) || '';
    const type = (file && file.type) || '';
    if (name && !/^image\.\w+$/i.test(name)) return name;
    const ext = (name.match(/\.(\w+)$/) || [])[1] || (type.split('/')[1] || 'png').replace('jpeg', 'jpg');
    const d = now || new Date();
    return `screenshot-${d.getFullYear()}${pad(d.getMonth() + 1)}${pad(d.getDate())}-` +
      `${pad(d.getHours())}${pad(d.getMinutes())}${pad(d.getSeconds())}.${ext}`;
  }

  /** Put `path` into `text` over the selection, a space on each side unless
   *  one is there already. Returns the text and where the caret goes. */
  function insertPath(text, start, end, path) {
    const t = text || '';
    const s = Math.max(0, Math.min(start ?? t.length, t.length));
    const e = Math.max(s, Math.min(end ?? s, t.length));
    const before = t.slice(0, s);
    const after = t.slice(e);
    const lead = before && !/\s$/.test(before) ? ' ' : '';
    const trail = after && /^\s/.test(after) ? '' : ' ';
    const value = before + lead + path + trail + after;
    return { value, caret: (before + lead + path + trail).length };
  }

  /** The message to send: the words, then every uploaded file's path. */
  function composeMessage(text, attachments) {
    const paths = (attachments || []).map((a) => a && a.path).filter(Boolean);
    return [(text || '').trim(), ...paths].filter(Boolean).join(' ');
  }

  /** Attachments still on their way to the Mac. */
  function pendingCount(attachments) {
    return (attachments || []).filter((a) => a && !a.path && !a.error).length;
  }

  /** A file the composer can show as a picture. */
  function isImage(file) {
    return !!file && /^image\//.test(file.type || '');
  }

  /** Why a file cannot go, or '' when it can. */
  function refusal(file) {
    if (!file) return 'Nothing to attach';
    if (file.size > MAX_BYTES) return `${file.name || 'File'} is over ${MAX_BYTES >> 20} MB`;
    return '';
  }

  /** An ArrayBuffer as base64, in slices so a large file does not overflow
   *  the argument list of `String.fromCharCode`. */
  function toBase64(buf) {
    const bytes = new Uint8Array(buf);
    let bin = '';
    for (let i = 0; i < bytes.length; i += 0x8000) {
      bin += String.fromCharCode.apply(null, bytes.subarray(i, i + 0x8000));
    }
    return typeof btoa === 'function' ? btoa(bin) : Buffer.from(bin, 'binary').toString('base64');
  }

  return { MAX_BYTES, filesOf, uploadName, insertPath, composeMessage, pendingCount, isImage, refusal, toBase64 };
});
