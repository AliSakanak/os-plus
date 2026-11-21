import Foundation

public enum Format {
    /// "70 GB", "5.3 GB", "748 MB". Decimal units, like Finder.
    public static func bytes(_ value: UInt64) -> String {
        scaled(Double(value), base: 1000)
    }

    /// Binary units, like Activity Monitor ("48 GB" for 48 GiB of RAM).
    public static func memory(_ value: UInt64) -> String {
        scaled(Double(value), base: 1024)
    }

    /// One decimal below 10 units, none above: precise enough to act on without being noisy.
    private static func scaled(_ value: Double, base: Double) -> String {
        let units = ["bytes", "KB", "MB", "GB", "TB", "PB"]
        var v = value
        var i = 0
        while v >= base, i < units.count - 1 {
            v /= base
            i += 1
        }
        if i == 0 { return "\(Int(v)) bytes" }
        // Avoid "1000 MB" when rounding pushes it over the next unit.
        if v.rounded() >= base, i < units.count - 1 {
            v /= base
            i += 1
        }
        let text = v < 10 ? String(format: "%.1f", v) : String(format: "%.0f", v)
        return "\(text.hasSuffix(".0") ? String(text.dropLast(2)) : text) \(units[i])"
    }

    /// "5d 22h", "3h 12m", "4m".
    public static func duration(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        let days = total / 86_400
        let hours = (total % 86_400) / 3_600
        let minutes = (total % 3_600) / 60
        if days > 0 { return "\(days)d \(hours)h" }
        if hours > 0 { return "\(hours)h \(minutes)m" }
        return "\(minutes)m"
    }

    /// "1:51" style used for battery time remaining.
    public static func hoursMinutes(_ minutes: Int) -> String {
        "\(minutes / 60):" + String(format: "%02d", minutes % 60)
    }

    public static func percent(_ value: Double, decimals: Int = 0) -> String {
        String(format: "%.\(decimals)f%%", value)
    }
}
