#if DEBUG
    import DenshaCore
    import SwiftUI

    enum Sample {
        static let web = ServiceStatus(
            name: "storefront/admin", state: .running, pid: 4211, pgid: 4211, port: 3000,
            startedAt: Date().timeIntervalSince1970 - 184, health: .passing,
            command: "npm run dev -w apps/admin", cwd: "/Users/you/work/storefront")

        static let native = ServiceStatus(
            name: "storefront/native", state: .starting, pid: 4212, pgid: 4212, port: 8081,
            startedAt: Date().timeIntervalSince1970 - 6, health: .pending,
            command: "npm run dev -w apps/native", cwd: "/Users/you/work/storefront")

        static let api = ServiceStatus(
            name: "storefront/api", state: .unhealthy, pid: 4213, pgid: 4213, port: 5040,
            startedAt: Date().timeIntervalSince1970 - 42, health: .failing,
            command: "dotnet run --project src/Api", cwd: "/Users/you/work/storefront-api")

        static let worker = ServiceStatus(
            name: "storefront/worker", state: .stopped, command: "npm run worker",
            cwd: "/Users/you/work/storefront")

        static let otherWeb = ServiceStatus(
            name: "warehouse/web", state: .failed, port: 3000, exitCode: 1,
            command: "pnpm dev", cwd: "/Users/you/work/warehouse")

        static let postgres = ServiceStatus(
            name: "postgres", state: .running, pid: 4290, pgid: 4290, port: 5432,
            startedAt: Date().timeIntervalSince1970 - 5400, health: .passing,
            command: "postgres -D /opt/homebrew/var/postgresql@16", cwd: "/Users/you")

        static let all = [postgres, web, native, api, worker, otherWeb]

        static let scannedPorts: [ScannedPort] = [
            ScannedPort(
                port: 3000, pid: 4288, processName: "node", conflictsWith: "storefront/admin"),
            ScannedPort(port: 5432, pid: 4290, processName: "postgres"),
            ScannedPort(port: 6379, pid: 4301, processName: "redis-server"),
            ScannedPort(port: 8787, pid: 4377, processName: "node"),
        ]

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
            lastError: String? = nil,
            scannedPorts: [ScannedPort] = [],
            serviceEditor: ServiceEditorRequest? = nil
        ) -> AppModel {
            let model = AppModel(
                daemon: PreviewDaemonService(), applicationActions: PreviewApplicationActions())
            model.services = services
            model.scannedPorts = scannedPorts
            model.link = link
            model.warnings = warnings
            model.lastError = lastError
            model.serviceEditor = serviceEditor
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
        func chooseFolder(startingAt path: String?) -> URL? { nil }
        func open(_ url: URL) {}
        func copyToClipboard(_ text: String) {}
        func saveLogFile(for service: String) throws {}
    }
#endif
