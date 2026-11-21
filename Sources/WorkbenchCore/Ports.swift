import Darwin
import Foundation

public struct ListeningPort: Sendable, Equatable, Identifiable {
    public enum Kind: Int, Sendable, Comparable {
        case dev = 0      // things you started: node, python, postgres, docker…
        case app = 1      // regular apps holding a local port (Discord, Steam, VS Code helpers)
        case system = 2   // macOS's own services (AirPlay receiver, rapportd…)
        public static func < (a: Kind, b: Kind) -> Bool { a.rawValue < b.rawValue }
    }

    public var pid: Int32
    public var port: Int
    public var processName: String
    /// Hosts it's bound to: "127.0.0.1", "[::1]", "*".
    public var hosts: [String]
    /// Exact executable path from the kernel (`proc_pidpath`), which is reliable even with spaces in it.
    public var executablePath: String?
    /// Full command line including arguments (from `ps`).
    public var command: String?
    public var workingDirectory: String?
    public var elapsedSeconds: TimeInterval?

    public init(pid: Int32, port: Int, processName: String, hosts: [String], executablePath: String? = nil,
                command: String? = nil, workingDirectory: String? = nil, elapsedSeconds: TimeInterval? = nil) {
        self.pid = pid
        self.port = port
        self.processName = processName
        self.hosts = hosts
        self.executablePath = executablePath
        self.command = command
        self.workingDirectory = workingDirectory
        self.elapsedSeconds = elapsedSeconds
    }

    public var id: String { "\(pid):\(port)" }

    /// True when only reachable from this Mac.
    public var isLocalOnly: Bool {
        !hosts.isEmpty && hosts.allSatisfy { $0 == "127.0.0.1" || $0 == "[::1]" || $0 == "localhost" }
    }

    public var kind: Kind {
        PortsReader.classify(executablePath: executablePath, processName: processName, command: command,
                             workingDirectory: workingDirectory)
    }

    public var url: URL? { URL(string: "http://localhost:\(port)") }

    /// A friendly label: "vite", "uvicorn", "postgres", "Steam".
    public var displayName: String {
        PortsReader.friendlyName(executablePath: executablePath, command: command, fallback: processName)
    }

    /// "strava-footy-analyzer/frontend" from the working directory, if it's a meaningful folder.
    public var projectName: String? { PortsReader.projectName(forDirectory: workingDirectory) }

    /// False for well-known non-HTTP services (databases, caches), so we don't offer "Open in browser".
    public var looksLikeWebServer: Bool {
        !PortsReader.nonHTTPNames.contains(displayName.lowercased()) && !PortsReader.nonHTTPPorts.contains(port)
    }
}

public enum PortsReader {
    // MARK: Parsing

    /// Parses `lsof -nP -iTCP -sTCP:LISTEN -F pcn`. Duplicate fds/addresses (IPv4 + IPv6) merge into one row per pid+port.
    public static func parseLsof(_ output: String) -> [ListeningPort] {
        var ordered: [String] = []
        var byID: [String: ListeningPort] = [:]
        var pid: Int32?
        var name = ""

        for line in output.split(separator: "\n") {
            guard let tag = line.first else { continue }
            let value = String(line.dropFirst())
            switch tag {
            case "p":
                pid = Int32(value)
                name = ""
            case "c":
                name = value
            case "n":
                guard let pid, let (host, port) = splitAddress(value) else { continue }
                let id = "\(pid):\(port)"
                if var existing = byID[id] {
                    if !existing.hosts.contains(host) { existing.hosts.append(host) }
                    byID[id] = existing
                } else {
                    ordered.append(id)
                    byID[id] = ListeningPort(pid: pid, port: port, processName: name, hosts: [host])
                }
            default:
                continue
            }
        }
        return ordered.compactMap { byID[$0] }
    }

    /// "127.0.0.1:5432" → ("127.0.0.1", 5432); "[::1]:5173" → ("[::1]", 5173); "*:7000" → ("*", 7000).
    static func splitAddress(_ address: String) -> (String, Int)? {
        // Connections look like "a:1->b:2"; LISTEN rows shouldn't, but be safe.
        let local = address.components(separatedBy: "->").first ?? address
        guard let colon = local.lastIndex(of: ":"), let port = Int(local[local.index(after: colon)...]) else {
            return nil
        }
        return (String(local[..<colon]), port)
    }

    /// Parses `ps -o pid=,etime=,command= -p …`.
    static func parsePs(_ output: String) -> [Int32: (elapsed: TimeInterval?, command: String)] {
        var result: [Int32: (TimeInterval?, String)] = [:]
        for line in output.split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard parts.count == 3, let pid = Int32(parts[0]) else { continue }
            result[pid] = (parseElapsed(String(parts[1])), String(parts[2]))
        }
        return result
    }

    /// ps etime: "[[dd-]hh:]mm:ss".
    static func parseElapsed(_ value: String) -> TimeInterval? {
        var days = 0
        var rest = Substring(value)
        if let dash = rest.firstIndex(of: "-") {
            guard let d = Int(rest[..<dash]) else { return nil }
            days = d
            rest = rest[rest.index(after: dash)...]
        }
        let numbers = rest.split(separator: ":").compactMap { Int($0) }
        guard !numbers.isEmpty, numbers.count <= 3 else { return nil }
        var seconds = 0
        for n in numbers { seconds = seconds * 60 + n }
        return TimeInterval(days * 86_400 + seconds)
    }

    /// Parses `lsof -a -d cwd -p … -Fn`, which emits "p<pid>", "fcwd", "n<path>" triples.
    static func parseCwd(_ output: String) -> [Int32: String] {
        var result: [Int32: String] = [:]
        var pid: Int32?
        for line in output.split(separator: "\n") {
            guard let tag = line.first else { continue }
            let value = String(line.dropFirst())
            if tag == "p" { pid = Int32(value) }
            else if tag == "n", let pid { result[pid] = value }
        }
        return result
    }

    // MARK: Classification & naming

    static let systemPrefixes = ["/System/", "/usr/libexec/", "/usr/sbin/", "/sbin/", "/Library/Apple/"]
    static let systemNames: Set<String> = ["rapportd", "ControlCenter", "sharingd", "launchd", "mDNSResponder",
                                           "remoted", "identityservicesd", "WiFiAgent", "AirPlayXPCHelper"]

    static let interpreters: Set<String> = ["node", "python", "python3", "ruby", "bun", "deno", "java", "php",
                                            "perl", "uv", "npx", "pnpm", "yarn", "npm", "go", "dotnet", "beam.smp",
                                            "erl", "elixir", "rails", "puma", "gunicorn", "uvicorn"]

    /// Developer tools you run in a terminal that hold ports for their own use: not "your servers".
    static let devToolNames: Set<String> = ["claude", "opencode", "opencode-cli", "code", "cursor", "codex", "gemini"]

    /// Where command-line installs live. A binary from here is something you ran yourself.
    static func devInstallPrefixes(home: String) -> [String] {
        ["/opt/homebrew/", "/usr/local/", "\(home)/.cargo/", "\(home)/go/", "\(home)/.bun/", "\(home)/.deno/",
         "\(home)/.nvm/", "\(home)/.volta/", "\(home)/.pyenv/", "\(home)/.rbenv/", "\(home)/.asdf/",
         "\(home)/.local/bin/", "\(home)/.rustup/"]
    }

    static let nonHTTPNames: Set<String> = ["postgres", "postmaster", "mysqld", "mariadbd", "redis-server", "mongod",
                                            "memcached", "sshd", "valkey-server"]
    static let nonHTTPPorts: Set<Int> = [22, 3306, 5432, 6379, 11211, 27017]

    static let appBundleMarkers = [".app/", ".AppBundle/"]

    public static func classify(executablePath: String?, processName: String, command: String?,
                                workingDirectory: String?, home: String = NSHomeDirectory()) -> ListeningPort.Kind {
        let path = executablePath ?? command ?? ""
        if systemNames.contains(processName) || systemPrefixes.contains(where: { path.hasPrefix($0) }) {
            return .system
        }
        let name = friendlyName(executablePath: executablePath, command: command, fallback: processName)
        if devToolNames.contains(name.lowercased()) { return .app }
        // Docker's backend publishes container ports: those are your servers.
        if path.contains("com.docker.backend") || name == "com.docker.backend" { return .dev }
        if appBundleMarkers.contains(where: { path.contains($0) }) { return .app }

        let exe = (path as NSString).lastPathComponent
        if isInterpreter(exe) { return .dev }
        if devInstallPrefixes(home: home).contains(where: { path.hasPrefix($0) }) { return .dev }
        if let dir = workingDirectory, gitRoot(above: dir, home: home) != nil { return .dev }
        if path.hasPrefix(home + "/Library/") { return .app }
        return .dev
    }

    static func isInterpreter(_ exe: String) -> Bool {
        let base = exe.split(separator: ".").first.map(String.init) ?? exe
        return interpreters.contains(exe) || interpreters.contains(base) || exe.hasPrefix("python")
    }

    /// Picks the most recognisable name for a process.
    public static func friendlyName(executablePath: String?, command: String?, fallback: String) -> String {
        let path = executablePath ?? command?.split(separator: " ").first.map(String.init) ?? ""
        guard !path.isEmpty else { return fallback }

        // Inside an app bundle: use the bundle's name ("Steam", "Discord"), not the helper binary.
        if let bundle = outermostBundleName(path) {
            return bundle
        }

        var exe = (path as NSString).lastPathComponent
        // Some tools install as a version-numbered binary (".../versions/2.1.329"); use argv[0] instead.
        if exe.allSatisfy({ $0.isNumber || $0 == "." }), let arg0 = command?.split(separator: " ").first {
            exe = (String(arg0) as NSString).lastPathComponent
        }
        guard isInterpreter(exe), let command else { return exe }

        // For interpreters, the script or module is the interesting part.
        let words = command.split(separator: " ").map(String.init)
        var i = 1
        while i < words.count {
            let word = words[i]
            if word == "-m", i + 1 < words.count { return words[i + 1] }   // python -m uvicorn
            if word.hasPrefix("-") { i += 1; continue }
            var script = (word as NSString).lastPathComponent
            // node …/vite/bin/vite.js → "vite"; node server.js → "server.js"
            if script.hasSuffix(".js") || script.hasSuffix(".mjs") || script.hasSuffix(".cjs") {
                let binDir = (word as NSString).deletingLastPathComponent
                if (binDir as NSString).lastPathComponent == "bin" {
                    script = ((binDir as NSString).deletingLastPathComponent as NSString).lastPathComponent
                }
            }
            return script
        }
        return exe
    }

    /// "/Applications/Discord.app/Contents/Frameworks/Discord Helper.app/…" → "Discord".
    static func outermostBundleName(_ path: String) -> String? {
        for component in path.split(separator: "/") {
            for marker in [".app", ".AppBundle"] where component.hasSuffix(marker) {
                return String(component.dropLast(marker.count))
            }
        }
        return nil
    }

    /// The nearest folder containing `.git`, searching only inside the home folder
    /// (so system-wide git checkouts like /opt/homebrew don't count as "your project").
    static func gitRoot(above directory: String, home: String, fileManager: FileManager = .default) -> String? {
        guard directory.hasPrefix(home + "/") else { return nil }
        var current = directory
        while current.count > home.count {
            if fileManager.fileExists(atPath: current + "/.git") { return current }
            current = (current as NSString).deletingLastPathComponent
        }
        return nil
    }

    /// "repo" or "repo/sub/folder" for folders in a git repo; the folder name otherwise.
    public static func projectName(forDirectory directory: String?, home: String = NSHomeDirectory(),
                                   fileManager: FileManager = .default) -> String? {
        guard let directory, directory != "/", !directory.isEmpty else { return nil }
        if appBundleMarkers.contains(where: { directory.contains($0) }) { return nil }
        if directory == home { return "~" }
        if let root = gitRoot(above: directory, home: home, fileManager: fileManager) {
            let repo = (root as NSString).lastPathComponent
            return repo + String(directory.dropFirst(root.count))
        }
        return (directory as NSString).lastPathComponent
    }

    // MARK: Reading

    /// The kernel's record of a process's executable.
    public static func executablePath(pid: Int32) -> String? {
        var buffer = [UInt8](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(decoding: buffer.prefix(Int(length)), as: UTF8.self)
    }

    public static func read(
        runner: CommandRunning = CommandRunner(),
        executablePath: @Sendable (Int32) -> String? = { PortsReader.executablePath(pid: $0) }
    ) async -> [ListeningPort] {
        guard let lsof = try? await runner.run("/usr/sbin/lsof", ["-nP", "-iTCP", "-sTCP:LISTEN", "-F", "pcn"]) else {
            return []
        }
        // lsof exits 1 when nothing matches, so don't treat that as an error.
        var ports = parseLsof(lsof.stdout)
        guard !ports.isEmpty else { return [] }

        let pidList = Set(ports.map(\.pid)).map(String.init).joined(separator: ",")
        async let psResult = try? runner.run("/bin/ps", ["-o", "pid=,etime=,command=", "-p", pidList])
        async let cwdResult = try? runner.run("/usr/sbin/lsof", ["-a", "-d", "cwd", "-p", pidList, "-Fn"])
        let psInfo = parsePs(await psResult?.stdout ?? "")
        let cwds = parseCwd(await cwdResult?.stdout ?? "")

        for i in ports.indices {
            let pid = ports[i].pid
            ports[i].executablePath = executablePath(pid)
            ports[i].command = psInfo[pid]?.command
            ports[i].elapsedSeconds = psInfo[pid]?.elapsed ?? nil
            ports[i].workingDirectory = cwds[pid]
        }
        return ports.sorted { ($0.kind, $0.port) < ($1.kind, $1.port) }
    }

    public enum StopError: Error, LocalizedError {
        case notPermitted, noSuchProcess, other(Int32)
        public var errorDescription: String? {
            switch self {
            case .notPermitted: "macOS won't let OS+ stop this process (it belongs to another user or the system)."
            case .noSuchProcess: "That process has already stopped."
            case .other(let code): "Couldn't stop the process (error \(code))."
            }
        }
    }

    /// Sends SIGTERM (polite) or SIGKILL (force).
    public static func stop(pid: Int32, force: Bool) throws {
        guard pid > 1 else { throw StopError.notPermitted }
        if Darwin.kill(pid, force ? SIGKILL : SIGTERM) != 0 {
            switch errno {
            case EPERM: throw StopError.notPermitted
            case ESRCH: throw StopError.noSuchProcess
            default: throw StopError.other(errno)
            }
        }
    }
}
