# Seahelm Rebrand Design

**Date:** 2026-06-24
**Status:** Approved (design discussion locked)

## Problem

The product name `seamux` (sea + multiplexer) detaches from the product's
navy/command-bridge metaphor: every concept word is nautical — Captain (user),
Bridge (left overview), First Mate (rule engine), Sailor (per-worktree agent) —
but the main name is the technical term "mux", which also still implies the old
"terminal multiplexer" positioning the product has since outgrown (it is now an
agent-fleet command bridge, not an IDE/mux).

Decision: rename to **Seahelm** (sea + helm). "Helm" is both the ship's wheel and
the act of command ("at the helm", "take the helm") — it names exactly what the
Captain does: stand at the helm and command the agent fleet, with the First Mate
on the Bridge. It keeps the `sea` root (continuity from amux→seamux), drops `mux`,
and fits the metaphor system.

Also rebrand the app **logo** to match the parent company "sea" brand family.

## Decisions (locked)

1. **Name:** `seamux` / `Seamux` → `seahelm` / `Seahelm`.
2. **Config directory:** migrate `~/.config/seamux/` → `~/.config/seahelm/` on
   first launch (copy, keep old dir for rollback), mirroring the existing
   amux→seamux migration. Both prior migrations stay in place.
3. **Backend session prefix `amux-`:** UNCHANGED (renaming it loses recovery of
   running sessions — same rule applied in the previous rename). Brand-independent.
4. **Logo:** concept A — the "sea" layered-wave disc encircled by a ship's-wheel
   (helm) ring, in the parent "sea" palette. Replaces the current cyan
   stacked-terminal-cards icon.

## Scope

### A. Pure branding (rename freely)

- `project.yml`: project `name`, `bundleIdPrefix` (`com.seamux` → `com.seahelm`),
  targets `seamux`/`seamuxTests`/`seamuxUITests` → `seahelm`/`seahelmTests`/
  `seahelmUITests`, `PRODUCT_NAME`, `PRODUCT_BUNDLE_IDENTIFIER` (all `com.seamux.*`
  → `com.seahelm.*`), `TEST_TARGET_NAME`, and the bridging header reference.
- Bridging header file: `seamux-Bridging-Header.h` → `seahelm-Bridging-Header.h`
  (rename file + update `SWIFT_OBJC_BRIDGING_HEADER` path).
- Swift module name changes `seamux` → `seahelm`, so EVERY test file's
  `@testable import seamux` → `@testable import seahelm`.
- Generated project: `seamux.xcodeproj` → `seahelm.xcodeproj` (via `xcodegen
  generate` after `project.yml` rename).
- Docs: `CLAUDE.md`, `README.md` references and build commands.

### B. Data-path branding (migrate, don't break)

- Source strings referencing `~/.config/seamux`: `Config.swift` (path + migration),
  `WorktreeTaskStore.swift` / `WorktreeAgentTypeStore.swift` (doc comments + paths),
  `TabCoordinator.swift` (NSLog message), `GhosttyBridge.swift`
  (`~/.config/seamux/ghostty.conf`). All move to `seahelm`, gated by the
  first-launch migration so existing users keep their config.

### C. Out of scope / unchanged

- Backend session prefix `amux-` (data safety).
- The `~/.config/amux` → `~/.config/seamux` migration code stays (older users may
  still need it); the new code adds a `seamux` → `seahelm` hop on top.
- Bundle ID change (`com.seamux.app` → `com.seahelm.app`) means macOS treats it as
  a new app identity (fresh prefs/permissions). Acceptable for this pre-release
  internal tool; noted, not mitigated.

## Logo Design (concept A)

Rewrite `scripts/generate_icon.py` to draw, then regenerate
`Assets.xcassets/AppIcon.appiconset/*` at all sizes.

**Elements:**
- **Sea disc** (center): a circle filled with the parent brand's layered waves —
  top band warm (red/orange sun-on-water), a bright cyan mid-band, royal-blue
  lower waves, deep-navy base. Smooth wave separators (approximated with filled
  polygons / arcs in PIL).
- **Helm ring** (around the disc): a thin ship's-wheel ring with 8 evenly spaced
  spoke-handles protruding past the rim, in deep navy, framing the sea disc.
- **Badge:** the existing rounded-square (squircle) app-icon silhouette, on a
  light/white field so the navy + waves read at small sizes.

**Palette (from the "sea" brand):**
- Navy `#0A0A64` (ring, base, outline)
- Red/orange `#FF4D2E` (top sun band)
- Cyan `#19D1E0` (mid band)
- Royal blue `#2B6FFF` (lower waves)

**Constraints:**
- Must remain legible at 16×16 (the helm spokes simplify/merge gracefully; the
  sea disc + ring silhouette carries recognition at small sizes).
- Implemented in PIL only (no new deps), consistent with the current script.
- Output PNGs at all `Contents.json` sizes (16/32/64/128/256/512/1024 and @2x).

## Verification

- `xcodegen generate` succeeds with the renamed targets; the project opens as
  `seahelm.xcodeproj`.
- Build succeeds: `xcodebuild -project seahelm.xcodeproj -scheme seahelm …`.
- Test suite builds/runs under scheme `seahelmTests` with `@testable import seahelm`.
- First-launch migration: with a populated `~/.config/seamux/` and no
  `~/.config/seahelm/`, launching copies config across; existing `~/.config/seamux/`
  is left intact.
- Rendered app icon visually matches concept A at 1024 and remains legible at 16.

## Out of scope

- In-app rendered wordmark/marketing assets beyond the app icon.
- Renaming the backend session prefix or the `amux`/`seamux` config dirs' contents.
- Animated/alternate icon variants.
