# CJK fonts

The UI text is Chinese. LVGL's built-in fonts (Montserrat) have no CJK glyphs, so
until a CJK font is registered the Chinese strings render as tofu (□). Latin/
digits still render, so the first flash proves display + LVGL + board bringup;
CJK is the immediately-following step.

Two options — pick one and wire it in `sh_theme.h`:

## Option A — pre-generated subset font (small, fast, recommended for M1)

Generate a C array font containing only the glyphs the UI actually uses.

1. Install the converter: `npm i -g lv_font_conv`
2. Collect the CJK codepoints used (from `sh_data.c` + `sh_ui.c` literals). A
   subset of a few hundred chars keeps the font ~100–300 KB.
3. Generate, e.g. at 28 px:
   ```bash
   lv_font_conv --font NotoSansSC-Medium.ttf --size 28 --bpp 4 \
     --format lvgl -o sh_font_cn_28.c \
     --symbols "运行中等你已完成失败空闲未知个在跑…"   # + the full used set
   ```
4. Drop `sh_font_cn_*.c` into `main/`, add to `main/CMakeLists.txt` SRCS,
   `LV_FONT_DECLARE(sh_font_cn_28)`, and point the `SH_FONT_*` macros at them.

## Option B — runtime FreeType + full TTF (any text, heavier)

Enable LVGL's FreeType (`CONFIG_LV_USE_FREETYPE`), flash a full `NotoSansSC.ttf`
into the `assets` SPIFFS partition (see `partitions.csv`), and create fonts with
`lv_freetype_font_create(...)` at boot. Handles arbitrary Chinese (live MQTT
messages in M2) without regenerating a subset, at the cost of the FreeType lib +
PSRAM. Prefer this once M2 shows arbitrary agent output.

> M1 default: ship without CJK (tofu), confirm hardware, then land Option A.
