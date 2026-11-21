import Foundation
import Observation
import WorkbenchCore

@MainActor
@Observable
final class HealthModel {
    private(set) var battery: BatteryInfo?
    private(set) var hasBattery = true
    private(set) var memory: MemoryInfo?
    private(set) var storage: StorageInfo?
    private(set) var cpu: CPUInfo?
    private(set) var backup: BackupStatus?
    private(set) var uptime: TimeInterval?
    private(set) var apps: [AppUsage] = []
    private(set) var lastUpdated: Date?

    let chip = HealthModel.sysctlString("machdep.cpu.brand_string") ?? "Mac"
    let osVersion = ProcessInfo.processInfo.operatingSystemVersionString

    private let sampler = CPUSampler()
    private let runner = CommandRunner()
    private var timer: Timer?
    private var isVisible = false
    private var isRefreshing = false
    private var lastBackupCheck: Date?

    init() {
        refresh()
        schedule()
    }

    // MARK: Assessments

    var batteryAssessment: Assessment? { battery.map(Assess.battery) }
    var storageAssessment: Assessment? { storage.map(Assess.storage) }
    var memoryAssessment: Assessment? { memory.map(Assess.memory) }
    var thermalAssessment: Assessment? { cpu.map { Assess.thermal($0.thermal, cpuUsage: $0.usagePercent) } }
    var backupAssessment: Assessment? { backup.map { Assess.backup($0) } }
    var uptimeAssessment: Assessment? { uptime.map(Assess.uptime) }

    var allAssessments: [Assessment] {
        [batteryAssessment, storageAssessment, memoryAssessment, thermalAssessment, backupAssessment, uptimeAssessment]
            .compactMap { $0 }
    }

    var overall: Verdict { Assess.overall(allAssessments) }

    var topMemoryApps: [AppUsage] { ProcessReader.topByMemory(apps) }
    var topCPUApps: [AppUsage] { ProcessReader.topByCPU(apps) }

    // MARK: Refreshing

    /// Fast refresh while the popover is open, slow in the background (just enough to keep the menu-bar icon honest).
    func setVisible(_ visible: Bool) {
        guard visible != isVisible else { return }
        isVisible = visible
        if visible { refresh() }
        schedule()
    }

    private func schedule() {
        timer?.invalidate()
        let interval: TimeInterval = isVisible ? 3 : 300
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func refresh() {
        guard !isRefreshing else { return }
        isRefreshing = true
        // Cheap, synchronous reads.
        let battery = BatteryReader.read()
        self.battery = battery
        hasBattery = battery != nil
        memory = MemoryReader.read()
        cpu = sampler.read()
        uptime = SystemReader.uptime()

        let runner = self.runner
        let checkBackup = lastBackupCheck.map { Date().timeIntervalSince($0) > 600 } ?? true
        Task {
            async let storage = StorageReader.read(runner: runner)
            async let apps = ProcessReader.read(runner: runner)
            async let backup: BackupStatus? = checkBackup ? SystemReader.readBackup(runner: runner) : nil
            let (s, a, b) = await (storage, apps, backup)
            self.storage = s
            self.apps = a
            if let b {
                self.backup = b
                self.lastBackupCheck = Date()
            }
            self.lastUpdated = Date()
            self.isRefreshing = false
        }
    }

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(decoding: buffer.prefix { $0 != 0 }, as: UTF8.self)
    }
}
