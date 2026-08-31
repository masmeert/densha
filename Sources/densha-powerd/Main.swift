import DenshaCore
import Foundation

final class PowerHelper: NSObject, PowerHelperCommands {
    func setSleepDisabled(_ disabled: Bool, reply: @escaping @Sendable (Bool) -> Void) {
        let pmset = Process()
        pmset.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        pmset.arguments = ["-a", "disablesleep", disabled ? "1" : "0"]
        do {
            try pmset.run()
            pmset.waitUntilExit()
            reply(pmset.terminationStatus == 0)
        } catch {
            reply(false)
        }
    }
}

final class PowerHelperListener: NSObject, NSXPCListenerDelegate {
    func listener(
        _ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection
    ) -> Bool {
        // ponytail: identifier-only requirement; pin the Team ID too once builds
        // are always Developer ID signed (ad-hoc dev builds have no Team ID).
        do {
            try connection.setCodeSigningRequirement("identifier \"com.densha.Densha\"")
        } catch {
            return false
        }
        connection.exportedInterface = NSXPCInterface(with: PowerHelperCommands.self)
        connection.exportedObject = PowerHelper()
        connection.resume()
        return true
    }
}

@main
struct PowerHelperDaemon {
    static func main() {
        let delegate = PowerHelperListener()
        let listener = NSXPCListener(machServiceName: powerHelperMachService)
        listener.delegate = delegate
        listener.resume()
        RunLoop.main.run()
    }
}
