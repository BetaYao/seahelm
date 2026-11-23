/* Remote screen: the whole Mac, seen and driven from this page
 * (docs/superpowers/specs/2026-11-22-remote-screen-design.md, phases 1–2).
 *
 * The gateway sends the picture as binary kind 3 frames (`u8 version,
 * u8 flags (bit 0 key frame), u8 kind=3, u8 codec, u16 BE width,
 * u16 BE height, payload`): codec 2 is H.264 as Annex B access units,
 * decoded in hardware by WebCodecs' `VideoDecoder`; codec 1 is JPEG stills,
 * for a page without WebCodecs or outside a secure context (WebCodecs is
 * HTTPS-only). Input goes back as `screen.pointer` / `screen.scroll` /
 * `screen.key` / `screen.text`, coordinates normalised to the picture.
 *
 * Touch: tap = click (a quick second tap = double click), long press =
 * right click, long press then drag = mouse drag, one-finger drag = scroll,
 * pinch = zoom the picture here (never sent), two-finger drag when zoomed =
 * pan. A mouse works as a mouse (the Mac counts quick presses as double
 * clicks).
 *
 * The gateway's `screen.info` brings the Mac's displays (more than one:
 * the bar's display button picks which, `screen.display`), the Mac's
 * clipboard text whenever it changes (the clipboard button copies it here,
 * or sends this device's clipboard over, `screen.clipboard`), and the
 * bitrate the gateway settled on for this link when it is less than asked.
 *
 * index.html wires it: `ScreenView.init({send, log})`, `ScreenView.onFrame`
 * for kind 3 frames, `ScreenView.onState` for `screen.state`,
 * `ScreenView.onInfo` for `screen.info`,
 * `ScreenView.linkUp` / `linkDown` around reconnects.
 */
(function () {
  'use strict';

  const LONG_PRESS_MS = 450;
  const TAP_SLOP = 10;
  const DOUBLE_TAP_MS = 350;
  const MOVE_EVERY_MS = 33;
  const SCROLL_EVERY_MS = 40;
  const JPEG_FPS = 5;
  const H264_FPS = 30;
  const H264_KBPS = 3000;
  /// Frames waiting in the decoder past this: drop to the next key frame.
  const DECODE_BACKLOG = 6;

  let api = { send() {}, log() {} };
  let root, stage, canvas, ctx, statusEl, kbd, keyStrip, hint;
  let open = false;          // the user has the view up
  let live = false;          // the gateway accepted screen.open on this link
  let img = { w: 0, h: 0 };
  let zoom = 1, panX = 0, panY = 0;
  let decoding = false, pendingFrame = null;
  let frames = 0, fpsShown = 0, fpsTimer = null, rxBytes = 0, kbpsShown = 0, codecShown = '';
  let h264Probe = null;       // Promise<boolean>, once per page
  let dec = null, decCodec = '', decTs = 0, needKey = true;
  const mods = new Set();
  let displays = [], displayNow = null, macClip = null, linkKbps = 0;
  let panel = null;           // the open popover: 'display' | 'clip' | null

  function css() {
    const s = document.createElement('style');
    s.textContent = `
#screenView{position:fixed;inset:0;z-index:1000;background:#000;color:#eee;display:none;
  touch-action:none;user-select:none;-webkit-user-select:none;-webkit-touch-callout:none;overscroll-behavior:none}
#screenView.open{display:block}
#screenView .sv-stage{position:absolute;inset:0;overflow:hidden}
#screenView canvas{position:absolute;left:0;top:0;image-rendering:auto;cursor:default}
#screenView .sv-bar{position:absolute;top:max(6px,env(safe-area-inset-top));right:max(6px,env(safe-area-inset-right));
  display:flex;gap:6px;align-items:center;z-index:2}
#screenView .sv-bar button,#screenView .sv-keys button{background:rgba(40,40,44,.82);color:#f2f2f2;border:1px solid rgba(255,255,255,.14);
  border-radius:9px;min-width:38px;height:34px;padding:0 10px;font:600 14px -apple-system,system-ui,sans-serif;
  backdrop-filter:blur(8px);-webkit-backdrop-filter:blur(8px)}
#screenView .sv-bar button{display:flex;align-items:center;justify-content:center;width:38px;padding:0}
#screenView .sv-bar svg{width:19px;height:19px;fill:none;stroke:currentColor;stroke-width:1.7;stroke-linecap:round;stroke-linejoin:round}
#screenView .sv-keys button.on{background:#2f6fde;border-color:#2f6fde}
#screenView .sv-status{position:absolute;left:max(8px,env(safe-area-inset-left));top:max(8px,env(safe-area-inset-top));
  font:12px ui-monospace,Menlo,monospace;color:rgba(255,255,255,.75);background:rgba(0,0,0,.45);padding:3px 7px;border-radius:6px;z-index:2;
  max-width:60vw}
#screenView .sv-status.err{color:#ffb4a8}
#screenView .sv-hint{position:absolute;inset:0;display:flex;align-items:center;justify-content:center;text-align:center;
  padding:24px;font:15px -apple-system,system-ui,sans-serif;color:rgba(255,255,255,.8);pointer-events:none}
#screenView .sv-keys{position:absolute;left:0;right:0;bottom:max(6px,env(safe-area-inset-bottom));display:none;
  justify-content:center;flex-wrap:wrap;gap:6px;padding:0 8px;z-index:2}
#screenView .sv-keys.show{display:flex}
#screenView textarea.sv-type{position:absolute;left:-1000px;top:0;width:10px;height:10px;opacity:0;font-size:16px}
#screenView .sv-pop{position:absolute;top:calc(max(6px,env(safe-area-inset-top)) + 42px);right:max(6px,env(safe-area-inset-right));
  z-index:3;display:none;flex-direction:column;gap:8px;width:min(320px,calc(100vw - 16px));padding:10px;border-radius:12px;
  background:rgba(30,30,34,.94);border:1px solid rgba(255,255,255,.14);font:14px -apple-system,system-ui,sans-serif;color:#eee}
#screenView .sv-pop.show{display:flex}
#screenView .sv-pop button{background:rgba(255,255,255,.1);color:#f2f2f2;border:1px solid rgba(255,255,255,.14);border-radius:8px;
  min-height:34px;padding:4px 10px;font:600 14px -apple-system,system-ui,sans-serif;text-align:left}
#screenView .sv-pop button.on{background:#2f6fde;border-color:#2f6fde}
#screenView .sv-pop .sv-clip{font:12px ui-monospace,Menlo,monospace;color:rgba(255,255,255,.75);white-space:pre-wrap;word-break:break-all;
  max-height:96px;overflow:auto;background:rgba(0,0,0,.35);border-radius:6px;padding:6px}
#screenView .sv-pop textarea{width:100%;box-sizing:border-box;min-height:64px;font-size:16px;border-radius:8px;
  background:rgba(0,0,0,.35);color:#eee;border:1px solid rgba(255,255,255,.14);padding:6px;user-select:text;-webkit-user-select:text}
#screenView .sv-pop .sv-row{display:flex;gap:6px}
#screenView .sv-pop .sv-row button{flex:1;text-align:center}
#screenView [hidden]{display:none!important}
`;
    document.head.appendChild(s);
  }

  function build() {
    css();
    root = document.createElement('div');
    root.id = 'screenView';
    root.setAttribute('role', 'application');
    root.setAttribute('aria-label', 'Mac screen');
    root.innerHTML = `
<div class="sv-stage"><canvas></canvas><div class="sv-hint"></div></div>
<div class="sv-status"></div>
<div class="sv-bar">
  <button type="button" data-act="display" title="Display" aria-label="Display" hidden><svg viewBox="0 0 24 24" aria-hidden="true"><rect x="3" y="4.5" width="18" height="12" rx="1.6"/><path d="M9 20h6M12 16.5V20"/></svg></button>
  <button type="button" data-act="clip" title="Clipboard" aria-label="Clipboard"><svg viewBox="0 0 24 24" aria-hidden="true"><rect x="5.5" y="4.5" width="13" height="16" rx="2"/><path d="M9 4.5V3.8c0-.7.5-1.3 1.2-1.3h3.6c.7 0 1.2.6 1.2 1.3v.7M9 10h6M9 14h4"/></svg></button>
  <button type="button" data-act="fit" title="Fit" aria-label="Fit"><svg viewBox="0 0 24 24" aria-hidden="true"><path d="M4 9V4h5M20 9V4h-5M4 15v5h5M20 15v5h-5"/></svg></button>
  <button type="button" data-act="kbd" title="Keyboard" aria-label="Keyboard"><svg viewBox="0 0 24 24" aria-hidden="true"><rect x="2.5" y="6" width="19" height="12" rx="2"/><path d="M6 10h.01M9.5 10h.01M13 10h.01M16.5 10h.01M6.5 14h11"/></svg></button>
  <button type="button" data-act="close" title="Close" aria-label="Close"><svg viewBox="0 0 24 24" aria-hidden="true"><path d="M6 6l12 12M18 6L6 18"/></svg></button>
</div>
<div class="sv-keys">
  <button type="button" data-mod="cmd">⌘</button><button type="button" data-mod="alt">⌥</button>
  <button type="button" data-mod="ctrl">⌃</button><button type="button" data-mod="shift">⇧</button>
  <button type="button" data-key="esc">esc</button><button type="button" data-key="tab">tab</button>
  <button type="button" data-key="left">←</button><button type="button" data-key="up">↑</button>
  <button type="button" data-key="down">↓</button><button type="button" data-key="right">→</button>
  <button type="button" data-key="backspace">⌫</button><button type="button" data-key="return">⏎</button>
</div>
<div class="sv-pop" data-pop="display"></div>
<div class="sv-pop" data-pop="clip">
  <div>Mac clipboard</div>
  <div class="sv-clip">(nothing yet)</div>
  <button type="button" data-clip="copy">Copy to this device</button>
  <textarea placeholder="Text for the Mac's clipboard" autocapitalize="off" autocomplete="off" autocorrect="off" spellcheck="false"></textarea>
  <div class="sv-row"><button type="button" data-clip="send">Put on Mac</button><button type="button" data-clip="paste">Put on Mac + ⌘V</button></div>
</div>
<textarea class="sv-type" autocapitalize="off" autocomplete="off" autocorrect="off" spellcheck="false" aria-label="Type on the Mac"></textarea>`;
    document.body.appendChild(root);
    stage = root.querySelector('.sv-stage');
    canvas = root.querySelector('canvas');
    ctx = canvas.getContext('2d');
    statusEl = root.querySelector('.sv-status');
    hint = root.querySelector('.sv-hint');
    keyStrip = root.querySelector('.sv-keys');
    kbd = root.querySelector('textarea.sv-type');

    root.querySelector('.sv-bar').addEventListener('click', (e) => {
      const b = e.target.closest('button');
      if (!b) return;
      const act = b.dataset.act;
      if (act === 'close') close();
      else if (act === 'fit') { zoom = 1; panX = panY = 0; layout(); }
      else if (act === 'kbd') toggleKeyboard();
      else if (act === 'display' || act === 'clip') togglePanel(act);
    });
    wirePanels();
    // Keep focus in the hidden textarea, so the system keyboard stays up.
    keyStrip.addEventListener('pointerdown', (e) => e.preventDefault());
    keyStrip.addEventListener('click', (e) => {
      const b = e.target.closest('button');
      if (!b) return;
      if (b.dataset.mod) {
        const m = b.dataset.mod;
        if (mods.has(m)) mods.delete(m); else mods.add(m);
        b.classList.toggle('on', mods.has(m));
      } else if (b.dataset.key) {
        sendKey(b.dataset.key);
      }
    });
    wireKeyboard();
    wireTouch();
    wireMouse();
    window.addEventListener('resize', layout);
    document.addEventListener('visibilitychange', () => {
      if (!open) return;
      if (document.hidden) stop(); else start();
    });
  }

  // ── lifecycle ──────────────────────────────────────────────────────────

  /** Whether this page can decode H.264: WebCodecs exists only in a secure
   *  context, and a decoder may still refuse the profile. */
  function probeH264() {
    if (!h264Probe) {
      h264Probe = (async () => {
        if (!window.isSecureContext || typeof VideoDecoder === 'undefined') return false;
        try {
          const r = await VideoDecoder.isConfigSupported({ codec: 'avc1.640028', optimizeForLatency: true });
          return !!r.supported;
        } catch { return false; }
      })();
    }
    return h264Probe;
  }

  function wanted(h264) {
    const short = Math.min(window.screen.width, window.screen.height) * (window.devicePixelRatio || 1);
    return {
      fps: h264 ? H264_FPS : JPEG_FPS,
      kbps: H264_KBPS,
      max_short: Math.max(480, Math.min(1600, Math.round(short))),
      codecs: h264 ? ['h264', 'jpeg'] : ['jpeg'],
    };
  }

  async function start() {
    if (!open || live) return;
    setHint('Connecting to the Mac…');
    const h264 = await probeH264();
    if (!open || live) return;
    if (!h264) api.log('sys', '(screen)', window.isSecureContext ? 'no H.264 decoder: JPEG' : 'not a secure context: JPEG');
    resetDecoder();
    linkKbps = 0;
    api.send('screen.open', wanted(h264), (r, err) => {
      if (!open) { if (r && r.ok) api.send('screen.close', {}); return; }
      if (err || !r) { setHint((err && err.message) || 'No answer from the Mac.'); return; }
      if (!r.ok) { setHint(r.message || 'The Mac refused.'); return; }
      live = true;
      setHint(img.w ? '' : 'Waiting for the first picture…');
    });
  }

  function stop() {
    if (live) api.send('screen.close', {});
    live = false;
    resetDecoder();
  }

  function show() {
    if (!root) build();
    open = true;
    root.classList.add('open');
    document.body.classList.add('screen-open');
    zoom = 1; panX = panY = 0;
    layout();
    clearInterval(fpsTimer);
    fpsTimer = setInterval(() => {
      fpsShown = frames; frames = 0;
      kbpsShown = Math.round(rxBytes * 8 / 1000); rxBytes = 0;
      status();
    }, 1000);
    start();
  }

  function close() {
    stop();
    open = false;
    kbd && kbd.blur();
    clearInterval(fpsTimer);
    if (root) root.classList.remove('open');
    document.body.classList.remove('screen-open');
  }

  function setHint(t) {
    hint.textContent = t || '';
    hint.style.display = t ? 'flex' : 'none';
  }

  let lastError = '';
  function status() {
    if (!statusEl) return;
    statusEl.classList.toggle('err', !!lastError);
    const rate = kbpsShown >= 1000 ? `${(kbpsShown / 1000).toFixed(1)} Mbps` : `${kbpsShown} kbps`;
    // The gateway lowered this link's bitrate: say to what.
    const cap = linkKbps && linkKbps < H264_KBPS && codecShown === 'h264' ? ` · cap ${(linkKbps / 1000).toFixed(1)} Mbps` : '';
    statusEl.textContent = lastError || (img.w ? `${codecShown} · ${img.w}×${img.h} · ${fpsShown} fps · ${rate}${cap}` : '');
  }

  // ── frames ─────────────────────────────────────────────────────────────

  function onFrame(buf) {
    if (!open || !live || buf.length < 8) return;
    const codec = buf[3], key = (buf[1] & 1) === 1;
    const w = (buf[4] << 8) | buf[5], h = (buf[6] << 8) | buf[7];
    rxBytes += buf.length;
    if (codec === 2) { h264Frame(buf.subarray(8), key, w, h); return; }
    if (codec !== 1) { api.log('sys', '(screen)', `codec ${codec} not supported`); return; }
    codecShown = 'jpeg';
    resetDecoder();
    pendingFrame = { w, h, bytes: buf.subarray(8) };
    if (!decoding) drawNext();
  }

  // ── H.264 ──────────────────────────────────────────────────────────────

  /** `avc1.PPCCLL` from the SPS in an Annex B access unit; null without one. */
  function codecFromSps(au) {
    for (let i = 0; i + 4 < au.length; i++) {
      if (au[i] !== 0 || au[i + 1] !== 0) continue;
      let at = -1;
      if (au[i + 2] === 1) at = i + 3;
      else if (au[i + 2] === 0 && au[i + 3] === 1) at = i + 4;
      if (at < 0 || at + 3 >= au.length) continue;
      if ((au[at] & 0x1f) === 7) {
        const hex = (n) => n.toString(16).padStart(2, '0');
        return 'avc1.' + hex(au[at + 1]) + hex(au[at + 2]) + hex(au[at + 3]);
      }
      i = at;
    }
    return null;
  }

  function resetDecoder() {
    if (dec && dec.state !== 'closed') { try { dec.close(); } catch {} }
    dec = null; decCodec = ''; needKey = true;
  }

  function decoderBroke(why) {
    api.log('sys', '(screen)', 'decoder: ' + why);
    resetDecoder();
    if (live) api.send('screen.key_frame', {});
  }

  function h264Frame(au, key, w, h) {
    codecShown = 'h264';
    if (key) {
      const c = codecFromSps(au);
      if (c && (c !== decCodec || !dec || dec.state === 'closed')) {
        resetDecoder();
        try {
          dec = new VideoDecoder({ output: showVideoFrame, error: (e) => decoderBroke(e && e.message || String(e)) });
          dec.configure({ codec: c, codedWidth: w, codedHeight: h, optimizeForLatency: true });
          decCodec = c;
        } catch (e) { decoderBroke(e && e.message || String(e)); return; }
      }
    }
    if (!dec || dec.state !== 'configured') return;
    if (!key && needKey) return;
    if (!key && dec.decodeQueueSize > DECODE_BACKLOG) {
      // Falling behind: everything queued is stale. Skip to a key frame.
      needKey = true;
      api.send('screen.key_frame', {});
      return;
    }
    if (key) needKey = false;
    try {
      // Copied, so the chunk owns exactly its bytes.
      dec.decode(new EncodedVideoChunk({ type: key ? 'key' : 'delta', timestamp: (decTs++) * 33333, data: au.slice() }));
    } catch (e) { decoderBroke(e && e.message || String(e)); }
  }

  function showVideoFrame(frame) {
    try {
      if (!open) return;
      const w = frame.displayWidth, h = frame.displayHeight;
      if (canvas.width !== w || canvas.height !== h) { canvas.width = w; canvas.height = h; }
      const resized = img.w !== w || img.h !== h;
      img = { w, h };
      ctx.drawImage(frame, 0, 0);
      frames++;
      if (resized) layout();
      if (hint.textContent) setHint('');
    } finally {
      frame.close();
    }
  }

  async function drawNext() {
    const f = pendingFrame;
    if (!f) return;
    pendingFrame = null;
    decoding = true;
    try {
      const bmp = await createImageBitmap(new Blob([f.bytes], { type: 'image/jpeg' }));
      if (canvas.width !== bmp.width || canvas.height !== bmp.height) {
        canvas.width = bmp.width; canvas.height = bmp.height;
      }
      const resized = img.w !== bmp.width || img.h !== bmp.height;
      img = { w: bmp.width, h: bmp.height };
      ctx.drawImage(bmp, 0, 0);
      bmp.close && bmp.close();
      frames++;
      if (resized) layout();
      if (hint.textContent) setHint('');
    } catch (e) {
      api.log('sys', '(screen)', 'decode failed: ' + (e && e.message || e));
    } finally {
      decoding = false;
      if (pendingFrame) drawNext();
    }
  }

  function onState(p) {
    if (!open) return;
    if (p.open === false) {
      live = false;
      const why = { stopped: 'Sharing was stopped on the Mac.', app_gone: 'seahelm on the Mac went away.', gateway: 'The gateway closed the screen.' }[p.reason] || 'The screen was closed.';
      setHint(why + ' Close and open the screen again to retry.');
      return;
    }
    lastError = p.error || '';
    status();
  }

  // ── displays and clipboard ─────────────────────────────────────────────

  function onInfo(p) {
    if (Array.isArray(p.displays)) {
      displays = p.displays;
      displayNow = p.display != null ? p.display : displayNow;
      renderDisplays();
    }
    if (typeof p.clipboard === 'string') {
      macClip = p.clipboard;
      renderClip();
    }
    if (typeof p.kbps === 'number') { linkKbps = p.kbps; status(); }
  }

  function togglePanel(which) {
    panel = panel === which ? null : which;
    root.querySelectorAll('.sv-pop').forEach((el) => el.classList.toggle('show', el.dataset.pop === panel));
    if (panel === 'clip') renderClip();
  }

  function renderDisplays() {
    if (!root) return;
    root.querySelector('[data-act="display"]').hidden = displays.length < 2;
    const pop = root.querySelector('[data-pop="display"]');
    pop.textContent = '';
    for (const d of displays) {
      const b = document.createElement('button');
      b.type = 'button';
      b.dataset.display = String(d.id);
      b.textContent = `${d.name || 'Display'} · ${d.width}×${d.height}${d.main ? ' · main' : ''}`;
      b.classList.toggle('on', d.id === displayNow);
      pop.appendChild(b);
    }
    if (displays.length < 2 && panel === 'display') togglePanel('display');
  }

  function renderClip() {
    if (!root) return;
    const el = root.querySelector('.sv-clip');
    if (macClip == null) { el.textContent = '(nothing yet)'; return; }
    el.textContent = macClip.length > 600 ? macClip.slice(0, 600) + '…' : macClip;
  }

  async function copyHere(text) {
    try { await navigator.clipboard.writeText(text); return true; } catch {}
    // Web views that refuse the async API (Telegram's) still copy this way.
    const t = document.createElement('textarea');
    t.value = text; t.style.position = 'fixed'; t.style.opacity = '0';
    root.appendChild(t); t.select();
    let ok = false;
    try { ok = document.execCommand('copy'); } catch {}
    t.remove();
    return ok;
  }

  function wirePanels() {
    root.querySelector('[data-pop="display"]').addEventListener('click', (e) => {
      const b = e.target.closest('button[data-display]');
      if (!b || !live) return;
      const id = Number(b.dataset.display);
      api.send('screen.display', { id });
      displayNow = id;
      renderDisplays();
      togglePanel('display');
    });
    const pop = root.querySelector('[data-pop="clip"]');
    const box = pop.querySelector('textarea');
    pop.addEventListener('click', async (e) => {
      const b = e.target.closest('button[data-clip]');
      if (!b) return;
      const act = b.dataset.clip;
      if (act === 'copy') {
        if (macClip == null) return;
        const ok = await copyHere(macClip);
        b.textContent = ok ? 'Copied' : 'Copy failed';
        setTimeout(() => { b.textContent = 'Copy to this device'; }, 1500);
        return;
      }
      if (!live) return;
      // The box's text, else this device's clipboard (the browser may ask).
      let text = box.value;
      if (!text) { try { text = await navigator.clipboard.readText(); } catch {} }
      if (!text) { box.focus(); return; }
      api.send('screen.clipboard', { text });
      macClip = text; renderClip();
      box.value = '';
      if (act === 'paste') api.send('screen.key', { key: 'cmd+v' });
      togglePanel('clip');
    });
  }

  function linkDown() { if (open) { live = false; setHint('Reconnecting…'); } }
  function linkUp() { if (open) start(); }

  // ── geometry ───────────────────────────────────────────────────────────

  function box() {
    const W = stage.clientWidth, H = stage.clientHeight;
    if (!img.w) return { left: 0, top: 0, scale: 1, W, H };
    const fit = Math.min(W / img.w, H / img.h);
    const scale = fit * zoom;
    const left = (W - img.w * scale) / 2 + panX;
    const top = (H - img.h * scale) / 2 + panY;
    return { left, top, scale, W, H };
  }

  function layout() {
    if (!canvas || !img.w) return;
    clampPan();
    const b = box();
    canvas.style.width = `${img.w * b.scale}px`;
    canvas.style.height = `${img.h * b.scale}px`;
    canvas.style.left = `${b.left}px`;
    canvas.style.top = `${b.top}px`;
  }

  function clampPan() {
    if (zoom <= 1.001) { zoom = 1; panX = panY = 0; return; }
    const W = stage.clientWidth, H = stage.clientHeight;
    const fit = Math.min(W / img.w, H / img.h);
    const maxX = Math.max(0, (img.w * fit * zoom - W) / 2);
    const maxY = Math.max(0, (img.h * fit * zoom - H) / 2);
    panX = Math.max(-maxX, Math.min(maxX, panX));
    panY = Math.max(-maxY, Math.min(maxY, panY));
  }

  /** A point on the page → the picture, normalised; null when off it. */
  function norm(clientX, clientY) {
    if (!img.w) return null;
    const r = stage.getBoundingClientRect();
    const b = box();
    const x = (clientX - r.left - b.left) / (img.w * b.scale);
    const y = (clientY - r.top - b.top) / (img.h * b.scale);
    if (x < 0 || x > 1 || y < 0 || y > 1) return null;
    return { x, y };
  }

  /** Page pixels → picture pixels, for scroll deltas. */
  function toPicture(d) { return d / box().scale; }

  // ── input out ──────────────────────────────────────────────────────────

  function pointer(action, p) {
    if (!live || !p) return;
    api.send('screen.pointer', { action, x: +p.x.toFixed(5), y: +p.y.toFixed(5) });
  }

  let scrollAcc = { dx: 0, dy: 0, at: null, timer: null };
  function scroll(p, dx, dy) {
    if (!live || !p) return;
    scrollAcc.dx += dx; scrollAcc.dy += dy; scrollAcc.at = p;
    if (scrollAcc.timer) return;
    scrollAcc.timer = setTimeout(() => {
      const { dx: sx, dy: sy, at } = scrollAcc;
      scrollAcc = { dx: 0, dy: 0, at: null, timer: null };
      if (Math.abs(sx) < 0.5 && Math.abs(sy) < 0.5) return;
      api.send('screen.scroll', { x: at.x, y: at.y, dx: Math.round(sx), dy: Math.round(sy) });
    }, SCROLL_EVERY_MS);
  }

  function sendKey(name) {
    if (!live) return;
    const chord = [...mods, name].join('+');
    api.send('screen.key', { key: chord });
    clearMods();
  }

  function clearMods() {
    if (!mods.size) return;
    mods.clear();
    keyStrip.querySelectorAll('button.on').forEach((b) => b.classList.remove('on'));
  }

  function sendText(t) {
    if (!live || !t) return;
    // With a modifier held, a single character is a shortcut, not text.
    if (mods.size && [...t].length === 1) { sendKey(t.toLowerCase()); return; }
    api.send('screen.text', { text: t });
  }

  // ── keyboard ───────────────────────────────────────────────────────────

  function toggleKeyboard() {
    const showing = keyStrip.classList.toggle('show');
    if (showing) kbd.focus({ preventScroll: true }); else kbd.blur();
  }

  function wireKeyboard() {
    let composing = false;
    kbd.addEventListener('compositionstart', () => { composing = true; });
    kbd.addEventListener('compositionend', (e) => {
      composing = false;
      sendText(e.data || kbd.value);
      kbd.value = '';
    });
    kbd.addEventListener('keydown', (e) => {
      if (composing || e.isComposing) return;
      const named = { Enter: 'return', Backspace: 'backspace', Tab: 'tab', Escape: 'esc', ArrowLeft: 'left',
        ArrowRight: 'right', ArrowUp: 'up', ArrowDown: 'down', Delete: 'forwarddelete', Home: 'home', End: 'end',
        PageUp: 'pageup', PageDown: 'pagedown' }[e.key];
      const hw = e.metaKey || e.ctrlKey || e.altKey;
      if (named || (hw && e.key.length === 1)) {
        e.preventDefault();
        if (e.metaKey) mods.add('cmd');
        if (e.ctrlKey) mods.add('ctrl');
        if (e.altKey) mods.add('alt');
        if (e.shiftKey && named) mods.add('shift');
        sendKey(named || e.key.toLowerCase());
      }
    });
    kbd.addEventListener('input', (e) => {
      if (composing || e.isComposing) return;
      if (e.inputType === 'deleteContentBackward') { sendKey('backspace'); kbd.value = ''; return; }
      if (e.inputType === 'insertLineBreak') { sendKey('return'); kbd.value = ''; return; }
      const t = e.data != null ? e.data : kbd.value;
      kbd.value = '';
      sendText(t);
    });
  }

  // ── touch ──────────────────────────────────────────────────────────────

  function wireTouch() {
    let one = null;      // one-finger gesture
    let two = null;      // pinch / pan
    let lastTap = { t: 0, x: 0, y: 0 };
    let moveTimer = 0;

    const center = (a, b) => ({ x: (a.clientX + b.clientX) / 2, y: (a.clientY + b.clientY) / 2 });
    const dist = (a, b) => Math.hypot(a.clientX - b.clientX, a.clientY - b.clientY);

    stage.addEventListener('touchstart', (e) => {
      e.preventDefault();
      if (e.touches.length >= 2) {
        if (one && one.dragging) pointer('up', one.last);
        if (one) clearTimeout(one.timer);
        one = null;
        const [a, b] = e.touches;
        two = { d: dist(a, b), c: center(a, b), zoom, panX, panY };
        return;
      }
      const t = e.touches[0];
      const p = norm(t.clientX, t.clientY);
      one = { x: t.clientX, y: t.clientY, lx: t.clientX, ly: t.clientY, start: p, last: p,
        held: false, dragging: false, scrolling: false, timer: 0 };
      one.timer = setTimeout(() => {
        if (!one || one.scrolling) return;
        one.held = true;
        if (navigator.vibrate) navigator.vibrate(12);
      }, LONG_PRESS_MS);
    }, { passive: false });

    stage.addEventListener('touchmove', (e) => {
      e.preventDefault();
      if (two && e.touches.length >= 2) {
        const [a, b] = e.touches;
        const c = center(a, b);
        const r = stage.getBoundingClientRect();
        const z = Math.max(1, Math.min(6, two.zoom * dist(a, b) / two.d));
        // Zoom about the pinch centre, then follow the fingers.
        const ox = two.c.x - r.left - stage.clientWidth / 2, oy = two.c.y - r.top - stage.clientHeight / 2;
        const k = z / two.zoom;
        zoom = z;
        panX = ox - (ox - two.panX) * k + (c.x - two.c.x);
        panY = oy - (oy - two.panY) * k + (c.y - two.c.y);
        layout();
        return;
      }
      if (!one) return;
      const t = e.touches[0];
      const moved = Math.hypot(t.clientX - one.x, t.clientY - one.y) > TAP_SLOP;
      const p = norm(t.clientX, t.clientY) || one.last;
      if (one.held) {
        if (!one.dragging && moved) { one.dragging = true; pointer('down', one.start); }
        if (one.dragging) {
          one.last = p;
          const now = performance.now();
          if (now - moveTimer > MOVE_EVERY_MS) { moveTimer = now; pointer('move', p); }
        }
        return;
      }
      if (moved && !one.scrolling) { one.scrolling = true; clearTimeout(one.timer); }
      if (one.scrolling) {
        scroll(one.start || p, toPicture(t.clientX - one.lx), toPicture(t.clientY - one.ly));
        one.lx = t.clientX; one.ly = t.clientY;
      }
    }, { passive: false });

    const end = (e) => {
      e.preventDefault();
      if (two) { if (e.touches.length < 2) two = null; return; }
      if (!one) return;
      clearTimeout(one.timer);
      const g = one;
      one = null;
      if (g.dragging) { pointer('move', g.last); pointer('up', g.last); return; }
      if (g.scrolling) return;
      if (g.held) { pointer('right', g.start); return; }
      const now = performance.now();
      const near = Math.hypot(g.x - lastTap.x, g.y - lastTap.y) < 30;
      if (now - lastTap.t < DOUBLE_TAP_MS && near) {
        pointer('double', g.start);
        lastTap = { t: 0, x: 0, y: 0 };
      } else {
        pointer('click', g.start);
        lastTap = { t: now, x: g.x, y: g.y };
      }
    };
    stage.addEventListener('touchend', end, { passive: false });
    stage.addEventListener('touchcancel', end, { passive: false });
  }

  // ── mouse (a desktop browser) ──────────────────────────────────────────

  function wireMouse() {
    let down = false, lastMove = 0;
    stage.addEventListener('mousedown', (e) => {
      if (e.button === 2) return;
      down = true;
      pointer('down', norm(e.clientX, e.clientY));
    });
    stage.addEventListener('mousemove', (e) => {
      const now = performance.now();
      if (now - lastMove < MOVE_EVERY_MS) return;
      lastMove = now;
      pointer('move', norm(e.clientX, e.clientY));
    });
    window.addEventListener('mouseup', (e) => {
      if (!down || !open) return;
      down = false;
      pointer('up', norm(e.clientX, e.clientY) || { x: 0, y: 0 });
    });
    stage.addEventListener('contextmenu', (e) => { e.preventDefault(); pointer('right', norm(e.clientX, e.clientY)); });
    stage.addEventListener('wheel', (e) => {
      e.preventDefault();
      scroll(norm(e.clientX, e.clientY), -toPicture(e.deltaX), -toPicture(e.deltaY));
    }, { passive: false });
  }

  window.ScreenView = {
    init(o) { api = Object.assign(api, o); },
    open: show,
    close,
    get isOpen() { return open; },
    onFrame,
    onState,
    onInfo,
    linkUp,
    linkDown,
  };
})();
