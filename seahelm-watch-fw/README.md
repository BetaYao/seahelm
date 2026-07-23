# seahelm-watch-fw

Seahelm 圆屏手表客户端固件(ESP32-S3 + 466×466 AMOLED)。
实现 claude.ai/design 的「Seahelm 手表(简化版)」设计:一枚随身的 seahelm
观察端 —— glance 首页 → repos → worktrees → panes → pane 详情(聊天流 + 长按语音),
suggest / question / notification 事件覆盖任意屏。

> **这是一个独立工程**,与主仓库的 Swift 版 Seahelm 无源码耦合,可整目录移出。

## 硬件

- **板子**:M5Stack **StopWatch**(ESP32-S3-R8N8,16M Flash / 8M PSRAM)。
- **屏**:1.75" 圆形 AMOLED **CO5300** QSPI,466×466。
- **触摸**:**CST820**(I2C,触摸唤醒)。
- **物理输入**:KEYA=G2(黄)、KEYB=G1(蓝)、PWR 键;触摸滑动。
- 由 **M5Unified / M5GFX** 自动识别并驱动面板/触摸/按键/IO 扩展器上电时序。
- 映射:KEYA→`M5.BtnA`(滚动)、KEYB→`M5.BtnB`(选择/长按语音)、右滑手势→返回。

## 工具链

- **ESP-IDF v5.3.3**(装在移动磁盘 `/Volumes/openbeta/esp`)
- **LVGL 9** + **M5Unified/M5GFX**(由 IDF component manager 拉取,见 `main/idf_component.yml`)
- LVGL↔屏 的 flush/touch 胶水在 `main/main.cpp`

```bash
idf.py set-target esp32s3
idf.py build flash monitor
```

## 里程碑

- **M1(本工程当前状态)**:显示层 + 全部核心屏 + 导航 + 输入,**跑 mock 数据**(`main/sh_data.c`),不接网络。视觉/交互先在真机跑通。
- **M2**:接 MQTT,`sh_data` 由 broker 的 retained `pane/+/status` / `focus` 填充;
  overlay 由 `pane/{id}/event` 触发;语音/选项经 `command` topic 发
  `pane.send_text` / `suggest.pick` / `question.answer`。对接点见
  `../docs/remote-clients-design.md` §15 协议报文规范,代码里以 `// M2:` 标注。

## ⚠️ 两个真机前置项

1. **中文字体(必须)**:LVGL 内置字体不含 CJK,整屏中文需生成子集字体。
   见 `main/fonts/README.md`。未放字体前,中文会显示为空白/豆腐块。
2. **BSP 点亮**:SH8601/触摸/编码器经 BSP 初始化(`main/bsp_hooks.c`),
   引脚与时序以 Waveshare 官方组件为准,需实际板子验证。

## 目录

```
main/
  main.cpp          app_main:M5Unified 初始化 + LVGL 胶水(flush/touch/tick)+ 按键→导航
  sh_theme.h        Sumi 墨配色 + 字体符号 + 状态色映射
  sh_data.c/.h      mock 数据模型(repos→worktrees→panes)+ 计数/汇总
  sh_ui.c/.h        导航栈 + 状态环 + 全部屏(boot/home/list/detail/overlay)+ overlay 事件
  fonts/            CJK 字体(需自行生成,见其 README)
```

## 状态色(与设计一致)

| status | 色 | 呼吸 |
|---|---|---|
| running | green `#6E9159` | 是 |
| waiting | amber `#C6993F` | 是 |
| done | green | 否 |
| failed | red `#9A3B2B` | 否 |
| idle / unknown | ash `#7C7368` | 否 |
