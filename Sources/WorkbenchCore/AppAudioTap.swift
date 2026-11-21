import AudioToolbox
import CoreAudio
import Foundation
import WorkbenchAudioRT

public struct AudioTapError: Error, LocalizedError, Equatable {
    public let step: String
    public let status: OSStatus

    public var errorDescription: String? {
        "Couldn't \(step) (Core Audio error \(AudioTapError.describe(status)))."
    }

    /// Core Audio errors are usually four-character codes ('!obj'); fall back to the number.
    static func describe(_ status: OSStatus) -> String {
        let n = UInt32(bitPattern: status)
        let bytes = [UInt8(n >> 24 & 0xFF), UInt8(n >> 16 & 0xFF), UInt8(n >> 8 & 0xFF), UInt8(n & 0xFF)]
        if bytes.allSatisfy({ $0 >= 0x20 && $0 < 0x7F }), let s = String(bytes: bytes, encoding: .ascii) {
            return "'\(s)'"
        }
        return String(status)
    }
}

/// Plays one app's sound at a chosen volume.
///
/// How it works (Core Audio process taps, macOS 14.2+; no drivers, nothing installed):
/// 1. A *private* process tap on the app's audio processes, with `mutedWhenTapped`: macOS silences
///    the app's own output **only while this tap is being read**.
/// 2. A *private* aggregate device containing only that tap (no microphone or other hardware), whose
///    IOProc copies the app's audio into a ring buffer.
/// 3. A HAL output unit (output only, input never enabled) on the device the app was playing to,
///    which plays the ring buffer back with the gain applied.
///
/// Fail-safe: everything here is owned by this process. If Workbench stops reading (stop(), quit,
/// crash) macOS destroys the tap and the app is heard at its normal volume again.
public final class AppAudioTap {
    public private(set) var processObjectIDs: [AudioObjectID]
    public private(set) var outputDevice: AudioDeviceID
    public let name: String

    private let tapUUID = UUID()
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var output: PipeOutput?
    private var pipe: OpaquePointer?
    private var sampleRate: Double = 48_000
    private var stopped = false

    /// - Parameters:
    ///   - gain: linear amplitude 0…1.
    ///   - fadeFromFull: glide from full volume down to `gain` (~15 ms), so taking control of an app
    ///     that was playing normally doesn't click. Pass false when replacing a tap that was already
    ///     controlling the app, so a muted app isn't briefly heard at full volume.
    public init(processes: [AudioObjectID], outputDevice: AudioDeviceID, gain: Float, name: String,
                fadeFromFull: Bool = true) throws {
        precondition(!processes.isEmpty, "a tap needs at least one process")
        self.processObjectIDs = processes
        self.outputDevice = outputDevice
        self.name = name
        do {
            try createTap()
            try createAggregate()
            guard let pipe = wb_pipe_create(16_384, sampleRate, fadeFromFull ? 1.0 : gain) else {
                throw AudioTapError(step: "allocate the audio buffer", status: -108)
            }
            self.pipe = pipe
            wb_pipe_set_gain(pipe, gain)
            configureLatency()
            // Output first (it plays silence until audio arrives), then start reading the tap,
            // which is the moment macOS mutes the app's direct output.
            try startOutput(on: outputDevice)
            try startTapIO()
        } catch {
            stop()
            throw error
        }
    }

    deinit { stop() }

    // MARK: Control

    public func setGain(_ gain: Float) {
        guard let pipe, !stopped else { return }
        wb_pipe_set_gain(pipe, gain)
    }

    /// Changes which processes are in the tap without rebuilding it (no gap, no full-volume blip).
    public func updateProcesses(_ processes: [AudioObjectID]) throws {
        guard !stopped, !processes.isEmpty, processes != processObjectIDs else { return }
        let description = makeDescription(processes)
        var addr = AudioHAL.address(kAudioTapPropertyDescription)
        var ref: CATapDescription = description
        let status = withUnsafeMutablePointer(to: &ref) { ptr in
            AudioObjectSetPropertyData(tapID, &addr, 0, nil, UInt32(MemoryLayout<CATapDescription>.size), ptr)
        }
        try check(status, "update the app's audio processes")
        processObjectIDs = processes
    }

    /// Moves playback to another output device (the app switched to headphones, say). The tap keeps
    /// running, so the app stays at its chosen volume throughout.
    public func switchOutput(to device: AudioDeviceID) throws {
        guard !stopped, device != outputDevice else { return }
        disposeOutput()
        outputDevice = device
        if let rate = try? readTapFormat().mSampleRate, rate > 1000 { sampleRate = rate }
        configureLatency()
        try startOutput(on: device)
    }

    /// If the tap's sample rate changed (the app moved to a device running at another rate), restart
    /// the output at the new rate; otherwise the sound would play at the wrong speed and pitch.
    public func followFormatChanges() throws {
        guard !stopped, let rate = try? readTapFormat().mSampleRate, rate > 1000, abs(rate - sampleRate) > 0.5 else { return }
        disposeOutput()
        sampleRate = rate
        configureLatency()
        try startOutput(on: outputDevice)
    }

    /// Tears everything down. Safe to call more than once.
    public func stop() {
        if stopped { return }
        stopped = true
        // Stop reading the tap first: from this moment macOS plays the app directly again.
        if aggregateID != kAudioObjectUnknown, let ioProcID {
            AudioDeviceStop(aggregateID, ioProcID)
            AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
        }
        ioProcID = nil
        disposeOutput()
        if aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
        // Both audio threads have been stopped and disposed above, so nothing can touch the pipe now.
        if let pipe { wb_pipe_destroy(pipe) }
        pipe = nil
    }

    /// Both halves are running. If the tap half stops, macOS plays the app normally again; if only
    /// the output half stops, the app would be muted with nothing playing it, so callers rebuild.
    public var isRunning: Bool {
        guard !stopped, aggregateID != kAudioObjectUnknown, let output, output.isRunning else { return false }
        return (AudioHAL.uint32(aggregateID, kAudioDevicePropertyDeviceIsRunning) ?? 0) != 0
    }

    public struct Stats: Sendable {
        public var framesWritten: UInt64
        public var framesRead: UInt64
        public var underruns: UInt32
        public var overruns: UInt32
        public var skips: UInt32
        public var buffered: UInt32
        public var currentGain: Float
        public var inputPeak: Float
        public var outputPeak: Float
        public var latencyMs: Double
    }

    /// Counters for diagnostics. Reading the peaks resets them.
    public func takeStats() -> Stats? {
        guard let pipe, !stopped else { return nil }
        let s = wb_pipe_stats(pipe)
        return Stats(framesWritten: s.framesWritten, framesRead: s.framesRead, underruns: s.underruns,
                     overruns: s.overruns, skips: s.skips, buffered: s.buffered, currentGain: s.currentGain,
                     inputPeak: wb_pipe_take_peak(pipe, true), outputPeak: wb_pipe_take_peak(pipe, false),
                     latencyMs: Double(s.buffered) / sampleRate * 1000)
    }

    // MARK: Setup

    private func makeDescription(_ processes: [AudioObjectID]) -> CATapDescription {
        let description = CATapDescription(stereoMixdownOfProcesses: processes)
        description.uuid = tapUUID
        description.name = "Workbench volume: \(name)"
        description.isPrivate = true
        description.muteBehavior = .mutedWhenTapped
        return description
    }

    private func createTap() throws {
        var id = AudioObjectID(kAudioObjectUnknown)
        try check(AudioHardwareCreateProcessTap(makeDescription(processObjectIDs), &id), "create the audio tap")
        tapID = id

        let format = try readTapFormat()
        guard format.mFormatID == kAudioFormatLinearPCM,
              format.mFormatFlags & kAudioFormatFlagIsFloat != 0,
              format.mBitsPerChannel == 32 else {
            throw AudioTapError(step: "use the tap's audio format", status: OSStatus(bitPattern: format.mFormatID))
        }
        if format.mSampleRate > 1000 { sampleRate = format.mSampleRate }
    }

    private func readTapFormat() throws -> AudioStreamBasicDescription {
        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var addr = AudioHAL.address(kAudioTapPropertyFormat)
        try check(AudioObjectGetPropertyData(tapID, &addr, 0, nil, &size, &format), "read the tap's format")
        return format
    }

    private func createAggregate() throws {
        let composition: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Workbench volume: \(name)",
            kAudioAggregateDeviceUIDKey: "local.workbench.volume.\(tapUUID.uuidString)",
            kAudioAggregateDeviceIsPrivateKey: true,   // invisible to other apps, gone when we exit
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: false,
            // Only the tap: no hardware sub-devices, so no microphone is ever opened.
            kAudioAggregateDeviceTapListKey: [
                [kAudioSubTapUIDKey: tapUUID.uuidString, kAudioSubTapDriftCompensationKey: true],
            ],
        ]
        var id = AudioObjectID(kAudioObjectUnknown)
        try check(AudioHardwareCreateAggregateDevice(composition as CFDictionary, &id), "create the private tap device")
        aggregateID = id
    }

    private func configureLatency() {
        guard let pipe else { return }
        let tapFrames = AudioHAL.bufferFrameSize(aggregateID) ?? 512
        var outFrames = AudioHAL.bufferFrameSize(outputDevice) ?? 512
        if let deviceRate = AudioHAL.nominalSampleRate(outputDevice), deviceRate > 1000 {
            outFrames = UInt32((Double(outFrames) * sampleRate / deviceRate).rounded(.up))
        }
        let target = max(256, outFrames + tapFrames / 2)
        wb_pipe_set_latency(pipe, target, target + 2 * tapFrames + outFrames)
    }

    private func startTapIO() throws {
        var procID: AudioDeviceIOProcID?
        try check(AudioDeviceCreateIOProcID(aggregateID, wb_tap_ioproc, UnsafeMutableRawPointer(pipe), &procID),
                  "attach to the tap")
        ioProcID = procID
        try check(AudioDeviceStart(aggregateID, procID), "start reading the tap")
    }

    private func startOutput(on device: AudioDeviceID) throws {
        guard let pipe else { return }
        output = try PipeOutput(pipe: pipe, sampleRate: sampleRate, device: device)
    }

    private func disposeOutput() {
        output?.stop()
        output = nil
    }

    private func check(_ status: OSStatus, _ step: String) throws {
        try checkStatus(status, step)
    }
}

func checkStatus(_ status: OSStatus, _ step: String) throws {
    if status != noErr { throw AudioTapError(step: step, status: status) }
}

/// Plays a WBPipe on an output device through Apple's HAL output unit. Output only: the unit's
/// input side is never enabled, so no microphone is opened (which would also switch Bluetooth
/// headphones into their low-quality call mode).
public final class PipeOutput {
    private var unit: AudioUnit?

    /// - Parameter pipe: must outlive this object (call `stop()` before destroying it).
    public init(pipe: OpaquePointer, sampleRate: Double, device: AudioDeviceID) throws {
        var desc = AudioComponentDescription(componentType: kAudioUnitType_Output,
                                             componentSubType: kAudioUnitSubType_HALOutput,
                                             componentManufacturer: kAudioUnitManufacturer_Apple,
                                             componentFlags: 0, componentFlagsMask: 0)
        guard let component = AudioComponentFindNext(nil, &desc) else {
            throw AudioTapError(step: "find the system output unit", status: -1)
        }
        var created: AudioUnit?
        try checkStatus(AudioComponentInstanceNew(component, &created), "create an output")
        guard let unit = created else { throw AudioTapError(step: "create an output", status: -1) }
        self.unit = unit
        do {
            var off: UInt32 = 0, on: UInt32 = 1
            try checkStatus(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1,
                                                 &off, UInt32(MemoryLayout<UInt32>.size)), "turn off input")
            try checkStatus(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0,
                                                 &on, UInt32(MemoryLayout<UInt32>.size)), "turn on output")
            var dev = device
            try checkStatus(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                                 &dev, UInt32(MemoryLayout<AudioDeviceID>.size)), "choose the output device")
            // Non-interleaved stereo Float32 at the tap's rate; the unit converts to whatever the device wants.
            var format = AudioStreamBasicDescription(
                mSampleRate: sampleRate, mFormatID: kAudioFormatLinearPCM,
                mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved,
                mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4, mChannelsPerFrame: 2,
                mBitsPerChannel: 32, mReserved: 0)
            try checkStatus(AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0,
                                                 &format, UInt32(MemoryLayout<AudioStreamBasicDescription>.size)),
                            "set the output format")
            var callback = AURenderCallbackStruct(inputProc: wb_output_render, inputProcRefCon: UnsafeMutableRawPointer(pipe))
            try checkStatus(AudioUnitSetProperty(unit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0,
                                                 &callback, UInt32(MemoryLayout<AURenderCallbackStruct>.size)),
                            "connect the output")
            try checkStatus(AudioUnitInitialize(unit), "prepare the output")
            try checkStatus(AudioOutputUnitStart(unit), "start the output")
        } catch {
            stop()
            throw error
        }
    }

    deinit { stop() }

    public var isRunning: Bool {
        guard let unit else { return false }
        var running: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioUnitGetProperty(unit, kAudioOutputUnitProperty_IsRunning, kAudioUnitScope_Global, 0, &running, &size)
        return status == noErr && running != 0
    }

    /// Stops and disposes the unit. After this returns the render callback won't run again.
    public func stop() {
        guard let unit else { return }
        AudioOutputUnitStop(unit)
        AudioUnitUninitialize(unit)
        AudioComponentInstanceDispose(unit)
        self.unit = nil
    }
}
