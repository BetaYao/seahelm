// sh_crypto.c — E2EE implementation using mbedTLS (ESP-IDF built-in).
// Implements the seahelm E2EE contract: HKDF-SHA256 key derivation,
// AES-256-GCM seal/open with topic AAD, base64 envelope.
#include "sh_crypto.h"
#include <string.h>
#include <stdio.h>
#include <stdlib.h>
#include "esp_log.h"
#include "esp_random.h"   // esp_fill_random
#include "mbedtls/hkdf.h"
#include "mbedtls/gcm.h"
#include "mbedtls/base64.h"

__attribute__((unused)) static const char *TAG = "sh_crypto";

// ── internal state ──────────────────────────────────────────────────────────
static struct {
    bool    initialized;
    uint8_t enc_key[32];   // AES-256-GCM key
} s_crypto;

static const uint8_t SALT[] = "seahelm-pair-v1";
static const uint8_t ENVELOPE_VERSION = 0x01;
static const size_t GCM_NONCE_LEN = 12;
static const size_t GCM_TAG_LEN  = 16;

// ── HKDF helper ─────────────────────────────────────────────────────────────
static int hkdf_sha256(const uint8_t *ikm, size_t ikm_len,
                       const uint8_t *salt, size_t salt_len,
                       const uint8_t *info, size_t info_len,
                       uint8_t *out, size_t out_len) {
    return mbedtls_hkdf(mbedtls_md_info_from_type(MBEDTLS_MD_SHA256),
                        salt, salt_len,
                        ikm, ikm_len,
                        info, info_len,
                        out, out_len);
}

// ── derive credentials ──────────────────────────────────────────────────────
int sh_crypto_derive_credentials(const uint8_t *root_secret, size_t root_len,
                                 char *password_hex, size_t pass_sz,
                                 uint8_t *enc_key, size_t enc_sz) {
    uint8_t auth_key[32];
    int ret = hkdf_sha256(root_secret, root_len,
                          SALT, sizeof(SALT) - 1,
                          (const uint8_t *)"auth", 4,
                          auth_key, sizeof(auth_key));
    if (ret != 0) return ret;

    // auth_key → lowercase hex string
    for (int i = 0; i < 32 && i * 2 + 2 < (int)pass_sz; i++) {
        sprintf(password_hex + i * 2, "%02x", auth_key[i]);
    }

    ret = hkdf_sha256(root_secret, root_len,
                      SALT, sizeof(SALT) - 1,
                      (const uint8_t *)"e2ee", 4,
                      enc_key, enc_sz);
    return ret;
}

bool sh_crypto_active(void) { return s_crypto.initialized; }

void sh_crypto_reset(void) {
    memset(&s_crypto, 0, sizeof(s_crypto));
}

int sh_crypto_init(const uint8_t root_secret[32], char *password_hex, size_t pass_sz) {
    uint8_t enc_key[32];
    int ret = sh_crypto_derive_credentials(root_secret, 32,
                                           password_hex, pass_sz,
                                           enc_key, sizeof(enc_key));
    if (ret != 0) return ret;
    memcpy(s_crypto.enc_key, enc_key, sizeof(enc_key));
    s_crypto.initialized = true;
    return 0;
}

// ── helpers ─────────────────────────────────────────────────────────────────
__attribute__((unused)) static void hex_encode(const uint8_t *in, size_t in_len, char *out) {
    for (size_t i = 0; i < in_len; i++) {
        sprintf(out + i * 2, "%02x", in[i]);
    }
}

// ── base64 ──────────────────────────────────────────────────────────────────
static const unsigned char b64dec[256] = {
    0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,
    0,0,0,0,0,0,0,0,0,0,0,62,0,0,0,63, 52,53,54,55,56,57,58,59,60,61,0,0,0,0,0,0,
    0,0,1,2,3,4,5,6,7,8,9,10,11,12,13,14, 15,16,17,18,19,20,21,22,23,24,25,0,0,0,0,0,
    0,26,27,28,29,30,31,32,33,34,35,36,37,38,39,40, 41,42,43,44,45,46,47,48,49,50,51,0,0,0,0,0,
};

int sh_crypto_base64url_decode(const char *in, uint8_t *out, size_t out_sz, size_t *out_len) {
    size_t slen = strlen(in);
    size_t j = 0;
    uint8_t buf[4];
    int buf_i = 0;

    for (size_t i = 0; i < slen; i++) {
        unsigned char c = (unsigned char)in[i];
        if (c == '=') continue;
        // base64URL: '-'/'_' replace '+'/'/'. The table is standard-base64 only,
        // so map the URL chars explicitly or root_secret (base64url) decodes wrong.
        unsigned char v = (c == '-') ? 62 : (c == '_') ? 63 : b64dec[c];
        if (v == 0 && c != 'A') continue;
        buf[buf_i++] = v;
        if (buf_i == 4) {
            if (j + 3 > out_sz) return -1;
            out[j++] = (buf[0] << 2) | (buf[1] >> 4);
            out[j++] = (buf[1] << 4) | (buf[2] >> 2);
            out[j++] = (buf[2] << 6) | buf[3];
            buf_i = 0;
        }
    }
    if (buf_i >= 2 && j + 1 <= out_sz) out[j++] = (buf[0] << 2) | (buf[1] >> 4);
    if (buf_i >= 3 && j + 1 <= out_sz) out[j++] = (buf[1] << 4) | (buf[2] >> 2);
    *out_len = j;
    return 0;
}

char *sh_crypto_b64_encode(const uint8_t *data, size_t len) {
    size_t olen = 0;
    // mbedtls_base64_encode needs to be called twice
    int ret = mbedtls_base64_encode(NULL, 0, &olen, data, len);
    if (ret != MBEDTLS_ERR_BASE64_BUFFER_TOO_SMALL) return NULL;
    char *out = (char *)malloc(olen + 1);
    if (!out) return NULL;
    ret = mbedtls_base64_encode((unsigned char *)out, olen, &olen, data, len);
    if (ret != 0) { free(out); return NULL; }
    out[olen] = '\0';
    return out;
}

// ── seal / open ─────────────────────────────────────────────────────────────
// Envelope: version(1) | nonce(12) | ciphertext || tag(16)
// The nonce is prepended; the tag is appended by AES-GCM.

char *sh_crypto_seal(const char *plaintext, const char *topic) {
    if (!plaintext || plaintext[0] == '\0') {
        char *empty = (char *)malloc(1);
        if (empty) empty[0] = '\0';
        return empty;
    }

    mbedtls_gcm_context gcm;
    mbedtls_gcm_init(&gcm);
    int ret = mbedtls_gcm_setkey(&gcm, MBEDTLS_CIPHER_ID_AES, s_crypto.enc_key, 256);
    if (ret != 0) { mbedtls_gcm_free(&gcm); return NULL; }

    size_t pt_len = strlen(plaintext);
    size_t ct_len = pt_len;
    uint8_t *ct = (uint8_t *)malloc(ct_len + 16);  // extra for tag
    if (!ct) { mbedtls_gcm_free(&gcm); return NULL; }

    uint8_t nonce[GCM_NONCE_LEN];
    sh_crypto_random_nonce(nonce, GCM_NONCE_LEN);

    size_t tag_len = GCM_TAG_LEN;
    ret = mbedtls_gcm_crypt_and_tag(&gcm, MBEDTLS_GCM_ENCRYPT,
                                    pt_len,
                                    nonce, GCM_NONCE_LEN,
                                    (const unsigned char *)topic, strlen(topic),
                                    (const unsigned char *)plaintext,
                                    ct, tag_len, ct + ct_len);
    mbedtls_gcm_free(&gcm);
    if (ret != 0) { free(ct); return NULL; }

    // Build envelope: version | nonce | ciphertext_tag
    size_t env_len = 1 + GCM_NONCE_LEN + ct_len + tag_len;
    uint8_t *env = (uint8_t *)malloc(env_len);
    if (!env) { free(ct); return NULL; }
    env[0] = ENVELOPE_VERSION;
    memcpy(env + 1, nonce, GCM_NONCE_LEN);
    memcpy(env + 1 + GCM_NONCE_LEN, ct, ct_len + tag_len);
    free(ct);

    char *b64 = sh_crypto_b64_encode(env, env_len);
    free(env);
    return b64;
}

char *sh_crypto_open(const char *payload_b64, const char *topic) {
    if (!payload_b64 || payload_b64[0] == '\0') {
        char *empty = (char *)malloc(1);
        if (empty) empty[0] = '\0';
        return empty;
    }

    size_t env_len = 0;
    uint8_t env[2048];
    if (sh_crypto_base64url_decode(payload_b64, env, sizeof(env), &env_len) != 0) {
        // Try standard base64
        // mbedtls_base64_decode
        size_t olen = 0;
        int ret = mbedtls_base64_decode(NULL, 0, &olen,
                                        (const unsigned char *)payload_b64, strlen(payload_b64));
        if (ret != MBEDTLS_ERR_BASE64_BUFFER_TOO_SMALL || olen > sizeof(env)) return NULL;
        ret = mbedtls_base64_decode(env, olen, &env_len,
                                    (const unsigned char *)payload_b64, strlen(payload_b64));
        if (ret != 0) return NULL;
    }

    if (env_len < 1 + GCM_NONCE_LEN + 1 || env[0] != ENVELOPE_VERSION) return NULL;

    const uint8_t *nonce = env + 1;
    const uint8_t *ct_tag = env + 1 + GCM_NONCE_LEN;
    size_t ct_tag_len = env_len - 1 - GCM_NONCE_LEN;
    if (ct_tag_len <= GCM_TAG_LEN) return NULL;
    size_t ct_len = ct_tag_len - GCM_TAG_LEN;

    mbedtls_gcm_context gcm;
    mbedtls_gcm_init(&gcm);
    int ret = mbedtls_gcm_setkey(&gcm, MBEDTLS_CIPHER_ID_AES, s_crypto.enc_key, 256);
    if (ret != 0) { mbedtls_gcm_free(&gcm); return NULL; }

    uint8_t *pt = (uint8_t *)malloc(ct_len + 1);
    if (!pt) { mbedtls_gcm_free(&gcm); return NULL; }

    ret = mbedtls_gcm_auth_decrypt(&gcm,
                                   ct_len,
                                   nonce, GCM_NONCE_LEN,
                                   (const unsigned char *)topic, strlen(topic),
                                   ct_tag + ct_len, GCM_TAG_LEN,
                                   ct_tag,
                                   pt);
    mbedtls_gcm_free(&gcm);
    if (ret != 0) { free(pt); return NULL; }

    pt[ct_len] = '\0';
    return (char *)pt;
}

// ── short-code pairing ──────────────────────────────────────────────────────
void sh_crypto_code_key(const char *code, const uint8_t *nonce, size_t nonce_len,
                        uint8_t key_out[32]) {
    hkdf_sha256((const uint8_t *)code, strlen(code),
                (const uint8_t *)"seahelm-paircode-v1", 19,
                nonce, nonce_len,
                key_out, 32);
}

char *sh_crypto_seal_with_key(const char *plaintext, const char *topic,
                              const uint8_t key[32]) {
    if (!plaintext || plaintext[0] == '\0') {
        char *empty = (char *)malloc(1);
        if (empty) empty[0] = '\0';
        return empty;
    }

    mbedtls_gcm_context gcm;
    mbedtls_gcm_init(&gcm);
    int ret = mbedtls_gcm_setkey(&gcm, MBEDTLS_CIPHER_ID_AES, key, 256);
    if (ret != 0) { mbedtls_gcm_free(&gcm); return NULL; }

    size_t pt_len = strlen(plaintext);
    uint8_t *ct = (uint8_t *)malloc(pt_len + 16);
    if (!ct) { mbedtls_gcm_free(&gcm); return NULL; }

    uint8_t nonce[GCM_NONCE_LEN];
    sh_crypto_random_nonce(nonce, GCM_NONCE_LEN);
    size_t tag_len = GCM_TAG_LEN;

    ret = mbedtls_gcm_crypt_and_tag(&gcm, MBEDTLS_GCM_ENCRYPT,
                                    pt_len, nonce, GCM_NONCE_LEN,
                                    (const unsigned char *)topic, strlen(topic),
                                    (const unsigned char *)plaintext,
                                    ct, tag_len, ct + pt_len);
    mbedtls_gcm_free(&gcm);
    if (ret != 0) { free(ct); return NULL; }

    size_t env_len = 1 + GCM_NONCE_LEN + pt_len + tag_len;
    uint8_t *env = (uint8_t *)malloc(env_len);
    if (!env) { free(ct); return NULL; }
    env[0] = ENVELOPE_VERSION;
    memcpy(env + 1, nonce, GCM_NONCE_LEN);
    memcpy(env + 1 + GCM_NONCE_LEN, ct, pt_len + tag_len);
    free(ct);
    char *b64 = sh_crypto_b64_encode(env, env_len);
    free(env);
    return b64;
}

char *sh_crypto_open_with_key(const char *payload_b64, const char *topic,
                              const uint8_t key[32]) {
    if (!payload_b64 || payload_b64[0] == '\0') {
        char *empty = (char *)malloc(1);
        if (empty) empty[0] = '\0';
        return empty;
    }

    size_t env_len = 0;
    uint8_t env[2048];
    int ret = mbedtls_base64_decode(env, sizeof(env), &env_len,
                                    (const unsigned char *)payload_b64, strlen(payload_b64));
    if (ret != 0) return NULL;
    if (env_len < 1 + GCM_NONCE_LEN + 1 || env[0] != ENVELOPE_VERSION) return NULL;

    const uint8_t *nonce = env + 1;
    const uint8_t *ct_tag = env + 1 + GCM_NONCE_LEN;
    size_t ct_tag_len = env_len - 1 - GCM_NONCE_LEN;
    if (ct_tag_len <= GCM_TAG_LEN) return NULL;
    size_t ct_len = ct_tag_len - GCM_TAG_LEN;

    mbedtls_gcm_context gcm;
    mbedtls_gcm_init(&gcm);
    ret = mbedtls_gcm_setkey(&gcm, MBEDTLS_CIPHER_ID_AES, key, 256);
    if (ret != 0) { mbedtls_gcm_free(&gcm); return NULL; }

    uint8_t *pt = (uint8_t *)malloc(ct_len + 1);
    if (!pt) { mbedtls_gcm_free(&gcm); return NULL; }
    ret = mbedtls_gcm_auth_decrypt(&gcm, ct_len,
                                   nonce, GCM_NONCE_LEN,
                                   (const unsigned char *)topic, strlen(topic),
                                   ct_tag + ct_len, GCM_TAG_LEN,
                                   ct_tag, pt);
    mbedtls_gcm_free(&gcm);
    if (ret != 0) { free(pt); return NULL; }
    pt[ct_len] = '\0';
    return (char *)pt;
}

void sh_crypto_free(char *s) { free(s); }

void sh_crypto_random_nonce(uint8_t *out, size_t len) {
    // Use ESP-IDF's hardware RNG
    esp_fill_random(out, len);
}
