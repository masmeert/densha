import Foundation

public enum Template {
    public static let starter = """
        # Densha — services.toml
        #
        # A service is one process: name, cwd and command are required, everything else
        # has a sensible default. Group services into a [[project]] when they belong to
        # the same codebase — a project starts and stops as a unit, and two projects may
        # declare the same port (only one of them runs at a time).

        [defaults]
        # Commands run through a login shell so that PATH and version managers
        # (mise, nvm, fnm, asdf) are set up the way they are in your terminal.
        #
        # If a service reports "command not found" but works in your terminal, your
        # version manager is probably initialised in ~/.zshrc, which zsh only reads for
        # *interactive* shells. Switch this to ["-lic"] in that case.
        shell_args = ["-lc"]

        # Seconds to wait after SIGTERM before resorting to SIGKILL.
        stop_timeout = 5

        # Ports that are listening on this Mac but owned by none of your running
        # services show up under "Other ports" in the menubar — including a port a
        # service below declares while another process holds it. Hide the noise:
        #
        # [scan]
        # enabled = true
        # ignore_ports = [15292]
        # ignore_processes = ["OrbStack Helper"]

        # [[project]]
        # name = "storefront"
        # # Services may give a cwd relative to this one, or inherit it entirely.
        # cwd = "~/code/storefront"
        #
        #   [[project.service]]
        #   name = "web"
        #   command = "pnpm dev"
        #   port = 3000
        #   # Start automatically when the daemon starts (i.e. at login):
        #   autostart = false
        #   env = { NODE_ENV = "development" }
        #   # Optional readiness probe; drives the colour of the dot.
        #   health = { type = "tcp", port = 3000 }
        #
        #   [[project.service]]
        #   name = "api"
        #   cwd = "../storefront-api"
        #   command = "go run ./cmd/api"
        #   port = 8080
        #   stop_timeout = 15
        #   health = { type = "http", port = 8080, path = "/healthz" }

        # A second project is free to reuse port 3000 — `densha start warehouse` stops
        # whatever holds it first. Refer to these as warehouse/web and storefront/web.
        #
        # [[project]]
        # name = "warehouse"
        # cwd = "~/code/warehouse"
        #
        #   [[project.service]]
        #   name = "web"
        #   command = "pnpm dev"
        #   port = 3000

        # Services outside any project still work, and keep their bare name.
        #
        # [[service]]
        # name = "postgres"
        # cwd = "~/code"
        # command = "postgres -D /opt/homebrew/var/postgresql@16"
        # port = 5432

        """
}
