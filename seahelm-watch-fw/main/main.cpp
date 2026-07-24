// main.cpp — M5Unified (CO5300 AMOLED + CST820 touch + keys) ↔ LVGL 9 glue.
// M2: MQTT + E2EE integrated. Connects to EMQX Cloud (or dev broker), decodes
// retained snapshots and live events into the sh_data slot store, and surfaces
// decisions (question/suggest) via sh_ui_overlay.
#include <M5Unified.h>
#include "lvgl.h"
#include "esp_timer.h"
#include "esp_heap_caps.h"
#include "esp_log.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "nvs_flash.h"
#include "cJSON.h"

extern "C" {
#include "sh_ui.h"
#include "sh_data.h"
#include "sh_config.h"
#include "sh_crypto.h"
#include "sh_mqtt.h"
#include "sh_wifi.h"
#include "sh_secrets.h"
}

static const char *TAG = "seahelm-watch";

// ── LVGL display flush via LovyanGFX ──────────────────────────────────────────
static void flush_cb(lv_display_t *disp, const lv_area_t *area, uint8_t *px_map) {
    int32_t w = area->x2 - area->x1 + 1;
    int32_t h = area->y2 - area->y1 + 1;
    M5.Display.startWrite();
    M5.Display.setAddrWindow(area->x1, area->y1, w, h);
    M5.Display.writePixels(reinterpret_cast<uint16_t *>(px_map), w * h, true /*swap*/);
    M5.Display.endWrite();
    lv_display_flush_ready(disp);
}

// ── touch (CST820) → LVGL pointer ─────────────────────────────────────────────
static void touch_cb(lv_indev_t *indev, lv_indev_data_t *data) {
    auto t = M5.Touch.getDetail();
    if (t.isPressed()) {
        data->point.x = t.x;
        data->point.y = t.y;
        data->state = LV_INDEV_STATE_PRESSED;
    } else {
        data->state = LV_INDEV_STATE_RELEASED;
    }
}

// ── LVGL tick from esp_timer ──────────────────────────────────────────────────
static uint32_t tick_cb(void) { return (uint32_t)(esp_timer_get_time() / 1000ULL); }

// ── back-gesture on the active screen ─────────────────────────────────────────
static void gesture_cb(lv_event_t *e) {
    lv_dir_t d = lv_indev_get_gesture_dir(lv_indev_active());
    if (d == LV_DIR_RIGHT) sh_ui_back();
}

// ── MQTT callbacks ────────────────────────────────────────────────────────────
// These are called from MQTT task context. We queue state changes and trigger
// LVGL refresh via a timer (since LVGL is not thread-safe).

static void on_mqtt_state(sh_mqtt_state_t state) {
    ESP_LOGI(TAG, "MQTT state: %d", state);
    sh_ui_refresh();   // update the connection-status screen (WiFi→MQTT→data)
}

static void on_pane_status(const char *slot, const char *payload_json) {
    ESP_LOGD(TAG, "pane/status %s: %s", slot, payload_json ? payload_json : "(tombstone)");
    sh_data_m2_update_pane(slot, payload_json);
    sh_ui_refresh();
}

static void on_pane_event(const char *slot, const char *payload_json) {
    ESP_LOGD(TAG, "pane/event %s: %s", slot, payload_json ? payload_json : "(resolved)");
    sh_data_m2_update_event(slot, payload_json);

    // If a new question/suggest arrived, push an overlay
    if (payload_json && payload_json[0]) {
        cJSON *j = cJSON_Parse(payload_json);
        if (j) {
            cJSON *type_f = cJSON_GetObjectItem(j, "type");
            if (type_f && cJSON_IsString(type_f)) {
                const char *type = type_f->valuestring;
                if (strcmp(type, "question") == 0) {
                    cJSON *pr = cJSON_GetObjectItem(j, "prompt");
                    cJSON *opts = cJSON_GetObjectItem(j, "options");
                    const char *prompt = pr && cJSON_IsString(pr) ? pr->valuestring : "";
                    int nopts = opts && cJSON_IsArray(opts) ? cJSON_GetArraySize(opts) : 0;
                    const char *opt_ptrs[6];
                    char opt_buf[6][64];
                    if (nopts > 6) nopts = 6;
                    for (int i = 0; i < nopts; i++) {
                        cJSON *o = cJSON_GetArrayItem(opts, i);
                        if (o && cJSON_IsString(o)) {
                            strncpy(opt_buf[i], o->valuestring, sizeof(opt_buf[i]) - 1);
                            opt_ptrs[i] = opt_buf[i];
                        }
                    }
                    sh_ui_overlay(SH_OV_QUESTION, slot, "", prompt, nopts > 0 ? opt_ptrs : NULL, nopts);
                } else if (strcmp(type, "suggest") == 0) {
                    cJSON *msg = cJSON_GetObjectItem(j, "message");
                    cJSON *opts = cJSON_GetObjectItem(j, "options");
                    const char *message = msg && cJSON_IsString(msg) ? msg->valuestring : "";
                    int nopts = opts && cJSON_IsArray(opts) ? cJSON_GetArraySize(opts) : 0;
                    const char *opt_ptrs[6];
                    char opt_buf[6][64];
                    if (nopts > 6) nopts = 6;
                    for (int i = 0; i < nopts; i++) {
                        cJSON *o = cJSON_GetArrayItem(opts, i);
                        if (o && cJSON_IsString(o)) {
                            strncpy(opt_buf[i], o->valuestring, sizeof(opt_buf[i]) - 1);
                            opt_ptrs[i] = opt_buf[i];
                        }
                    }
                    sh_ui_overlay(SH_OV_SUGGEST, slot, "", message, nopts > 0 ? opt_ptrs : NULL, nopts);
                }
            }
            cJSON_Delete(j);
        }
    }
}

static void on_worktree(const char *slot, const char *payload_json) {
    // Worktree status is rolled up from panes; no direct action needed.
    ESP_LOGD(TAG, "worktree/status %s", slot);
}

static void on_focus(const char *payload_json) {
    sh_data_m2_set_focus(payload_json);
    // The UI's glance reads from sh_repos counts; focus data can be stored for
    // the glance view if needed.
}

static void on_presence(bool online) {
    ESP_LOGI(TAG, "Mac presence: %s", online ? "online" : "offline");
    sh_data_m2_set_presence(online);
}

static void on_dnd(const char *payload_json) {
    sh_data_m2_set_dnd(payload_json);
}

// ══════════════════════════════════════════════════════════════════════════════
// app_main
// ══════════════════════════════════════════════════════════════════════════════

extern "C" void app_main(void) {
    // 0) Init NVS (for config persistence)
    esp_err_t nvs_err = nvs_flash_init();
    if (nvs_err == ESP_ERR_NVS_NO_FREE_PAGES || nvs_err == ESP_ERR_NVS_NEW_VERSION_FOUND) {
        nvs_flash_erase();
        nvs_flash_init();
    }

    // 1) Load config
    sh_config_t cfg;
    if (sh_config_load(&cfg) != 0) {
        cfg = SH_CONFIG_DEFAULT;
        ESP_LOGI(TAG, "using default config (unpaired)");
    } else {
        ESP_LOGI(TAG, "config loaded: host=%s mac_id=%s paired=%d",
                 cfg.host, cfg.mac_id, sh_config_is_paired(&cfg));
    }

    // 1.5) Dev pre-pair: if no root secret yet, bake in the one from sh_secrets.h
    // so the device connects to EMQX as the paired identity and shows real data
    // (instead of the M1 mock fallback) without the short-code flow.
    if (!sh_config_is_paired(&cfg) && SH_ROOT_SECRET[0] != '\0') {
        strncpy(cfg.root_secret, SH_ROOT_SECRET, sizeof(cfg.root_secret) - 1);
        ESP_LOGI(TAG, "pre-paired from sh_secrets.h");
    }

    // 2) Init E2EE if paired
    if (sh_config_is_paired(&cfg)) {
        if (sh_config_derive_creds(&cfg) == 0) {
            ESP_LOGI(TAG, "E2EE initialized");
        } else {
            ESP_LOGW(TAG, "E2EE init failed, falling back to plaintext");
            cfg.root_secret[0] = '\0';
        }
    }

    // 3) Board
    auto board_cfg = M5.config();
    M5.begin(board_cfg);
    ESP_LOGI(TAG, "display %dx%d", (int)M5.Display.width(), (int)M5.Display.height());
    M5.Display.setRotation(0);
    M5.Display.setBrightness(200);
    M5.Display.fillScreen(TFT_BLACK);

    // 4) LVGL
    lv_init();
    lv_tick_set_cb(tick_cb);

    const int32_t hor = M5.Display.width();
    const int32_t ver = M5.Display.height();
    lv_display_t *disp = lv_display_create(hor, ver);
    lv_display_set_flush_cb(disp, flush_cb);

    // partial draw buffers in PSRAM (2 x 1/10 screen)
    const size_t buf_px = hor * 48;
    static lv_color_t *buf1, *buf2;
    buf1 = (lv_color_t *)heap_caps_malloc(buf_px * sizeof(lv_color_t), MALLOC_CAP_SPIRAM);
    buf2 = (lv_color_t *)heap_caps_malloc(buf_px * sizeof(lv_color_t), MALLOC_CAP_SPIRAM);
    lv_display_set_buffers(disp, buf1, buf2, buf_px * sizeof(lv_color_t),
                           LV_DISPLAY_RENDER_MODE_PARTIAL);

    lv_indev_t *touch = lv_indev_create();
    lv_indev_set_type(touch, LV_INDEV_TYPE_POINTER);
    lv_indev_set_read_cb(touch, touch_cb);

    // 5) UI init (boot screen)
    sh_ui_init();
    lv_obj_add_event_cb(lv_screen_active(), gesture_cb, LV_EVENT_GESTURE, NULL);

    // 5.5) WiFi — MUST be up before MQTT, else esp-mqtt asserts "Invalid mbox"
    // (no TCP/IP netif). Wait up to 15s for an IP; reconnect continues after.
    if (sh_wifi_start(15000)) {
        ESP_LOGI(TAG, "WiFi connected");
    } else {
        ESP_LOGW(TAG, "WiFi not up yet — MQTT will connect once it reconnects");
    }

    // 6) MQTT init
    sh_mqtt_callbacks_t cbs;
    memset(&cbs, 0, sizeof(cbs));
    cbs.on_state       = on_mqtt_state;
    cbs.on_pane_status = on_pane_status;
    cbs.on_pane_event  = on_pane_event;
    cbs.on_worktree    = on_worktree;
    cbs.on_focus       = on_focus;
    cbs.on_presence    = on_presence;
    cbs.on_dnd         = on_dnd;

    sh_mqtt_init(&cfg, &cbs);
    sh_mqtt_start();

    // 7) Event + render loop
    bool voicing = false;
    while (true) {
        M5.update();

        if (M5.BtnA.wasClicked())      sh_ui_scroll(+1);
        if (M5.BtnA.wasHold())         sh_ui_back();

        if (M5.BtnB.wasClicked())      sh_ui_select();
        if (M5.BtnB.isHolding() && !voicing) { voicing = true; sh_ui_voice_start(); }
        if (voicing && M5.BtnB.wasReleased()) { voicing = false; sh_ui_voice_end(); }

        lv_timer_handler();
        vTaskDelay(pdMS_TO_TICKS(5));
    }
}
