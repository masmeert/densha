# Changelog

## Unreleased

### Fixed
- **Keep Mac awake** now keeps the display on instead of only keeping the CPU awake. It was taking an assertion that let the screen black out and lock on the idle timer, so the Mac looked asleep while the switch was on.
- Picking a **Move cursor** interval no longer does nothing on a Mac that has not granted Densha accessibility access. The interval is kept and the panel points at the Accessibility settings that are still missing, instead of silently snapping back to "Off".
- A service that writes a lot of output no longer freezes the app. New lines are batched instead of redrawing the window for each one, and the transcript now only draws the lines you can see. The log view also gains Cmd+F find.

## 0.8.1 — 2026-08-31

### Fixed
- Cursor movement intervals now repeat until turned off instead of stopping after the selected number of minutes.

## 0.8.0 — 2026-08-31

### Added
- **Move cursor** nudges the pointer every 30 seconds for 1, 2, 3, or 5 minutes, with a live countdown and automatic permission request.

### Fixed
- Log transcripts now allow selecting multiple lines at once.

## 0.7.0 — 2026-08-31

### Added
- A **Power** tab joins Services in the menu bar panel, a home for power-user tools. It ships with two: keeping the Mac awake and keeping it awake with the lid closed.
- **Keep Mac awake** does what `caffeinate` does, with a mode picker: off, while services run, for 30 minutes, 1 hour or 3 hours (with a live countdown), or until turned off. "While services run" holds the Mac awake only while something is in service and survives relaunches. While any of it is active, a small cup joins the tram in the menu bar so an override is never left on unnoticed.
- **Stay awake with lid closed** flips the system-wide `pmset disablesleep` setting. It goes through a small privileged helper that is approved once in System Settings → Login Items; until then the toggle falls back to asking for an admin password. The setting is read back from the system, so the toggle shows the truth even after a relaunch or when changed elsewhere.

### Changed
- Adding a service moved from the header **+** into the footer next to "Stop all", so the actions that belong to services show only on the Services tab.

## 0.6.0 — 2026-08-27

### Added
- A project header now carries a restart button next to its start and stop buttons, the same one the service rows have. It restarts every service in the project that is currently running and leaves the stopped ones alone.

## 0.5.1 — 2026-08-25

### Changed
- Services now run through an interactive login shell (`shell_args = ["-lic"]`) rather than a login shell alone, so node, python and their version managers resolve the way they do in your terminal — nvm, fnm, volta, mise and asdf are initialised in ~/.zshrc, which a non-interactive shell never reads. A service that reported "command not found" while the same command worked in the terminal now starts. Set `shell_args = ["-lc"]` under `[defaults]` to keep the old behaviour, which is worth doing if your shell startup greets interactive shells with a banner.

## 0.5.0 — 2026-08-25

### Added
- A port under "Other ports" can be adopted as a service with a single click: Densha reads the working directory of the process holding the port, takes the project name and dev command from it the same way the **+** flow does, and opens the service editor with the folder, project and port already filled in. The project is picked from the ones already configured when it matches, and offered as a new one when it does not.

### Changed
- Opening an unclaimed port in the browser now lives only in its right-click menu, since the row itself adds the port as a service.

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
