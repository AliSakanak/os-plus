import Foundation

/// How worried the user should be about one area of the Mac.
public enum Verdict: Int, Sendable, Comparable, CaseIterable {
    case good = 0
    case watch = 1
    case act = 2
    case unknown = -1

    public static func < (lhs: Verdict, rhs: Verdict) -> Bool { lhs.rawValue < rhs.rawValue }

    public var label: String {
        switch self {
        case .good: "Healthy"
        case .watch: "Keep an eye on it"
        case .act: "Needs attention"
        case .unknown: "Unavailable"
        }
    }
}

/// A verdict plus the one-line reason shown under it.
public struct Assessment: Sendable, Equatable {
    public let verdict: Verdict
    public let reason: String

    public init(_ verdict: Verdict, _ reason: String) {
        self.verdict = verdict
        self.reason = reason
    }
}

/// All the thresholds in one place so they're easy to tune and test.
public enum Assess {
    public static func battery(_ info: BatteryInfo) -> Assessment {
        if info.permanentFailure {
            return Assessment(.act, "The battery reports a permanent failure. Book a service.")
        }
        let health = info.healthPercent
        let cycles = info.cycleCount
        let rated = info.designCycleCount ?? 1000
        if health < 80 {
            return Assessment(.act, "Below 80% of original capacity. Apple considers this worn.")
        }
        if health < 85 || Double(cycles) > Double(rated) * 0.8 {
            return Assessment(.watch, "Ageing normally. Fine for now, but it won't last a full day like it used to.")
        }
        return Assessment(.good, "Normal wear for \(cycles) cycles. Apple counts a battery as worn below 80%.")
    }

    public static func storage(_ info: StorageInfo) -> Assessment {
        let freeGB = Double(info.available) / 1_000_000_000
        let usedFraction = info.usedFraction
        if info.smartStatus == .failing {
            return Assessment(.act, "The SSD's self-test is failing. Back up now.")
        }
        if freeGB < 20 || usedFraction > 0.95 {
            return Assessment(.act, "Very low on space. macOS needs room for updates and swap.")
        }
        if freeGB < 50 || usedFraction > 0.85 {
            return Assessment(.watch, "Getting full. Worth clearing some caches.")
        }
        return Assessment(.good, "\(Format.bytes(info.available)) free.")
    }

    public static func memory(_ info: MemoryInfo) -> Assessment {
        switch info.pressure {
        case .critical:
            return Assessment(.act, "Memory pressure is critical. Quit something heavy.")
        case .warning:
            return Assessment(.watch, "Memory is under pressure, so the Mac is compressing and swapping.")
        case .normal, .unknown:
            let swapGB = Double(info.swapUsed) / 1_073_741_824
            if swapGB > 8 {
                return Assessment(.watch, "Pressure is fine, but \(Format.memory(info.swapUsed)) is in swap.")
            }
            return Assessment(.good, "Plenty of memory to spare.")
        }
    }

    public static func thermal(_ state: ThermalLevel, cpuUsage: Double?) -> Assessment {
        switch state {
        case .critical:
            return Assessment(.act, "Running very hot and throttling hard.")
        case .serious:
            return Assessment(.watch, "Running hot. Performance is being reduced.")
        case .fair:
            return Assessment(.good, "A little warm, which is normal under load.")
        case .nominal:
            if let cpuUsage, cpuUsage > 80 {
                return Assessment(.good, "Working hard but staying cool, so it isn't throttling.")
            }
            return Assessment(.good, "Running cool, no throttling.")
        }
    }

    public static func backup(_ status: BackupStatus, now: Date = Date()) -> Assessment {
        switch status {
        case .notConfigured:
            return Assessment(.watch, "Time Machine isn't set up, so nothing on this Mac is backed up.")
        case .noAccess:
            return Assessment(.unknown, "Give OS+ Full Disk Access to check backups.")
        case .neverCompleted:
            return Assessment(.watch, "Time Machine is set up but has no completed backup.")
        case .lastBackup(let date):
            let days = now.timeIntervalSince(date) / 86_400
            let ago = Format.duration(now.timeIntervalSince(date))
            if days > 14 { return Assessment(.act, "Last backup was \(ago) ago.") }
            if days > 7 { return Assessment(.watch, "Last backup was \(ago) ago.") }
            return Assessment(.good, "Last backup \(ago) ago.")
        }
    }

    public static func uptime(_ seconds: TimeInterval) -> Assessment {
        let days = seconds / 86_400
        if days > 30 {
            return Assessment(.watch, "Up for \(Format.duration(seconds)). A restart clears leaks and applies updates.")
        }
        return Assessment(.good, "No need to restart yet.")
    }

    /// The worst verdict across areas, ignoring ones we couldn't read.
    public static func overall(_ assessments: [Assessment]) -> Verdict {
        assessments.map(\.verdict).filter { $0 != .unknown }.max() ?? .unknown
    }
}
