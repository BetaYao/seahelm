# Bundle zmx Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Bundle the MIT-licensed `zmx` binary inside seahelm.app so the app works out of the box, routing every call site through a single `ZmxLocator` seam.

**Architecture:** One `ZmxLocator` type owns "where is the zmx executable" (bundled copy always wins, `$PATH` is a dev-only fallback). All Swift call sites that hardcoded `"zmx"` resolve through it. A checksummed build script fetches the pinned arm64 zmx release, embeds it at `Contents/Resources/bin/zmx`, and code-signs it under hardened runtime. The install-nag UX is deleted.

**Tech Stack:** Swift 5.10, AppKit, XcodeGen (`project.yml`), macOS 14+, arm64-only.

## Global Constraints

- Platform: **macOS 14.0+, arm64 only** (no universal/x86_64, no `lipo`).
- zmx is **MIT licensed** — ship `Resources/licenses/zmx-LICENSE` in the bundle.
- Bundled binary **always wins** over any `$PATH` zmx.
- Pinned zmx version + SHA-256 live in a committed `Vendor/zmx.pin`; a checksum mismatch **fails the build**.
- Do **not** build a daemon, a client binary, a `TerminalBackend` protocol, or touch `tmux`/`local` behavior.
- Build/test commands must pass `-skipPackagePluginValidation -skipMacroValidation` (SwiftLint plugin failures on `CodeEdit*` packages are pre-existing and expected — ignore them).
- Reference spec: `docs/superpowers/specs/2026-07-01-bundle-zmx-design.md`.

---

### Task 1: `ZmxLocator` seam + unit tests

**Files:**
- Create: `Sources/Core/ZmxLocator.swift`
- Test: `Tests/ZmxLocatorTests.swift`

**Interfaces:**
- Consumes: `ProcessRunner.commandPath(_:) -> String?` (existing).
- Produces:
  - `ZmxLocator.resolve(bundledPath: String?, pathLookup: () -> String?) -> String?` (pure)
  - `ZmxLocator.executable() -> String` (bundled path, else `"zmx"`)
  - `ZmxLocator.path() -> String?`
  - `ZmxLocator.isAvailable: Bool`
  - `ZmxLocator.isBundled: Bool`

- [ ] **Step 1: Write the failing test**

Create `Tests/ZmxLocatorTests.swift`:

```swift
import XCTest
@testable import seahelm

final class ZmxLocatorTests: XCTestCase {
    func testBundledAlwaysWinsOverPath() {
        let result = ZmxLocator.resolve(bundledPath: "/app/Resources/bin/zmx",
                                        pathLookup: { "/opt/homebrew/bin/zmx" })
        XCTAssertEqual(result, "/app/Resources/bin/zmx")
    }

    func testFallsBackToPathWhenNotBundled() {
        let result = ZmxLocator.resolve(bundledPath: nil,
                                        pathLookup: { "/opt/homebrew/bin/zmx" })
        XCTAssertEqual(result, "/opt/homebrew/bin/zmx")
    }

    func testNilWhenNeitherBundledNorOnPath() {
        let result = ZmxLocator.resolve(bundledPath: nil, pathLookup: { nil })
        XCTAssertNil(result)
    }

    func testExecutableFallsBackToLiteralZmx() {
        // With no bundled binary in the test host, executable() must still yield a
        // usable token so `/usr/bin/env <token>` resolves on PATH.
        XCTAssertFalse(ZmxLocator.executable().isEmpty)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -project seahelm.xcodeproj -scheme seahelmTests -configuration Debug -skipPackagePluginValidation -skipMacroValidation test -only-testing:seahelmTests/ZmxLocatorTests 2>&1 | tail -15`
Expected: FAIL — compile error, `ZmxLocator` is not defined.

- [ ] **Step 3: Write minimal implementation**

Create `Sources/Core/ZmxLocator.swift`:

```swift
import Foundation

/// Single source of truth for the zmx executable location. The bundled copy
/// (shipped in Contents/Resources/bin/zmx) always wins; $PATH is consulted only
/// in dev builds that never fetched/embedded the binary.
///
/// This is also the seam a future in-house persistence daemon would replace:
/// it is the one place that knows *which* executable provides session persistence.
enum ZmxLocator {
    /// Pure resolution: bundled path if present, else whatever the PATH lookup finds.
    static func resolve(bundledPath: String?, pathLookup: () -> String?) -> String? {
        bundledPath ?? pathLookup()
    }

    /// Absolute path to the zmx binary, or nil if genuinely absent.
    static func path() -> String? {
        resolve(bundledPath: bundledResourcePath(),
                pathLookup: { ProcessRunner.commandPath("zmx") })
    }

    /// A token safe to hand to `/usr/bin/env` or a shell: the absolute bundled
    /// path when available, otherwise the literal "zmx" (PATH-resolved downstream).
    static func executable() -> String { path() ?? "zmx" }

    static var isAvailable: Bool { path() != nil }
    static var isBundled: Bool { bundledResourcePath() != nil }

    /// Path to the embedded binary if it exists and is executable.
    private static func bundledResourcePath() -> String? {
        guard let url = Bundle.main.url(forResource: "zmx", withExtension: nil, subdirectory: "bin"),
              FileManager.default.isExecutableFile(atPath: url.path) else { return nil }
        return url.path
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `xcodebuild -project seahelm.xcodeproj -scheme seahelmTests -configuration Debug -skipPackagePluginValidation -skipMacroValidation test -only-testing:seahelmTests/ZmxLocatorTests 2>&1 | tail -15`
Expected: PASS — "Executed 4 tests, with 0 failures". (`ZmxLocatorTests.swift` is picked up automatically because `Tests` is globbed as a group.)

- [ ] **Step 5: Commit**

```bash
git add Sources/Core/ZmxLocator.swift Tests/ZmxLocatorTests.swift
git commit -m "feat: add ZmxLocator seam for resolving the zmx executable"
```

---

### Task 2: Route all Swift call sites through `ZmxLocator`

**Files:**
- Modify: `Sources/Terminal/Station.swift:61`, `:421` (ghostty command), `:432`, `:435`, `:461` (ProcessRunner calls)
- Modify: `Sources/Core/TmuxChannel.swift:76`, `:82` (ZmxChannel)
- Modify: `Sources/Core/SessionManager.swift:81`, `:148`, `:161`
- Modify: `Sources/App/MainWindowController.swift:291`
- Modify: `Sources/App/AppDelegate.swift:80`

**Interfaces:**
- Consumes: `ZmxLocator.executable()`, `ZmxLocator.isAvailable`, `ShellEscape.singleQuote(_:)` (existing).
- Produces: no new symbols — behavior-preserving rewiring.

- [ ] **Step 1: Replace the ghostty attach command (2 sites in Station.swift)**

In `Sources/Terminal/Station.swift`, both occurrences read:

```swift
let zmxCommand = "zmx attach \(sessionName)"
```

Replace **each** with:

```swift
let zmxCommand = "\(ShellEscape.singleQuote(ZmxLocator.executable())) attach \(sessionName)"
```

(The bundled Resources path can contain spaces; single-quoting is required because ghostty runs this string through a shell.)

- [ ] **Step 2: Replace the ProcessRunner zmx calls in Station.swift**

`Sources/Terminal/Station.swift` — replace:

```swift
ProcessRunner.runSync(["zmx", "kill", sessionName])
```
with
```swift
ProcessRunner.runSync([ZmxLocator.executable(), "kill", sessionName])
```

replace:
```swift
guard let listOutput = ProcessRunner.output(["zmx", "list"]) else { return }
```
with
```swift
guard let listOutput = ProcessRunner.output([ZmxLocator.executable(), "list"]) else { return }
```

replace:
```swift
guard let versionOutput = ProcessRunner.output(["zmx", "version"]) else { return nil }
```
with
```swift
guard let versionOutput = ProcessRunner.output([ZmxLocator.executable(), "version"]) else { return nil }
```

- [ ] **Step 3: Replace ZmxChannel calls in TmuxChannel.swift**

`Sources/Core/TmuxChannel.swift` — replace:
```swift
let args = ["zmx", "run", sessionName, command]
```
with
```swift
let args = [ZmxLocator.executable(), "run", sessionName, command]
```
and replace:
```swift
let args = ["zmx", "history", sessionName]
```
with
```swift
let args = [ZmxLocator.executable(), "history", sessionName]
```

- [ ] **Step 4: Replace SessionManager calls**

`Sources/Core/SessionManager.swift` — replace both:
```swift
ProcessRunner.output(["zmx", "list"])
```
(lines ~81 and ~161) with:
```swift
ProcessRunner.output([ZmxLocator.executable(), "list"])
```
and replace:
```swift
return [["zmx", "run", name, shell, "-lic", inner]]
```
with:
```swift
return [[ZmxLocator.executable(), "run", name, shell, "-lic", inner]]
```

- [ ] **Step 5: Replace the availability checks**

`Sources/App/MainWindowController.swift` line ~291 — replace:
```swift
guard ProcessRunner.commandExists("zmx") else {
```
with:
```swift
guard ZmxLocator.isAvailable else {
```

`Sources/App/AppDelegate.swift` line ~80 — replace:
```swift
guard ProcessRunner.commandExists("zmx") else { return }
```
with:
```swift
guard ZmxLocator.isAvailable else { return }
```

- [ ] **Step 6: Build and run the full unit-test suite**

Run: `xcodebuild -project seahelm.xcodeproj -scheme seahelm -configuration Debug -skipPackagePluginValidation -skipMacroValidation build 2>&1 | grep -E "error:|BUILD"`
Expected: `** BUILD SUCCEEDED **`

Run: `xcodebuild -project seahelm.xcodeproj -scheme seahelmTests -configuration Debug -skipPackagePluginValidation -skipMacroValidation test -only-testing:seahelmTests/ZmxLocatorTests -only-testing:seahelmTests/StationHealthCheckTests 2>&1 | tail -8`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add Sources/Terminal/Station.swift Sources/Core/TmuxChannel.swift Sources/Core/SessionManager.swift Sources/App/MainWindowController.swift Sources/App/AppDelegate.swift
git commit -m "refactor: resolve zmx executable via ZmxLocator at every call site"
```

---

### Task 3: Simplify `BackendResolver` — drop the install-nag

**Files:**
- Modify: `Sources/App/BackendResolver.swift:61`, `:76-88`, `:105-121`
- Test: `Tests/BackendResolverTests.swift` (if present; else skip test edits)

**Interfaces:**
- Consumes: `ZmxLocator.isAvailable`.
- Produces: `BackendResolver.resolveAsync` / `showWarningIfNeeded` unchanged signatures; the "not installed" branch removed.

- [ ] **Step 1: Use ZmxLocator for availability in resolveAsync**

`Sources/App/BackendResolver.swift` line ~61 — replace:
```swift
let zmxAvailable = ProcessRunner.commandExists("zmx")
```
with:
```swift
let zmxAvailable = ZmxLocator.isAvailable
```

- [ ] **Step 2: Remove the "not installed" warning branch**

In `resolveAsync`, replace this block:
```swift
            if preferred == "zmx" {
                if !zmxAvailable {
                    warningMessage = "zmx is not installed. Install with `brew install neurosnap/tap/zmx`."
                } else if let version = zmxVersion, !isSupportedZmxVersion(version) {
                    warningMessage = "zmx version is too old. Please upgrade to zmx 0.4.2+ for stability."
                }
            }
```
with (bundled zmx is always present, so only the version safety-net remains):
```swift
            if preferred == "zmx", let version = zmxVersion, !isSupportedZmxVersion(version) {
                warningMessage = "Bundled zmx version is unexpectedly unsupported (\(version))."
            }
```

- [ ] **Step 3: Remove the brew/docs buttons from the warning dialog**

In `showWarningIfNeeded`, replace the whole `if configBackend == "zmx" && !resolution.zmxAvailable { … } else { … }` block with just:
```swift
        alert.addButton(withTitle: "OK")
        alert.runModal()
```

- [ ] **Step 4: Build**

Run: `xcodebuild -project seahelm.xcodeproj -scheme seahelm -configuration Debug -skipPackagePluginValidation -skipMacroValidation build 2>&1 | grep -E "error:|BUILD"`
Expected: `** BUILD SUCCEEDED **`. (If `BackendResolverTests` references the removed message text, update those assertions to match the new version-only message, then re-run the tests.)

- [ ] **Step 5: Commit**

```bash
git add Sources/App/BackendResolver.swift Tests/BackendResolverTests.swift 2>/dev/null; git add Sources/App/BackendResolver.swift
git commit -m "refactor: drop zmx install-nag now that zmx is bundled"
```

---

### Task 4: Pin file + checksummed fetch script

**Files:**
- Create: `Vendor/zmx.pin`
- Create: `Scripts/fetch-zmx.sh`

**Interfaces:**
- Produces: `Scripts/fetch-zmx.sh <dest-path>` — idempotent fetch that writes a verified arm64 `zmx` binary to `<dest-path>`; exits non-zero on checksum mismatch or download failure.

- [ ] **Step 1: Generate the pin file from the real release**

Find the arm64 macOS asset on `https://github.com/neurosnap/zmx/releases` (pin the current version, e.g. `0.6.0`). Download it, compute its SHA-256, and write `Vendor/zmx.pin` with three lines — `VERSION`, `URL` (direct asset download URL), `SHA256`. Example (replace URL/version with the real asset; the tarball may need extraction — if the asset is a `.tar.gz`, point `URL` at it and the script extracts):

```
VERSION=0.6.0
URL=https://github.com/neurosnap/zmx/releases/download/v0.6.0/zmx-aarch64-apple-darwin.tar.gz
SHA256=<paste output of: shasum -a 256 the-downloaded-asset>
```

Produce the real SHA with:
```bash
curl -fsSL -o /tmp/zmx-asset "$URL" && shasum -a 256 /tmp/zmx-asset
```
Paste that hash into `SHA256=`.

- [ ] **Step 2: Write the fetch script**

Create `Scripts/fetch-zmx.sh`:

```bash
#!/bin/bash
# Fetch the pinned arm64 zmx binary to $1, verifying its SHA-256.
# Idempotent: if the destination already matches the pinned binary checksum, skip.
set -euo pipefail

DEST="${1:?usage: fetch-zmx.sh <dest-path>}"
PIN="$(cd "$(dirname "$0")/.." && pwd)/Vendor/zmx.pin"

# shellcheck disable=SC1090
source "$PIN"   # sets VERSION, URL, SHA256

verify() { shasum -a 256 "$1" | awk '{print $1}'; }

# The pinned SHA256 is of the downloaded ASSET (tarball). We keep a marker so we
# can skip re-downloading when DEST is already the extracted binary from this pin.
MARKER="${DEST}.pin-sha"
if [ -f "$DEST" ] && [ -f "$MARKER" ] && [ "$(cat "$MARKER")" = "$SHA256" ]; then
  echo "fetch-zmx: up to date ($VERSION)"; exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
echo "fetch-zmx: downloading zmx $VERSION"
curl -fsSL -o "$TMP/asset" "$URL"

GOT="$(verify "$TMP/asset")"
if [ "$GOT" != "$SHA256" ]; then
  echo "fetch-zmx: CHECKSUM MISMATCH" >&2
  echo "  expected $SHA256" >&2
  echo "  got      $GOT" >&2
  exit 1
fi

# Extract if tarball, else treat as the raw binary.
case "$URL" in
  *.tar.gz|*.tgz) tar -xzf "$TMP/asset" -C "$TMP"; BIN="$(find "$TMP" -type f -name zmx | head -1)";;
  *)              BIN="$TMP/asset";;
esac
[ -n "${BIN:-}" ] && [ -f "$BIN" ] || { echo "fetch-zmx: no zmx binary in asset" >&2; exit 1; }

mkdir -p "$(dirname "$DEST")"
cp "$BIN" "$DEST"
chmod +x "$DEST"
printf '%s' "$SHA256" > "$MARKER"
echo "fetch-zmx: installed $VERSION -> $DEST"
```

Then:
```bash
chmod +x Scripts/fetch-zmx.sh
```

- [ ] **Step 3: Run the script to verify it fetches and verifies**

Run: `./Scripts/fetch-zmx.sh /tmp/zmx-bundle-test/zmx && /tmp/zmx-bundle-test/zmx version`
Expected: prints "fetch-zmx: installed …" then zmx's version output. Running it a second time prints "up to date".

- [ ] **Step 4: Verify checksum enforcement**

Temporarily corrupt the pin and confirm the build-breaking behavior:
```bash
sed 's/^SHA256=.*/SHA256=deadbeef/' Vendor/zmx.pin > /tmp/badpin && \
  cp Vendor/zmx.pin /tmp/goodpin && cp /tmp/badpin Vendor/zmx.pin && \
  (./Scripts/fetch-zmx.sh /tmp/zmx-bad/zmx; echo "exit=$?"); \
  cp /tmp/goodpin Vendor/zmx.pin
```
Expected: prints "CHECKSUM MISMATCH" and `exit=1`; the pin is restored afterward.

- [ ] **Step 5: Commit**

```bash
git add Vendor/zmx.pin Scripts/fetch-zmx.sh
git commit -m "build: add pinned, checksummed zmx fetch script"
```

---

### Task 5: Embed + sign zmx in the app bundle, ship license, verify

**Files:**
- Modify: `project.yml` (add a pre-build script phase to the `seahelm` target)
- Create: `Resources/licenses/zmx-LICENSE`
- Regenerate: `seahelm.xcodeproj` (via `xcodegen generate`)

**Interfaces:**
- Consumes: `Scripts/fetch-zmx.sh`, `Vendor/zmx.pin`, `ZmxLocator.bundledResourcePath()` (expects `Contents/Resources/bin/zmx`).
- Produces: `seahelm.app/Contents/Resources/bin/zmx` (signed) + `Contents/Resources/licenses/zmx-LICENSE`.

- [ ] **Step 1: Add the zmx MIT license text**

Download the license from the pinned tag and save it:
```bash
mkdir -p Resources/licenses
curl -fsSL -o Resources/licenses/zmx-LICENSE https://raw.githubusercontent.com/neurosnap/zmx/v0.6.0/LICENSE
```
Confirm it is the MIT text: `head -1 Resources/licenses/zmx-LICENSE` (expect "MIT License").

- [ ] **Step 2: Add the fetch+embed+sign build phase to project.yml**

In `project.yml`, under `targets: seahelm:`, add a `preBuildScripts` entry (place it as a sibling of `sources:` / `settings:`), and add the license dir to `sources` as a resource:

```yaml
    preBuildScripts:
      - name: "Embed and sign bundled zmx"
        basedOnDependencyAnalysis: false
        script: |
          set -euo pipefail
          RES="${CODESIGNING_FOLDER_PATH}/Contents/Resources/bin"
          "${SRCROOT}/Scripts/fetch-zmx.sh" "${RES}/zmx"
          if [ "${CODE_SIGNING_ALLOWED:-YES}" = "YES" ] && [ -n "${EXPANDED_CODE_SIGN_IDENTITY:-}" ]; then
            codesign --force --options runtime --timestamp=none \
              --sign "${EXPANDED_CODE_SIGN_IDENTITY}" "${RES}/zmx"
          fi
```

And add to the `sources:` list of the `seahelm` target:
```yaml
      - path: Resources/licenses
```

(`preBuildScripts` runs before compile; `CODESIGNING_FOLDER_PATH` already points at the app being built, so dropping the binary there before the final app seal makes the outer signature cover it. `--timestamp=none` keeps offline/dev builds fast; for notarized release builds the engineer may drop `=none` to get a secure timestamp.)

- [ ] **Step 3: Regenerate the project and build**

Run:
```bash
xcodegen generate && xcodebuild -project seahelm.xcodeproj -scheme seahelm -configuration Debug -skipPackagePluginValidation -skipMacroValidation build 2>&1 | grep -E "error:|BUILD"
```
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Verify the embedded, signed binary in the built app**

Run:
```bash
APP=$(ls -d ~/Library/Developer/Xcode/DerivedData/seahelm-*/Build/Products/Debug/seahelm.app | head -1)
ls -l "$APP/Contents/Resources/bin/zmx" && \
codesign -v --verbose=2 "$APP/Contents/Resources/bin/zmx" && \
"$APP/Contents/Resources/bin/zmx" version && \
ls "$APP/Contents/Resources/licenses/zmx-LICENSE"
```
Expected: the binary exists, `codesign -v` reports it valid, `zmx version` prints a version, and the license file is present.

- [ ] **Step 5: Verify the running app resolves the bundled binary (not PATH)**

Add a one-off log at startup to confirm `ZmxLocator.isBundled == true` in the built app, OR run this check that greps the app's own resolution by launching and inspecting logs:
```bash
open "$APP" && sleep 4 && \
log show --predicate 'process == "seahelm"' --last 1m 2>/dev/null | grep -i "zmx" | tail -5; \
pkill -x seahelm
```
Expected: the app launches; any zmx-related log references the bundled Resources path. (If you added a temporary `NSLog("[ZmxLocator] bundled=\(isBundled) path=\(path() ?? "nil")")` at startup, confirm `bundled=true`, then remove it before committing.)

- [ ] **Step 6: Commit**

```bash
git add project.yml seahelm.xcodeproj Resources/licenses/zmx-LICENSE
git commit -m "build: embed and sign bundled zmx in the app, ship MIT license"
```

---

## Self-Review

**Spec coverage:**
- Seam (`ZmxLocator`, bundled-wins) → Task 1, wired in Task 2. ✓
- All zmx usage sites (attach/run/history/list/kill/version, commandExists) → Task 2. ✓
- Fetch-with-checksum, pinned, arm64-only, mismatch fails build → Task 4. ✓
- Embed + hardened-runtime sign + MIT license → Task 5. ✓
- Delete install-nag UX, keep version safety-net → Task 3. ✓
- No daemon / no protocol / tmux+local untouched → respected (Global Constraints; no such tasks). ✓

**Placeholder scan:** The only non-literal values are the real zmx release URL/SHA/version, which are *generated by a documented command* in Task 4 Step 1 and Task 5 Step 1 — not TBDs. No "add error handling"/"similar to" placeholders.

**Type consistency:** `ZmxLocator.executable()` (non-optional) is used at every ProcessRunner/ghostty call site; `ZmxLocator.isAvailable` at the two guard sites; `ZmxLocator.path()`/`isBundled` in verification. `bundledResourcePath()` expects `Resources/bin/zmx`, which Task 5's build phase produces. Consistent.
