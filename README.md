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

Requires macOS 26 and Swift 6.2.

```sh
swift test
./Scripts/build-app.sh
open dist/Densha.app
```

Publish the assembled `dist/Densha.app` as a GitHub Release asset.
