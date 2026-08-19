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
        let config = try parse("""
            [[service]]
            name = "web"
            cwd = "/tmp"
            command = "pnpm dev"
            """)
        let web = try #require(config.service(named: "web"))
        #expect(web.command == "pnpm dev")
        #expect(web.shellArgs == ["-lc"])
        #expect(web.stopTimeout == 5)
        #expect(web.restartGrace == 250)
        #expect(web.autostart == false)
        #expect(web.health == nil)
        #expect(web.port == nil)
    }

    @Test("argv runs the command through a shell rather than pre-splitting it")
    func argvUsesShell() throws {
        let config = try parse("""
            [[service]]
            name = "web"
            cwd = "/tmp"
            command = "pnpm dev && echo done"
            """)
        let web = try #require(config.service(named: "web"))
        #expect(web.argv.count == 3)
        #expect(web.argv[1] == "-lc")
        // The whole command must arrive as one argument, or shell operators break.
        #expect(web.argv[2] == "pnpm dev && echo done")
    }

    @Test("per-service values win over [defaults], which win over built-ins")
    func resolutionOrder() throws {
        let config = try parse("""
            [defaults]
            stop_timeout = 9
            shell_args = ["-lic"]
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
        #expect(a.stopTimeout == 9)          // from [defaults]
        #expect(b.stopTimeout == 30)         // per-service override
        #expect(a.shellArgs == ["-lic"])     // [defaults] applies to all
        #expect(b.shellArgs == ["-lic"])
        #expect(a.restartGrace == 10)
    }

    @Test("tilde in cwd expands to the home directory")
    func tildeExpansion() throws {
        let config = try parse("""
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
        let config = try parse("""
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
            try parse("""
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

    @Test("names that would be unsafe as filenames are rejected", arguments: [
        "we b", "../etc", "a/b", "we$b",
    ])
    func badNames(_ name: String) {
        #expect(throws: ConfigError.self) {
            try parse("""
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
            try parse("""
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
            try parse("""
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
        let config = try parse("""
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
            try parse("""
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
            try parse("""
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
            try parse("""
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
        let config = try parse("""
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

    @Test("the shipped starter template is itself valid once uncommented")
    func templateIsValid() throws {
        // Every [[service]] in the template is commented out, so parsing it as-is must
        // fail for exactly one reason: there are no services.
        #expect(throws: ConfigError.self) {
            try ConfigLoader.parse(Data(Template.starter.utf8))
        }
        // Uncommenting must produce a working config — this catches typos in the
        // example a user is most likely to start from.
        let uncommented = Template.starter
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> String in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard trimmed.hasPrefix("# ") else { return String(line) }
                let body = trimmed.dropFirst(2)
                // Only uncomment config lines, not prose.
                if body.contains("=") || body.hasPrefix("[[") { return String(body) }
                return String(line)
            }
            .joined(separator: "\n")
        let config = try ConfigLoader.parse(Data(uncommented.utf8))
        #expect(config.services.map(\.name) == ["web", "api"])
        #expect(config.service(named: "api")?.stopTimeout == 15)
        #expect(config.service(named: "api")?.health?.kind == .http)
        #expect(config.service(named: "web")?.health?.port == 3000)
    }
}
