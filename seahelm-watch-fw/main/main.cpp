// main.cpp — M5Unified (CO5300 AMOLED + CST820 touch + keys) ↔ LVGL 9 glue.
// Board: M5Stack StopWatch (ESP32-S3-R8N8, 466x466). M5.begin() autodetects it.
#include <M5Unified.h>
#include "lvgl.h"
#include "esp_timer.h"
#include "esp_heap_caps.h"
#include "esp_log.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"

extern "C" {
#include "sh_ui.h"
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

extern "C" void app_main(void) {
    // 1) board
    auto cfg = M5.config();
    M5.begin(cfg);
    ESP_LOGI(TAG, "display %dx%d", (int)M5.Display.width(), (int)M5.Display.height());
    M5.Display.setRotation(0);
    M5.Display.setBrightness(200);
    M5.Display.fillScreen(TFT_BLACK);

    // 2) lvgl
    lv_init();
    lv_tick_set_cb(tick_cb);

    const int32_t hor = M5.Display.width();
    const int32_t ver = M5.Display.height();
    lv_display_t *disp = lv_display_create(hor, ver);
    lv_display_set_flush_cb(disp, flush_cb);

    // partial draw buffers in PSRAM (2 x ~1/10 screen)
    const size_t buf_px = hor * 48;
    static lv_color_t *buf1, *buf2;
    buf1 = (lv_color_t *)heap_caps_malloc(buf_px * sizeof(lv_color_t), MALLOC_CAP_SPIRAM);
    buf2 = (lv_color_t *)heap_caps_malloc(buf_px * sizeof(lv_color_t), MALLOC_CAP_SPIRAM);
    lv_display_set_buffers(disp, buf1, buf2, buf_px * sizeof(lv_color_t),
                           LV_DISPLAY_RENDER_MODE_PARTIAL);

    lv_indev_t *touch = lv_indev_create();
    lv_indev_set_type(touch, LV_INDEV_TYPE_POINTER);
    lv_indev_set_read_cb(touch, touch_cb);

    // 3) ui
    sh_ui_init();
    lv_obj_add_event_cb(lv_screen_active(), gesture_cb, LV_EVENT_GESTURE, NULL);

    // 4) event + render loop
    //   BtnA (G2, yellow) : scroll list  (crown surrogate)
    //   BtnB (G1, blue)   : short = select/confirm; hold in detail = voice
    //   BtnA hold         : back
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
