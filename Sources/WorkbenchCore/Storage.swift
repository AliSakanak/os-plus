import Foundation

public enum SmartStatus: Sendable, Equatable {
    case verified, failing, notSupported, unknown

    public init(diskutilValue: String?) {
        switch diskutilValue?.lowercased() {
        case "verified": self = .verified
        case "failing", "about to fail": self = .failing
        case "not supported": self = .notSupported
        default: self = .unknown
        }
    }

    public var label: String {
        switch self {
        case .verified: "Passed"
        case .failing: "Failing"
        case .notSupported: "Not reported"
        case .unknown: "Unknown"
        }
    }
}

public struct StorageInfo: Sendable, Equatable {
    public var total: UInt64
    /// Free space including purgeable data, which matches what Finder shows.
    public var available: UInt64
    public var smartStatus: SmartStatus
    public var deviceName: String?

    public var used: UInt64 { total > available ? total - available : 0 }
    public var usedFraction: Double { total == 0 ? 0 : Double(used) / Double(total) }
}

public enum StorageReader {
    public static func readCapacity(volume: URL = URL(fileURLWithPath: "/")) -> (total: UInt64, available: UInt64)? {
        let keys: Set<URLResourceKey> = [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey]
        guard let values = try? volume.resourceValues(forKeys: keys),
              let total = values.volumeTotalCapacity,
              let available = values.volumeAvailableCapacityForImportantUsage
        else { return nil }
        return (UInt64(total), UInt64(max(0, available)))
    }

    /// Parses `diskutil info -plist /` output.
    public static func parseDiskutil(_ plist: String) -> (smart: SmartStatus, deviceName: String?) {
        guard let data = plist.data(using: .utf8),
              let dict = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return (.unknown, nil) }
        return (SmartStatus(diskutilValue: dict["SMARTStatus"] as? String), dict["MediaName"] as? String)
    }

    public static func read(runner: CommandRunning = CommandRunner()) async -> StorageInfo? {
        guard let capacity = readCapacity() else { return nil }
        var smart = SmartStatus.unknown
        var device: String?
        if let result = try? await runner.run("/usr/sbin/diskutil", ["info", "-plist", "/"]), result.exitCode == 0 {
            (smart, device) = parseDiskutil(result.stdout)
        }
        return StorageInfo(total: capacity.total, available: capacity.available, smartStatus: smart, deviceName: device)
    }
}
