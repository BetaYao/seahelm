// sh_mqtt.c — MQTT client implementation using ESP-IDF esp-mqtt.
#include "sh_mqtt.h"
#include "sh_crypto.h"
#include "sh_data.h"
#include <string.h>
#include <stdio.h>
#include <stdlib.h>
#include "esp_log.h"
#include "mqtt_client.h"
#include "esp_crt_bundle.h"   // esp_crt_bundle_attach (built-in CA bundle)
#include "cJSON.h"
#include "mbedtls/base64.h"

static const char *TAG = "sh_mqtt";

// ── internal state ──────────────────────────────────────────────────────────
static struct {
    const sh_config_t       *cfg;
    sh_mqtt_callbacks_t      cbs;
    esp_mqtt_client_handle_t client;
    sh_mqtt_state_t          state;
    char                     base[64];     // seahelm/{mac_id}
    char                     reply_base[80]; // seahelm/{mac_id}/reply/{client_id}
    int                      corr_n;
    bool                      has_pending_pair;
    char                     pair_nonce_b64[32];  // base64url of pair nonce
    uint8_t                  pair_nonce[16];
} s_mqtt;

// ── helpers ─────────────────────────────────────────────────────────────────
static void set_state(sh_mqtt_state_t st) {
    s_mqtt.state = st;
    if (s_mqtt.cbs.on_state) s_mqtt.cbs.on_state(st);
}

// Generate reply_to and corr for a command
static void next_corr(char *corr, size_t sz) {
    s_mqtt.corr_n++;
    snprintf(corr, sz, "c%d", s_mqtt.corr_n);
}

// ── topic route ──────────────────────────────────────────────────────────────
// Called after E2EE decryption. Routes a message to the appropriate callback.
static void route_message(const char *topic, const char *payload) {
    // Topic format: seahelm/{mac_id}/{segments...}
    const char *base = s_mqtt.base;
    size_t base_len = strlen(base);
    if (strncmp(topic, base, base_len) != 0 || topic[base_len] != '/') return;
    const char *seg = topic + base_len + 1;  // skip "seahelm/{mac_id}/"

    // Split into segments
    char seg_copy[256];
    strncpy(seg_copy, seg, sizeof(seg_copy) - 1);
    seg_copy[sizeof(seg_copy) - 1] = '\0';

    char *parts[8];
    int nparts = 0;
    char *tok = strtok(seg_copy, "/");
    while (tok && nparts < 8) {
        parts[nparts++] = tok;
        tok = strtok(NULL, "/");
    }

    if (nparts < 1) return;

    // Presence
    if (nparts == 1 && strcmp(parts[0], "presence") == 0) {
        cJSON *j = cJSON_Parse(payload);
        bool online = false;
        if (j) {
            cJSON *o = cJSON_GetObjectItem(j, "online");
            if (cJSON_IsBool(o)) online = cJSON_IsTrue(o);
            cJSON_Delete(j);
        }
        if (s_mqtt.cbs.on_presence) s_mqtt.cbs.on_presence(online);
        return;
    }

    // Focus
    if (nparts == 1 && strcmp(parts[0], "focus") == 0) {
        if (s_mqtt.cbs.on_focus) s_mqtt.cbs.on_focus(payload);
        return;
    }

    // DND state
    if (nparts == 1 && strcmp(parts[0], "dnd") == 0) {
        if (s_mqtt.cbs.on_dnd) s_mqtt.cbs.on_dnd(payload);
        return;
    }

    // pane/{slot}/status, pane/{slot}/event, pane/{slot}/message
    if (nparts >= 3 && strcmp(parts[0], "pane") == 0) {
        const char *slot = parts[1];  // pane_session_key
        if (strcmp(parts[2], "status") == 0) {
            // If payload is empty (retained tombstone), pass NULL
            const char *p = (payload && payload[0]) ? payload : NULL;
            if (s_mqtt.cbs.on_pane_status) s_mqtt.cbs.on_pane_status(slot, p);
        } else if (strcmp(parts[2], "event") == 0) {
            const char *p = (payload && payload[0]) ? payload : NULL;
            if (s_mqtt.cbs.on_pane_event) s_mqtt.cbs.on_pane_event(slot, p);
        }
        return;
    }

    // worktree/{id}/status
    if (nparts >= 3 && strcmp(parts[0], "worktree") == 0 && strcmp(parts[2], "status") == 0) {
        const char *p = (payload && payload[0]) ? payload : NULL;
        if (s_mqtt.cbs.on_worktree) s_mqtt.cbs.on_worktree(parts[1], p);
        return;
    }

    // pair/grant/{nonce} — short-code pairing handshake
    if (nparts >= 3 && strcmp(parts[0], "pair") == 0 && strcmp(parts[1], "grant") == 0 && nparts >= 3) {
        if (s_mqtt.has_pending_pair && strcmp(parts[2], s_mqtt.pair_nonce_b64) == 0) {
            // Decrypt with code-derived key
            // The grant comes back as an E2EE envelope sealed with the code key
            // We handle this before normal crypto in the MQTT event handler
            if (s_mqtt.cbs.on_pair_grant) s_mqtt.cbs.on_pair_grant(payload);
            s_mqtt.has_pending_pair = false;
        }
        return;
    }

    // reply/{client_id}/{corr} — handled via generic mechanism
    ESP_LOGD(TAG, "unrouted topic: %s", topic);
}

// ── MQTT event handler ──────────────────────────────────────────────────────
static void mqtt_event_handler(void *handler_args, esp_event_base_t base,
                               int32_t event_id, void *event_data) {
    esp_mqtt_event_handle_t event = (esp_mqtt_event_handle_t)event_data;

    switch (event->event_id) {
    case MQTT_EVENT_CONNECTED: {
        ESP_LOGI(TAG, "MQTT connected to %s:%d", s_mqtt.cfg->host, s_mqtt.cfg->port);
        set_state(SH_MQTT_CONNECTED);
        // Subscribe to all topics under our namespace
        char sub[128];
        snprintf(sub, sizeof(sub), "%s/#", s_mqtt.base);
        esp_mqtt_client_subscribe(s_mqtt.client, sub, 1);
        ESP_LOGI(TAG, "subscribed to %s (crypto_active=%d)", sub, sh_crypto_active());
        break;
    }
    case MQTT_EVENT_DISCONNECTED: {
        ESP_LOGI(TAG, "MQTT disconnected");
        set_state(SH_MQTT_DISCONNECTED);
        break;
    }
    case MQTT_EVENT_BEFORE_CONNECT:
        set_state(SH_MQTT_CONNECTING);
        break;
    case MQTT_EVENT_DATA: {
        // Build topic string
        char topic[256];
        size_t tlen = event->topic_len < sizeof(topic) - 1 ? event->topic_len : sizeof(topic) - 1;
        strncpy(topic, event->topic, tlen);
        topic[tlen] = '\0';

        // Build payload string
        char payload[2048];
        size_t plen = event->data_len < sizeof(payload) - 1 ? event->data_len : sizeof(payload) - 1;
        strncpy(payload, event->data, plen);
        payload[plen] = '\0';

        ESP_LOGD(TAG, "RX topic=%s len=%d", topic, event->data_len);

        // Short-code pairing grant: decrypt with code key (not E2EE key)
        if (s_mqtt.has_pending_pair) {
            char grant_topic[128];
            snprintf(grant_topic, sizeof(grant_topic), "%s/pair/grant/%s",
                     s_mqtt.base, s_mqtt.pair_nonce_b64);
            if (strcmp(topic, grant_topic) == 0 && payload[0]) {
                // We need the code key — but we don't store the code in s_mqtt.
                // The pair_with_code function stores the code temporarily.
                // For now, pass the raw payload and let the handler deal with it.
                if (s_mqtt.cbs.on_pair_grant) s_mqtt.cbs.on_pair_grant(payload);
                s_mqtt.has_pending_pair = false;
                return;
            }
        }

        // E2EE decrypt
        char *decrypted = NULL;
        if (sh_crypto_active() && payload[0]) {
            decrypted = sh_crypto_open(payload, topic);
            if (!decrypted) {
                ESP_LOGW(TAG, "decrypt failed for %s, dropping", topic);
                return;
            }
        }

        const char *msg = decrypted ? decrypted : payload;
        ESP_LOGI(TAG, "RX %s dec=%d m2=%d", topic, decrypted ? 1 : 0, sh_data_m2_active());
        route_message(topic, msg);

        if (decrypted) sh_crypto_free(decrypted);
        break;
    }
    case MQTT_EVENT_ERROR:
        ESP_LOGE(TAG, "MQTT error");
        break;
    case MQTT_EVENT_SUBSCRIBED:
        ESP_LOGD(TAG, "subscribed to topic");
        break;
    default:
        break;
    }
}

// ── public API ──────────────────────────────────────────────────────────────

void sh_mqtt_init(const sh_config_t *cfg, const sh_mqtt_callbacks_t *cbs) {
    memset(&s_mqtt, 0, sizeof(s_mqtt));
    s_mqtt.cfg = cfg;
    if (cbs) s_mqtt.cbs = *cbs;
    s_mqtt.state = SH_MQTT_DISCONNECTED;

    // Build base topic
    sh_config_base(cfg, s_mqtt.base, sizeof(s_mqtt.base));
    snprintf(s_mqtt.reply_base, sizeof(s_mqtt.reply_base),
             "%s/reply/%s", s_mqtt.base, sh_config_client_id());

    ESP_LOGI(TAG, "base=%s, client_id=%s", s_mqtt.base, sh_config_client_id());
}

void sh_mqtt_start(void) {
    if (s_mqtt.client) {
        esp_mqtt_client_destroy(s_mqtt.client);
        s_mqtt.client = NULL;
    }

    const sh_config_t *cfg = s_mqtt.cfg;

    // Build broker URI
    char uri[128];
    if (cfg->tls) {
        snprintf(uri, sizeof(uri), "mqtts://%s:%d", cfg->host, cfg->port);
    } else {
        snprintf(uri, sizeof(uri), "mqtt://%s:%d", cfg->host, cfg->port);
    }

    ESP_LOGI(TAG, "connecting to %s as %s", uri, cfg->username[0] ? cfg->username : "(anon)");

    esp_mqtt_client_config_t mqtt_cfg = {
        .broker.address.uri = uri,
        .credentials.client_id = sh_config_client_id(),
        .session.keepalive = 45,
        // NOTE: do NOT enlarge .buffer.size here — internal RAM is at its limit
        // (WiFi + LVGL + 8 KB TLS), and a bigger MQTT buffer starves the hardware
        // SHA alloc during the TLS handshake ("esp-sha: Failed to allocate buf").
        // Generous network timeouts are free (no extra RAM) and keep a slow link
        // from being misread as dead.
        .network.timeout_ms = 10000,
        .network.reconnect_timeout_ms = 4000,
    };

    // Set credentials if available
    if (cfg->username[0]) {
        mqtt_cfg.credentials.username = cfg->username;
        if (cfg->password[0]) {
            mqtt_cfg.credentials.authentication.password = cfg->password;
        }
    }

    // Set LWT (presence offline on disconnect)
    char lwt_topic[80];
    snprintf(lwt_topic, sizeof(lwt_topic), "%s/presence", s_mqtt.base);
    mqtt_cfg.session.last_will.topic = lwt_topic;
    mqtt_cfg.session.last_will.msg = "{\"online\":false}";
    mqtt_cfg.session.last_will.msg_len = strlen(mqtt_cfg.session.last_will.msg);
    mqtt_cfg.session.last_will.qos = 1;
    mqtt_cfg.session.last_will.retain = true;

    // TLS config: verify EMQX's server cert against ESP-IDF's built-in CA bundle
    // (CONFIG_MBEDTLS_CERTIFICATE_BUNDLE, which includes DigiCert Global Root G2 —
    // EMQX Serverless's CA). Without a CA source esp-tls can't verify the server
    // and the handshake fails with "Error transport connect".
    if (cfg->tls) {
        mqtt_cfg.broker.verification.crt_bundle_attach = esp_crt_bundle_attach;
    }

    s_mqtt.client = esp_mqtt_client_init(&mqtt_cfg);
    if (!s_mqtt.client) {
        ESP_LOGE(TAG, "MQTT client init failed");
        return;
    }

    esp_mqtt_client_register_event(s_mqtt.client, ESP_EVENT_ANY_ID, mqtt_event_handler, NULL);
    esp_mqtt_client_start(s_mqtt.client);
    set_state(SH_MQTT_CONNECTING);
}

void sh_mqtt_stop(void) {
    if (s_mqtt.client) {
        esp_mqtt_client_stop(s_mqtt.client);
        esp_mqtt_client_destroy(s_mqtt.client);
        s_mqtt.client = NULL;
    }
    set_state(SH_MQTT_DISCONNECTED);
}

sh_mqtt_state_t sh_mqtt_state(void) { return s_mqtt.state; }

void sh_mqtt_publish_json(const char *topic, const char *json_str) {
    if (!s_mqtt.client || !json_str) return;

    // E2EE seal when active
    if (sh_crypto_active()) {
        char *sealed = sh_crypto_seal(json_str, topic);
        if (sealed) {
            esp_mqtt_client_publish(s_mqtt.client, topic, sealed, 0, 1, 0);
            sh_crypto_free(sealed);
        }
    } else {
        esp_mqtt_client_publish(s_mqtt.client, topic, json_str, 0, 1, 0);
    }
}

void sh_mqtt_subscribe(const char *topic_filter) {
    if (s_mqtt.client) {
        esp_mqtt_client_subscribe(s_mqtt.client, topic_filter, 1);
    }
}

void sh_mqtt_command(const char *method, const char *params_json) {
    char corr[16];
    next_corr(corr, sizeof(corr));

    char reply_to[128];
    snprintf(reply_to, sizeof(reply_to), "%s/%s", s_mqtt.reply_base, corr);

    // Build JSON payload
    cJSON *root = cJSON_CreateObject();
    cJSON_AddStringToObject(root, "method", method);
    cJSON_AddStringToObject(root, "reply_to", reply_to);
    cJSON_AddStringToObject(root, "corr", corr);

    // Parse and merge params
    if (params_json && params_json[0]) {
        cJSON *params = cJSON_Parse(params_json);
        if (params) {
            cJSON_AddItemToObject(root, "params", params);
        } else {
            cJSON_AddStringToObject(root, "params", params_json);
        }
    }

    char *json_str = cJSON_PrintUnformatted(root);
    if (json_str) {
        char topic[128];
        snprintf(topic, sizeof(topic), "%s/command", s_mqtt.base);

        // Subscribe to reply topic first
        esp_mqtt_client_subscribe(s_mqtt.client, reply_to, 1);

        // Publish
        if (sh_crypto_active()) {
            char *sealed = sh_crypto_seal(json_str, topic);
            if (sealed) {
                esp_mqtt_client_publish(s_mqtt.client, topic, sealed, 0, 1, 0);
                sh_crypto_free(sealed);
            }
        } else {
            esp_mqtt_client_publish(s_mqtt.client, topic, json_str, 0, 1, 0);
        }

        free(json_str);
    }
    cJSON_Delete(root);
}

void sh_mqtt_history(const char *pane_session_key, int limit) {
    char corr[16];
    next_corr(corr, sizeof(corr));

    char reply_to[128];
    snprintf(reply_to, sizeof(reply_to), "%s/%s", s_mqtt.reply_base, corr);

    cJSON *root = cJSON_CreateObject();
    cJSON_AddStringToObject(root, "pane_session_key", pane_session_key);
    cJSON_AddNumberToObject(root, "limit", limit);
    cJSON_AddStringToObject(root, "reply_to", reply_to);
    cJSON_AddStringToObject(root, "corr", corr);

    char *json_str = cJSON_PrintUnformatted(root);
    if (json_str) {
        char topic[128];
        snprintf(topic, sizeof(topic), "%s/history/request", s_mqtt.base);
        esp_mqtt_client_subscribe(s_mqtt.client, reply_to, 1);

        if (sh_crypto_active()) {
            char *sealed = sh_crypto_seal(json_str, topic);
            if (sealed) {
                esp_mqtt_client_publish(s_mqtt.client, topic, sealed, 0, 1, 0);
                sh_crypto_free(sealed);
            }
        } else {
            esp_mqtt_client_publish(s_mqtt.client, topic, json_str, 0, 1, 0);
        }
        free(json_str);
    }
    cJSON_Delete(root);
}

void sh_mqtt_pair_with_code(const char *code) {
    // Generate nonce
    sh_crypto_random_nonce(s_mqtt.pair_nonce, sizeof(s_mqtt.pair_nonce));

    // Base64url encode nonce
    size_t olen = 0;
    mbedtls_base64_encode(NULL, 0, &olen, s_mqtt.pair_nonce, sizeof(s_mqtt.pair_nonce));
    if (olen >= sizeof(s_mqtt.pair_nonce_b64)) return;
    mbedtls_base64_encode((unsigned char *)s_mqtt.pair_nonce_b64, olen, &olen,
                          s_mqtt.pair_nonce, sizeof(s_mqtt.pair_nonce));
    s_mqtt.pair_nonce_b64[olen] = '\0';
    // Convert to base64url
    for (char *p = s_mqtt.pair_nonce_b64; *p; p++) {
        if (*p == '+') *p = '-';
        else if (*p == '/') *p = '_';
        else if (*p == '=') { *p = '\0'; break; }
    }

    // Subscribe to grant topic
    char grant_topic[128];
    snprintf(grant_topic, sizeof(grant_topic), "%s/pair/grant/%s",
             s_mqtt.base, s_mqtt.pair_nonce_b64);
    esp_mqtt_client_subscribe(s_mqtt.client, grant_topic, 1);

    // Publish claim
    cJSON *claim = cJSON_CreateObject();
    cJSON_AddStringToObject(claim, "code", code);
    // nonce in standard base64 for the claim
    size_t b64len = 0;
    uint8_t b64buf[32];
    mbedtls_base64_encode(b64buf, sizeof(b64buf), &b64len,
                          s_mqtt.pair_nonce, sizeof(s_mqtt.pair_nonce));
    b64buf[b64len] = '\0';
    cJSON_AddStringToObject(claim, "nonce", (const char *)b64buf);

    char *json_str = cJSON_PrintUnformatted(claim);
    if (json_str) {
        char claim_topic[128];
        snprintf(claim_topic, sizeof(claim_topic), "%s/pair/claim", s_mqtt.base);
        // Claim is sent in plaintext (code + nonce are the only auth)
        esp_mqtt_client_publish(s_mqtt.client, claim_topic, json_str, 0, 1, 0);
        free(json_str);
    }
    cJSON_Delete(claim);

    s_mqtt.has_pending_pair = true;

    // Timeout after 10 seconds
    // (In production, set up a timer; for now rely on the callback being called with NULL)
}
