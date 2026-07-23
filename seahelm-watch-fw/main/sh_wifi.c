// sh_wifi.c — WiFi station bring-up with automatic reconnect.
//
// The firmware's MQTT client needs a live TCP/IP stack + a connected netif;
// starting it before WiFi is up asserts "Invalid mbox" in lwip/tcpip.c. So
// app_main brings WiFi up (and ideally waits for an IP) before sh_mqtt_start().
#include "sh_wifi.h"
#include "sh_secrets.h"

#include <string.h>
#include "esp_wifi.h"
#include "esp_event.h"
#include "esp_netif.h"
#include "esp_log.h"
#include "freertos/FreeRTOS.h"
#include "freertos/event_groups.h"

static const char *TAG = "sh_wifi";

#define WIFI_CONNECTED_BIT BIT0

static EventGroupHandle_t s_wifi_events;
static volatile bool      s_connected = false;

static void on_wifi_event(void *arg, esp_event_base_t base, int32_t id, void *data) {
    if (base == WIFI_EVENT && id == WIFI_EVENT_STA_START) {
        esp_wifi_connect();
    } else if (base == WIFI_EVENT && id == WIFI_EVENT_STA_DISCONNECTED) {
        s_connected = false;
        xEventGroupClearBits(s_wifi_events, WIFI_CONNECTED_BIT);
        ESP_LOGW(TAG, "disconnected, reconnecting…");
        esp_wifi_connect();
    } else if (base == IP_EVENT && id == IP_EVENT_STA_GOT_IP) {
        ip_event_got_ip_t *e = (ip_event_got_ip_t *)data;
        ESP_LOGI(TAG, "got ip: " IPSTR, IP2STR(&e->ip_info.ip));
        s_connected = true;
        xEventGroupSetBits(s_wifi_events, WIFI_CONNECTED_BIT);
    }
}

bool sh_wifi_start(int wait_ms) {
    s_wifi_events = xEventGroupCreate();

    ESP_ERROR_CHECK(esp_netif_init());
    ESP_ERROR_CHECK(esp_event_loop_create_default());
    esp_netif_create_default_wifi_sta();

    wifi_init_config_t init = WIFI_INIT_CONFIG_DEFAULT();
    ESP_ERROR_CHECK(esp_wifi_init(&init));

    ESP_ERROR_CHECK(esp_event_handler_instance_register(
        WIFI_EVENT, ESP_EVENT_ANY_ID, &on_wifi_event, NULL, NULL));
    ESP_ERROR_CHECK(esp_event_handler_instance_register(
        IP_EVENT, IP_EVENT_STA_GOT_IP, &on_wifi_event, NULL, NULL));

    wifi_config_t wc = {0};
    strncpy((char *)wc.sta.ssid, SH_WIFI_SSID, sizeof(wc.sta.ssid) - 1);
    strncpy((char *)wc.sta.password, SH_WIFI_PASS, sizeof(wc.sta.password) - 1);
    wc.sta.threshold.authmode = WIFI_AUTH_WPA2_PSK;

    ESP_ERROR_CHECK(esp_wifi_set_mode(WIFI_MODE_STA));
    ESP_ERROR_CHECK(esp_wifi_set_config(WIFI_IF_STA, &wc));
    ESP_ERROR_CHECK(esp_wifi_start());
    ESP_LOGI(TAG, "connecting to SSID \"%s\"…", SH_WIFI_SSID);

    if (wait_ms <= 0) return false;
    EventBits_t bits = xEventGroupWaitBits(
        s_wifi_events, WIFI_CONNECTED_BIT, pdFALSE, pdTRUE, pdMS_TO_TICKS(wait_ms));
    return (bits & WIFI_CONNECTED_BIT) != 0;
}

bool sh_wifi_is_connected(void) { return s_connected; }
