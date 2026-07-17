# Auto Update Download Design

## Goal

When Seahelm detects a newer GitHub Release, it automatically downloads and prepares the update, then asks the user to restart to install it.

## Scope

- Keep GitHub Releases as the update source.
- Keep the existing banner UI and skip/retry/restart affordances.
- Change the default found-update flow from "show Update button" to "start downloading immediately".
- Do not auto-restart the app.
- Do not replace Sparkle or add a new updater dependency.

## Behavior

- Periodic checks run when `auto_update.enabled` is true.
- If the latest release is newer and does not equal `skippedVersion`, Seahelm stores it as `pendingRelease`, shows download progress, and starts downloading.
- After extraction and signature verification, the banner shows `Restart Now`.
- If download/preparation fails, the banner shows `Retry` and `Skip`; retry downloads the same pending release again.
- Manual checks reuse the same auto-download path when an update exists; if none exists, Seahelm shows the existing up-to-date alert.

## Safety

- Installation still requires explicit user action via `Restart Now`.
- Skipped versions suppress automatic downloads.
- Concurrent duplicate downloads for the same detected release are avoided.
