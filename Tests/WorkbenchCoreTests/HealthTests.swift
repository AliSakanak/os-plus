import Foundation
import Testing
@testable import WorkbenchCore

// Values captured from a real MacBook Pro (M4 Pro), serial number removed.
nonisolated(unsafe) private let realBattery: [String: Any] = [
    "DesignCapacity": 8579,
    "AppleRawMaxCapacity": 7675,
    "NominalChargeCapacity": 7919,
    "MaxCapacity": 100,
    "CycleCount": 193,
    "DesignCycleCount9C": 1000,
    "Temperature": 3027,
    "CurrentCapacity": 41,
    "IsCharging": false,
    "ExternalConnected": false,
    "FullyCharged": false,
    "AvgTimeToEmpty": 129,
    "AvgTimeToFull": 65535,
    "BatteryInstalled": true,
    "PermanentFailureStatus": 0,
]

@Suite("Battery")
struct BatteryTests {
    @Test func parsesRealValues() throws {
        let b = try #require(BatteryReader.parse(realBattery))
        #expect(b.cycleCount == 193)
        #expect(b.designCycleCount == 1000)
        #expect(abs(b.healthPercent - 89.46) < 0.01)
        #expect(b.temperatureC == 30.27)
        #expect(b.chargePercent == 41)
        #expect(b.minutesRemaining == 129)
        #expect(b.statusText == "2:09 remaining")
    }

    @Test func ignoresMaxCapacityPercentageOnAppleSilicon() throws {
        // MaxCapacity reads 100 but the real health is ~89%: we must use AppleRawMaxCapacity.
        let b = try #require(BatteryReader.parse(realBattery))
        #expect(b.rawMaxCapacity == 7675)
    }

    @Test func calculatingTimeIsNil() throws {
        var props = realBattery
        props["IsCharging"] = true
        props["ExternalConnected"] = true
        let b = try #require(BatteryReader.parse(props))
        #expect(b.minutesRemaining == nil)  // 65535 = still estimating
        #expect(b.statusText == "Charging")
    }

    @Test func noBatteryReturnsNil() {
        #expect(BatteryReader.parse(["BatteryInstalled": false, "DesignCapacity": 8579]) == nil)
        #expect(BatteryReader.parse([:]) == nil)
    }

    @Test func verdicts() throws {
        var b = try #require(BatteryReader.parse(realBattery))
        #expect(Assess.battery(b).verdict == .good)
        b.rawMaxCapacity = 7100   // 82.8%
        #expect(Assess.battery(b).verdict == .watch)
        b.rawMaxCapacity = 6700   // 78%
        #expect(Assess.battery(b).verdict == .act)
        b.rawMaxCapacity = 8000
        b.permanentFailure = true
        #expect(Assess.battery(b).verdict == .act)
    }
}

@Suite("Storage")
struct StorageTests {
    let diskutilPlist = """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0"><dict>
      <key>MediaName</key><string>APPLE SSD AP0512Z</string>
      <key>SMARTStatus</key><string>Verified</string>
    </dict></plist>
    """

    @Test func parsesDiskutil() {
        let (smart, name) = StorageReader.parseDiskutil(diskutilPlist)
        #expect(smart == .verified)
        #expect(name == "APPLE SSD AP0512Z")
        #expect(StorageReader.parseDiskutil("garbage").smart == .unknown)
    }

    @Test func verdicts() {
        // A real Mac: 494 GB container, 67 GB free → 86% used → watch.
        let mine = StorageInfo(total: 494_384_795_648, available: 67_168_555_008, smartStatus: .verified)
        #expect(Assess.storage(mine).verdict == .watch)
        let roomy = StorageInfo(total: 1_000_000_000_000, available: 400_000_000_000, smartStatus: .verified)
        #expect(Assess.storage(roomy).verdict == .good)
        let tight = StorageInfo(total: 500_000_000_000, available: 15_000_000_000, smartStatus: .verified)
        #expect(Assess.storage(tight).verdict == .act)
        let failing = StorageInfo(total: 1_000_000_000_000, available: 400_000_000_000, smartStatus: .failing)
        #expect(Assess.storage(failing).verdict == .act)
    }
}

@Suite("Memory & CPU")
struct MemoryCPUTests {
    @Test func pressureLevels() {
        #expect(MemoryPressure(sysctlLevel: 1) == .normal)
        #expect(MemoryPressure(sysctlLevel: 2) == .warning)
        #expect(MemoryPressure(sysctlLevel: 4) == .critical)
        #expect(MemoryPressure(sysctlLevel: 0) == .unknown)
    }

    @Test func memoryVerdicts() {
        let gb: UInt64 = 1_073_741_824
        var m = MemoryInfo(total: 48 * gb, appMemory: 10 * gb, wired: 3 * gb, compressed: 1 * gb,
                           cachedFiles: 8 * gb, swapUsed: gb / 2, swapTotal: 2 * gb, pressure: .normal)
        #expect(m.used == 14 * gb)
        #expect(Assess.memory(m).verdict == .good)
        m.swapUsed = 10 * gb
        #expect(Assess.memory(m).verdict == .watch)
        m.pressure = .critical
        #expect(Assess.memory(m).verdict == .act)
    }

    @Test func liveReadersReturnSaneValues() throws {
        let m = try #require(MemoryReader.read())
        #expect(m.total > 0)
        #expect(m.used <= m.total * 2)  // compressed can make this odd, but never wildly off
        let cpu = CPUSampler().read()
        #expect(cpu.coreCount > 0)
    }

    @Test func cpuUsageFromTicks() {
        let a = CPUTicks(user: 100, system: 50, idle: 850, nice: 0)
        let b = CPUTicks(user: 200, system: 100, idle: 1700, nice: 0)
        #expect(CPUTicks.usage(from: a, to: b) == 15)
        #expect(CPUTicks.usage(from: a, to: a) == nil)
    }
}

@Suite("System")
struct SystemTests {
    @Test func backupDateFromPath() throws {
        let date = try #require(SystemReader.parseBackupDate(
            fromPath: "/Volumes/.timemachine/ABC/2026-11-12-101010.backup/2026-11-12-101010.backup\n"))
        let c = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        #expect(c.year == 2026 && c.month == 11 && c.day == 12 && c.hour == 10 && c.minute == 10)
        #expect(SystemReader.parseBackupDate(fromPath: "nonsense") == nil)
    }

    @Test func backupInterpretation() {
        let empty = CommandResult(stdout: "<plist version=\"1.0\">\n<dict>\n</dict>\n</plist>\n")
        #expect(SystemReader.interpretBackup(destinationInfo: empty, latest: nil) == .notConfigured)

        let denied = CommandResult(stdout: "", stderr: "Operation not permitted", exitCode: 1)
        #expect(SystemReader.interpretBackup(destinationInfo: denied, latest: nil) == .noAccess)

        let configured = CommandResult(stdout: "<dict><key>Destinations</key><array><dict><key>ID</key></dict></array></dict>")
        #expect(SystemReader.interpretBackup(destinationInfo: configured, latest: nil) == .neverCompleted)

        let failedMount = CommandResult(stdout: "", stderr: "Failed to mount backup destination", exitCode: 1)
        #expect(SystemReader.interpretBackup(destinationInfo: configured, latest: failedMount) == .neverCompleted)

        let ok = CommandResult(stdout: "/Volumes/x/2026-11-19-080000.backup\n")
        guard case .lastBackup = SystemReader.interpretBackup(destinationInfo: configured, latest: ok) else {
            Issue.record("expected a backup date")
            return
        }
    }

    @Test func backupVerdicts() {
        let now = Date()
        #expect(Assess.backup(.lastBackup(now.addingTimeInterval(-86_400)), now: now).verdict == .good)
        #expect(Assess.backup(.lastBackup(now.addingTimeInterval(-10 * 86_400)), now: now).verdict == .watch)
        #expect(Assess.backup(.lastBackup(now.addingTimeInterval(-20 * 86_400)), now: now).verdict == .act)
        #expect(Assess.backup(.notConfigured).verdict == .watch)
        #expect(Assess.backup(.noAccess).verdict == .unknown)
    }

    @Test func overallIgnoresUnknown() {
        #expect(Assess.overall([Assessment(.good, ""), Assessment(.unknown, "")]) == .good)
        #expect(Assess.overall([Assessment(.good, ""), Assessment(.watch, ""), Assessment(.act, "")]) == .act)
        #expect(Assess.overall([]) == .unknown)
    }

    @Test func formatting() {
        #expect(Format.duration(5 * 86_400 + 22 * 3_600 + 100) == "5d 22h")
        #expect(Format.duration(3 * 3_600 + 12 * 60) == "3h 12m")
        #expect(Format.duration(59) == "0m")
        #expect(Format.hoursMinutes(111) == "1:51")
    }
}

@Suite("Processes")
struct ProcessTests {
    let psOutput = """
    82877 2819776   0.0 /System/Library/Frameworks/WebKit.framework/Versions/A/XPCServices/com.apple.WebKit.WebContent.xpc/Contents/MacOS/com.apple.WebKit.WebContent
    72133 1066896  40.6 /Applications/Discord.app/Contents/Frameworks/Discord Helper (Renderer).app/Contents/MacOS/Discord Helper (Renderer)
    72100  200000   2.0 /Applications/Discord.app/Contents/MacOS/Discord
     1003   50000   0.1 /opt/homebrew/opt/postgresql@16/bin/postgres
    """

    @Test func groupsHelpersIntoApps() throws {
        let apps = ProcessReader.group(psOutput)
        let discord = try #require(apps.first { $0.name == "Discord" })
        #expect(discord.processCount == 2)
        #expect(discord.memoryBytes == (1_066_896 + 200_000) * 1024)
        #expect(abs(discord.cpuPercent - 42.6) < 0.001)
        #expect(apps.contains { $0.name == "postgres" })
        #expect(apps.contains { $0.name == "Web pages (Safari & apps)" })
    }

    @Test func topLists() {
        let apps = ProcessReader.group(psOutput)
        #expect(ProcessReader.topByMemory(apps, limit: 1).first?.name == "Web pages (Safari & apps)")
        #expect(ProcessReader.topByCPU(apps).first?.name == "Discord")
        #expect(!ProcessReader.topByCPU(apps).contains { $0.name == "postgres" })  // under 0.5%
    }
}

@Suite("Byte formatting")
struct ByteFormatTests {
    @Test func decimal() {
        #expect(Format.bytes(69_920_000_000) == "70 GB")
        #expect(Format.bytes(494_380_000_000) == "494 GB")
        #expect(Format.bytes(5_340_000_000) == "5.3 GB")
        #expect(Format.bytes(748_000_000) == "748 MB")
        #expect(Format.bytes(999_900_000) == "1 GB")
        #expect(Format.bytes(2_000_000_000) == "2 GB")
        #expect(Format.bytes(512) == "512 bytes")
    }

    @Test func binary() {
        #expect(Format.memory(48 * 1_073_741_824) == "48 GB")
        #expect(Format.memory(785_186_816) == "749 MB")
    }
}
