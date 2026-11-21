import AppKit
import CoreAudio
import Foundation
import Observation
import WorkbenchCore

/// One app in the Sound tab.
struct SoundRow: Identifiable, Equatable {
    let id: String
    let name: String
    let pid: pid_t
    var isPlaying: Bool
    var setting: VolumeSetting
    var isControlled: Bool
    var error: String?
}

/// Per-app volume. Levels live for this session only: quitting Workbench (or a crash) returns
/// every app to its normal volume, because macOS removes our taps when the process ends.
@MainActor
@Observable
final class SoundModel {
    private(set) var rows: [SoundRow] = []
    private(set) var permission: AudioCapturePermission.Status = AudioCapturePermission.status
    private(set) var outputName: String?
    private(set) var isRequestingPermission = false

    private var settings: [String: VolumeSetting] = [:]
    private var taps: [String: AppAudioTap] = [:]
    private var plans: [String: TapPlan] = [:]
    private struct Failure {
        var plan: TapPlan
        var message: String
        var at: Date
        /// Only a slider move retries it (no automatic retries).
        var sticky = false
    }
    private var failed: [String: Failure] = [:]
    /// Apps back at 100% whose tap is kept a moment longer, so a slider dragged through 100%
    /// doesn't tear down and rebuild the tap (each rebuild is a tiny gap in the sound).
    private var holdUntil: [String: Date] = [:]
    /// When each app's tap was last rebuilt after stopping on its own, to spot a tap that keeps dying.
    private var rebuilds: [String: [Date]] = [:]
    /// When the TCC check itself is unavailable, the user's "Allow" click is taken as consent and
    /// macOS shows its own prompt on first use.
    private var proceedWithoutPreflight = false
    /// `--demo-sound`: shows sample levels for screenshots. Never creates a tap.
    private var previewOnly = false

    private var listeners: [AudioListenerToken] = []
    private var timer: Timer?
    private var isVisible = false
    private var reconcileQueued = false
    private var icons: [String: NSImage] = [:]

    init() {
        let queue = DispatchQueue.main
        let poke: @Sendable () -> Void = { [weak self] in
            Task { @MainActor in self?.queueReconcile() }
        }
        // Apps follow a new default output (headphones plugged in) a moment after macOS announces
        // it, so look again shortly afterwards too.
        let outputChanged: @Sendable () -> Void = { [weak self] in
            Task { @MainActor in self?.outputDidChange() }
        }
        let restarted: @Sendable () -> Void = { [weak self] in
            Task { @MainActor in self?.audioServerRestarted() }
        }
        listeners = [
            AudioHAL.listen(AudioHAL.system, kAudioHardwarePropertyProcessObjectList, queue: queue, handler: poke),
            AudioHAL.listen(AudioHAL.system, kAudioHardwarePropertyDefaultOutputDevice, queue: queue, handler: outputChanged),
            AudioHAL.listen(AudioHAL.system, kAudioHardwarePropertyDevices, queue: queue, handler: poke),
            AudioHAL.listen(AudioHAL.system, kAudioHardwarePropertyServiceRestarted, queue: queue, handler: restarted),
        ].compactMap { $0 }
    }

    var canControl: Bool { permission == .authorized || proceedWithoutPreflight || previewOnly }
    var anyChanged: Bool { settings.values.contains { $0.needsTap } }
    var controlledCount: Int { taps.count }
    var playing: [SoundRow] { rows.filter(\.isPlaying) }
    var quiet: [SoundRow] { rows.filter { !$0.isPlaying } }

    func icon(for row: SoundRow) -> NSImage {
        if let cached = icons[row.id] { return cached }
        let image = NSRunningApplication(processIdentifier: row.pid)?.icon
            ?? NSWorkspace.shared.icon(for: .application)
        icons[row.id] = image
        return image
    }

    func setVisible(_ visible: Bool) {
        guard visible != isVisible else { return }
        isVisible = visible
        if visible { reconcile() }
        schedule()
    }

    func showPreview() {
        previewOnly = true
        reconcile()
        let ids = rows.map(\.id)
        if ids.count > 0 { settings[ids[0]] = VolumeSetting(level: 0.35) }
        if ids.count > 2 { settings[ids[2]] = VolumeSetting(level: 0.6, muted: true) }
        reconcile()
    }

    // MARK: User actions

    func setLevel(_ level: Double, for id: String) {
        var setting = settings[id] ?? .normal
        setting.level = min(1, max(0, level))
        if setting.level > 0.005 { setting.muted = false }
        apply(setting, to: id)
    }

    func toggleMute(_ id: String) {
        var setting = settings[id] ?? .normal
        setting.muted.toggle()
        if !setting.muted && setting.level < 0.005 { setting.level = 0.5 }
        apply(setting, to: id)
    }

    func reset(_ id: String) {
        apply(.normal, to: id, hold: 0.25)
    }

    func resetAll() {
        for id in Array(settings.keys) { apply(.normal, to: id, hold: 0.25) }
    }

    func requestPermission() {
        guard !isRequestingPermission else { return }
        isRequestingPermission = true
        AudioCapturePermission.request { granted in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isRequestingPermission = false
                if AudioCapturePermission.status == .unknown && granted == false {
                    // The TCC calls aren't there (future macOS?). Let macOS prompt on first use instead.
                    self.proceedWithoutPreflight = true
                }
                self.reconcile()
            }
        }
    }

    func openPrivacySettings() {
        NSWorkspace.shared.open(AudioCapturePermission.settingsURL)
    }

    /// Called when Workbench quits: hand every app back cleanly (macOS would also do this for us).
    func stopAll() {
        for tap in taps.values { tap.stop() }
        taps.removeAll()
        plans.removeAll()
    }

    // MARK: Engine

    private func apply(_ setting: VolumeSetting, to id: String, hold: TimeInterval = 3) {
        settings[id] = setting
        // Let a fresh slider move retry a failed app, but not 60 times a second mid-drag.
        if let failure = failed[id], Date().timeIntervalSince(failure.at) > 2 { failed[id] = nil }
        if setting.needsTap {
            holdUntil[id] = nil
        } else if taps[id] != nil {
            holdUntil[id] = Date().addingTimeInterval(hold)
            DispatchQueue.main.asyncAfter(deadline: .now() + hold + 0.05) { [weak self] in
                self?.reconcile()
            }
        }
        if let tap = taps[id] {
            tap.setGain(setting.gain)
            updateRow(id)
        } else if setting.needsTap {
            reconcile()
        } else {
            updateRow(id)
        }
        schedule()
    }

    private func updateRow(_ id: String) {
        guard let i = rows.firstIndex(where: { $0.id == id }) else { return }
        rows[i].setting = settings[id] ?? .normal
        rows[i].isControlled = taps[id] != nil
        rows[i].error = failed[id]?.message
    }

    /// Nothing to keep up to date: tab closed and no app turned down. Then audio events are ignored.
    private var isIdle: Bool { !isVisible && taps.isEmpty && !anyChanged }

    private func outputDidChange() {
        queueReconcile()
        for delay in [0.3, 1.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.queueReconcile() }
        }
    }

    private func queueReconcile() {
        guard !reconcileQueued, !isIdle else { return }
        reconcileQueued = true
        DispatchQueue.main.async { [weak self] in
            self?.reconcileQueued = false
            self?.reconcile()
        }
    }

    private func audioServerRestarted() {
        // Every object we held belonged to the old audio server. Drop them and start over.
        for tap in taps.values { tap.stop() }
        taps.removeAll()
        plans.removeAll()
        failed.removeAll()
        reconcile()
    }

    private static func identity(for pid: pid_t) -> AppIdentity? {
        guard let app = NSRunningApplication(processIdentifier: pid),
              app.activationPolicy == .regular,
              let id = app.bundleIdentifier else { return nil }
        return AppIdentity(id: id, name: app.localizedName ?? id, pid: pid)
    }

    private static func isUsableOutput(_ device: AudioDeviceID) -> Bool {
        AudioHAL.deviceIsAlive(device) && AudioHAL.hasOutput(device)
    }

    /// Brings the running taps in line with the settings, the apps using audio and the devices.
    func reconcile() {
        let processes = AudioHAL.snapshotProcesses()
        let apps = AudioAppGrouping.group(processes, ownPID: getpid(),
                                          responsible: ResponsibleProcess.pid(for:),
                                          app: Self.identity(for:))
        let defaultOutput = AudioHAL.defaultOutputDevice
        outputName = defaultOutput.flatMap(AudioHAL.deviceName)
        permission = AudioCapturePermission.status

        // A tap the audio server stopped running (sleep, device vanished) is rebuilt from scratch.
        var rebuild: Set<String> = []
        for (id, tap) in taps {
            if tap.isRunning {
                do { try tap.followFormatChanges() } catch {
                    tap.stop()
                    taps[id] = nil
                    plans[id] = nil
                    rebuild.insert(id)
                }
            } else {
                tap.stop()
                taps[id] = nil
                plans[id] = nil
                rebuild.insert(id)
            }
        }

        let now = Date()
        holdUntil = holdUntil.filter { $0.value > now }
        for id in rebuild {
            let recent = (rebuilds[id] ?? []).filter { now.timeIntervalSince($0) < 30 } + [now]
            rebuilds[id] = recent
            if recent.count > 3, let plan = plans[id] ?? VolumePlanner.plan(
                apps: apps, settings: settings, defaultOutput: defaultOutput, isUsable: Self.isUsableOutput)[id] {
                // Something keeps stopping it: give the app back at its normal volume and say so,
                // rather than looping. A slider move tries again.
                failed[id] = Failure(plan: plan, message: "Its sound kept dropping out here, so it's back at normal volume.",
                                     at: now, sticky: true)
                rebuild.remove(id)
            }
        }
        var desired: [String: TapPlan] = [:]
        if canControl && !previewOnly {
            desired = VolumePlanner.plan(apps: apps, settings: settings, holding: Set(holdUntil.keys),
                                         defaultOutput: defaultOutput, isUsable: Self.isUsableOutput)
        }
        // Without permission a tap would mute the app and deliver silence, so none are created
        // (and any that exist are removed, e.g. if permission was revoked).

        for change in VolumePlanner.changes(current: plans, desired: desired) {
            switch change {
            case .stop(let id):
                taps[id]?.stop()
                taps[id] = nil
                plans[id] = nil

            case .start(let plan):
                // Don't hammer a failing app: retry only if something changed or a while has passed.
                if let previous = failed[plan.appID],
                   previous.sticky || (previous.plan == plan && now.timeIntervalSince(previous.at) < 30) { continue }
                // A rebuilt tap jumps straight to the chosen level (no fade down from full).
                startTap(plan, fadeFromFull: !rebuild.contains(plan.appID))

            case .retarget(let plan, let processesChanged, let deviceChanged):
                guard let tap = taps[plan.appID] else { continue }
                do {
                    if processesChanged { try tap.updateProcesses(plan.processObjectIDs) }
                    if deviceChanged { try tap.switchOutput(to: plan.outputDevice) }
                    plans[plan.appID] = plan
                } catch {
                    // Build a fresh tap before dropping the old one, so the app isn't briefly
                    // heard at full volume in between.
                    let old = tap
                    taps[plan.appID] = nil
                    plans[plan.appID] = nil
                    startTap(plan, fadeFromFull: false)
                    old.stop()
                }
            }
        }

        rows = apps.map { app in
            SoundRow(id: app.id, name: app.name, pid: app.pid, isPlaying: app.isPlaying,
                     setting: settings[app.id] ?? .normal, isControlled: taps[app.id] != nil,
                     error: failed[app.id]?.message)
        }
        schedule()
    }

    private func startTap(_ plan: TapPlan, fadeFromFull: Bool) {
        let gain = (settings[plan.appID] ?? .normal).gain
        do {
            let tap = try AppAudioTap(processes: plan.processObjectIDs, outputDevice: plan.outputDevice,
                                      gain: gain, name: plan.name, fadeFromFull: fadeFromFull)
            taps[plan.appID] = tap
            plans[plan.appID] = plan
            failed[plan.appID] = nil
        } catch {
            failed[plan.appID] = Failure(plan: plan, message: error.localizedDescription, at: Date())
        }
    }

    private func schedule() {
        timer?.invalidate()
        timer = nil
        // While visible: keep "playing" dots fresh. While controlling apps in the background: a
        // slower check that catches an app switching output device on its own.
        let interval: TimeInterval? = isVisible ? 1 : (taps.isEmpty ? nil : 2)
        guard let interval else { return }
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.reconcile() }
        }
    }
}
