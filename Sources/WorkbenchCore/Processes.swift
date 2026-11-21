import Foundation

/// One app's combined footprint, with helper processes folded into their parent app.
public struct AppUsage: Sendable, Equatable, Identifiable {
    public var name: String
    public var memoryBytes: UInt64
    public var cpuPercent: Double
    public var processCount: Int
    public var pids: [Int32]
    public var id: String { name }
}

public enum ProcessReader {
    struct Row {
        let pid: Int32
        let rssKB: UInt64
        let cpu: Double
        let path: String
    }

    /// Parses `ps -Ao pid=,rss=,%cpu=,comm=` output. The path (last column) may contain spaces.
    static func parseRows(_ output: String) -> [Row] {
        output.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
            guard parts.count == 4,
                  let pid = Int32(parts[0]),
                  let rss = UInt64(parts[1]),
                  let cpu = Double(parts[2].replacingOccurrences(of: ",", with: "."))
            else { return nil }
            return Row(pid: pid, rssKB: rss, cpu: cpu, path: String(parts[3]))
        }
    }

    /// "/Applications/Discord.app/Contents/Frameworks/Discord Helper (Renderer).app/..." → "Discord".
    /// The outermost `.app` wins, so helpers roll up into their parent app.
    public static func appName(forExecutablePath path: String) -> String {
        if path.contains("com.apple.WebKit.WebContent") || path.contains("com.apple.WebKit.GPU")
            || path.contains("com.apple.WebKit.Networking") {
            return "Web pages (Safari & apps)"
        }
        for component in path.split(separator: "/") where component.hasSuffix(".app") {
            return String(component.dropLast(4))
        }
        return (path as NSString).lastPathComponent
    }

    public static func group(_ output: String) -> [AppUsage] {
        var byName: [String: AppUsage] = [:]
        for row in parseRows(output) {
            let name = appName(forExecutablePath: row.path)
            var entry = byName[name] ?? AppUsage(name: name, memoryBytes: 0, cpuPercent: 0, processCount: 0, pids: [])
            entry.memoryBytes += row.rssKB * 1024
            entry.cpuPercent += row.cpu
            entry.processCount += 1
            entry.pids.append(row.pid)
            byName[name] = entry
        }
        return Array(byName.values)
    }

    public static func read(runner: CommandRunning = CommandRunner()) async -> [AppUsage] {
        guard let result = try? await runner.run("/bin/ps", ["-Ao", "pid=,rss=,%cpu=,comm="]),
              result.exitCode == 0
        else { return [] }
        return group(result.stdout)
    }

    public static func topByMemory(_ apps: [AppUsage], limit: Int = 5) -> [AppUsage] {
        Array(apps.sorted { $0.memoryBytes > $1.memoryBytes }.prefix(limit))
    }

    public static func topByCPU(_ apps: [AppUsage], limit: Int = 5) -> [AppUsage] {
        Array(apps.filter { $0.cpuPercent >= 0.5 }.sorted { $0.cpuPercent > $1.cpuPercent }.prefix(limit))
    }
}
