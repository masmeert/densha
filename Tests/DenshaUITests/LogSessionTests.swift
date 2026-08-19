import Testing

@testable import DenshaUI

@MainActor
@Suite("LogSession")
struct LogSessionTests {
    @Test("selecting a service stops the previous follower")
    func selectingServiceStopsPreviousFollower() {
        var followers: [RecordingLogFollower] = []
        let session = LogSession { service in
            let follower = RecordingLogFollower(service: service)
            followers.append(follower)
            return follower
        }

        session.select("web")
        session.select("api")

        #expect(followers.count == 2)
        #expect(followers[0].startCount == 1)
        #expect(followers[0].stopCount == 1)
        #expect(followers[1].startCount == 1)
        #expect(followers[1].stopCount == 0)

        session.stop()

        #expect(followers[1].stopCount == 1)
        #expect(session.follower == nil)
    }
}

@MainActor
private final class RecordingLogFollower: LogFollower {
    var startCount = 0
    var stopCount = 0

    override func start() {
        startCount += 1
    }

    override func stop() {
        stopCount += 1
    }
}
