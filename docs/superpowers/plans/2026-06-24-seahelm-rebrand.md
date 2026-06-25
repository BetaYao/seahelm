# Seahelm Rebrand Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Rebrand the app from `seamux` to `Seahelm` — config-dir migration, project/module/bundle rename, docs, and a new sea-disc + helm-ring app icon.

**Architecture:** Five tasks ordered so the tree stays buildable. Config-path changes and their migration land first (source strings still compile under the old module name), then a single atomic task renames the project/module/bundle and sweeps every `@testable import` so the build goes green again, then docs, then the PIL-drawn icon.

**Tech Stack:** Swift 5.10, AppKit, XcodeGen (`project.yml`), XCTest, Python 3 + PIL (Pillow) for the icon.

## Global Constraints

- Swift 5.10, macOS 14.0+, AppKit.
- Project uses XcodeGen with **type:group sources (NOT globs)**: any file add/rename/delete requires `xcodegen generate` and the regenerated project committed.
- Backend session prefix `amux-` is NEVER renamed (running-session recovery). Out of scope.
- Config migration is COPY (not move): the old `~/.config/seamux/` directory stays for rollback, mirroring the existing `~/.config/amux` → `~/.config/seamux` copy.
- Tests import the app module with `@testable import <module>`; module name == `PRODUCT_NAME`.
- Until Task 3, module name is `seamux` and the test scheme is `seamuxTests`. From Task 3 onward, module is `seahelm` and the test/app schemes are `seahelmTests` / `seahelm`.
- Build/test commands require `-skipPackagePluginValidation -skipMacroValidation`.
- Pre-existing unrelated working-tree changes (StatusBarView.swift, TitleBarView.swift) must not be staged.

---

### Task 1: Config-dir rename + chained migration

**Files:**
- Modify: `Sources/Core/Config.swift:102-116` (configDir + migration)
- Modify: `Tests/ConfigTests.swift` (migration tests)

**Interfaces:**
- Consumes: nothing new.
- Produces: `Config.configDir` now points at `~/.config/seahelm`; `Config.migrateLegacyConfigDirIfNeeded(home:fileManager:)` keeps its signature but now copies the newest existing legacy dir (`seamux`, else `amux`) into `seahelm` when `seahelm` is absent.

**Note:** This task runs while the module is still `seamux` — use `@testable import seamux` and scheme `seamuxTests`.

- [ ] **Step 1: Write the failing tests**

Add to `Tests/ConfigTests.swift` (adapt to the file's existing `import`/helper style — it already has migration tests; place these beside them):

```swift
func testMigratesSeamuxIntoSeahelm() throws {
    let fm = FileManager.default
    let tmp = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let seamux = tmp.appendingPathComponent(".config/seamux")
    try fm.createDirectory(at: seamux, withIntermediateDirectories: true)
    try "{}".write(to: seamux.appendingPathComponent("config.json"), atomically: true, encoding: .utf8)

    Config.migrateLegacyConfigDirIfNeeded(home: tmp, fileManager: fm)

    let seahelm = tmp.appendingPathComponent(".config/seahelm/config.json")
    XCTAssertTrue(fm.fileExists(atPath: seahelm.path))
    // Source dir preserved for rollback
    XCTAssertTrue(fm.fileExists(atPath: seamux.appendingPathComponent("config.json").path))
}

func testMigratesAmuxWhenNoSeamux() throws {
    let fm = FileManager.default
    let tmp = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let amux = tmp.appendingPathComponent(".config/amux")
    try fm.createDirectory(at: amux, withIntermediateDirectories: true)
    try "{}".write(to: amux.appendingPathComponent("config.json"), atomically: true, encoding: .utf8)

    Config.migrateLegacyConfigDirIfNeeded(home: tmp, fileManager: fm)

    let seahelm = tmp.appendingPathComponent(".config/seahelm/config.json")
    XCTAssertTrue(fm.fileExists(atPath: seahelm.path))
}

func testNoMigrationWhenSeahelmExists() throws {
    let fm = FileManager.default
    let tmp = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let seahelm = tmp.appendingPathComponent(".config/seahelm")
    let seamux = tmp.appendingPathComponent(".config/seamux")
    try fm.createDirectory(at: seahelm, withIntermediateDirectories: true)
    try fm.createDirectory(at: seamux, withIntermediateDirectories: true)
    try "new".write(to: seahelm.appendingPathComponent("config.json"), atomically: true, encoding: .utf8)
    try "old".write(to: seamux.appendingPathComponent("config.json"), atomically: true, encoding: .utf8)

    Config.migrateLegacyConfigDirIfNeeded(home: tmp, fileManager: fm)

    let contents = try String(contentsOf: seahelm.appendingPathComponent("config.json"), encoding: .utf8)
    XCTAssertEqual(contents, "new")  // not overwritten
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild -project seamux.xcodeproj -scheme seamuxTests -configuration Debug test -only-testing:seamuxTests/ConfigTests -skipPackagePluginValidation -skipMacroValidation`
Expected: the three new tests FAIL (migration still targets `seamux`).

- [ ] **Step 3: Implement in `Sources/Core/Config.swift`**

```swift
static let configDir = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".config/seahelm")
static let configPath = configDir.appendingPathComponent("config.json")

/// Copies the newest pre-existing config dir (~/.config/seamux, else
/// ~/.config/amux) into ~/.config/seahelm on first launch. Source dirs are
/// kept for rollback. No-op once ~/.config/seahelm exists.
static func migrateLegacyConfigDirIfNeeded(
    home: URL = FileManager.default.homeDirectoryForCurrentUser,
    fileManager fm: FileManager = .default
) {
    let new = home.appendingPathComponent(".config/seahelm")
    guard !fm.fileExists(atPath: new.path) else { return }
    let candidates = [".config/seamux", ".config/amux"]
    for rel in candidates {
        let legacy = home.appendingPathComponent(rel)
        if fm.fileExists(atPath: legacy.path) {
            try? fm.copyItem(at: legacy, to: new)
            return
        }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: same as Step 2, plus the existing ConfigTests.
Expected: all ConfigTests PASS (the 3 new + pre-existing).

- [ ] **Step 5: Commit**

```bash
git add Sources/Core/Config.swift Tests/ConfigTests.swift
git commit -m "feat: migrate config dir seamux -> seahelm on first launch"
```

---

### Task 2: Rename remaining config-path strings

**Files:**
- Modify: `Sources/Core/WorktreeTaskStore.swift:6` (doc comment)
- Modify: `Sources/Core/WorktreeAgentTypeStore.swift:6` (doc comment)
- Modify: `Sources/App/TabCoordinator.swift:388` (NSLog message)
- Modify: `Sources/Terminal/GhosttyBridge.swift:32,34` (comment + `~/.config/seamux/ghostty.conf` path)

**Interfaces:** none (string/path changes).

**Note:** Still module `seamux` / scheme `seamuxTests` at this point. These stores write under `Config.configDir`, which Task 1 already moved to `seahelm`; only literal `seamux` strings/paths remain here. The `ghostty.conf` path is the one runtime path — it resolves under the migrated `~/.config/seahelm/`.

- [ ] **Step 1: Replace the literal paths/strings**

In `GhosttyBridge.swift` change the comment `Load seamux-specific overrides …` → `Load seahelm-specific overrides …` and the path component `.config/seamux/ghostty.conf` → `.config/seahelm/ghostty.conf`.

In `WorktreeTaskStore.swift` and `WorktreeAgentTypeStore.swift` change the doc-comment paths `~/.config/seamux/...` → `~/.config/seahelm/...`.

In `TabCoordinator.swift` change the NSLog string `~/.config/seamux/config.json` → `~/.config/seahelm/config.json`.

- [ ] **Step 2: Verify no stray `seamux` config-path literals remain in Sources**

Run: `grep -rin "seamux" Sources/ | grep -v ".build"`
Expected: no output (all source occurrences now read `seahelm`).

- [ ] **Step 3: Build**

Run: `xcodebuild -project seamux.xcodeproj -scheme seamux -configuration Debug -skipPackagePluginValidation -skipMacroValidation build`
Expected: BUILD SUCCEEDED.

- [ ] **Step 4: Commit**

```bash
git add Sources/Core/WorktreeTaskStore.swift Sources/Core/WorktreeAgentTypeStore.swift Sources/App/TabCoordinator.swift Sources/Terminal/GhosttyBridge.swift
git commit -m "feat: point remaining config paths at ~/.config/seahelm"
```

---

### Task 3: Rename project, module, bundle, bridging header, test imports (atomic — ends buildable)

**Files:**
- Modify: `project.yml` (all `seamux*` identifiers, `com.seamux*` bundle IDs, bridging-header path)
- Rename: `seamux-Bridging-Header.h` → `seahelm-Bridging-Header.h`
- Modify: every file under `Tests/` containing `@testable import seamux`
- Regenerate: the Xcode project (`seamux.xcodeproj` → `seahelm.xcodeproj`)

**Interfaces:** module name `seamux` → `seahelm` (every test's `@testable import`).

**Note:** This is one atomic task because renaming the module breaks every test import until they are all swept; the task ends only when the renamed project builds and tests compile.

- [ ] **Step 1: Edit `project.yml`**

Apply these exact replacements:
- `name: seamux` → `name: seahelm`
- `bundleIdPrefix: com.seamux` → `bundleIdPrefix: com.seahelm`
- target key `seamux:` → `seahelm:`
- `path: seamux-Bridging-Header.h` → `path: seahelm-Bridging-Header.h`
- `PRODUCT_BUNDLE_IDENTIFIER: com.seamux.app` → `com.seahelm.app`
- `PRODUCT_NAME: seamux` → `PRODUCT_NAME: seahelm`
- `SWIFT_OBJC_BRIDGING_HEADER: "$(PROJECT_DIR)/seamux-Bridging-Header.h"` → `.../seahelm-Bridging-Header.h`
- target key `seamuxTests:` → `seahelmTests:`, and under it `- target: seamux` → `- target: seahelm`, `PRODUCT_BUNDLE_IDENTIFIER: com.seamux.tests` → `com.seahelm.tests`
- target key `seamuxUITests:` → `seahelmUITests:`, `- target: seamux` → `- target: seahelm`, `PRODUCT_BUNDLE_IDENTIFIER: com.seamux.uitests` → `com.seahelm.uitests`, `TEST_TARGET_NAME: seamux` → `TEST_TARGET_NAME: seahelm`

- [ ] **Step 2: Rename the bridging header**

```bash
git mv seamux-Bridging-Header.h seahelm-Bridging-Header.h
```

- [ ] **Step 3: Sweep every test import**

```bash
grep -rl "@testable import seamux" Tests | xargs sed -i '' 's/@testable import seamux/@testable import seahelm/g'
```
Verify none remain: `grep -rn "@testable import seamux" Tests` → no output.

- [ ] **Step 4: Regenerate the project**

```bash
xcodegen generate
```
Expected: writes `seahelm.xcodeproj`. Remove the stale project dir if XcodeGen left it: confirm only `seahelm.xcodeproj` exists (`ls -d *.xcodeproj`). If `seamux.xcodeproj` lingers, `git rm -r seamux.xcodeproj`.

- [ ] **Step 5: Build + compile tests**

Run: `xcodebuild -project seahelm.xcodeproj -scheme seahelm -configuration Debug -skipPackagePluginValidation -skipMacroValidation build`
Expected: BUILD SUCCEEDED.
Run a focused test to confirm the test target compiles under the new module: `xcodebuild -project seahelm.xcodeproj -scheme seahelmTests -configuration Debug test -only-testing:seahelmTests/ConfigTests -skipPackagePluginValidation -skipMacroValidation`
Expected: ConfigTests PASS.

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "feat: rename project/module/bundle seamux -> seahelm"
```

---

### Task 4: Docs

**Files:**
- Modify: `CLAUDE.md` (project name, build commands, scheme names)
- Modify: `README.md`

**Interfaces:** none.

- [ ] **Step 1: Update build commands and names**

In `CLAUDE.md` and `README.md`, replace `seamux` → `seahelm` and `Seamux` → `Seahelm` in prose and in every `xcodebuild -project seamux.xcodeproj -scheme seamux…` / `seamuxTests` / `seamuxUITests` command. Keep the product description (the AMUX/agent-multiplexer framing) but update the headline name to Seahelm. Do NOT change the `amux-` session-prefix sentence.

- [ ] **Step 2: Verify**

Run: `grep -rin "seamux" CLAUDE.md README.md`
Expected: no output.

- [ ] **Step 3: Commit**

```bash
git add CLAUDE.md README.md
git commit -m "docs: rename seamux -> seahelm in CLAUDE.md and README"
```

---

### Task 5: New app icon — sea disc + helm ring

**Files:**
- Modify: `scripts/generate_icon.py` (rewrite `draw_icon`, update module docstring)
- Regenerate: `Assets.xcassets/AppIcon.appiconset/icon_*.png` (all sizes, via the script)

**Interfaces:** none (asset generation). The script already resizes a 1024 master to all sizes and writes `Contents.json` — only `draw_icon()` and the docstring change; the filename set in `Contents.json` stays identical.

**Note:** Not TDD (visual asset). Verified by running the script and inspecting the rendered master. Requires Pillow (`python3 -c "import PIL"`; if absent, `pip3 install Pillow`).

- [ ] **Step 1: Rewrite `draw_icon` in `scripts/generate_icon.py`**

Replace the stacked-cards drawing with concept A. Keep the existing `rounded_rect` helper, `main()`, resize loop, and `Contents.json` writer unchanged. Use the brand palette and draw: a light squircle badge, a clipped sea disc with four stacked wave bands (navy base, royal-blue lower wave, cyan mid band, red/orange top sun band), and a navy helm ring with 8 spoke-handles around the disc.

```python
#!/usr/bin/env python3
"""Generate Seahelm app icon: sea-wave disc framed by a ship's-wheel (helm) ring."""

from PIL import Image, ImageDraw
import os, json, math

SIZE = 1024
BADGE_BG = (255, 255, 255, 255)   # light squircle field
NAVY     = (10, 10, 100)          # #0A0A64 ring / base / outline
RED      = (255, 77, 46)          # #FF4D2E top sun band
CYAN     = (25, 209, 224)         # #19D1E0 mid band
BLUE     = (43, 111, 255)         # #2B6FFF lower wave

def draw_icon(size=1024):
    img = Image.new('RGBA', (size, size), (0, 0, 0, 0))
    draw = ImageDraw.Draw(img)
    s = size / 1024.0
    cx, cy = size / 2, size / 2

    # Light rounded-square badge
    pad = int(72 * s)
    rounded_rect(draw, [pad, pad, size - pad, size - pad], int(180 * s), fill=BADGE_BG)

    # Helm ring geometry
    ring_r = int(330 * s)          # outer radius of the navy ring band
    ring_w = max(int(34 * s), 4)   # ring thickness
    disc_r = ring_r - ring_w - int(18 * s)  # sea disc radius (inside the ring)

    # Helm spokes/handles (drawn under the ring so the ring caps them)
    handle_len = int(46 * s)
    handle_w = max(int(22 * s), 4)
    for i in range(8):
        ang = math.pi / 8 + i * (math.pi / 4)
        x0 = cx + (ring_r - ring_w // 2) * math.cos(ang)
        y0 = cy + (ring_r - ring_w // 2) * math.sin(ang)
        x1 = cx + (ring_r + handle_len) * math.cos(ang)
        y1 = cy + (ring_r + handle_len) * math.sin(ang)
        draw.line([x0, y0, x1, y1], fill=NAVY, width=handle_w)
        knob = int(16 * s)
        draw.ellipse([x1 - knob, y1 - knob, x1 + knob, y1 + knob], fill=NAVY)

    # Navy ring band
    draw.ellipse([cx - ring_r, cy - ring_r, cx + ring_r, cy + ring_r], outline=NAVY, width=ring_w)

    # Sea disc: render bands into a separate layer, then circular-mask it
    disc = Image.new('RGBA', (size, size), (0, 0, 0, 0))
    dd = ImageDraw.Draw(disc)
    top = cy - disc_r
    dd.rectangle([cx - disc_r, top, cx + disc_r, cy + disc_r], fill=NAVY)           # base
    _wave(dd, cx, top + disc_r * 0.55, disc_r, BLUE, amp=disc_r * 0.10)             # lower wave
    _wave(dd, cx, top + disc_r * 0.85, disc_r, CYAN, amp=disc_r * 0.12)             # mid band
    _wave(dd, cx, top + disc_r * 1.18, disc_r, RED,  amp=disc_r * 0.10)            # top sun band
    mask = Image.new('L', (size, size), 0)
    ImageDraw.Draw(mask).ellipse([cx - disc_r, cy - disc_r, cx + disc_r, cy + disc_r], fill=255)
    img.paste(disc, (0, 0), mask)

    return img


def _wave(draw, cx, baseline_y, r, color, amp):
    """Fill the region BELOW a sine crest at baseline_y across the disc width."""
    pts = []
    steps = 64
    for i in range(steps + 1):
        x = cx - r + (2 * r) * (i / steps)
        y = baseline_y - amp * math.sin(math.pi * (i / steps))
        pts.append((x, y))
    pts.append((cx + r, baseline_y + 4 * r))
    pts.append((cx - r, baseline_y + 4 * r))
    draw.polygon(pts, fill=color)
```

(Keep the file's existing `rounded_rect`, `main`, resize loop, and `Contents.json` block. `rounded_rect` already accepts `fill` only — the badge call passes no outline.)

- [ ] **Step 2: Generate the icons**

Run: `python3 scripts/generate_icon.py`
Expected: prints "Saved …/icon_1024x1024.png" and the six resized sizes; exit 0.

- [ ] **Step 3: Visually verify the master + small size**

Open `Assets.xcassets/AppIcon.appiconset/icon_1024x1024.png` and `icon_32x32.png`. Confirm: a sea-wave disc (navy → blue → cyan → red bands) framed by a navy helm ring with 8 handles, on a light squircle, recognizable at 32px. If proportions look off (disc too small, bands clipped, spokes merging), adjust the `s`-scaled constants and re-run. Then build to confirm the asset catalog still compiles:
`xcodebuild -project seahelm.xcodeproj -scheme seahelm -configuration Debug -skipPackagePluginValidation -skipMacroValidation build` → BUILD SUCCEEDED.

- [ ] **Step 4: Commit**

```bash
git add scripts/generate_icon.py Assets.xcassets/AppIcon.appiconset
git commit -m "feat: new Seahelm app icon (sea-wave disc + helm ring)"
```

---

## Self-Review

**Spec coverage:**
- Name rename across project.yml/module/bundle/bridging header → Task 3. ✓
- Test import sweep → Task 3. ✓
- Config dir migrate seamux→seahelm (copy, keep old, chained from amux) → Task 1. ✓
- Remaining config-path source strings (stores, TabCoordinator, GhosttyBridge ghostty.conf) → Task 2. ✓
- Docs → Task 4. ✓
- Backend `amux-` prefix unchanged → enforced by Global Constraints + Task 4 note. ✓
- Logo concept A (sea disc + helm ring, brand palette, legible at 16, PIL only, all sizes) → Task 5. ✓
- Bundle ID = new app identity → accepted in spec, applied in Task 3 (no mitigation needed). ✓

**Placeholder scan:** none — every code/edit step carries concrete content or exact replacements.

**Type/identifier consistency:** module `seahelm`, schemes `seahelm`/`seahelmTests`/`seahelmUITests`, bundle `com.seahelm.*`, bridging header `seahelm-Bridging-Header.h`, config dir `~/.config/seahelm` — used consistently across Tasks 1–5. Scheme-name switch (seamux→seahelm) at the Task 3 boundary is called out in Global Constraints and each task's note.

**Sequencing risk:** Tasks 1–2 build under the old `seamux` project; Task 3 renames atomically and re-greens; Tasks 4–5 run under `seahelm`. The `grep seamux Sources/` gate in Task 2 Step 2 and the `@testable import` gate in Task 3 Step 3 prevent stragglers.
