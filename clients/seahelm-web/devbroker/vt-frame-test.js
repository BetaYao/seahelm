// vt-frame-test.js — the one JS definition of the binary VT frame.
//
// Run:  node devbroker/vt-frame-test.js
//
// index.html decodes with this module and bench.html encodes with it, so this
// is where the format is pinned against Sources/Core/HostGatewayVTFrame.swift:
// the byte layouts below are written out from that encoder, not from this one.
'use strict';

const zlib = require('zlib');
const VTFrame = require('../vt-frame.js');

let pass = 0, fail = 0;
const check = (ok, name, extra = '') => {
  if (ok) { pass++; console.log(`  ok   ${name}`); }
  else { fail++; console.log(`  FAIL ${name} ${extra}`); }
};
const bytes = (...xs) => Uint8Array.from(xs.flat());
const ascii = (s) => Array.from(Buffer.from(s, 'utf8'));
const same = (a, b) => a.length === b.length && a.every((x, i) => x === b[i]);

(async () => {
  console.log('vt frame');

  {
    // Swift: version, flags, kind (.data = 1), keyLength, key, payload.
    const wire = bytes(1, 0, 1, 2, ascii('k1'), ascii('hi'));
    check(same(VTFrame.encode('k1', Uint8Array.from(ascii('hi'))), wire), 'a data frame encodes as the Swift layout');
    const f = VTFrame.parse(wire);
    check(f.type === 'vt.data' && f.key === 'k1' && !f.deflated && Buffer.from(f.body).toString() === 'hi',
      'and parses back', JSON.stringify(f));
    check(f.cols === undefined && f.rows === undefined, 'a data frame carries no geometry');
    check(f.body.buffer === wire.buffer, 'the body is a view into the frame, not a copy');
  }

  {
    // Swift: .snapshot = 2, then UInt16 cols and rows, big endian, before the payload.
    const wire = bytes(1, 0, 2, 1, ascii('p'), [0x01, 0x2c, 0x00, 0x32], ascii('screen'));
    const encoded = VTFrame.encode('p', Uint8Array.from(ascii('screen')), { kind: VTFrame.KIND_SNAPSHOT, cols: 300, rows: 50 });
    check(same(encoded, wire), 'a snapshot puts cols and rows big endian after the key');
    const f = VTFrame.parse(wire);
    check(f.type === 'vt.snapshot' && f.cols === 300 && f.rows === 50 && Buffer.from(f.body).toString() === 'screen',
      'and parses back with its geometry', JSON.stringify(f));
  }

  {
    const key = 'seahelm-task-中文';
    const f = VTFrame.parse(VTFrame.encode(key, new Uint8Array([7])));
    check(f.key === key, 'a key is UTF-8, and keyLength counts its bytes', f && f.key);
  }

  {
    const raw = Buffer.from('build log '.repeat(200));
    const wire = VTFrame.encode('k', zlib.deflateRawSync(raw), { deflated: true });
    check(wire[1] === VTFrame.DEFLATE_FLAG, 'deflated sets flag bit 0');
    const f = VTFrame.parse(wire);
    const inflated = await VTFrame.inflateRaw(f.body);
    check(f.deflated && Buffer.from(inflated).equals(raw), 'raw deflate from zlib inflates back to the payload');
    check(VTFrame.deflateSupported() === true, 'deflate-raw is supported where DecompressionStream can build it');
  }

  {
    check(VTFrame.parse(bytes(1, 0, 1)) === null, 'shorter than the header is refused');
    check(VTFrame.parse(bytes(2, 0, 1, 0, ascii('x'))) === null, 'an unknown version is refused');
    check(VTFrame.parse(bytes(1, 0, 1, 9, ascii('abc'))) === null, 'a key running past the frame is refused');
    check(VTFrame.parse(bytes(1, 0, 2, 1, ascii('p'), [0, 80])) === null, 'a snapshot without its geometry is refused');
  }

  console.log(`\n${pass} passed, ${fail} failed`);
  process.exit(fail ? 1 : 0);
})();
