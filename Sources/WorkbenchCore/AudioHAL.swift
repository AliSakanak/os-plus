import CoreAudio
import Darwin
import Foundation

/// Thin, typed wrappers over the Core Audio HAL property API. Read-only apart from the
/// tap/aggregate calls in AppAudioTap.
public enum AudioHAL {
    public static let system = AudioObjectID(kAudioObjectSystemObject)

    static func address(_ selector: AudioObjectPropertySelector,
                        _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    static func uint32(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                       _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> UInt32? {
        var addr = address(selector, scope)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }

    static func int32(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> Int32? {
        var addr = address(selector)
        var value: Int32 = 0
        var size = UInt32(MemoryLayout<Int32>.size)
        guard AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }

    static func float64(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> Float64? {
        var addr = address(selector)
        var value: Float64 = 0
        var size = UInt32(MemoryLayout<Float64>.size)
        guard AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }

    static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var addr = address(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &value) == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }

    static func objectList(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                           _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> [AudioObjectID] {
        var addr = address(selector, scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return Array(ids.prefix(Int(size) / MemoryLayout<AudioObjectID>.size))
    }

    static func streamCount(_ device: AudioObjectID, _ scope: AudioObjectPropertyScope) -> Int {
        var addr = address(kAudioDevicePropertyStreams, scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &addr, 0, nil, &size) == noErr else { return 0 }
        return Int(size) / MemoryLayout<AudioStreamID>.size
    }

    // MARK: System

    public static var defaultOutputDevice: AudioDeviceID? {
        guard let id = uint32(system, kAudioHardwarePropertyDefaultOutputDevice), id != kAudioObjectUnknown else { return nil }
        return id
    }

    public static var processObjects: [AudioObjectID] {
        objectList(system, kAudioHardwarePropertyProcessObjectList)
    }

    // MARK: Devices

    public static func deviceName(_ device: AudioDeviceID) -> String? { string(device, kAudioObjectPropertyName) }
    public static func deviceUID(_ device: AudioDeviceID) -> String? { string(device, kAudioDevicePropertyDeviceUID) }

    public static func deviceIsAlive(_ device: AudioDeviceID) -> Bool {
        (uint32(device, kAudioDevicePropertyDeviceIsAlive) ?? 0) != 0
    }

    public static func hasOutput(_ device: AudioDeviceID) -> Bool {
        streamCount(device, kAudioObjectPropertyScopeOutput) > 0
    }

    public static func bufferFrameSize(_ device: AudioDeviceID) -> UInt32? {
        uint32(device, kAudioDevicePropertyBufferFrameSize)
    }

    public static func nominalSampleRate(_ device: AudioDeviceID) -> Double? {
        float64(device, kAudioDevicePropertyNominalSampleRate)
    }

    public static func transportType(_ device: AudioDeviceID) -> UInt32? {
        uint32(device, kAudioDevicePropertyTransportType)
    }

    // MARK: Processes

    public static func processPID(_ process: AudioObjectID) -> pid_t? { int32(process, kAudioProcessPropertyPID) }
    public static func processBundleID(_ process: AudioObjectID) -> String? {
        string(process, kAudioProcessPropertyBundleID).flatMap { $0.isEmpty ? nil : $0 }
    }
    public static func processIsRunningOutput(_ process: AudioObjectID) -> Bool {
        (uint32(process, kAudioProcessPropertyIsRunningOutput) ?? 0) != 0
    }
    public static func processOutputDevices(_ process: AudioObjectID) -> [AudioDeviceID] {
        objectList(process, kAudioProcessPropertyDevices, kAudioObjectPropertyScopeOutput)
    }

    /// Every process the audio server knows about, with what it's doing right now.
    public static func snapshotProcesses() -> [AudioProcess] {
        processObjects.compactMap { object in
            guard let pid = processPID(object), pid > 0 else { return nil }
            return AudioProcess(
                objectID: object,
                pid: pid,
                bundleID: processBundleID(object),
                isPlaying: processIsRunningOutput(object),
                outputDevices: processOutputDevices(object)
            )
        }
    }

    // MARK: Listening

    /// Calls `handler` on `queue` whenever the property changes. Returns a token for `stopListening`.
    public static func listen(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                              scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                              queue: DispatchQueue, handler: @escaping @Sendable () -> Void) -> AudioListenerToken? {
        var addr = address(selector, scope)
        let block: AudioObjectPropertyListenerBlock = { _, _ in handler() }
        guard AudioObjectAddPropertyListenerBlock(object, &addr, queue, block) == noErr else { return nil }
        return AudioListenerToken(object: object, address: addr, queue: queue, block: block)
    }

    public static func stopListening(_ token: AudioListenerToken) {
        var addr = token.address
        AudioObjectRemovePropertyListenerBlock(token.object, &addr, token.queue, token.block)
    }
}

public struct AudioListenerToken: @unchecked Sendable {
    let object: AudioObjectID
    let address: AudioObjectPropertyAddress
    let queue: DispatchQueue
    let block: AudioObjectPropertyListenerBlock
}

/// One client process of the audio server (an app, a browser's audio helper, a daemon…).
public struct AudioProcess: Sendable, Equatable {
    public var objectID: AudioObjectID
    public var pid: pid_t
    public var bundleID: String?
    public var isPlaying: Bool
    public var outputDevices: [AudioDeviceID]

    public init(objectID: AudioObjectID, pid: pid_t, bundleID: String?, isPlaying: Bool, outputDevices: [AudioDeviceID]) {
        self.objectID = objectID
        self.pid = pid
        self.bundleID = bundleID
        self.isPlaying = isPlaying
        self.outputDevices = outputDevices
    }
}

/// Which app a helper process works for. Browsers play sound from helpers
/// ("Google Chrome Helper", Safari's "com.apple.WebKit.GPU"), so a pid is mapped to the app
/// that macOS holds responsible for it. Uses a libSystem function that has no public header;
/// if it's ever missing, each process just stands for itself.
public enum ResponsibleProcess {
    private typealias Fn = @convention(c) (pid_t) -> pid_t
    private static let fn: Fn? = {
        guard let handle = dlopen(nil, RTLD_NOW),
              let sym = dlsym(handle, "responsibility_get_pid_responsible_for_pid") else { return nil }
        return unsafeBitCast(sym, to: Fn.self)
    }()

    public static func pid(for pid: pid_t) -> pid_t {
        guard let fn else { return pid }
        let r = fn(pid)
        return r > 0 ? r : pid
    }
}
