import CoreAudio
import Darwin
import Foundation

// MARK: - Grouping audio processes into apps

/// The user-facing app a process belongs to.
public struct AppIdentity: Sendable, Equatable {
    public var id: String        // bundle identifier
    public var name: String
    public var pid: pid_t

    public init(id: String, name: String, pid: pid_t) {
        self.id = id
        self.name = name
        self.pid = pid
    }
}

/// An app with one or more audio processes (a browser and its audio helpers, say).
public struct AudioApp: Sendable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var pid: pid_t
    public var processes: [AudioProcess]

    public var isPlaying: Bool { processes.contains { $0.isPlaying } }
    public var processObjectIDs: [AudioObjectID] { processes.map(\.objectID).sorted() }

    /// Devices the app is playing to, most-used first.
    public var outputDevices: [AudioDeviceID] {
        var seen: [AudioDeviceID] = []
        for process in processes.sorted(by: { $0.isPlaying && !$1.isPlaying }) {
            for device in process.outputDevices where !seen.contains(device) { seen.append(device) }
        }
        return seen
    }
}

public enum AudioAppGrouping {
    /// Groups audio processes by the app responsible for them. Processes with no regular app behind
    /// them (daemons, system services) are left out, as is Workbench itself.
    /// - Parameters:
    ///   - responsible: maps a pid to the pid macOS holds responsible for it.
    ///   - app: the regular (Dock) app for a pid, or nil.
    public static func group(_ processes: [AudioProcess], ownPID: pid_t,
                             responsible: (pid_t) -> pid_t,
                             app: (pid_t) -> AppIdentity?) -> [AudioApp] {
        var byID: [String: AudioApp] = [:]
        for process in processes where process.pid != ownPID {
            let owner = responsible(process.pid)
            guard owner != ownPID, let identity = app(owner) ?? app(process.pid), identity.pid != ownPID else { continue }
            byID[identity.id, default: AudioApp(id: identity.id, name: identity.name, pid: identity.pid, processes: [])]
                .processes.append(process)
        }
        return byID.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}

// MARK: - Volume settings

public struct VolumeSetting: Sendable, Equatable {
    /// Slider position, 0…1. 1 = the app's normal volume (Workbench never boosts).
    public var level: Double
    public var muted: Bool

    public init(level: Double = 1, muted: Bool = false) {
        self.level = min(1, max(0, level))
        self.muted = muted
    }

    public static let normal = VolumeSetting()

    /// Anything other than "full and unmuted" needs a tap.
    public var needsTap: Bool { muted || level < 0.995 }

    /// Linear amplitude for the audio thread. Squared so the slider feels even to the ear:
    /// 50% is about half as loud (−12 dB) rather than barely quieter.
    public var gain: Float {
        if muted { return 0 }
        let l = min(1, max(0, level))
        return Float(l * l)
    }
}

// MARK: - Planning which taps should exist

public struct TapPlan: Sendable, Equatable {
    public var appID: String
    public var name: String
    public var processObjectIDs: [AudioObjectID]
    public var outputDevice: AudioDeviceID

    public init(appID: String, name: String, processObjectIDs: [AudioObjectID], outputDevice: AudioDeviceID) {
        self.appID = appID
        self.name = name
        self.processObjectIDs = processObjectIDs
        self.outputDevice = outputDevice
    }
}

public enum TapChange: Sendable, Equatable {
    case start(TapPlan)
    case stop(appID: String)
    /// Same app, different processes and/or output device: adjust the running tap in place.
    case retarget(TapPlan, processesChanged: Bool, deviceChanged: Bool)
}

public enum VolumePlanner {
    /// Where an app's audio should go: the device it's already playing to (if that's the default, or
    /// it's the only one), otherwise the default output.
    public static func outputDevice(for app: AudioApp, defaultOutput: AudioDeviceID?,
                                    isUsable: (AudioDeviceID) -> Bool) -> AudioDeviceID? {
        let devices = app.outputDevices.filter(isUsable)
        if let defaultOutput, devices.isEmpty || devices.contains(defaultOutput) { return defaultOutput }
        return devices.first ?? defaultOutput
    }

    /// The taps that should exist right now.
    /// - Parameter holding: apps back at 100% whose tap is kept briefly, so dragging a slider through
    ///   100% doesn't tear the tap down and rebuild it.
    public static func plan(apps: [AudioApp], settings: [String: VolumeSetting], holding: Set<String> = [],
                            defaultOutput: AudioDeviceID?,
                            isUsable: (AudioDeviceID) -> Bool = { _ in true }) -> [String: TapPlan] {
        var plans: [String: TapPlan] = [:]
        for app in apps where !app.processes.isEmpty {
            let wanted = settings[app.id]?.needsTap ?? false
            guard wanted || holding.contains(app.id) else { continue }
            guard let device = outputDevice(for: app, defaultOutput: defaultOutput, isUsable: isUsable) else { continue }
            plans[app.id] = TapPlan(appID: app.id, name: app.name, processObjectIDs: app.processObjectIDs, outputDevice: device)
        }
        return plans
    }

    /// What to do to get from the running taps to the planned ones.
    public static func changes(current: [String: TapPlan], desired: [String: TapPlan]) -> [TapChange] {
        var result: [TapChange] = []
        for id in current.keys.sorted() where desired[id] == nil {
            result.append(.stop(appID: id))
        }
        for id in desired.keys.sorted() {
            let want = desired[id]!
            guard let have = current[id] else {
                result.append(.start(want))
                continue
            }
            let processesChanged = have.processObjectIDs != want.processObjectIDs
            let deviceChanged = have.outputDevice != want.outputDevice
            if processesChanged || deviceChanged {
                result.append(.retarget(want, processesChanged: processesChanged, deviceChanged: deviceChanged))
            }
        }
        return result
    }
}

// MARK: - Permission

/// macOS asks once before an app can tap other apps' audio ("System Audio Recording Only" in
/// Privacy & Security). There's no public API to check that permission, so this uses the private
/// TCC calls that open-source audio-capture tools use: a read-only check, plus the standard system
/// prompt. If they're ever missing, the status is `.unknown`.
///
/// Checking matters for safety: a tap read without permission delivers silence while still muting
/// the app, so Workbench never creates a tap unless this says `.authorized`.
public enum AudioCapturePermission {
    public enum Status: Sendable, Equatable {
        case authorized, denied, notDetermined, unknown
    }

    private typealias Preflight = @convention(c) (CFString, CFDictionary?) -> Int
    private typealias Request = @convention(c) (CFString, CFDictionary?, @escaping @convention(block) (Bool) -> Void) -> Void

    nonisolated(unsafe) private static let tcc: UnsafeMutableRawPointer? =
        dlopen("/System/Library/PrivateFrameworks/TCC.framework/Versions/A/TCC", RTLD_NOW)
    private static var service: CFString { "kTCCServiceAudioCapture" as CFString }

    public static var status: Status {
        guard let tcc, let sym = dlsym(tcc, "TCCAccessPreflight") else { return .unknown }
        let preflight = unsafeBitCast(sym, to: Preflight.self)
        switch preflight(service, nil) {
        case 0: return .authorized
        case 1: return .denied
        default: return .notDetermined
        }
    }

    /// Shows the system prompt (only if the user hasn't answered yet) and reports the answer.
    public static func request(_ completion: @escaping @Sendable (Bool) -> Void) {
        guard let tcc, let sym = dlsym(tcc, "TCCAccessRequest") else {
            completion(false)
            return
        }
        let request = unsafeBitCast(sym, to: Request.self)
        request(service, nil) { granted in completion(granted) }
    }

    public static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture")!
}
