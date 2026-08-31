import Foundation

public let powerHelperMachService = "com.densha.powerd"
public let powerHelperPlistName = "com.densha.powerd.plist"

@objc(DenshaPowerHelperCommands)
public protocol PowerHelperCommands {
    func setSleepDisabled(_ disabled: Bool, reply: @escaping @Sendable (Bool) -> Void)
}
