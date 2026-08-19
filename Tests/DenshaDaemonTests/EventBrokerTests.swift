import DenshaCore
import Testing

@testable import DenshaDaemon

@Suite("EventBroker")
struct EventBrokerTests {
    @Test("status and log subscriptions receive only matching events")
    func subscriptionsReceiveMatchingEvents() async {
        var broker = EventBroker()
        let (_, statusStream) = broker.subscribe(status: true, logFilter: nil)
        let (_, logStream) = broker.subscribe(status: false, logFilter: "web")
        let service = ServiceStatus(name: "web", state: .running)
        let line = LogLine(seq: 1, ts: 0, text: "ready")
        var statusIterator = statusStream.makeAsyncIterator()
        var logIterator = logStream.makeAsyncIterator()

        broker.broadcast(.status([service]))
        broker.broadcastLog(name: "api", line: line)
        broker.broadcastLog(name: "web", line: line)

        #expect(await statusIterator.next() == .status([service]))
        #expect(await logIterator.next() == .log(name: "web", line: line))
    }
}
