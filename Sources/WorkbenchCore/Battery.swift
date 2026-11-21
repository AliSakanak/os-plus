import Foundation
import IOKit

public struct BatteryInfo: Sendable, Equatable {
    public var designCapacity: Int        // mAh
    public var rawMaxCapacity: Int        // mAh, what the battery can hold today
    public var cycleCount: Int
    public var designCycleCount: Int?
    public var temperatureC: Double?
    public var chargePercent: Int?
    public var isCharging: Bool
    public var isPluggedIn: Bool
    public var isFullyCharged: Bool
    /// Minutes to empty (on battery) or full (charging). Nil while macOS is still estimating.
    public var minutesRemaining: Int?
    public var permanentFailure: Bool

    /// Capacity today as a percentage of when new. Not capped at 100: new batteries can read slightly over.
    public var healthPercent: Double {
        guard designCapacity > 0 else { return 0 }
        return Double(rawMaxCapacity) / Double(designCapacity) * 100
    }

    public var statusText: String {
        if isFullyCharged && isPluggedIn { return "Fully charged" }
        if isCharging {
            if let m = minutesRemaining { return "Charging, \(Format.hoursMinutes(m)) to full" }
            return "Charging"
        }
        if isPluggedIn { return "Plugged in, not charging" }
        if let m = minutesRemaining { return "\(Format.hoursMinutes(m)) remaining" }
        return "On battery"
    }
}

public enum BatteryReader {
    /// Parses the `AppleSmartBattery` IORegistry properties. Returns nil on Macs without a battery.
    public static func parse(_ props: [String: Any]) -> BatteryInfo? {
        func int(_ key: String) -> Int? {
            if let n = props[key] as? NSNumber { return n.intValue }
            return props[key] as? Int
        }
        func bool(_ key: String) -> Bool {
            if let n = props[key] as? NSNumber { return n.boolValue }
            return props[key] as? Bool ?? false
        }

        if let installed = props["BatteryInstalled"], (installed as? NSNumber)?.boolValue == false {
            return nil
        }
        guard let design = int("DesignCapacity"), design > 0 else { return nil }
        // Apple silicon reports MaxCapacity as a percentage (often stuck at 100); the real mAh figure is AppleRawMaxCapacity.
        let rawMax = int("AppleRawMaxCapacity") ?? int("NominalChargeCapacity") ?? int("MaxCapacity") ?? design

        let isCharging = bool("IsCharging")
        var minutes: Int?
        let candidate = isCharging ? int("AvgTimeToFull") : (int("AvgTimeToEmpty") ?? int("TimeRemaining"))
        if let c = candidate, c > 0, c < 65_535 { minutes = c }

        return BatteryInfo(
            designCapacity: design,
            rawMaxCapacity: rawMax,
            cycleCount: int("CycleCount") ?? 0,
            designCycleCount: int("DesignCycleCount9C"),
            temperatureC: int("Temperature").map { Double($0) / 100 },
            chargePercent: int("CurrentCapacity"),
            isCharging: isCharging,
            isPluggedIn: bool("ExternalConnected"),
            isFullyCharged: bool("FullyCharged"),
            minutesRemaining: minutes,
            permanentFailure: (int("PermanentFailureStatus") ?? 0) != 0
        )
    }

    public static func read() -> BatteryInfo? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        var props: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let dict = props?.takeRetainedValue() as? [String: Any]
        else { return nil }
        return parse(dict)
    }
}
