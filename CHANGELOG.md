# Changelog

## 0.3.1 — 2026-08-19

### Added
- Densha is now MIT licensed.
- The app bundles its own license and the notices for every third-party component it ships, satisfying the attribution terms of Sparkle, TOMLDecoder, and swift-argument-parser.

## 0.3.0 — 2026-08-19

### Highlights
- **Densha updates itself**: the app ships Sparkle and checks a signed appcast, so a new version arrives without a manual download. "Check for Updates…" also lives in the menu.
- **Services group by project**: the menu lists services under the project that defines them, and surfaces ports in use that no service claims.

### Added
- Added self-updating through Sparkle, with an EdDSA-signed appcast and a "Check for Updates…" menu item.
- Added project grouping to the menu, with unclaimed listening ports shown separately and collapsed by default.
- Added a "Densha on GitHub" menu item beside "Check for Updates…".

### Changed
- Trimmed the readme and renamed the example project.

### Fixed
- Fixed release builds defaulting to the host architecture, which could publish an Apple-Silicon-only app that excluded Intel Macs.

### Internal
- Version now comes from a single `version.env`, with `Info.plist` generated at build time and a monotonic build number.
- Added a launch smoke test that runs the packaged app with the build checkout unreadable, covering resource, helper, and framework resolution.
- Release builds archive dSYMs and verify their UUIDs match the shipped binaries, so crash reports can be symbolicated.
- Zipping strips extended attributes and uses `ditto --norsrc`, so a downloaded bundle no longer risks broken code sealing from AppleDouble files.
- Notarization accepts an App Store Connect API key, and moved out of the Makefile into `Scripts/`.
- CI pins Xcode, caches SwiftPM builds, pins actions by digest, and bounds every job with a timeout.

## 0.2.1 — 2026-08-19

### Changed
- Paused the liquid glass UI experiment and returned to the previous chrome.

## 0.2.0 — 2026-08-19

### Highlights
- **Native macOS chrome**: the menu panel adopts standard system styling.
- **Logs you can keep**: copy a transcript or download it to a file.

### Added
- Added copy and download actions for service logs.

### Changed
- Adopted native macOS chrome and refined the menu panel layout.

### Fixed
- Fixed log downloads to carry a timestamp.
- Fixed port numbers rendering with thousands separators.

### Internal
- Strengthened the boundaries between the core, daemon, and UI modules.

## 0.1.1 — 2026-08-19

### Fixed
- Fixed signing diagnostics reporting as authoritative when they were only advisory.

### Internal
- Added a `make release` target.
- CI now fails fast on invalid signing or notary credentials.

## 0.1.0 — 2026-08-19

### Highlights
- **First release**: run your dev servers without keeping a terminal open, driven from a menu bar app, a background daemon, and the `densha` CLI.

### Added
- Added the menu bar app, the `denshad` daemon, and the `densha` command line interface.
- Added an app icon, SwiftUI previews, a Makefile, and a signing and release pipeline.
