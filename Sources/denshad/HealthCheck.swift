import Darwin
import DenshaCore
import Foundation

enum HealthCheck {
    static func probe(_ health: ResolvedHealth) async -> Bool {
        switch health.kind {
        case .tcp:
            return await tcp(port: health.port, timeout: health.timeout)
        case .http:
            return await http(port: health.port, path: health.path, timeout: health.timeout)
        }
    }

    static func tcp(port: Int, timeout: Double) async -> Bool {
        await Task.detached(priority: .utility) {
            tcpSync(port: port, timeout: timeout)
        }.value
    }

    private static func tcpSync(port: Int, timeout: Double) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }

        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(port).bigEndian)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")

        let rc = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.connect(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if rc == 0 { return true }
        guard errno == EINPROGRESS else { return false }

        var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        guard poll(&pfd, 1, Int32(timeout * 1000)) > 0 else { return false }

        var soError: Int32 = 0
        var len = socklen_t(MemoryLayout<Int32>.size)
        guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &soError, &len) == 0 else { return false }
        return soError == 0
    }

    static func http(port: Int, path: String, timeout: Double) async -> Bool {
        let normalized = path.hasPrefix("/") ? path : "/" + path
        guard let url = URL(string: "http://127.0.0.1:\(port)\(normalized)") else { return false }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = timeout
        request.cachePolicy = .reloadIgnoringLocalCacheData

        let session = URLSession(configuration: .ephemeral)
        defer { session.finishTasksAndInvalidate() }

        do {
            let (_, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { return false }
            return http.statusCode < 500
        } catch {
            return false
        }
    }
}
