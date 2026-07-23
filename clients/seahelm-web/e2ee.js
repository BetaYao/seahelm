// e2ee.js — shared crypto contract for seahelm remote clients (v1).
// Same envelope + key derivation the Swift publisher (MqttCrypto.swift) and the
// ESP32/Watch clients implement. Runs in the browser (WebCrypto) and in Node
// (webcrypto), so index.html and the dev mock share one source of truth.
//
// Contract (must match MqttCrypto.swift byte-for-byte):
//   pair URI : seahelm://pair?b=<broker_url>&m=<mac_id>&k=<base64url 32B root_secret>
//   HKDF-SHA256(ikm=root_secret, salt="seahelm-pair-v1"):
//     info="auth" → 32B → broker password = lowercase hex   (username = mac_id)
//     info="e2ee" → 32B → AES-256-GCM key
//   envelope : 0x01 | nonce(12) | ciphertext||tag(16)   base64 → MQTT payload
//              AAD = utf8(topic)   (binds ciphertext to its topic)
//   empty payload ("") is never encrypted — it is the retained-delete idiom.
(function (global, factory) {
  if (typeof module === 'object' && module.exports) module.exports = factory();
  else global.E2EE = factory();
})(typeof self !== 'undefined' ? self : this, function () {
  const subtle = (() => {
    if (typeof globalThis !== 'undefined' && globalThis.crypto && globalThis.crypto.subtle) {
      return globalThis.crypto.subtle;
    }
    return require('crypto').webcrypto.subtle; // Node ≥ 18
  })();
  const getRandom = (n) => {
    const buf = new Uint8Array(n);
    (typeof globalThis !== 'undefined' && globalThis.crypto ? globalThis.crypto
      : require('crypto').webcrypto).getRandomValues(buf);
    return buf;
  };
  const enc = new TextEncoder();
  const dec = new TextDecoder();
  const SALT = enc.encode('seahelm-pair-v1');
  const VERSION = 0x01;

  // ── byte helpers ──────────────────────────────────────────────────────────
  const toHex = (buf) => Array.from(new Uint8Array(buf))
    .map((b) => b.toString(16).padStart(2, '0')).join('');
  const b64 = (bytes) => {
    let s = '';
    const arr = new Uint8Array(bytes);
    for (let i = 0; i < arr.length; i++) s += String.fromCharCode(arr[i]);
    return btoa(s);
  };
  const unb64 = (str) => {
    const s = atob(str);
    const arr = new Uint8Array(s.length);
    for (let i = 0; i < s.length; i++) arr[i] = s.charCodeAt(i);
    return arr;
  };
  const unb64url = (str) => {
    let s = str.replace(/-/g, '+').replace(/_/g, '/');
    while (s.length % 4) s += '=';
    return unb64(s);
  };

  // ── pairing ───────────────────────────────────────────────────────────────
  // Accepts a full `seahelm://pair?...` URI. Returns {broker, mac, rootBytes}.
  function parsePairURI(str) {
    const m = String(str || '').trim().match(/^seahelm:\/\/pair\?(.*)$/i);
    if (!m) throw new Error('not a seahelm pair link');
    const q = new URLSearchParams(m[1]);
    const broker = q.get('b'); const mac = q.get('m'); const k = q.get('k');
    if (!broker || !mac || !k) throw new Error('pair link missing b/m/k');
    return { broker, mac, rootBytes: unb64url(k) };
  }

  // root_secret bytes → { password (hex), encKey (CryptoKey) }.
  async function deriveKeys(rootBytes) {
    const baseKey = await subtle.importKey('raw', rootBytes, 'HKDF', false, ['deriveBits']);
    const authBits = await subtle.deriveBits(
      { name: 'HKDF', hash: 'SHA-256', salt: SALT, info: enc.encode('auth') }, baseKey, 256);
    const encBits = await subtle.deriveBits(
      { name: 'HKDF', hash: 'SHA-256', salt: SALT, info: enc.encode('e2ee') }, baseKey, 256);
    const encKey = await subtle.importKey('raw', encBits, { name: 'AES-GCM' }, false,
      ['encrypt', 'decrypt']);
    return { password: toHex(authBits), encKey };
  }

  // ── payload sealing ─────────────────────────────────────────────────────────
  async function seal(encKey, topic, plaintext) {
    if (plaintext === '' || plaintext == null) return ''; // retained-delete passthrough
    const iv = getRandom(12);
    const ct = new Uint8Array(await subtle.encrypt(
      { name: 'AES-GCM', iv, additionalData: enc.encode(topic), tagLength: 128 },
      encKey, enc.encode(plaintext)));
    const env = new Uint8Array(1 + 12 + ct.length);
    env[0] = VERSION; env.set(iv, 1); env.set(ct, 13);
    return b64(env);
  }

  async function open(encKey, topic, payloadB64) {
    if (payloadB64 === '' || payloadB64 == null) return ''; // retained-delete
    const env = unb64(payloadB64);
    if (env[0] !== VERSION) throw new Error('bad envelope version');
    const iv = env.subarray(1, 13);
    const ct = env.subarray(13);
    const pt = await subtle.decrypt(
      { name: 'AES-GCM', iv, additionalData: enc.encode(topic), tagLength: 128 }, encKey, ct);
    return dec.decode(pt);
  }

  return { parsePairURI, deriveKeys, seal, open, toHex };
});
