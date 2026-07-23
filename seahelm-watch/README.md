# Seahelm · Apple Watch

Standalone watchOS SwiftUI client for Seahelm. Connects to the Mac's MQTT broker
**over WebSocket** and mirrors the remote-clients protocol (§15 in
`docs/remote-clients-design.md`): subscribes to retained `pane/worktree/focus/
presence/dnd` state, sends `command` / `history/request`, and routes replies via
`reply/{clientId}/{corr}`.

Ported from the design prototype (Claude Design project *esp32* →
`Seahelm Apple Watch.html` + `seahelm-watch-*.jsx`).

## Build

```bash
brew install xcodegen          # if needed
cd seahelm-watch
xcodegen generate              # → seahelm-watch.xcodeproj
open seahelm-watch.xcodeproj   # build/run on a watchOS simulator (needs Xcode + watchOS SDK)
```

The SPM dependency (`CocoaMQTT`, incl. `CocoaMQTTWebSocket`) resolves on first
open. This repo can't build watchOS headlessly — build in Xcode.

## Connecting (dev)

`Sources/Config.swift` → `WatchConfig` defaults to the Mac's local dev broker:

- `host` `localhost`, `port` `8083`, `wsPath` `/mqtt`, `tls` `false`, `macId` `live`.
- On the **watch simulator** `localhost` reaches the Mac — start the devbroker
  (`clients/seahelm-web/devbroker`) and the Mac app (with `mqtt.enabled`), then run.
- On a **real watch** set `host` to the Mac's LAN IP (e.g. `192.168.1.20`).
- For **emqx cloud**: `tls = true`, `port = 8084`, set `host` + `username`/`password`,
  and drop `NSAllowsArbitraryLoads` from the Info.plist.

`macId` must match the Mac publisher's `mqtt.mac_id`.

## Screens (all wired to live data)

Home (focus / 灰灵 idle) · All sessions (repo→worktree) · Pane list · Pane detail
(history bubbles + question/suggest options + dictation reply) · Orders (待处理) ·
Confirm / 2FA · DND. Capability tiers (`read` / `interactive` / `control`) gate the
controls; `Mac offline` (LWT) drops to read-only.

## ⚠️ Server-side dependency

Free-text (`pane.send_text`) already works on the Mac. **Answering questions,
picking suggestions, and DND still need Mac-side handlers** —
`question.answer` / `suggest.pick` / `dnd.set` + retained `dnd/state` — which are
the Phase-1 server work (`ControlRouter` / `MqttChannel`). Until those land, the
watch's confirm/pick/DND buttons send commands that the Mac ignores.
