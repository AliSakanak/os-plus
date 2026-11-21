import AppKit
import CoreAudio
import Foundation
import WorkbenchAudioRT
import WorkbenchCore

/// `Workbench --sound-cli list|output-test|selftest`: checks per-app volume from a terminal.
///
/// - `list`: the apps using audio, grouped as the Sound tab shows them. Changes nothing.
/// - `output-test`: plays a −100 dBFS tone (far below hearing) through the output half of the
///   pipeline for 1.5 s and checks it flowed. Needs no permission and no tap.
/// - `selftest`: the whole thing. Plays a quiet tone with `afplay`, turns it down to 50% with a
///   real tap, and measures the level going in and coming out. Needs the audio permission; without
///   it, it stops before creating any tap.
enum SoundCLI {
    static func run(_ mode: String) -> Int32 {
        switch mode {
        case "list": return list()
        case "output-test": return outputTest()
        case "selftest": return selfTest()
        default:
            print("usage: Workbench --sound-cli list|output-test|selftest")
            return 64
        }
    }

    private static func identity(for pid: pid_t) -> AppIdentity? {
        guard let app = NSRunningApplication(processIdentifier: pid), app.activationPolicy == .regular,
              let id = app.bundleIdentifier else { return nil }
        return AppIdentity(id: id, name: app.localizedName ?? id, pid: pid)
    }

    private static func list() -> Int32 {
        let processes = AudioHAL.snapshotProcesses()
        let apps = AudioAppGrouping.group(processes, ownPID: getpid(), responsible: ResponsibleProcess.pid(for:),
                                          app: identity(for:))
        let output = AudioHAL.defaultOutputDevice
        print("Permission: \(AudioCapturePermission.status)")
        print("Default output: \(output.flatMap(AudioHAL.deviceName) ?? "none") (\(output.map(String.init) ?? "-"))")
        print("\(processes.count) audio processes → \(apps.count) apps")
        for app in apps {
            let devices = app.outputDevices.map { AudioHAL.deviceName($0) ?? String($0) }
            print("  \(app.isPlaying ? "▶" : " ") \(app.name) [\(app.id)] processes \(app.processObjectIDs)"
                  + (devices.isEmpty ? "" : " → \(devices.joined(separator: ", "))"))
        }
        return 0
    }

    private static func outputTest() -> Int32 {
        guard let device = AudioHAL.defaultOutputDevice else {
            print("FAIL: no output device")
            return 1
        }
        let rate = AudioHAL.nominalSampleRate(device) ?? 48_000
        guard let pipe = wb_pipe_create(16_384, rate, 1) else { return 1 }
        defer { wb_pipe_destroy(pipe) }
        wb_pipe_set_latency(pipe, 512, 4_096)
        let amplitude: Float = 0.000_01   // −100 dBFS: inaudible
        print("Output test on \(AudioHAL.deviceName(device) ?? "?") at \(Int(rate)) Hz, −100 dBFS")

        let output: PipeOutput
        do {
            output = try PipeOutput(pipe: pipe, sampleRate: rate, device: device)
        } catch {
            print("FAIL: \(error.localizedDescription)")
            return 1
        }
        // Feed it like a tap would: 480-frame chunks, roughly in real time.
        let chunk = 480
        var phase = 0.0
        let step = 2 * Double.pi * 440 / rate
        let start = Date()
        var fed = 0
        while Date().timeIntervalSince(start) < 1.5 {
            let due = Int(Date().timeIntervalSince(start) * rate) + 1_024
            while fed < due {
                var samples = [Float](repeating: 0, count: chunk * 2)
                for i in 0..<chunk {
                    let s = Float(sin(phase)) * amplitude
                    samples[2 * i] = s
                    samples[2 * i + 1] = s
                    phase += step
                }
                samples.withUnsafeMutableBufferPointer { buf in
                    var list = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(
                        mNumberChannels: 2, mDataByteSize: UInt32(buf.count * 4), mData: buf.baseAddress))
                    wb_pipe_write(pipe, &list, UInt32(chunk))
                }
                fed += chunk
            }
            usleep(5_000)
        }
        let peak = wb_pipe_take_peak(pipe, false)
        output.stop()
        let stats = wb_pipe_stats(pipe)
        let expected = 1.5 * rate
        print("read \(stats.framesRead) frames (expected ≈ \(Int(expected))), underruns \(stats.underruns), "
              + "skips \(stats.skips), peak \(peak)")
        let ok = Double(stats.framesRead) > expected * 0.8 && peak > amplitude * 0.9 && peak <= amplitude * 1.01
        print(ok ? "PASS" : "FAIL")
        return ok ? 0 : 1
    }

    private static func selfTest() -> Int32 {
        let status = AudioCapturePermission.status
        guard status == .authorized else {
            print("Permission is \(status). Allow OS+ in the Sound tab first (no tap was created).")
            return 2
        }
        guard let device = AudioHAL.defaultOutputDevice else {
            print("FAIL: no output device")
            return 1
        }
        // A quiet 440 Hz tone (−30 dBFS) for 4 s.
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("workbench-selftest-\(getpid()).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let amplitude = 0.0316
        do { try writeTone(to: url, seconds: 4, amplitude: amplitude) } catch {
            print("FAIL: couldn't write the test tone: \(error)")
            return 1
        }
        let player = Process()
        player.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
        player.arguments = [url.path]
        do { try player.run() } catch {
            print("FAIL: couldn't start afplay: \(error)")
            return 1
        }
        defer { if player.isRunning { player.terminate() } }

        // Wait for afplay to show up as a playing audio process.
        var object: AudioObjectID?
        for _ in 0..<40 {
            if let p = AudioHAL.snapshotProcesses().first(where: { $0.pid == player.processIdentifier && $0.isPlaying }) {
                object = p.objectID
                break
            }
            usleep(50_000)
        }
        guard let object else {
            print("FAIL: afplay never started playing")
            return 1
        }
        let setting = VolumeSetting(level: 0.5)
        print("Tapping afplay (object \(object)) at 50% → gain \(setting.gain) on \(AudioHAL.deviceName(device) ?? "?")")
        let tap: AppAudioTap
        do {
            tap = try AppAudioTap(processes: [object], outputDevice: device, gain: setting.gain, name: "selftest")
        } catch {
            print("FAIL: \(error.localizedDescription)")
            return 1
        }
        defer { tap.stop() }
        usleep(500_000)
        _ = tap.takeStats()   // reset peaks after the 15 ms glide
        usleep(1_500_000)
        guard let stats = tap.takeStats() else { return 1 }
        let ratio = stats.inputPeak > 0 ? stats.outputPeak / stats.inputPeak : 0
        print(String(format: "in peak %.4f (expected ≈ %.4f), out peak %.4f, ratio %.3f (expected %.3f)",
                     stats.inputPeak, amplitude, stats.outputPeak, ratio, setting.gain))
        print("frames \(stats.framesWritten) in / \(stats.framesRead) out, underruns \(stats.underruns), "
              + "skips \(stats.skips), overruns \(stats.overruns), latency \(String(format: "%.1f", stats.latencyMs)) ms")
        let ok = stats.inputPeak > Float(amplitude) * 0.8 && abs(ratio - setting.gain) < 0.03 && stats.underruns <= 2
        if stats.inputPeak == 0 { print("The tap delivered silence: macOS may be blocking audio capture.") }
        print(ok ? "PASS" : "FAIL")
        return ok ? 0 : 1
    }

    /// 16-bit stereo WAV.
    private static func writeTone(to url: URL, seconds: Double, amplitude: Double) throws {
        let rate = 48_000
        let frames = Int(Double(rate) * seconds)
        var data = Data()
        func append<T: FixedWidthInteger>(_ v: T) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        data.append(contentsOf: Array("RIFF".utf8)); append(UInt32(36 + frames * 4))
        data.append(contentsOf: Array("WAVEfmt ".utf8)); append(UInt32(16)); append(UInt16(1)); append(UInt16(2))
        append(UInt32(rate)); append(UInt32(rate * 4)); append(UInt16(4)); append(UInt16(16))
        data.append(contentsOf: Array("data".utf8)); append(UInt32(frames * 4))
        for i in 0..<frames {
            // 20 ms fade in/out so it doesn't click.
            let edge = min(1, Double(min(i, frames - i)) / (0.02 * Double(rate)))
            let s = Int16(sin(2 * .pi * 440 * Double(i) / Double(rate)) * amplitude * edge * 32_767)
            append(s); append(s)
        }
        try data.write(to: url)
    }
}
