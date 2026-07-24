// sh_config.c — NVS config persistence + pairing URI parser.
#include "sh_config.h"
#include "sh_crypto.h"
#include <string.h>
#include <stdio.h>
#include <stdlib.h>
#include "nvs.h"
#include "nvs_flash.h"
#include "esp_log.h"
#include "esp_mac.h"

static const char *TAG = "sh_config";
static const char *NVS_NS = "seahelm";
static const char *KEY_CFG = "config";

// Forward declaration: crypto HKDF derivation used by sh_config_derive_creds.
// Implemented in sh_crypto.c.
int sh_crypto_derive_credentials(const uint8_t *root_secret, size_t root_len,
                                 char *password_hex, size_t pass_sz,
                                 uint8_t *enc_key, size_t enc_sz);

const sh_config_t SH_CONFIG_DEFAULT = {
    .host        = "a81fb6d3.ala.cn-hangzhou.emqxsl.cn",
    .port        = 8883,
    .tls         = true,
    .mac_id      = "live",
    .username    = "seahelm",   // fixed broker auth (decoupled from mac_id/E2EE)
    .password    = "seahelm",
    .root_secret = "",
    .capability  = SH_CAP_CONTROL,
};

// ── client id (stable per device) ───────────────────────────────────────────
static char s_client_id[32] = "";

const char *sh_config_client_id(void) {
    if (s_client_id[0] == '\0') {
        uint8_t mac[6];
        esp_efuse_mac_get_default(mac);
        snprintf(s_client_id, sizeof(s_client_id), "seahelm-esp32-%02x%02x%02x%02x%02x%02x",
                 mac[0], mac[1], mac[2], mac[3], mac[4], mac[5]);
    }
    return s_client_id;
}

// ── NVS helpers ─────────────────────────────────────────────────────────────
int sh_config_load(sh_config_t *cfg) {
    nvs_handle_t h;
    esp_err_t err = nvs_open(NVS_NS, NVS_READONLY, &h);
    if (err != ESP_OK) return -1;

    size_t sz = sizeof(*cfg);
    err = nvs_get_blob(h, KEY_CFG, cfg, &sz);
    nvs_close(h);
    if (err != ESP_OK) return -1;
    return 0;
}

int sh_config_save(const sh_config_t *cfg) {
    nvs_handle_t h;
    esp_err_t err = nvs_open(NVS_NS, NVS_READWRITE, &h);
    if (err != ESP_OK) return -1;
    err = nvs_set_blob(h, KEY_CFG, cfg, sizeof(*cfg));
    if (err == ESP_OK) err = nvs_commit(h);
    nvs_close(h);
    return (err == ESP_OK) ? 0 : -1;
}

void sh_config_erase(void) {
    nvs_handle_t h;
    if (nvs_open(NVS_NS, NVS_READWRITE, &h) == ESP_OK) {
        nvs_erase_all(h);
        nvs_commit(h);
        nvs_close(h);
    }
}

// ── pairing URI parser ──────────────────────────────────────────────────────
bool sh_config_from_pair_uri(const char *uri, sh_config_t *cfg) {
    // Expected: seahelm://pair?b=<broker_url>&m=<mac_id>&k=<base64url_root_secret>
    if (!uri || !cfg) return false;

    const char *q = strstr(uri, "seahelm://pair?");
    if (!q) return false;
    q += 15;  // skip "seahelm://pair?"

    char broker[256] = "", mac[32] = "", key[128] = "";

    // Simple query string parser (no URL decoding needed; b/m/k values are URL-safe)
    while (*q) {
        const char *amp = strchr(q, '&');
        size_t kv_len = amp ? (size_t)(amp - q) : strlen(q);

        const char *eq = (const char *)memchr(q, '=', kv_len);
        if (eq) {
            size_t klen = (size_t)(eq - q);
            size_t vlen = kv_len - klen - 1;
            const char *val = eq + 1;
            if (klen == 1 && q[0] == 'b' && vlen < sizeof(broker)) {
                memcpy(broker, val, vlen); broker[vlen] = '\0';
            } else if (klen == 1 && q[0] == 'm' && vlen < sizeof(mac)) {
                memcpy(mac, val, vlen); mac[vlen] = '\0';
            } else if (klen == 1 && q[0] == 'k' && vlen < sizeof(key)) {
                memcpy(key, val, vlen); key[vlen] = '\0';
            }
        }
        if (!amp) break;
        q = amp + 1;
    }

    if (!broker[0] || !mac[0] || !key[0]) {
        ESP_LOGE(TAG, "pair URI missing b/m/k");
        return false;
    }

    // Parse broker URL: wss://host:port/path or mqtts://host:port
    // Extract host, port, tls.
    bool tls = false;
    char host[64] = "";
    uint16_t port = 8883;
    if (strstr(broker, "wss://") == broker) {
        tls = true;
        // wss://host:port/path → host, port
        const char *rest = broker + 6;
        (void)sscanf(rest, "%63[^:]:%hu", host, &port);
    } else if (strstr(broker, "ws://") == broker) {
        tls = false;
        const char *rest = broker + 5;
        (void)sscanf(rest, "%63[^:]:%hu", host, &port);
    } else if (strstr(broker, "mqtts://") == broker) {
        tls = true;
        const char *rest = broker + 8;
        (void)sscanf(rest, "%63[^:]:%hu", host, &port);
    } else if (strstr(broker, "mqtt://") == broker) {
        tls = false;
        const char *rest = broker + 7;
        (void)sscanf(rest, "%63[^:]:%hu", host, &port);
    } else {
        // Plain host:port
        (void)sscanf(broker, "%63[^:]:%hu", host, &port);
        tls = false;
    }

    if (!host[0]) {
        ESP_LOGE(TAG, "could not parse broker host from '%s'", broker);
        return false;
    }

    // Fill config
    memset(cfg, 0, sizeof(*cfg));
    strncpy(cfg->host, host, sizeof(cfg->host) - 1);
    cfg->port = port;
    cfg->tls  = tls;
    strncpy(cfg->mac_id, mac, sizeof(cfg->mac_id) - 1);
    strncpy(cfg->root_secret, key, sizeof(cfg->root_secret) - 1);
    strncpy(cfg->username, mac, sizeof(cfg->username) - 1);  // username = mac_id when paired
    cfg->capability = SH_CAP_CONTROL;
    return true;
}

// ── derive broker credentials from root_secret ──────────────────────────────
int sh_config_derive_creds(sh_config_t *cfg) {
    if (!sh_config_is_paired(cfg)) return -1;

    // Decode base64url root_secret → raw 32 bytes
    // (We store the base64url string; decode it for HKDF)
    size_t root_len = 0;
    uint8_t root_raw[32];

    // Simple base64url decode
    const char *s = cfg->root_secret;
    // Count padding and characters
    int pad = 0;
    size_t slen = strlen(s);
    // base64url: chars A-Z a-z 0-9 - _
    // Estimate decoded len = slen * 3 / 4, max 32
    uint8_t d[64];
    // Use mbedTLS base64 decode
    // Actually, let's just use the crypto module's own base64url decode.
    // For simplicity, we'll call into sh_crypto_base64url_decode.
    // But sh_crypto isn't necessarily included yet. Let's include it properly.

    // We'll do inline base64url decode here.
    static const unsigned char b64dec[256] = {
        0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,
        0,0,0,0,0,0,0,0,0,0,0,62,0,0,0,63, 52,53,54,55,56,57,58,59,60,61,0,0,0,0,0,0,
        0,0,1,2,3,4,5,6,7,8,9,10,11,12,13,14, 15,16,17,18,19,20,21,22,23,24,25,0,0,0,0,0,
        0,26,27,28,29,30,31,32,33,34,35,36,37,38,39,40, 41,42,43,44,45,46,47,48,49,50,51,0,0,0,0,0,
    };

    size_t i, j = 0;
    uint8_t buf[4];
    int buf_i = 0;
    for (i = 0; i < slen; i++) {
        unsigned char c = (unsigned char)s[i];
        if (c == '=') { pad++; continue; }
        unsigned char v = b64dec[c];
        if (v == 0 && c != 'A') continue;  // skip whitespace/invalid
        buf[buf_i++] = v;
        if (buf_i == 4) {
            d[j++] = (buf[0] << 2) | (buf[1] >> 4);
            d[j++] = (buf[1] << 4) | (buf[2] >> 2);
            d[j++] = (buf[2] << 6) | buf[3];
            buf_i = 0;
        }
    }
    if (buf_i >= 2) d[j++] = (buf[0] << 2) | (buf[1] >> 4);
    if (buf_i >= 3) d[j++] = (buf[1] << 4) | (buf[2] >> 2);
    // j = decoded length, should be 32

    root_len = j;
    memcpy(root_raw, d, (root_len < 32 ? root_len : 32));

    if (root_len < 16) {
        ESP_LOGE(TAG, "root_secret too short (%zu)", root_len);
        return -1;
    }

    // Derive: HKDF → auth (password hex) + enc_key (AES-256-GCM key).
    // Broker auth is now fixed (seahelm/seahelm) so we DON'T overwrite
    // cfg->password — the derived auth hex goes to a throwaway buffer; only the
    // E2EE enc_key is kept (by sh_crypto).
    uint8_t enc_key[32];
    char    auth_hex[128];
    int ret = sh_crypto_derive_credentials(root_raw, root_len,
                                           auth_hex, sizeof(auth_hex),
                                           enc_key, sizeof(enc_key));
    if (ret != 0) {
        ESP_LOGE(TAG, "credential derivation failed");
        return -1;
    }

    // enc_key is only needed in-memory by sh_crypto; we don't store it in NVS.
    // The crypto module keeps its own copy.
    return 0;
}

// ── topic base ──────────────────────────────────────────────────────────────
int sh_config_base(const sh_config_t *cfg, char *out, size_t out_sz) {
    return snprintf(out, out_sz, "seahelm/%s", cfg->mac_id);
}
