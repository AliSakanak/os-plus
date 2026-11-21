import Foundation
import Testing
@testable import WorkbenchCore

// Real `lsof -nP -iTCP -sTCP:LISTEN -F pcn` output from a real Mac, plus a vite server.
private let lsofOutput = """
p626
crapportd
f10
n*:49198
f11
n*:49198
p661
cControlCenter
f9
n*:7000
f10
n*:7000
f11
n*:5000
p1003
cpostgres
f7
n[::1]:5432
f8
n127.0.0.1:5432
p72133
cDiscord Helper (Renderer)
f36
n127.0.0.1:6463
p9001
cnode
f20
n[::1]:5173
"""

/// Canned command output so `PortsReader.read` can be tested end to end.
private struct FakeRunner: CommandRunning {
    func run(_ executable: String, _ arguments: [String], timeout: TimeInterval) async throws -> CommandResult {
        if executable.hasSuffix("lsof"), arguments.contains("LISTEN") || arguments.contains("-sTCP:LISTEN") {
            return CommandResult(stdout: lsofOutput, exitCode: 0)
        }
        if executable.hasSuffix("lsof") {
            return CommandResult(stdout: "p9001\nfcwd\nn/tmp/myapp/frontend\np1003\nfcwd\nn/opt/homebrew/var/postgresql@16\n")
        }
        if executable.hasSuffix("ps") {
            return CommandResult(stdout: """
              626 5-02:10:00 /usr/libexec/rapportd
              661 5-02:10:01 /System/Library/CoreServices/ControlCenter.app/Contents/MacOS/ControlCenter
             1003 2-00:00:05 /opt/homebrew/opt/postgresql@16/bin/postgres -D /opt/homebrew/var/postgresql@16
            72133    01:02:03 /Applications/Discord.app/Contents/Frameworks/Discord Helper (Renderer).app/Contents/MacOS/Discord Helper (Renderer) --type=renderer
             9001       12:34 node /tmp/myapp/frontend/node_modules/vite/bin/vite.js --port 5173
            """)
        }
        return CommandResult(stdout: "", exitCode: 1)
    }
}

@Suite("Ports")
struct PortsTests {
    @Test func mergesDuplicateAddresses() {
        let ports = PortsReader.parseLsof(lsofOutput)
        #expect(ports.count == 6)  // rapportd, ControlCenter×2, postgres, Discord, node
        let postgres = ports.first { $0.port == 5432 }
        #expect(postgres?.hosts == ["[::1]", "127.0.0.1"])
        #expect(postgres?.isLocalOnly == true)
        #expect(ports.first { $0.port == 7000 }?.isLocalOnly == false)
    }

    @Test func splitsAddresses() {
        #expect(PortsReader.splitAddress("*:7000")! == ("*", 7000))
        #expect(PortsReader.splitAddress("[::1]:5173")! == ("[::1]", 5173))
        #expect(PortsReader.splitAddress("127.0.0.1:80->10.0.0.1:5000")! == ("127.0.0.1", 80))
        #expect(PortsReader.splitAddress("nonsense") == nil)
    }

    @Test func elapsedTimes() {
        #expect(PortsReader.parseElapsed("12:34") == 754)
        #expect(PortsReader.parseElapsed("01:02:03") == 3723)
        #expect(PortsReader.parseElapsed("5-02:10:00") == TimeInterval(5 * 86_400 + 7_800))
        #expect(PortsReader.parseElapsed("x") == nil)
    }

    @Test func friendlyNames() {
        func name(_ exe: String?, _ cmd: String?, _ fallback: String = "x") -> String {
            PortsReader.friendlyName(executablePath: exe, command: cmd, fallback: fallback)
        }
        #expect(name("/usr/local/bin/node", "node /a/node_modules/vite/bin/vite.js --port 5173") == "vite")
        #expect(name("/usr/local/bin/node", "node server.js") == "server.js")
        #expect(name("/opt/homebrew/bin/python3.12", "python3 -m uvicorn main:app") == "uvicorn")
        #expect(name("/opt/homebrew/opt/postgresql@16/bin/postgres", "postgres -D x") == "postgres")
        #expect(name("/Applications/Discord.app/Contents/Frameworks/Discord Helper (Renderer).app/Contents/MacOS/Discord Helper (Renderer)",
                     "/Applications/Discord.app/... --type=renderer") == "Discord")
        // Real-world cases the first version got wrong:
        #expect(name("/Users/me/Library/Application Support/Steam/Steam.AppBundle/Steam/Contents/MacOS/steam_osx",
                     "/Users/me/Library/Application Support/Steam/Steam.AppBundle/Steam/Contents/MacOS/steam_osx") == "Steam")
        #expect(name("/Users/me/.local/share/claude/versions/2.1.329", "claude --dangerously-skip-permissions") == "claude")
        #expect(name(nil, nil, "thing") == "thing")
        #expect(name(nil, "node vite.js") == "vite.js")
    }

    @Test func classification() {
        let home = "/Users/me"
        func kind(_ exe: String?, _ name: String, cmd: String? = nil, cwd: String? = nil) -> ListeningPort.Kind {
            PortsReader.classify(executablePath: exe, processName: name, command: cmd, workingDirectory: cwd, home: home)
        }
        #expect(kind("/usr/libexec/rapportd", "rapportd") == .system)
        #expect(kind("/System/Library/CoreServices/ControlCenter.app/Contents/MacOS/ControlCenter", "ControlCenter") == .system)
        #expect(kind("/Applications/Steam.app/Contents/MacOS/steam_osx", "steam_osx") == .app)
        #expect(kind("/Users/me/Library/Application Support/Steam/Steam.AppBundle/Steam/Contents/MacOS/steam_osx",
                     "steam_osx", cwd: "/Users/me/Library/Application Support/Steam/Steam.AppBundle/Steam/Contents/MacOS") == .app)
        #expect(kind("/Users/me/.local/share/claude/versions/2.1.329", "2.1.329", cmd: "claude") == .app)
        #expect(kind("/Applications/OpenCode.app/Contents/Resources/opencode-cli", "opencode-cli") == .app)
        #expect(kind("/usr/local/bin/node", "node", cmd: "node vite.js") == .dev)
        #expect(kind("/opt/homebrew/opt/postgresql@16/bin/postgres", "postgres") == .dev)
        #expect(kind("/Applications/Docker.app/Contents/MacOS/com.docker.backend", "com.docker.backend") == .dev)
    }

    @Test func webServerGuess() {
        #expect(!ListeningPort(pid: 1, port: 5432, processName: "postgres", hosts: ["127.0.0.1"],
                               executablePath: "/opt/homebrew/bin/postgres").looksLikeWebServer)
        #expect(ListeningPort(pid: 1, port: 5173, processName: "node", hosts: ["[::1]"],
                              executablePath: "/usr/local/bin/node", command: "node vite.js").looksLikeWebServer)
    }

    @Test func endToEndWithFakeRunner() async throws {
        let exePaths: [Int32: String] = [
            626: "/usr/libexec/rapportd",
            661: "/System/Library/CoreServices/ControlCenter.app/Contents/MacOS/ControlCenter",
            1003: "/opt/homebrew/opt/postgresql@16/bin/postgres",
            72133: "/Applications/Discord.app/Contents/Frameworks/Discord Helper (Renderer).app/Contents/MacOS/Discord Helper (Renderer)",
            9001: "/usr/local/bin/node",
        ]
        let ports = await PortsReader.read(runner: FakeRunner(), executablePath: { exePaths[$0] })
        // Sorted: dev first (by port), then apps, then system.
        #expect(ports.map(\.port) == [5173, 5432, 6463, 5000, 7000, 49198])
        let vite = try #require(ports.first)
        #expect(vite.displayName == "vite")
        #expect(vite.workingDirectory == "/tmp/myapp/frontend")
        #expect(vite.elapsedSeconds == 754)
        #expect(vite.kind == .dev)
        let discord = try #require(ports.first { $0.port == 6463 })
        #expect(discord.kind == .app)
        #expect(discord.displayName == "Discord")
    }

    @Test func projectNames() throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appendingPathComponent("wb-home-\(UUID().uuidString)").path
        let repo = home + "/code/myrepo"
        try fm.createDirectory(atPath: repo + "/.git", withIntermediateDirectories: true)
        try fm.createDirectory(atPath: repo + "/frontend", withIntermediateDirectories: true)
        defer { try? fm.removeItem(atPath: home) }
        #expect(PortsReader.projectName(forDirectory: repo + "/frontend", home: home) == "myrepo/frontend")
        #expect(PortsReader.projectName(forDirectory: repo, home: home) == "myrepo")
        #expect(PortsReader.projectName(forDirectory: home, home: home) == "~")
        #expect(PortsReader.projectName(forDirectory: "/", home: home) == nil)
        // Outside home, a git checkout (like /opt/homebrew) isn't "your project": just the folder name.
        #expect(PortsReader.projectName(forDirectory: "/opt/homebrew/var/postgresql@16", home: home) == "postgresql@16")
        #expect(PortsReader.projectName(forDirectory: "/Applications/Steam.app/Contents/MacOS", home: home) == nil)
    }

    @Test func stopRefusesPidOne() {
        #expect(throws: PortsReader.StopError.self) { try PortsReader.stop(pid: 1, force: false) }
    }
}

@Suite("Space")
struct SpaceTests {
    @Test func findsNodeModulesWithoutNesting() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("wb-space-\(UUID().uuidString)")
        let paths = [
            "proj-a/node_modules/left-pad/node_modules/inner",
            "proj-b/frontend/node_modules/react",
            "proj-c/.git/node_modules",          // inside a hidden folder: skipped
            "proj-d/src",
        ]
        for p in paths {
            try fm.createDirectory(at: root.appendingPathComponent(p), withIntermediateDirectories: true)
        }
        try Data(count: 4096).write(to: root.appendingPathComponent("proj-a/node_modules/left-pad/index.js"))
        defer { try? fm.removeItem(at: root) }

        let found = CacheScanner.findNodeModules(under: root.path).sorted()
        #expect(found == [root.path + "/proj-a/node_modules", root.path + "/proj-b/frontend/node_modules"])
        #expect(CacheScanner.nodeModulesLabel(found[1], root: root.path) == "proj-b/frontend")
        let size = try #require(CacheScanner.size(of: root.path + "/proj-a/node_modules"))
        #expect(size >= 4096)
        #expect(CacheScanner.size(of: root.path + "/missing") == nil)
    }

    @Test func downloadsAndTrashAreNeverTrashable() {
        let locs = CacheScanner.knownLocations(home: "/Users/test")
        for loc in locs where loc.name == "Downloads" || loc.name == "Trash" {
            let item = SpaceItem(name: loc.name, path: loc.path, bytes: 1, safety: loc.safety)
            #expect(!item.canTrash)
        }
    }
}
