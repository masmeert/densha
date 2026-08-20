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

Add a service from the menu bar with **+**: choose the folder it runs in and Densha
names the project after it — the `name` in its `package.json`, its git remote, or the
folder itself — creating that project if it is new, or drop it into one you already
have. Right-click a service to edit it. Everything lands in
`~/.config/densha/services.toml`, which you are free to edit by hand:

```toml
[[project]]
name = "storefront"
cwd = "~/code/storefront"

  [[project.service]]
  name = "web"
  command = "pnpm dev"
  port = 3000
  health = { type = "tcp", port = 3000 }

  [[project.service]]
  name = "api"
  cwd = "../storefront-api"  # relative to the project cwd
  command = "go run ./cmd/api"
  port = 8080
```

Reload changes from the menu bar or with `densha reload`.

A project groups the services of one codebase and starts and stops as a unit. Its
services are named `project/service`, so two projects may declare the same port — the
usual case being several Vite apps that all want `:3000`. Starting one stops whichever
live service already holds a port it needs. Top-level `[[service]]` entries stay
ungrouped and keep their bare name.

The menu bar also lists **Other ports**: processes holding a local port that none of
your running services owns. Hover one to copy or open its address, or to kill whatever
holds it — the ✕ goes red and takes a second click. Densha sends SIGTERM and follows
with SIGKILL if the process holds on. Tune what shows up with:

```toml
[scan]
enabled = true
ignore_ports = [15292]
ignore_processes = ["OrbStack Helper"]
```

## CLI

```sh
densha start storefront        # a whole project
densha restart storefront/web  # one service
densha stop --all
densha logs web -f
densha status --json
densha ports
densha kill :3000              # free a port a foreign process holds
```

## Development

Requires macOS 26 and Swift 6.2. SwiftPM is the source of truth — there is no Xcode
project. Run `make` for the full target list.

```sh
make build      # ~1s
make test       # 104 tests, ~2s warm
make lint       # swift-format, configured in .swift-format
make run        # rebuild (debug) and relaunch the app
```

## License

MIT — see [LICENSE](LICENSE). Densha bundles Sparkle, TOMLDecoder, and swift-argument-parser; their notices ship inside the app and are listed in `Contents/Resources/ThirdPartyLicenses.txt`.
