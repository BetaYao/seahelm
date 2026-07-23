# M5Unified is C++, so main is built as C++ where needed; sh_*.c stay C.
idf_component_register(
    SRCS
        "main.cpp"
        "sh_data.c"
        "sh_ui.c"
        "sh_font_cn_20.c"
        "sh_font_cn_26.c"
        "sh_font_cn_34.c"
        "sh_font_num_96.c"
    INCLUDE_DIRS "."
    REQUIRES
        driver
        esp_timer
)

# GCC's format-truncation is over-conservative for our small numeric buffers.
target_compile_options(${COMPONENT_LIB} PRIVATE -Wno-error=format-truncation)
