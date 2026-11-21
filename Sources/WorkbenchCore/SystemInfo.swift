import Darwin
import Foundation

public enum BackupStatus: Sendable, Equatable {
    case notConfigured
    case noAccess
    case neverCompleted
    case lastBackup(Date)
}

public enum SystemReader {
    public static func bootTime() -> Date? {
        var tv = timeval()
        var size = MemoryLayout<timeval>.size
        guard sysctlbyname("kern.boottime", &tv, &size, nil, 0) == 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(tv.tv_sec) + TimeInterval(tv.tv_usec) / 1_000_000)
    }

    public static func uptime(now: Date = Date()) -> TimeInterval? {
        bootTime().map { now.timeIntervalSince($0) }
    }

    /// Backup snapshot folders are named like `2026-11-12-101010` (sometimes with a `.backup` or `.previous` suffix).
    public static func parseBackupDate(fromPath path: String) -> Date? {
        let name = (path.trimmingCharacters(in: .whitespacesAndNewlines) as NSString).lastPathComponent
        let stamp = String(name.prefix(17))
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        return formatter.date(from: stamp)
    }

    /// Interprets `tmutil destinationinfo -X` and `tmutil latestbackup` results.
    public static func interpretBackup(destinationInfo: CommandResult, latest: CommandResult?) -> BackupStatus {
        let combined = (destinationInfo.stdout + destinationInfo.stderr).lowercased()
        if combined.contains("operation not permitted") || combined.contains("full disk access") {
            return .noAccess
        }
        let hasDestination = destinationInfo.stdout.contains("<key>Destinations</key>")
            || destinationInfo.stdout.contains("<key>ID</key>")
        guard hasDestination else { return .notConfigured }

        guard let latest else { return .neverCompleted }
        let latestText = (latest.stdout + latest.stderr).lowercased()
        if latestText.contains("operation not permitted") { return .noAccess }
        if latest.exitCode == 0, let date = parseBackupDate(fromPath: latest.stdout) {
            return .lastBackup(date)
        }
        return .neverCompleted
    }

    public static func readBackup(runner: CommandRunning = CommandRunner()) async -> BackupStatus {
        guard let dest = try? await runner.run("/usr/bin/tmutil", ["destinationinfo", "-X"]) else {
            return .notConfigured
        }
        let status = interpretBackup(destinationInfo: dest, latest: nil)
        guard status == .neverCompleted else { return status }
        let latest = try? await runner.run("/usr/bin/tmutil", ["latestbackup"], timeout: 15)
        return interpretBackup(destinationInfo: dest, latest: latest)
    }
}
