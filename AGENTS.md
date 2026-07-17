# Repository Guidelines

## Project Structure & Module Organization

Seahelm is a native macOS app generated with XcodeGen from `project.yml`. Application code lives in `Sources/`, organized by responsibility: `App/` for coordinators, `Core/` for shared models and services, `Git/`, `Status/`, `Terminal/`, `Update/`, `Usage/`, and `UI/` for AppKit views and controllers. Keep feature UI in subdirectories such as `UI/Dashboard`, `UI/SidePanel`, and `UI/Split`.

Unit tests live in `Tests/`. UI tests live in `UITests/`, with page objects in `UITests/Pages` and helpers in `UITests/Helpers`. Assets and bundled resources are under `Assets.xcassets` and `Resources/`; release and setup automation is under `scripts/`.

## Build, Test, and Development Commands

- `scripts/setup.sh`: initializes Ghostty, builds or reuses `GhosttyKit.xcframework`, and prepares bundled resources.
- `xcodegen generate`: regenerates `seahelm.xcodeproj` from `project.yml` after target, dependency, or layout changes.
- `xcodebuild -project seahelm.xcodeproj -scheme seahelm -configuration Debug -skipPackagePluginValidation -skipMacroValidation build`: builds the app locally.
- `./run.sh`: builds into `.build/`, stops any running Seahelm instance, and launches the debug app.
- `./run_ui_tests.sh [TestClass]`: regenerates the project if possible and runs UI tests, optionally filtered.
- `./scripts/package_release.sh`: creates the current-machine release package in `dist/`.

## Coding Style & Naming Conventions

Use Swift 5.10 and target macOS 14.0. Follow AppKit-style naming: types in `PascalCase`, functions and properties in `camelCase`, and test files named after the behavior or type under test, such as `SessionManagerTests.swift`. Group code by feature directory rather than adding broad utility files. Preserve the lowercase target and module name `seahelm`; `PRODUCT_NAME` is intentionally `Seahelm`.

## Testing Guidelines

Add focused unit tests in `Tests/` for model, parser, coordinator, and service behavior. Add UI coverage in `UITests/Tests` when changing flows, panes, navigation, dialogs, or status surfaces. Prefer deterministic tests and reuse helpers/page objects instead of duplicating XCUI queries.

## Commit & Pull Request Guidelines

Git history uses concise Conventional Commit-style prefixes such as `feat:`, `fix:`, `ci:`, and `chore:`. Keep subjects imperative and specific, for example `fix: use a unique identifier per notification`. Pull requests should describe the user-visible change, list validation, link issues, and include screenshots or recordings for UI changes. Note release-impacting changes such as version updates in `project.yml`, signing, bundled resources, or packaging scripts.

## Security & Configuration Tips

Do not commit signing certificates, Apple credentials, generated archives, or local build outputs. Keep release secrets in GitHub Actions configuration, not in the repository. Treat `GhosttyKit.xcframework`, `.build/`, and `dist/` as generated artifacts unless a maintainer explicitly asks otherwise.
