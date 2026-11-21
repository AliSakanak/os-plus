import Foundation

public struct CommandResult: Sendable, Equatable {
    public let stdout: String
    public let stderr: String
    public let exitCode: Int32

    public init(stdout: String, stderr: String = "", exitCode: Int32 = 0) {
        self.stdout = stdout
        self.stderr = stderr
        self.exitCode = exitCode
    }
}

public enum CommandError: Error, Equatable {
    case timedOut
    case launchFailed(String)
}

/// Abstraction over running a command-line tool, so parsers can be tested with canned output.
public protocol CommandRunning: Sendable {
    func run(_ executable: String, _ arguments: [String], timeout: TimeInterval) async throws -> CommandResult
}

extension CommandRunning {
    public func run(_ executable: String, _ arguments: [String]) async throws -> CommandResult {
        try await run(executable, arguments, timeout: 10)
    }
}

/// Runs real processes. Reads stdout/stderr concurrently so large output can't deadlock the pipe.
public struct CommandRunner: CommandRunning {
    public init() {}

    public func run(_ executable: String, _ arguments: [String], timeout: TimeInterval) async throws -> CommandResult {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: executable)
                process.arguments = arguments
                process.standardInput = FileHandle.nullDevice
                let outPipe = Pipe()
                let errPipe = Pipe()
                process.standardOutput = outPipe
                process.standardError = errPipe

                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: CommandError.launchFailed(error.localizedDescription))
                    return
                }

                let output = OutputBox()
                let group = DispatchGroup()
                group.enter()
                DispatchQueue.global().async {
                    output.stdout = outPipe.fileHandleForReading.readDataToEndOfFile()
                    group.leave()
                }
                group.enter()
                DispatchQueue.global().async {
                    output.stderr = errPipe.fileHandleForReading.readDataToEndOfFile()
                    group.leave()
                }

                let timedOut = TimeoutFlag()
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                    if process.isRunning {
                        timedOut.value = true
                        process.terminate()
                    }
                }

                process.waitUntilExit()
                group.wait()

                if timedOut.value {
                    continuation.resume(throwing: CommandError.timedOut)
                } else {
                    continuation.resume(returning: CommandResult(
                        stdout: String(decoding: output.stdout, as: UTF8.self),
                        stderr: String(decoding: output.stderr, as: UTF8.self),
                        exitCode: process.terminationStatus
                    ))
                }
            }
        }
    }
}

private final class OutputBox: @unchecked Sendable {
    var stdout = Data()
    var stderr = Data()
}

private final class TimeoutFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = false
    var value: Bool {
        get { lock.withLock { _value } }
        set { lock.withLock { _value = newValue } }
    }
}
