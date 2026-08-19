#if DEBUG
    import DenshaCore
    import SwiftUI

    enum Sample {
        static let web = ServiceStatus(
            name: "admin", state: .running, pid: 4211, pgid: 4211, port: 3000,
            startedAt: Date().timeIntervalSince1970 - 184, health: .passing,
            command: "npm run dev -w apps/admin", cwd: "/Users/you/work/apmoove")

        static let native = ServiceStatus(
            name: "native", state: .starting, pid: 4212, pgid: 4212, port: 8081,
            startedAt: Date().timeIntervalSince1970 - 6, health: .pending,
            command: "npm run dev -w apps/native", cwd: "/Users/you/work/apmoove")

        static let api = ServiceStatus(
            name: "api", state: .unhealthy, pid: 4213, pgid: 4213, port: 5040,
            startedAt: Date().timeIntervalSince1970 - 42, health: .failing,
            command: "dotnet run --project src/Api", cwd: "/Users/you/work/apmoove-api")

        static let worker = ServiceStatus(
            name: "worker", state: .stopped, command: "npm run worker",
            cwd: "/Users/you/work/apmoove")

        static let broken = ServiceStatus(
            name: "caisse", state: .failed, exitCode: 1,
            command: "npm run dev -w apps/caisse", cwd: "/Users/you/work/apmoove")

        static let all = [web, native, api, worker, broken]

        static let logLines: [LogLine] = [
            LogLine(seq: 1, ts: Date().timeIntervalSince1970 - 9, text: "> vite"),
            LogLine(
                seq: 2, ts: Date().timeIntervalSince1970 - 8,
                text: "  \u{1B}[32mVITE v8.1.5\u{1B}[0m  \u{1B}[2mready in 957 ms\u{1B}[0m"),
            LogLine(
                seq: 3, ts: Date().timeIntervalSince1970 - 8,
                text: "  \u{1B}[32m➜\u{1B}[0m  Local:   \u{1B}[36mhttp://localhost:3000/\u{1B}[0m"),
            LogLine(
                seq: 4, ts: Date().timeIntervalSince1970 - 3,
                text: "\u{1B}[38;5;208m[hmr]\u{1B}[0m update /src/routes/index.tsx"),
            LogLine(
                seq: 5, ts: Date().timeIntervalSince1970 - 1,
                text:
                    "\u{1B}[1;31merror\u{1B}[0m  \u{1B}[38;2;255;128;0mTS2304\u{1B}[0m: Cannot find name 'foo'"
            ),
        ]
    }

    @MainActor
    extension AppModel {
        static func preview(
            services: [ServiceStatus] = Sample.all,
            link: LinkState = .connected,
            warnings: [String] = [],
            lastError: String? = nil
        ) -> AppModel {
            let model = AppModel(
                daemon: PreviewDaemonService(), applicationActions: PreviewApplicationActions())
            model.services = services
            model.link = link
            model.warnings = warnings
            model.lastError = lastError
            return model
        }
    }

    private final class PreviewDaemonService: DaemonServing {
        func events() -> AsyncStream<LinkEvent> {
            AsyncStream { $0.finish() }
        }

        func run(_ command: DaemonCommand) async throws -> Response {
            Response(id: 0, ok: true)
        }

        func stop() {}
    }

    private final class PreviewApplicationActions: ApplicationActions {
        func revealInFinder(path: String) {}
        func openConfig() throws {}
    }
#endif
