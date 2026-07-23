// sh_crypto.h — E2EE for ESP32: HKDF + AES-256-GCM.
// Contract: byte-for-byte compatible with e2ee.js and WatchCrypto.swift.
// See docs/remote-clients-design.md §7.5.
#pragma once
#include <stdbool.h>
#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

// ── one-time init ───────────────────────────────────────────────────────────
// Initialize crypto context from raw 32-byte root secret. Derives auth password
// (as hex string) and AES-256-GCM key. Store password_hex (at least 65 bytes)
// for broker auth; the enc_key is kept internally.
// Returns 0 on success.
int sh_crypto_init(const uint8_t root_secret[32], char *password_hex, size_t pass_sz);

// Returns true if crypto is initialized (E2EE active).
bool sh_crypto_active(void);

// Reset to uninitialized (plaintext mode).
void sh_crypto_reset(void);

// ── HKDF helper (used by sh_config_derive_creds) ────────────────────────────
int sh_crypto_derive_credentials(const uint8_t *root_secret, size_t root_len,
                                 char *password_hex, size_t pass_sz,
                                 uint8_t *enc_key, size_t enc_sz);

// ── payload sealing ─────────────────────────────────────────────────────────
// Seal plaintext with topic as AAD. Returns base64-encoded envelope string
// (caller must free with sh_crypto_free). Returns NULL on failure.
// Empty plaintext returns empty string (retained-delete passthrough).
char *sh_crypto_seal(const char *plaintext, const char *topic);

// Open a base64-encoded envelope. Returns allocated plaintext string (caller
// must free with sh_crypto_free). Returns NULL on failure/undecryptable.
// Empty payload returns empty string.
char *sh_crypto_open(const char *payload_b64, const char *topic);

// Free a string returned by seal/open.
void sh_crypto_free(char *s);

// ── base64 / base64url utilities ───────────────────────────────────────────
// Decode a base64url string (no padding required). out_len returns decoded size.
// Returns 0 on success.
int sh_crypto_base64url_decode(const char *in, uint8_t *out, size_t out_sz, size_t *out_len);

// Encode bytes to base64 (standard, with padding). Returns allocated string
// (caller must free).
char *sh_crypto_b64_encode(const uint8_t *data, size_t len);

// ── short-code pairing (§7.5.4) ────────────────────────────────────────────
// Derive ephemeral key from an 8-digit pairing code + per-claim nonce.
void sh_crypto_code_key(const char *code, const uint8_t *nonce, size_t nonce_len,
                        uint8_t key_out[32]);

// Seal/open with an explicit key (short-code handshake).
char *sh_crypto_seal_with_key(const char *plaintext, const char *topic,
                              const uint8_t key[32]);
char *sh_crypto_open_with_key(const char *payload_b64, const char *topic,
                              const uint8_t key[32]);

// Generate random nonce bytes.
void sh_crypto_random_nonce(uint8_t *out, size_t len);

#ifdef __cplusplus
}
#endif
