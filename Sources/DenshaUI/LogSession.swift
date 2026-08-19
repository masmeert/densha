import Observation

@MainActor
@Observable
final class LogSession {
    private(set) var follower: LogFollower?
    @ObservationIgnored private let makeFollower: @MainActor (String) -> LogFollower

    init(makeFollower: @escaping @MainActor (String) -> LogFollower = LogFollower.init) {
        self.makeFollower = makeFollower
    }

    func select(_ service: String?) {
        guard follower?.service != service else { return }
        follower?.stop()
        guard let service else {
            follower = nil
            return
        }
        let follower = makeFollower(service)
        self.follower = follower
        follower.start()
    }

    func stop() {
        follower?.stop()
        follower = nil
    }
}
