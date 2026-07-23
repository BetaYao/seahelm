// sh_config.h — NVS-persisted broker config + pairing state.
#pragma once
#include <stdbool.h>
#include <stdint.h>
#include <stddef.h>   // size_t

#ifdef __cplusplus
extern "C" {
#endif

// Capability tier (matches the design's gating; ACL is the real enforcement).
typedef enum {
    SH_CAP_READ         = 0,
    SH_CAP_INTERACTIVE  = 1,
    SH_CAP_CONTROL      = 2,
} sh_capability_t;

typedef struct {
    // EMQX Cloud (public). Local dev: host "localhost", port 1883, tls false.
    char    host[64];
    uint16_t port;
    bool    tls;                // true = mqtts://, false = mqtt://
    char    mac_id[32];         // topic namespace: seahelm/{mac_id}/...
    char    username[32];       // broker username (mac_id when paired)
    char    password[128];      // broker password (HKDF-derived hex when paired)
    char    root_secret[128];   // base64url, from seahelm://pair link. "" = unpaired.
    sh_capability_t capability;
} sh_config_t;

// Default config (EMQX Cloud, unpaired).
extern const sh_config_t SH_CONFIG_DEFAULT;

// Load from NVS. Returns the number of configs loaded (0 if not found).
int sh_config_load(sh_config_t *cfg);

// Save to NVS.
int sh_config_save(const sh_config_t *cfg);

// Erase all config from NVS.
void sh_config_erase(void);

// Parse a "seahelm://pair?b=...&m=...&k=..." link into a config (broker
// address parsed from URL, mac_id and root_secret filled). Returns true on
// success. The caller should then derive broker credentials and save.
bool sh_config_from_pair_uri(const char *uri, sh_config_t *cfg);

// Derive broker password + E2EE key from root_secret, storing password in cfg.
// Returns 0 on success.
int sh_config_derive_creds(sh_config_t *cfg);

// Topic namespace root, e.g. "seahelm/live"
int sh_config_base(const sh_config_t *cfg, char *out, size_t out_sz);

// Stable client id: "seahelm-esp32-<chip-mac-hex>"
const char *sh_config_client_id(void);

// Is the config paired (has a root_secret)?
static inline bool sh_config_is_paired(const sh_config_t *cfg) {
    return cfg->root_secret[0] != '\0';
}

#ifdef __cplusplus
}
#endif
