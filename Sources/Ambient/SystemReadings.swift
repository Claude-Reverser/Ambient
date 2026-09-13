import Darwin
import Foundation
import Observation

struct UsageSample: Equatable {
    var cpu: Double
    var memory: Double
    var download: Double = 0
    var upload: Double = 0
}
struct UsageHistory {
    static let capacity = 120
    private(set) var samples: [UsageSample] = []
    mutating func append(_ sample: UsageSample) {
        samples.append(sample)
        if samples.count > Self.capacity { samples.removeFirst(samples.count - Self.capacity) }
    }
}
@MainActor @Observable final class SystemReadings {
    private(set) var date = Date()
    private(set) var cpu: Double?
    private(set) var memoryBytes: UInt64 = 0
    private(set) var history = UsageHistory()
    private(set) var download = 0.0
    private(set) var upload = 0.0
    private var networkBaseline: [String: (UInt32, UInt32)] = [:]
    private var networkTime: TimeInterval?
    private var previousTicks: [UInt32]?
    var cpuText: String { cpu.map { String(format: "%.1f%%", $0) } ?? "—" }
    var memoryText: String { String(format: "%.2f GB", Double(memoryBytes) / 1_073_741_824) }
    var memoryPercent: Double {
        min(100, Double(memoryBytes) / Double(ProcessInfo.processInfo.physicalMemory) * 100)
    }
    var downloadText: String { Self.rateText(download) }
    var uploadText: String { Self.rateText(upload) }
    static func rateText(_ bytes: Double) -> String {
        bytes >= 1_048_576
            ? String(format: "%.2f MB/s", bytes / 1_048_576)
            : String(format: "%.1f KB/s", bytes / 1024)
    }
    func resetBaseline() {
        previousTicks = nil
        cpu = nil
        networkBaseline = [:]
        networkTime = nil
        download = 0
        upload = 0
    }
    private func sampleNetwork() {
        var addresses: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addresses) == 0 else { return }
        defer { freeifaddrs(addresses) }
        var current: [String: (UInt32, UInt32)] = [:]
        var pointer = addresses
        while let entry = pointer {
            defer { pointer = entry.pointee.ifa_next }
            let item = entry.pointee
            guard let address = item.ifa_addr, address.pointee.sa_family == UInt8(AF_LINK),
                item.ifa_flags & UInt32(IFF_UP) != 0, item.ifa_flags & UInt32(IFF_RUNNING) != 0,
                let data = item.ifa_data
            else { continue }
            let name = String(cString: item.ifa_name)
            // Physical Ethernet/Wi-Fi adapters only, to avoid counting VPN traffic twice.
            guard name.hasPrefix("en") else { continue }
            let counters = data.assumingMemoryBound(to: if_data.self).pointee
            current[name] = (counters.ifi_ibytes, counters.ifi_obytes)
        }
        let now = ProcessInfo.processInfo.systemUptime
        if let last = networkTime, now > last {
            var received: UInt64 = 0
            var sent: UInt64 = 0
            for (name, counters) in current {
                if let old = networkBaseline[name] {
                    received += UInt64(counters.0 &- old.0)
                    sent += UInt64(counters.1 &- old.1)
                }
            }
            download = Double(received) / (now - last)
            upload = Double(sent) / (now - last)
        }
        networkTime = now
        networkBaseline = current
    }
    static func cpuPercent(ticks: [UInt32], previous: [UInt32]) -> Double? {
        guard ticks.count == 4, previous.count == 4 else { return nil }
        let delta = zip(ticks, previous).map { UInt64($0 &- $1) }
        let total = delta.reduce(0, +)
        return total > 0 ? Double(total - delta[2]) / Double(total) * 100 : nil
    }
    func refresh(stats: Bool) {
        let now = Date()
        if floor(now.timeIntervalSince1970 / 60) != floor(date.timeIntervalSince1970 / 60) {
            date = now
        }
        guard stats else { return }
        sampleNetwork()
        let host = mach_host_self()
        defer { mach_port_deallocate(mach_task_self_, host) }
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(host, HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        if result == KERN_SUCCESS {
            let ticks = [info.cpu_ticks.0, info.cpu_ticks.1, info.cpu_ticks.2, info.cpu_ticks.3]
            if let previousTicks { cpu = Self.cpuPercent(ticks: ticks, previous: previousTicks) }
            previousTicks = ticks
        }
        var vm = vm_statistics64()
        var vmCount = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let vmResult = withUnsafeMutablePointer(to: &vm) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(vmCount)) {
                host_statistics64(host, HOST_VM_INFO64, $0, &vmCount)
            }
        }
        if vmResult == KERN_SUCCESS {
            var pageSize: vm_size_t = 0
            host_page_size(host, &pageSize)
            memoryBytes =
                (UInt64(vm.active_count) + UInt64(vm.wire_count) + UInt64(vm.compressor_page_count))
                * UInt64(pageSize)
        }
        if let cpu {
            history.append(
                UsageSample(cpu: cpu, memory: memoryPercent, download: download, upload: upload))
        }
    }
}
