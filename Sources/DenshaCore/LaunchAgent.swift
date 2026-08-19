import Foundation

public enum LaunchAgent {
    public static let label = "com.densha.denshad"

    public static var plistURL: URL {
        Paths.home.appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    public static func plist(daemonPath: String) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
        \t<key>Label</key>
        \t<string>\(label)</string>
        \t<key>ProgramArguments</key>
        \t<array>
        \t\t<string>\(daemonPath)</string>
        \t</array>
        \t<key>RunAtLoad</key>
        \t<true/>
        \t<!-- Restart only after a crash. A plain `true` here would fight
        \t     `densha daemon stop`, relaunching the daemon the moment it exits. -->
        \t<key>KeepAlive</key>
        \t<dict>
        \t\t<key>SuccessfulExit</key>
        \t\t<false/>
        \t</dict>
        \t<key>StandardOutPath</key>
        \t<string>\(Paths.daemonLog.path)</string>
        \t<key>StandardErrorPath</key>
        \t<string>\(Paths.daemonLog.path)</string>
        \t<!-- Interactive keeps launchd from throttling CPU for the dev servers'
        \t     supervisor the way it would for a background job. -->
        \t<key>ProcessType</key>
        \t<string>Interactive</string>
        </dict>
        </plist>
        """
    }

    public static func resolveDaemonPath() throws -> String {
        guard
            let path = DaemonClient.daemonCandidates().first(where: {
                FileManager.default.isExecutableFile(atPath: $0)
            })
        else {
            throw DenshaError.daemonUnreachable("cannot find denshad to install")
        }
        return URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    }

    public static func install() throws -> String {
        let daemonPath = try resolveDaemonPath()
        try FileManager.default.createDirectory(
            at: plistURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try plist(daemonPath: daemonPath).write(to: plistURL, atomically: true, encoding: .utf8)

        _ = run("/bin/launchctl", ["bootout", "gui/\(getuid())/\(label)"])
        let result = run("/bin/launchctl", ["bootstrap", "gui/\(getuid())", plistURL.path])
        guard result.status == 0 else {
            throw DenshaError.daemonUnreachable(
                "launchctl bootstrap failed: \(result.output.isEmpty ? "status \(result.status)" : result.output)"
            )
        }
        return daemonPath
    }

    public static func uninstall() throws {
        _ = run("/bin/launchctl", ["bootout", "gui/\(getuid())/\(label)"])
        try? FileManager.default.removeItem(at: plistURL)
    }

    public static var isInstalled: Bool {
        FileManager.default.fileExists(atPath: plistURL.path)
    }

    @discardableResult
    static func run(_ path: String, _ arguments: [String]) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            return (-1, "\(error)")
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (
            process.terminationStatus,
            String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }
}

public enum CLIInstaller {
    public static let preferredDirectories = [
        "/usr/local/bin", Paths.home.appendingPathComponent(".local/bin").path,
    ]

    public static func currentExecutable() -> String {
        Bundle.main.executableURL?.resolvingSymlinksInPath().path
            ?? ProcessInfo.processInfo.arguments[0]
    }

    public static func install(source: String) throws -> String {
        for directory in preferredDirectories {
            var isDir: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: directory, isDirectory: &isDir)
            if !exists {
                guard directory.hasPrefix(Paths.home.path) else { continue }
                try? FileManager.default.createDirectory(
                    atPath: directory, withIntermediateDirectories: true)
            }
            guard FileManager.default.isWritableFile(atPath: directory) else { continue }

            let target = directory + "/densha"
            try? FileManager.default.removeItem(atPath: target)
            try FileManager.default.createSymbolicLink(atPath: target, withDestinationPath: source)
            return target
        }
        throw DenshaError.daemonUnreachable(
            """
            no writable directory on PATH. Run this instead:
              sudo ln -sf "\(source)" /usr/local/bin/densha
            """)
    }
}
