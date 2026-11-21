import CoreAudio
import Foundation
import Testing
import WorkbenchAudioRT
@testable import WorkbenchCore

// MARK: - Helpers

private func makePipe(capacity: UInt32 = 16_384, gain: Float = 1, target: UInt32 = 256, max: UInt32 = 8_192) -> OpaquePointer {
    let pipe = wb_pipe_create(capacity, 48_000, gain)!
    wb_pipe_set_latency(pipe, target, max)
    return pipe
}

/// Writes interleaved samples (`channels` per frame) as the tap would deliver them.
private func write(_ pipe: OpaquePointer, interleaved samples: [Float], channels: UInt32 = 2, byteSize: UInt32? = nil) {
    var samples = samples
    samples.withUnsafeMutableBufferPointer { buf in
        var list = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(
            mNumberChannels: channels, mDataByteSize: byteSize ?? UInt32(buf.count * 4), mData: buf.baseAddress))
        wb_pipe_write(pipe, &list, UInt32(buf.count) / channels)
    }
}

/// Writes stereo as two separate (non-interleaved) buffers.
private func write(_ pipe: OpaquePointer, left: [Float], right: [Float]) {
    var l = left, r = right
    l.withUnsafeMutableBufferPointer { lb in
        r.withUnsafeMutableBufferPointer { rb in
            let list = AudioBufferList.allocate(maximumBuffers: 2)
            defer { free(list.unsafeMutablePointer) }
            list[0] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(lb.count * 4), mData: lb.baseAddress)
            list[1] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(rb.count * 4), mData: rb.baseAddress)
            wb_pipe_write(pipe, list.unsafePointer, UInt32(lb.count))
        }
    }
}

private func read(_ pipe: OpaquePointer, _ frames: Int) -> (left: [Float], right: [Float]) {
    var left = [Float](repeating: -99, count: frames)
    var right = [Float](repeating: -99, count: frames)
    left.withUnsafeMutableBufferPointer { lb in
        right.withUnsafeMutableBufferPointer { rb in
            wb_pipe_read(pipe, lb.baseAddress!, rb.baseAddress!, UInt32(frames))
        }
    }
    return (left, right)
}

/// Frame i: left = i/10000, right = -i/10000, so positions are easy to check.
private func ramp(_ frames: Int, from start: Int = 0) -> [Float] {
    (start..<(start + frames)).flatMap { [Float($0) / 10_000, -Float($0) / 10_000] }
}

// MARK: - Real-time pipe

@Suite("Per-app volume: audio pipe")
struct AudioPipeTests {
    @Test func staysSilentUntilEnoughIsBuffered() {
        let pipe = makePipe(target: 256)
        defer { wb_pipe_destroy(pipe) }
        write(pipe, interleaved: ramp(100))
        let out = read(pipe, 64)
        #expect(out.left.allSatisfy { $0 == 0 } && out.right.allSatisfy { $0 == 0 })
        #expect(wb_pipe_stats(pipe).framesRead == 0)
    }

    @Test func passesAudioThroughInOrderAtFullGain() {
        let pipe = makePipe(target: 256)
        defer { wb_pipe_destroy(pipe) }
        write(pipe, interleaved: ramp(1_000))
        let out = read(pipe, 512)
        #expect(out.left[0] == 0)
        #expect(out.left[10] == Float(10) / 10_000)
        #expect(out.right[511] == -Float(511) / 10_000)
        #expect(wb_pipe_stats(pipe).buffered == 488)
    }

    @Test func appliesGain() {
        let pipe = makePipe(gain: 0.25)
        defer { wb_pipe_destroy(pipe) }
        write(pipe, interleaved: [Float](repeating: 0.8, count: 2 * 600))
        let out = read(pipe, 300)
        #expect(out.left.allSatisfy { abs($0 - 0.2) < 1e-6 })
        #expect(out.right.allSatisfy { abs($0 - 0.2) < 1e-6 })
    }

    @Test func glidesToNewGainWithoutAJump() {
        let pipe = makePipe(gain: 1)
        defer { wb_pipe_destroy(pipe) }
        wb_pipe_set_gain(pipe, 0)
        write(pipe, interleaved: [Float](repeating: 0.5, count: 2 * 9_000))
        let out = read(pipe, 7_200)  // 150 ms at 48 kHz = 10 time constants
        #expect(out.left[0] > 0.49)                            // starts where it was: no click
        #expect(zip(out.left, out.left.dropFirst()).allSatisfy { $0 >= $1 })   // only ever goes down
        #expect(out.left[2_400] < 0.5 * 0.01)                  // −40 dB within 50 ms
        #expect(out.left.last! < 1e-4)
    }

    @Test func immediateGainSkipsTheGlide() {
        let pipe = makePipe(gain: 1)
        defer { wb_pipe_destroy(pipe) }
        wb_pipe_set_gain_immediately(pipe, 0.5)
        write(pipe, interleaved: [Float](repeating: 0.5, count: 2 * 600))
        #expect(read(pipe, 300).left.allSatisfy { $0 == 0.25 })
    }

    @Test func neverBoostsAndClampsBadSamples() {
        let pipe = makePipe(gain: 1)
        defer { wb_pipe_destroy(pipe) }
        wb_pipe_set_gain_immediately(pipe, 4)  // asking for a boost gets 1
        #expect(wb_pipe_stats(pipe).currentGain == 1)
        write(pipe, interleaved: [3, -3, .nan, .infinity, 0.5, 0.5] + [Float](repeating: 0, count: 2 * 300))
        let out = read(pipe, 3)
        #expect(out.left == [1, 0, 0.5])     // 3 → clamped to full scale; NaN → silence
        #expect(out.right == [-1, 0, 0.5])   // −3 → clamped; inf → silence
        wb_pipe_set_gain_immediately(pipe, -1)
        wb_pipe_set_gain_immediately(pipe, .nan)
        _ = read(pipe, 1)
        #expect(wb_pipe_stats(pipe).currentGain == 0)
    }

    @Test func runningDryPadsWithSilenceThenWaitsForACushion() {
        let pipe = makePipe(target: 256)
        defer { wb_pipe_destroy(pipe) }
        write(pipe, interleaved: ramp(600))
        _ = read(pipe, 512)
        let second = read(pipe, 512)
        #expect(second.left[87] == Float(599) / 10_000)
        #expect(second.left[88...].allSatisfy { $0 == 0 })
        #expect(wb_pipe_stats(pipe).underruns == 1)
        write(pipe, interleaved: ramp(100, from: 600))   // less than the cushion: keep waiting
        #expect(read(pipe, 64).left.allSatisfy { $0 == 0 })
        write(pipe, interleaved: ramp(200, from: 700))
        #expect(read(pipe, 64).left[0] == Float(600) / 10_000)
    }

    @Test func dropsABacklogToKeepLatencyLow() {
        let pipe = makePipe(target: 256, max: 1_024)
        defer { wb_pipe_destroy(pipe) }
        write(pipe, interleaved: ramp(4_000))
        let out = read(pipe, 128)
        #expect(out.left[0] == Float(4_000 - 256) / 10_000)
        let stats = wb_pipe_stats(pipe)
        #expect(stats.skips == 1)
        #expect(stats.buffered == 128)
    }

    @Test func readsNonInterleavedAndMonoInput() {
        let pipe = makePipe(target: 64)
        defer { wb_pipe_destroy(pipe) }
        write(pipe, left: [Float](repeating: 0.1, count: 100), right: [Float](repeating: 0.2, count: 100))
        let stereo = read(pipe, 100)
        #expect(stereo.left.allSatisfy { $0 == 0.1 } && stereo.right.allSatisfy { $0 == 0.2 })

        write(pipe, interleaved: [Float](repeating: 0.3, count: 100), channels: 1)
        let mono = read(pipe, 100)
        #expect(mono.left.allSatisfy { $0 == 0.3 } && mono.right.allSatisfy { $0 == 0.3 })
    }

    @Test func neverReadsPastTheEndOfAShortBuffer() {
        let pipe = makePipe(target: 32)
        defer { wb_pipe_destroy(pipe) }
        // Claims 100 frames but the buffer only holds 40.
        var samples = [Float](repeating: 0.5, count: 200)
        samples.withUnsafeMutableBufferPointer { buf in
            var list = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(
                mNumberChannels: 2, mDataByteSize: 40 * 8, mData: buf.baseAddress))
            wb_pipe_write(pipe, &list, 100)
        }
        #expect(wb_pipe_stats(pipe).framesWritten == 40)
    }

    @Test func fullRingDropsNewAudioInsteadOfOverwriting() {
        let pipe = makePipe(capacity: 64, target: 32, max: 64)
        defer { wb_pipe_destroy(pipe) }
        write(pipe, interleaved: ramp(100))
        let stats = wb_pipe_stats(pipe)
        #expect(stats.overruns == 1)
        #expect(stats.framesWritten == 64)
    }

    @Test func tracksPeaksBeforeAndAfterGain() {
        let pipe = makePipe(gain: 0.5)
        defer { wb_pipe_destroy(pipe) }
        write(pipe, interleaved: [0.2, -0.8] + [Float](repeating: 0, count: 600))
        _ = read(pipe, 300)
        #expect(wb_pipe_take_peak(pipe, true) == 0.8)
        #expect(wb_pipe_take_peak(pipe, false) == 0.4)
        #expect(wb_pipe_take_peak(pipe, true) == 0)   // reset by reading
    }

    @Test func renderCallbackHandlesMissingOrMonoBuffers() {
        let pipe = makePipe(target: 32)
        defer { wb_pipe_destroy(pipe) }
        write(pipe, interleaved: [Float](repeating: 0.4, count: 2 * 100))
        var flags = AudioUnitRenderActionFlags()
        var time = AudioTimeStamp()
        #expect(wb_output_render(UnsafeMutableRawPointer(pipe), &flags, &time, 0, 64, nil) == noErr)

        var mono = [Float](repeating: -9, count: 64)
        mono.withUnsafeMutableBufferPointer { buf in
            var list = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(
                mNumberChannels: 1, mDataByteSize: 64 * 4, mData: buf.baseAddress))
            _ = wb_output_render(UnsafeMutableRawPointer(pipe), &flags, &time, 0, 64, &list)
        }
        #expect(mono.allSatisfy { abs($0 - 0.4) < 1e-6 })
    }
}

// MARK: - Settings, grouping, planning

@Suite("Per-app volume: planning")
struct VolumePlanningTests {
    @Test func volumeCurve() {
        #expect(VolumeSetting(level: 1).gain == 1)
        #expect(VolumeSetting(level: 0.5).gain == 0.25)
        #expect(VolumeSetting(level: 0).gain == 0)
        #expect(VolumeSetting(level: 0.8, muted: true).gain == 0)
        #expect(VolumeSetting(level: 7).level == 1)       // no boosting
        #expect(!VolumeSetting.normal.needsTap)
        #expect(VolumeSetting(level: 0.99).needsTap)
        #expect(VolumeSetting(level: 1, muted: true).needsTap)
    }

    // Real process objects from a Mac: browsers play through helpers.
    private let processes: [AudioProcess] = [
        AudioProcess(objectID: 117, pid: 661, bundleID: "com.apple.controlcenter", isPlaying: false, outputDevices: []),
        AudioProcess(objectID: 130, pid: 68047, bundleID: "systemsoundserverd", isPlaying: false, outputDevices: []),
        AudioProcess(objectID: 133, pid: 23697, bundleID: "com.apple.WebKit.GPU", isPlaying: true, outputDevices: [90]),
        AudioProcess(objectID: 141, pid: 74136, bundleID: "com.apple.WebKit.GPU", isPlaying: false, outputDevices: []),
        AudioProcess(objectID: 139, pid: 38810, bundleID: "com.google.Chrome.helper", isPlaying: false, outputDevices: []),
        AudioProcess(objectID: 140, pid: 38811, bundleID: "com.google.Chrome.helper", isPlaying: true, outputDevices: [73]),
        AudioProcess(objectID: 150, pid: 500, bundleID: "local.workbench", isPlaying: true, outputDevices: [90]),
    ]

    private func group() -> [AudioApp] {
        let responsible: [pid_t: pid_t] = [23697: 23681, 74136: 74134, 38810: 38629, 38811: 38629]
        let apps: [pid_t: AppIdentity] = [
            23681: AppIdentity(id: "com.apple.Safari", name: "Safari", pid: 23681),
            74134: AppIdentity(id: "com.apple.mail", name: "Mail", pid: 74134),
            38629: AppIdentity(id: "com.google.Chrome", name: "Google Chrome", pid: 38629),
            500: AppIdentity(id: "local.workbench", name: "Workbench", pid: 500),
        ]
        return AudioAppGrouping.group(processes, ownPID: 500,
                                      responsible: { responsible[$0] ?? $0 }, app: { apps[$0] })
    }

    @Test func groupsHelpersUnderTheirAppAndHidesSystemAndSelf() {
        let apps = group()
        #expect(apps.map(\.name) == ["Google Chrome", "Mail", "Safari"])
        let chrome = apps[0]
        #expect(chrome.processObjectIDs == [139, 140])
        #expect(chrome.isPlaying)
        #expect(chrome.outputDevices == [73])
        #expect(apps[1].isPlaying == false)
        #expect(apps[2].processObjectIDs == [133])   // Safari's WebKit helper, not Mail's
    }

    @Test func plansTapsOnlyForAppsThatAreTurnedDown() {
        let apps = group()
        let settings: [String: VolumeSetting] = [
            "com.apple.Safari": VolumeSetting(level: 0.3),
            "com.apple.mail": .normal,
            "com.example.NotRunning": VolumeSetting(level: 0.1),
        ]
        let plans = VolumePlanner.plan(apps: apps, settings: settings, defaultOutput: 90)
        #expect(Array(plans.keys) == ["com.apple.Safari"])
        #expect(plans["com.apple.Safari"] == TapPlan(appID: "com.apple.Safari", name: "Safari",
                                                     processObjectIDs: [133], outputDevice: 90))
        // Held taps stay while a slider passes through 100%.
        let held = VolumePlanner.plan(apps: apps, settings: settings, holding: ["com.apple.mail"], defaultOutput: 90)
        #expect(Set(held.keys) == ["com.apple.Safari", "com.apple.mail"])
    }

    @Test func followsTheDeviceTheAppIsPlayingTo() {
        let chrome = group()[0]   // playing to device 73, not the default
        #expect(VolumePlanner.outputDevice(for: chrome, defaultOutput: 90, isUsable: { _ in true }) == 73)
        // If that device isn't usable any more, fall back to the default.
        #expect(VolumePlanner.outputDevice(for: chrome, defaultOutput: 90, isUsable: { $0 != 73 }) == 90)
        let mail = group()[1]     // not playing: default
        #expect(VolumePlanner.outputDevice(for: mail, defaultOutput: 90, isUsable: { _ in true }) == 90)
        var both = chrome
        both.processes[0].outputDevices = [90]
        #expect(VolumePlanner.outputDevice(for: both, defaultOutput: 90, isUsable: { _ in true }) == 90)
        #expect(VolumePlanner.outputDevice(for: mail, defaultOutput: nil, isUsable: { _ in true }) == nil)
    }

    @Test func diffsRunningTapsAgainstThePlan() {
        let a = TapPlan(appID: "a", name: "A", processObjectIDs: [1], outputDevice: 90)
        let b = TapPlan(appID: "b", name: "B", processObjectIDs: [2], outputDevice: 90)
        let c = TapPlan(appID: "c", name: "C", processObjectIDs: [3], outputDevice: 90)
        var b2 = b
        b2.processObjectIDs = [2, 5]
        var c2 = c
        c2.outputDevice = 73
        let changes = VolumePlanner.changes(current: ["a": a, "b": b, "c": c], desired: ["b": b2, "c": c2, "d": a])
        #expect(changes == [
            .stop(appID: "a"),
            .retarget(b2, processesChanged: true, deviceChanged: false),
            .retarget(c2, processesChanged: false, deviceChanged: true),
            .start(a),
        ])
        #expect(VolumePlanner.changes(current: ["a": a], desired: ["a": a]).isEmpty)
    }

    @Test func errorsReadAsFourCharacterCodes() {
        #expect(AudioTapError.describe(OSStatus(bitPattern: 0x216F_626A)) == "'!obj'")
        #expect(AudioTapError.describe(-50) == "-50")
    }
}
