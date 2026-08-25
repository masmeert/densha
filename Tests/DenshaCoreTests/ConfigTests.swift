import Foundation
import Testing

@testable import DenshaCore

@Suite("Config")
struct ConfigTests {
    private func parse(_ toml: String) throws -> Config {
        try ConfigLoader.parse(Data(toml.utf8))
    }

    @Test("minimal service gets built-in defaults")
    func minimal() throws {
        let config = try parse(
            """
            [[service]]
            name = "web"
            cwd = "/tmp"
            command = "pnpm dev"
            """)
        let web = try #require(config.service(named: "web"))
        #expect(web.command == "pnpm dev")
        #expect(web.shellArgs == ["-lic"])
        #expect(web.stopTimeout == 5)
        #expect(web.restartGrace == 250)
        #expect(web.autostart == false)
        #expect(web.health == nil)
        #expect(web.port == nil)
    }

    @Test("argv runs the command through a shell rather than pre-splitting it")
    func argvUsesShell() throws {
        let config = try parse(
            """
            [[service]]
            name = "web"
            cwd = "/tmp"
            command = "pnpm dev && echo done"
            """)
        let web = try #require(config.service(named: "web"))
        #expect(web.argv.count == 3)
        #expect(web.argv[1] == "-lic")
        #expect(web.argv[2] == "pnpm dev && echo done")
    }

    @Test("per-service values win over [defaults], which win over built-ins")
    func resolutionOrder() throws {
        let config = try parse(
            """
            [defaults]
            stop_timeout = 9
            shell_args = ["-lc"]
            restart_grace = 10

            [[service]]
            name = "a"
            cwd = "/tmp"
            command = "x"

            [[service]]
            name = "b"
            cwd = "/tmp"
            command = "y"
            stop_timeout = 30
            """)
        let a = try #require(config.service(named: "a"))
        let b = try #require(config.service(named: "b"))
        #expect(a.stopTimeout == 9)
        #expect(b.stopTimeout == 30)
        #expect(a.shellArgs == ["-lc"])
        #expect(b.shellArgs == ["-lc"])
        #expect(a.restartGrace == 10)
    }

    @Test("tilde in cwd expands to the home directory")
    func tildeExpansion() throws {
        let config = try parse(
            """
            [[service]]
            name = "web"
            cwd = "~/code/foo"
            command = "x"
            """)
        let web = try #require(config.service(named: "web"))
        #expect(web.cwd == NSHomeDirectory() + "/code/foo")
        #expect(!web.cwd.contains("~"))
    }

    @Test("a missing cwd warns but still loads, so one stale repo cannot block the rest")
    func missingCwdIsAWarning() throws {
        let config = try parse(
            """
            [[service]]
            name = "web"
            cwd = "/definitely/not/here/at/all"
            command = "x"
            """)
        #expect(config.services.count == 1)
        #expect(config.warnings.count == 1)
        #expect(config.warnings[0].contains("cwd does not exist"))
    }

    @Test("duplicate names are rejected")
    func duplicateNames() {
        #expect(throws: ConfigError.self) {
            try parse(
                """
                [[service]]
                name = "web"
                cwd = "/tmp"
                command = "x"

                [[service]]
                name = "web"
                cwd = "/tmp"
                command = "y"
                """)
        }
    }

    @Test(
        "names that would be unsafe as filenames are rejected",
        arguments: [
            "we b", "../etc", "a/b", "we$b",
        ])
    func badNames(_ name: String) {
        #expect(throws: ConfigError.self) {
            try parse(
                """
                [[service]]
                name = "\(name)"
                cwd = "/tmp"
                command = "x"
                """)
        }
    }

    @Test("empty command is rejected")
    func emptyCommand() {
        #expect(throws: ConfigError.self) {
            try parse(
                """
                [[service]]
                name = "web"
                cwd = "/tmp"
                command = "   "
                """)
        }
    }

    @Test("a relative cwd is rejected rather than silently resolved")
    func relativeCwd() {
        #expect(throws: ConfigError.self) {
            try parse(
                """
                [[service]]
                name = "web"
                cwd = "code/foo"
                command = "x"
                """)
        }
    }

    @Test("no services at all is an error")
    func noServices() {
        #expect(throws: ConfigError.self) { try parse("[defaults]\nstop_timeout = 4\n") }
    }

    @Test("health falls back to the service port")
    func healthInheritsPort() throws {
        let config = try parse(
            """
            [[service]]
            name = "web"
            cwd = "/tmp"
            command = "x"
            port = 3000
            health = { type = "tcp" }
            """)
        let health = try #require(config.service(named: "web")?.health)
        #expect(health.kind == .tcp)
        #expect(health.port == 3000)
        #expect(health.interval == 2)
    }

    @Test("health with no port anywhere is an error")
    func healthNeedsAPort() {
        #expect(throws: ConfigError.self) {
            try parse(
                """
                [[service]]
                name = "web"
                cwd = "/tmp"
                command = "x"
                health = { type = "tcp" }
                """)
        }
    }

    @Test("unknown health type is an error")
    func badHealthType() {
        #expect(throws: ConfigError.self) {
            try parse(
                """
                [[service]]
                name = "web"
                cwd = "/tmp"
                command = "x"
                health = { type = "grpc", port = 1 }
                """)
        }
    }

    @Test("out-of-range port is an error")
    func badPort() {
        #expect(throws: ConfigError.self) {
            try parse(
                """
                [[service]]
                name = "web"
                cwd = "/tmp"
                command = "x"
                port = 99999
                """)
        }
    }

    @Test("malformed TOML reports a readable message, not a Swift type name")
    func syntaxError() {
        do {
            _ = try parse("[[service]\nname = ")
            Issue.record("expected a syntax error")
        } catch let error as ConfigError {
            #expect("\(error)".contains("not valid TOML"))
        } catch {
            Issue.record("wrong error type: \(error)")
        }
    }

    @Test("env and autostart round-trip")
    func envAndAutostart() throws {
        let config = try parse(
            """
            [[service]]
            name = "web"
            cwd = "/tmp"
            command = "x"
            autostart = true
            env = { NODE_ENV = "development", API = "http://localhost:8080" }
            """)
        let web = try #require(config.service(named: "web"))
        #expect(web.autostart)
        #expect(web.env["NODE_ENV"] == "development")
        #expect(web.env["API"] == "http://localhost:8080")
    }

    @Test("two services on one port load but warn, since only one can bind")
    func duplicatePortsWarn() throws {
        let config = try parse(
            """
            [[service]]
            name = "admin"
            cwd = "/tmp"
            command = "pnpm dev"
            port = 3000

            [[service]]
            name = "admin-legacy"
            cwd = "/tmp"
            command = "pnpm dev:legacy"
            port = 3000
            """)

        #expect(config.services.map(\.name) == ["admin", "admin-legacy"])
        #expect(
            config.warnings == [
                "services \"admin\" and \"admin-legacy\" both declare port 3000 "
                    + "— only one of them can run at a time"
            ])
    }

    @Test("port scanning is on by default and configurable")
    func scanRules() throws {
        let defaults = try parse(
            """
            [[service]]
            name = "web"
            cwd = "/tmp"
            command = "pnpm dev"
            """)
        #expect(defaults.scan == .default)
        #expect(defaults.scan.enabled)

        let tuned = try parse(
            """
            [scan]
            enabled = false
            ignore_ports = [15292, 15393]
            ignore_processes = ["OrbStack Helper"]

            [[service]]
            name = "web"
            cwd = "/tmp"
            command = "pnpm dev"
            """)
        #expect(!tuned.scan.enabled)
        #expect(tuned.scan.ignoredPorts == [15292, 15393])
        #expect(tuned.scan.ignores(port: 15393, processName: "node"))
        #expect(tuned.scan.ignores(port: 8080, processName: "OrbStack Helper"))
        #expect(!tuned.scan.ignores(port: 8080, processName: "node"))
    }

    @Test("an out-of-range ignored port is rejected")
    func scanRejectsImpossiblePort() throws {
        #expect(throws: ConfigError.self) {
            try parse(
                """
                [scan]
                ignore_ports = [70000]

                [[service]]
                name = "web"
                cwd = "/tmp"
                command = "pnpm dev"
                """)
        }
    }

    @Test("services in a project are qualified and inherit the project cwd")
    func projectsQualifyAndShareCwd() throws {
        let config = try parse(
            """
            [[project]]
            name = "storefront"
            cwd = "/tmp"

              [[project.service]]
              name = "web"
              command = "pnpm dev"
              port = 3000

              [[project.service]]
              name = "api"
              cwd = "nested"
              command = "go run ./cmd/api"
            """)

        #expect(config.services.map(\.name) == ["storefront/web", "storefront/api"])
        #expect(config.service(named: "storefront/web")?.cwd == "/tmp")
        #expect(config.service(named: "storefront/api")?.cwd == "/tmp/nested")
        #expect(config.service(named: "storefront/web")?.shortName == "web")
        #expect(config.service(named: "storefront/web")?.project == "storefront")
    }

    @Test("two projects may declare the same port without complaint")
    func projectsMayShareAPort() throws {
        let config = try parse(
            """
            [[project]]
            name = "storefront"
            cwd = "/tmp"

              [[project.service]]
              name = "web"
              command = "pnpm dev"
              port = 3000

            [[project]]
            name = "warehouse"
            cwd = "/tmp"

              [[project.service]]
              name = "web"
              command = "pnpm dev"
              port = 3000
            """)

        #expect(config.services.map(\.name) == ["storefront/web", "warehouse/web"])
        #expect(config.warnings.isEmpty)
    }

    @Test("one project claiming a port twice is still a mistake")
    func duplicatePortsInsideAProjectWarn() throws {
        let config = try parse(
            """
            [[project]]
            name = "storefront"
            cwd = "/tmp"

              [[project.service]]
              name = "web"
              command = "pnpm dev"
              port = 3000

              [[project.service]]
              name = "web-legacy"
              command = "pnpm dev:legacy"
              port = 3000
            """)

        #expect(
            config.warnings == [
                "services \"storefront/web\" and \"storefront/web-legacy\" both declare port 3000 "
                    + "— only one of them can run at a time"
            ])
    }

    @Test("a relative cwd needs a project to be relative to")
    func relativeCwdNeedsAProject() throws {
        #expect(throws: ConfigError.self) {
            try parse(
                """
                [[service]]
                name = "web"
                cwd = "code/web"
                command = "pnpm dev"
                """)
        }
    }

    @Test("a service in a project without any cwd is rejected")
    func cwdIsStillRequired() throws {
        #expect(throws: ConfigError.self) {
            try parse(
                """
                [[project]]
                name = "storefront"

                  [[project.service]]
                  name = "web"
                  command = "pnpm dev"
                """)
        }
    }

    @Test("a project cannot share its name with an ungrouped service")
    func projectAndServiceNamesCannotCollide() throws {
        #expect(throws: ConfigError.self) {
            try parse(
                """
                [[service]]
                name = "storefront"
                cwd = "/tmp"
                command = "pnpm dev"

                [[project]]
                name = "storefront"
                cwd = "/tmp"

                  [[project.service]]
                  name = "web"
                  command = "pnpm dev"
                """)
        }
    }

    @Test("two projects cannot share a name")
    func projectNamesAreUnique() throws {
        #expect(throws: ConfigError.self) {
            try parse(
                """
                [[project]]
                name = "storefront"
                cwd = "/tmp"

                  [[project.service]]
                  name = "web"
                  command = "pnpm dev"

                [[project]]
                name = "storefront"
                cwd = "/tmp"

                  [[project.service]]
                  name = "api"
                  command = "pnpm api"
                """)
        }
    }

    @Test("the shipped starter template is itself valid once uncommented")
    func templateIsValid() throws {
        #expect(throws: ConfigError.self) {
            try ConfigLoader.parse(Data(Template.starter.utf8))
        }
        let uncommented = Template.starter
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> String in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard trimmed.hasPrefix("# ") else { return String(line) }
                let body = trimmed.dropFirst(2).trimmingCharacters(in: .whitespaces)
                if body.contains("=") || body.hasPrefix("[[") { return body }
                return String(line)
            }
            .joined(separator: "\n")
        let config = try ConfigLoader.parse(Data(uncommented.utf8))

        #expect(
            config.services.map(\.name) == [
                "postgres", "storefront/web", "storefront/api", "warehouse/web",
            ])
        #expect(config.service(named: "storefront/api")?.stopTimeout == 15)
        #expect(config.service(named: "storefront/api")?.health?.kind == .http)
        #expect(config.service(named: "storefront/web")?.health?.port == 3000)
        #expect(
            config.service(named: "storefront/web")?.cwd == NSHomeDirectory() + "/code/storefront"
        )
        #expect(
            config.service(named: "storefront/api")?.cwd
                == NSHomeDirectory() + "/code/storefront-api"
        )
        #expect(config.service(named: "warehouse/web")?.port == 3000)
        #expect(config.warnings.allSatisfy { $0.contains("cwd does not exist") })
    }
}
