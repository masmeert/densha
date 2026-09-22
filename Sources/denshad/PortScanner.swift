import Darwin
import DenshaCore
import Foundation

enum PortScanner {
    static func listeningPorts() -> [ScannedPort] {
        var found: [ScannedPort] = []
        var descriptors = [proc_fdinfo](repeating: proc_fdinfo(), count: 256)
        for pid in allProcessIdentifiers() {
            let ports = listeningPorts(of: pid, reusing: &descriptors)
                .filter { PortScanRules.scannablePorts.contains($0) }
            guard !ports.isEmpty else { continue }
            let processName = name(of: pid)
            for port in ports {
                found.append(ScannedPort(port: port, pid: pid, processName: processName))
            }
        }
        return found
    }

    static func unclaimed(
        among listening: [ScannedPort],
        services: [ServiceStatus],
        rules: PortScanRules = .default,
        processGroupOf: (pid_t) -> pid_t = { getpgid($0) }
    ) -> [ScannedPort] {
        var declaringService: [Int: String] = [:]
        var portsOfLiveServices = Set<Int>()
        var supervisedProcessGroups = Set<pid_t>()
        for service in services {
            if let pgid = service.pgid { supervisedProcessGroups.insert(pgid) }
            guard let port = service.port else { continue }
            if declaringService[port] == nil { declaringService[port] = service.name }
            if service.isLive { portsOfLiveServices.insert(port) }
        }

        var claimed = Set<Int>()
        var kept: [ScannedPort] = []
        for candidate in listening {
            guard PortScanRules.scannablePorts.contains(candidate.port) else { continue }
            guard !portsOfLiveServices.contains(candidate.port) else { continue }
            guard !rules.ignores(port: candidate.port, processName: candidate.processName)
            else { continue }
            guard !supervisedProcessGroups.contains(processGroupOf(candidate.pid)) else { continue }
            guard claimed.insert(candidate.port).inserted else { continue }
            var port = candidate
            port.conflictsWith = declaringService[candidate.port]
            kept.append(port)
        }
        return kept.sorted { first, second in
            let firstConflicts = first.conflictsWith != nil
            let secondConflicts = second.conflictsWith != nil
            if firstConflicts != secondConflicts { return firstConflicts }
            return first.port < second.port
        }
    }

    private static func allProcessIdentifiers() -> [pid_t] {
        let probed = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard probed > 0 else { return [] }
        let capacity = Int(probed) / MemoryLayout<pid_t>.size + 64
        var identifiers = [pid_t](repeating: 0, count: capacity)
        let written = proc_listpids(
            UInt32(PROC_ALL_PIDS), 0, &identifiers,
            Int32(capacity * MemoryLayout<pid_t>.size))
        guard written > 0 else { return [] }
        return identifiers.prefix(Int(written) / MemoryLayout<pid_t>.size).filter { $0 > 0 }
    }

    static func listeningPorts(of pid: pid_t) -> [Int] {
        var descriptors = [proc_fdinfo](repeating: proc_fdinfo(), count: 256)
        return listeningPorts(of: pid, reusing: &descriptors)
    }

    private static let maxDescriptors = 1 << 16

    private static func listeningPorts(
        of pid: pid_t, reusing descriptors: inout [proc_fdinfo]
    ) -> [Int] {
        let stride = MemoryLayout<proc_fdinfo>.stride
        var openDescriptors = 0
        while true {
            let written = descriptors.withUnsafeMutableBytes { raw in
                Int(proc_pidinfo(pid, PROC_PIDLISTFDS, 0, raw.baseAddress, Int32(raw.count)))
            }
            guard written > 0 else { return [] }
            openDescriptors = written / stride
            guard openDescriptors == descriptors.count, descriptors.count < maxDescriptors else {
                break
            }
            descriptors = [proc_fdinfo](
                repeating: proc_fdinfo(), count: descriptors.count * 2)
        }

        var ports: [Int] = []
        var info = socket_fdinfo()
        let size = Int32(MemoryLayout<socket_fdinfo>.size)
        for descriptor in descriptors.prefix(openDescriptors) {
            guard descriptor.proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) else { continue }
            guard proc_pidfdinfo(pid, descriptor.proc_fd, PROC_PIDFDSOCKETINFO, &info, size) == size
            else { continue }
            guard info.psi.soi_kind == SOCKINFO_TCP else { continue }
            let tcp = info.psi.soi_proto.pri_tcp
            guard tcp.tcpsi_state == Int32(TSI_S_LISTEN) else { continue }
            let port = Int(
                UInt16(bigEndian: UInt16(truncatingIfNeeded: tcp.tcpsi_ini.insi_lport)))
            if !ports.contains(port) { ports.append(port) }
        }
        return ports
    }

    private static func name(of pid: pid_t) -> String {
        var buffer = [CChar](repeating: 0, count: Int(MAXCOMLEN) * 4 + 1)
        guard proc_name(pid, &buffer, UInt32(buffer.count)) > 0 else { return "pid \(pid)" }
        let name = String(cString: buffer)
        return name.isEmpty ? "pid \(pid)" : name
    }
}
