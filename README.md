# Densha

A macOS menu bar app for running your local development services. Start, stop, check
status, and view logs without keeping a terminal window open.

Services are supervised by a background daemon, so they keep running when the app is
closed or updated.

## Install

Download the latest `Densha.app` from [GitHub Releases](../../releases), move it to
`/Applications`, and open it.

Optionally install the CLI and create a starter configuration:

```sh
/Applications/Densha.app/Contents/Helpers/densha install-cli
densha init
```

## Configuration

Create or edit `~/.config/densha/services.toml`:

```toml
[[service]]
name = "web"
cwd = "~/my-project"
command = "npm run dev"
port = 3000
health = { type = "tcp", port = 3000 }
```

Reload changes from the menu bar or with `densha reload`.

## CLI

```sh
densha start web
densha stop --all
densha logs web -f
densha status --json
```

## Development

Requires macOS 26 and Swift 6.2. There is no Xcode project — SwiftPM is the source of
truth. Run `make` for the full target list.

```sh
make build      # ~1s
make test       # 54 tests, ~0.5s warm
make lint       # swift-format, configured in .swift-format
make run        # rebuild (debug) and relaunch the app
make xcode      # open Package.swift in Xcode, for SwiftUI previews
```

### Pre-commit formatting

Install [mise](https://mise.jdx.dev/) once with `brew install mise`, then run:

```sh
make hooks
```

This installs the pinned Python and pre-commit versions from `mise.toml`, then installs
the repository-local Git hook. At commit time it runs `swift format --in-place` only on
staged Swift files. If formatting changes a file, the commit stops so you can review and
stage that change. The hook never runs as part of an Xcode build.

Run `make hook-check` to apply the same formatter to every tracked Swift file, or
`make fmt` to format all source and test files directly.

`make run` restarts only the GUI. Your services keep running, because the daemon
outlives the app — which is the point.

Views live in the `DenshaUI` library rather than in the `DenshaApp` executable, because
Xcode previews are reliable for library targets and flaky for SwiftPM executables.
`Sources/DenshaUI/PreviewSupport.swift` holds sample data covering every service state
plus the empty, daemon-down and warning cases. Previews never open a socket — otherwise
rendering the log window would spawn a real daemon.

`make icon` regenerates `Resources/Densha.icns` (committed, so a normal build renders
nothing) from the same `tram.fill` symbol the menu bar uses.

## Releases

`make app` assembles `dist/Densha.app`, ad-hoc signed with the hardened runtime and
signed inside-out (helpers first, then the bundle — Apple discourages `--deep`).

Ad-hoc is fine on the machine that built it, but **Gatekeeper rejects ad-hoc builds
that were downloaded**, so a Release asset has to be notarized. That needs a *Developer
ID Application* certificate; an "Apple Development" certificate cannot notarize.

`make signing` reports which certificates and credentials this machine has, and prints
the one-time setup if the Developer ID certificate is missing. Once it is present,
`make notarize` finds it automatically — no identity string to paste:

```sh
NOTARY_PROFILE=densha make notarize   # builds, signs, submits, staples
make verify-release                   # hard gate: notarized, stapled, accepted
```

The stapled ticket lives inside the bundle, so it is destroyed by the next `make app`.
Only `make notarize` produces a shippable build; `make sign-check` tells you which one
you are holding.

### Automated releases

Tagging publishes a notarized universal build to GitHub Releases:

```sh
# bump the version in Sources/densha/CLI.swift first — the workflow refuses to
# release a binary whose --version disagrees with the tag
git tag v0.1.1 && git push --tags
```

`.github/workflows/release.yml` builds universal (arm64 + x86_64), signs with the
Developer ID, notarizes, staples, re-zips, verifies Gatekeeper actually accepts the
result, and only then creates the release. It needs four repository secrets:

| Secret | What |
| --- | --- |
| `APPLE_CERT_P12_BASE64` | `base64` of the Developer ID Application identity exported as `.p12` |
| `APPLE_CERT_PASSWORD` | the password used when exporting that `.p12` |
| `NOTARY_APPLE_ID` | Apple ID of the developer account |
| `NOTARY_PASSWORD` | an app-specific password from appleid.apple.com |
| `NOTARY_TEAM_ID` | the team id — the certificate's `OU`, which `make signing` prints |

Export the identity from Keychain Access (right-click the *Developer ID Application*
certificate → Export → `.p12`), then:

```sh
base64 -i Densha.p12 | pbcopy
```

For CI that runs often, consider an App Store Connect API key instead of an
app-specific password: the password is tied to a personal Apple ID and is revoked
whenever that account's password changes, which would break releases at a bad moment.

`make notarize` leaves `dist/Densha.zip` ready to attach to the release.
