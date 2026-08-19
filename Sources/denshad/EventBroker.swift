import DenshaCore
import Foundation

struct EventSubscriber {
    let wantsStatus: Bool
    let logFilter: String?
    let continuation: AsyncStream<DaemonEvent>.Continuation
}

struct EventBroker {
    private var subscribers: [UUID: EventSubscriber] = [:]

    mutating func subscribe(status wantsStatus: Bool, logFilter: String?)
        -> (UUID, AsyncStream<DaemonEvent>)
    {
        let id = UUID()
        let (stream, continuation) = AsyncStream<DaemonEvent>.makeStream(
            of: DaemonEvent.self, bufferingPolicy: .bufferingNewest(4096))
        subscribers[id] = EventSubscriber(
            wantsStatus: wantsStatus, logFilter: logFilter, continuation: continuation)
        return (id, stream)
    }

    mutating func unsubscribe(_ id: UUID) {
        subscribers[id]?.continuation.finish()
        subscribers.removeValue(forKey: id)
    }

    func broadcast(_ event: DaemonEvent) {
        for subscriber in subscribers.values where subscriber.wantsStatus {
            subscriber.continuation.yield(event)
        }
    }

    func broadcastLog(name: String, line: LogLine) {
        for subscriber in subscribers.values {
            guard let filter = subscriber.logFilter, filter == name || filter == "*" else {
                continue
            }
            subscriber.continuation.yield(.log(name: name, line: line))
        }
    }
}
