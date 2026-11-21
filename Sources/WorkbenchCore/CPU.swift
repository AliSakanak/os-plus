import Darwin
import Foundation

public enum ThermalLevel: Sendable, Equatable {
    case nominal, fair, serious, critical

    public init(_ state: ProcessInfo.ThermalState) {
        switch state {
        case .nominal: self = .nominal
        case .fair: self = .fair
        case .serious: self = .serious
        case .critical: self = .critical
        @unknown default: self = .nominal
        }
    }

    public var label: String {
        switch self {
        case .nominal: "Cool"
        case .fair: "Warm"
        case .serious: "Hot"
        case .critical: "Very hot"
        }
    }
}

public struct CPUTicks: Sendable, Equatable {
    public var user: UInt64
    public var system: UInt64
    public var idle: UInt64
    public var nice: UInt64

    public init(user: UInt64, system: UInt64, idle: UInt64, nice: UInt64) {
        self.user = user
        self.system = system
        self.idle = idle
        self.nice = nice
    }

    /// Busy percentage between two samples (0–100), or nil if no time passed.
    public static func usage(from old: CPUTicks, to new: CPUTicks) -> Double? {
        let busy = Double((new.user &- old.user) &+ (new.system &- old.system) &+ (new.nice &- old.nice))
        let idle = Double(new.idle &- old.idle)
        let total = busy + idle
        guard total > 0 else { return nil }
        return busy / total * 100
    }
}

public struct CPUInfo: Sendable, Equatable {
    public var usagePercent: Double?
    public var loadAverage: (one: Double, five: Double, fifteen: Double)
    public var coreCount: Int
    public var thermal: ThermalLevel

    public static func == (a: CPUInfo, b: CPUInfo) -> Bool {
        a.usagePercent == b.usagePercent && a.coreCount == b.coreCount && a.thermal == b.thermal
            && a.loadAverage.one == b.loadAverage.one
    }
}

/// Keeps the previous tick sample so each read reports usage since the last one.
public final class CPUSampler: @unchecked Sendable {
    private var previous: CPUTicks?
    private let lock = NSLock()

    public init() {
        previous = Self.ticks()
    }

    public static func ticks() -> CPUTicks? {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        let t = info.cpu_ticks
        return CPUTicks(
            user: UInt64(t.0), system: UInt64(t.1), idle: UInt64(t.2), nice: UInt64(t.3)
        )
    }

    public func read() -> CPUInfo {
        let now = Self.ticks()
        let usage: Double? = lock.withLock {
            defer { if let now { previous = now } }
            guard let old = previous, let now else { return nil }
            return CPUTicks.usage(from: old, to: now)
        }
        var loads = [Double](repeating: 0, count: 3)
        _ = getloadavg(&loads, 3)
        return CPUInfo(
            usagePercent: usage,
            loadAverage: (loads[0], loads[1], loads[2]),
            coreCount: ProcessInfo.processInfo.activeProcessorCount,
            thermal: ThermalLevel(ProcessInfo.processInfo.thermalState)
        )
    }
}
