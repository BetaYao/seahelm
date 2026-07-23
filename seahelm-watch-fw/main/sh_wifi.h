// sh_wifi.h — WiFi station bring-up (esp_netif + event loop + auto-reconnect).
#pragma once
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

// Init the TCP/IP stack, default event loop, and WiFi station, then start
// connecting. Blocks up to `wait_ms` for the first IP (0 = don't wait).
// Returns true if an IP was acquired within the timeout. Reconnects
// automatically for the rest of the session regardless of the return value.
bool sh_wifi_start(int wait_ms);

// True once the station currently holds an IP.
bool sh_wifi_is_connected(void);

#ifdef __cplusplus
}
#endif
