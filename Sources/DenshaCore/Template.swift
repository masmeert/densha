import Foundation

public enum Template {
    public static let starter = """
        # Densha — services.toml
        #
        # Each [[service]] becomes a row in the menubar. Only name, cwd and command are
        # required; everything else has a sensible default.

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

        # [[service]]
        # name = "web"
        # cwd = "~/code/foo"
        # command = "pnpm dev"
        # port = 3000
        # # Start automatically when the daemon starts (i.e. at login):
        # autostart = false
        # env = { NODE_ENV = "development" }
        # # Optional readiness probe; drives the colour of the dot.
        # health = { type = "tcp", port = 3000 }

        # [[service]]
        # name = "api"
        # cwd = "~/code/foo"
        # command = "go run ./cmd/api"
        # port = 8080
        # stop_timeout = 15
        # health = { type = "http", port = 8080, path = "/healthz" }

        """
}
