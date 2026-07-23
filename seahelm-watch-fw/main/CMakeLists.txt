# M2: MQTT + E2EE + cJSON added.
idf_component_register(
    SRCS
        "main.cpp"
        "sh_config.c"
        "sh_crypto.c"
        "sh_data.c"
        "sh_mqtt.c"
        "sh_wifi.c"
        "sh_ui.c"
        "sh_font_cn_20.c"
        "sh_font_cn_26.c"
        "sh_font_cn_34.c"
        "sh_font_num_96.c"
    INCLUDE_DIRS "."
    REQUIRES
        driver
        esp_timer
        nvs_flash
        esp_wifi
        esp_netif
        esp_event
        mqtt
        mbedtls
        json
)
