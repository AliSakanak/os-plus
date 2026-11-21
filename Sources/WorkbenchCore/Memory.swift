import Darwin
import Foundation

public enum MemoryPressure: Sendable, Equatable {
    case normal, warning, critical, unknown

    /// Values of `kern.memorystatus_vm_pressure_level`.
    public init(sysctlLevel: Int32) {
        switch sysctlLevel {
        case 1: self = .normal
        case 2: self = .warning
        case 4: self = .critical
        default: self = .unknown
        }
    }

    public var label: String {
        switch self {
        case .normal: "Normal"
        case .warning: "Elevated"
        case .critical: "Critical"
        case .unknown: "Unknown"
        }
    }
}

public struct MemoryInfo: Sendable, Equatable {
    public var total: UInt64
    public var appMemory: UInt64
    public var wired: UInt64
    public var compressed: UInt64
    public var cachedFiles: UInt64
    public var swapUsed: UInt64
    public var swapTotal: UInt64
    public var pressure: MemoryPressure

    /// Matches Activity Monitor's "Memory Used" (App + Wired + Compressed).
    public var used: UInt64 { appMemory + wired + compressed }
    public var usedFraction: Double { total == 0 ? 0 : min(1, Double(used) / Double(total)) }
}

public enum MemoryReader {
    public static func read() -> MemoryInfo? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }

        let page = UInt64(getpagesize())
        let internalPages = UInt64(stats.internal_page_count)
        let purgeable = UInt64(stats.purgeable_count)
        let app = (internalPages > purgeable ? internalPages - purgeable : 0) * page

        var swap = xsw_usage()
        var swapSize = MemoryLayout<xsw_usage>.size
        let swapOK = sysctlbyname("vm.swapusage", &swap, &swapSize, nil, 0) == 0

        return MemoryInfo(
            total: ProcessInfo.processInfo.physicalMemory,
            appMemory: app,
            wired: UInt64(stats.wire_count) * page,
            compressed: UInt64(stats.compressor_page_count) * page,
            cachedFiles: (UInt64(stats.external_page_count) + purgeable) * page,
            swapUsed: swapOK ? swap.xsu_used : 0,
            swapTotal: swapOK ? swap.xsu_total : 0,
            pressure: MemoryPressure(sysctlLevel: SysctlReader.int32("kern.memorystatus_vm_pressure_level") ?? 0)
        )
    }
}

enum SysctlReader {
    static func int32(_ name: String) -> Int32? {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        return sysctlbyname(name, &value, &size, nil, 0) == 0 ? value : nil
    }
}
