// vt-frame.js — the binary VT wire format, one definition for every page that
// speaks it.
//
// Third copy problem: this used to be retyped in index.html (decode) and again
// in bench.html (encode), each with a comment promising it stayed byte-identical
// to Sources/Core/HostGatewayVTFrame.swift and nothing enforcing it. A benchmark
// that measures a format the socket no longer speaks is worse than no benchmark,
// so the two clients now share this file and only Swift ↔ here has to be kept in
// step.
//
// Layout (see Sources/Core/HostGatewayVTFrame.swift):
//   u8  version (1)
//   u8  flags       bit0 = payload is raw deflate
//   u8  kind        1 = vt.data, 2 = vt.snapshot
//   u8  keyLength   pane session keys are short; longer keys are rejected
//   ..  key         UTF-8, keyLength bytes
//   u16 cols        big endian, snapshot only
//   u16 rows        big endian, snapshot only
//   ..  payload
(function (global, factory) {
  if (typeof module === 'object' && module.exports) module.exports = factory();
  else global.VTFrame = factory();
})(typeof self !== 'undefined' ? self : this, function () {
  const VERSION = 1;
  const KIND_DATA = 1;
  const KIND_SNAPSHOT = 2;
  const DEFLATE_FLAG = 1;

  function parse(buf){
    if (buf.length < 4 || buf[0] !== VERSION) return null;
    const flags = buf[1], kind = buf[2], keyLen = buf[3];
    let off = 4;
    if (buf.length < off + keyLen) return null;
    const key = new TextDecoder().decode(buf.subarray(off, off + keyLen));
    off += keyLen;
    let cols, rows;
    if (kind === KIND_SNAPSHOT){
      if (buf.length < off + 4) return null;
      cols = (buf[off] << 8) | buf[off+1];
      rows = (buf[off+2] << 8) | buf[off+3];
      off += 4;
    }
    return {
      type: kind === KIND_SNAPSHOT ? 'vt.snapshot' : 'vt.data',
      key, cols, rows,
      deflated: (flags & DEFLATE_FLAG) !== 0,
      body: buf.subarray(off),
    };
  }

  /** The encoder side, for benchmarks and tests. `kind` defaults to vt.data. */
  function encode(key, payload, { deflated = false, kind = KIND_DATA, cols, rows } = {}){
    const keyBytes = new TextEncoder().encode(key);
    const geometry = kind === KIND_SNAPSHOT ? 4 : 0;
    const buf = new Uint8Array(4 + keyBytes.length + geometry + payload.length);
    buf[0] = VERSION;
    buf[1] = deflated ? DEFLATE_FLAG : 0;
    buf[2] = kind;
    buf[3] = keyBytes.length;
    buf.set(keyBytes, 4);
    let off = 4 + keyBytes.length;
    if (geometry){
      buf[off]   = ((cols || 0) >> 8) & 0xff;
      buf[off+1] = (cols || 0) & 0xff;
      buf[off+2] = ((rows || 0) >> 8) & 0xff;
      buf[off+3] = (rows || 0) & 0xff;
      off += 4;
    }
    buf.set(payload, off);
    return buf;
  }

  /**
   * Whether this engine can actually inflate what we would negotiate for.
   *
   * `typeof DecompressionStream === 'function'` is NOT the same question:
   * Chrome/Edge 80–102 shipped the class with gzip and deflate only, so that
   * check advertised `vt_deflate`, the Mac started compressing, and every frame
   * ≥512B then threw inside the inflate and was swallowed by a catch — a
   * terminal that renders keystrokes and silently loses build logs. Construct
   * the format to ask the real question.
   */
  function deflateSupported(){
    if (typeof DecompressionStream !== 'function') return false;
    try {
      new DecompressionStream('deflate-raw');
      return true;
    } catch (e) {
      return false;
    }
  }

  async function inflateRaw(bytes){
    const stream = new Blob([bytes]).stream().pipeThrough(new DecompressionStream('deflate-raw'));
    return new Uint8Array(await new Response(stream).arrayBuffer());
  }

  return {
    VERSION, KIND_DATA, KIND_SNAPSHOT, DEFLATE_FLAG,
    parse, encode, deflateSupported, inflateRaw,
  };
});
