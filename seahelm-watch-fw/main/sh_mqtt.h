// sh_mqtt.h — MQTT client for seahelm-watch-fw.
// Uses ESP-IDF's esp-mqtt component. Routes retained snapshots and live events
// into the sh_data slot model, and provides outbound command/history/pair.
#pragma once
#include <stdbool.h>
#include <stdint.h>
#include "sh_config.h"

#ifdef __cplusplus
extern "C" {
#endif

// Connection state
typedef enum {
    SH_MQTT_DISCONNECTED,
    SH_MQTT_CONNECTING,
    SH_MQTT_CONNECTED,
} sh_mqtt_state_t;

// Callback types (set by main, called from MQTT task context)
typedef void (*sh_mqtt_on_state_t)(sh_mqtt_state_t state);

// Pane status received from retained snapshot or live update
// payload is the JSON string (already E2EE-decrypted if applicable).
// NULL payload = tombstone (pane closed).
typedef void (*sh_mqtt_on_pane_status_t)(const char *slot, const char *payload_json);
typedef void (*sh_mqtt_on_pane_event_t)(const char *slot, const char *payload_json);
typedef void (*sh_mqtt_on_worktree_t)(const char *slot, const char *payload_json);
typedef void (*sh_mqtt_on_focus_t)(const char *payload_json);
typedef void (*sh_mqtt_on_presence_t)(bool online);
typedef void (*sh_mqtt_on_dnd_t)(const char *payload_json);

// Short-code pairing handshake callbacks
typedef void (*sh_mqtt_on_pair_grant_t)(const char *root_secret_b64url);  // NULL on timeout/failure

typedef struct {
    sh_mqtt_on_state_t       on_state;
    sh_mqtt_on_pane_status_t on_pane_status;
    sh_mqtt_on_pane_event_t  on_pane_event;
    sh_mqtt_on_worktree_t    on_worktree;
    sh_mqtt_on_focus_t       on_focus;
    sh_mqtt_on_presence_t    on_presence;
    sh_mqtt_on_dnd_t         on_dnd;
    sh_mqtt_on_pair_grant_t  on_pair_grant;
} sh_mqtt_callbacks_t;

// ── lifecycle ───────────────────────────────────────────────────────────────

// Initialize and configure MQTT client. Does NOT connect yet.
// The config pointer must remain valid for the client's lifetime (or until
// sh_mqtt_stop is called).
void sh_mqtt_init(const sh_config_t *cfg, const sh_mqtt_callbacks_t *cbs);

// Start the MQTT connection (async). Call sh_mqtt_init first.
void sh_mqtt_start(void);

// Disconnect and free resources.
void sh_mqtt_stop(void);

// Current connection state.
sh_mqtt_state_t sh_mqtt_state(void);

// ── outbound ────────────────────────────────────────────────────────────────

// Publish a command (pane.send_text, question.answer, etc.)
// method: e.g. "pane.send_text"
// params_json: e.g. {"pane_session_key":"p1","text":"hello","enter":true}
void sh_mqtt_command(const char *method, const char *params_json);

// Request history for a pane.
void sh_mqtt_history(const char *pane_session_key, int limit);

// Short-code pairing: claim with code, await grant.
void sh_mqtt_pair_with_code(const char *code);

// Publish a generic JSON payload to a topic (used internally by pair/claim).
void sh_mqtt_publish_json(const char *topic, const char *json_str);

// Subscribe to a specific topic.
void sh_mqtt_subscribe(const char *topic_filter);

#ifdef __cplusplus
}
#endif
