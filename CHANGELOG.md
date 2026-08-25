# Changelog

## 0.4.2 — 2026-08-25

### Fixed
- Killing an unclaimed port no longer stalls on a second machine-wide socket scan; Densha revalidates the displayed process directly and updates its cached port list when the listener exits.
- `make run` now restarts the background daemon, so a rebuilt app cannot silently keep testing an older helper process.

## 0.4.1 — 2026-08-22

### Changed
- A repo-wide cleanup removed some 280 lines of dead code, single-use wrappers, and hand-rolled machinery the platform already ships — among it the log window's custom follow-scroll, now handed to SwiftUI, and a duplicated connection lock, now one shared primitive. Nothing changes in how Densha looks or behaves; the app is simply smaller.

## 0.4.0 — 2026-08-20

### Highlights
- **Services can be added without leaving the app**: point Densha at the folder a service runs in and it writes the entry into services.toml, taking the project name from the folder — its package.json name, its git remote, or the folder itself. Editing a service and revealing it in Finder live on its right-click menu.
- **Take a port back**: a port under "Other ports" can be killed from the menu bar or with `densha kill <port>`, which is the quickest way to hand a port back to the service that wants it.

### Added
- Services can be added from the menu bar with **+**: pick the folder a service runs in and Densha writes the entry into services.toml, comments and all. The project is taken from the folder — its package.json name, its git remote, or the folder itself — and created on the spot if it does not exist yet, or picked from the projects already configured. A package.json dev script is offered as the command.
- Right-click a service for "Edit Service…" and "Reveal in Finder". Editing rewrites the entry where it stands; moving a service to another project takes its old project with it when it was the last one there.
- A port under "Other ports" can be freed from the menu bar: hovering it turns up the same stop button the services have, which goes red and waits for a second click, and right-clicking offers the same. Densha sends SIGTERM to the process listening on that port, follows with SIGKILL if it holds on, and refuses the moment the port turns out to belong to a service it supervises.
- `densha kill <port>` frees a port from the terminal, with or without the leading colon that `densha ports` prints.

### Changed
- Projects and "Other ports" now share one section header, so their disclosure arrows, titles and counts line up with the service rows underneath, and every gap between sections is the same.
- Unclaimed ports gained the copy button the service rows have, which also lines their port signs up with the ones above.
- Every action in the panel now falls in one of two columns: the header's **+** and **⋯**, a project's play and stop, a service's restart and stop, and a port's copy and stop all line up, and the port signs beside them do too. Opening an unclaimed port lives on the row itself and in its right-click menu, which is what freed the column up.

## 0.3.2 — 2026-08-19

### Added
- Projects fold away: click a group header to collapse it, and it stays folded across launches. A collapsed project keeps its service count and shows the most restrictive signal among its members, so a failure cannot hide behind a fold.

### Changed
- Service status is now a three-aspect railway signal rather than a coloured dot, so state reads from lamp position as well as colour.
- Ports are shown as platform signs, and roll to the new number when a port changes.

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
