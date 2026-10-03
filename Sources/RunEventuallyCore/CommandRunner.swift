import Darwin
import Dispatch
import Foundation

public struct CommandOutcome: Sendable {
    public let exitCode: Int32
    public let standardOutput: String
    public let standardError: String
    public let timedOut: Bool

    public init(exitCode: Int32, standardOutput: String, standardError: String, timedOut: Bool) {
        self.exitCode = exitCode
        self.standardOutput = standardOutput
        self.standardError = standardError
        self.timedOut = timedOut
    }
}

public enum CommandRunnerError: Error, Equatable {
    case invalidTimeout
    case invalidOutputLimit
    case executableNotFound(String)
}

public enum CommandRunner {
    /// Runs a command without a shell. Output is limited to the first `outputLimitBytes`
    /// bytes of each stream. Excess bytes are drained and discarded so a verbose
    /// process cannot block on a full pipe or consume unbounded storage.
    public static func run(
        _ command: CommandSpec,
        timeoutSeconds: TimeInterval,
        outputLimitBytes: Int = 65_536
    ) throws -> CommandOutcome {
        guard timeoutSeconds.isFinite, timeoutSeconds > 0 else {
            throw CommandRunnerError.invalidTimeout
        }
        guard outputLimitBytes >= 0 else {
            throw CommandRunnerError.invalidOutputLimit
        }

        let environment = ProcessInfo.processInfo.environment.merging(command.environment) { _, override in
            override
        }
        let executable = try resolveExecutable(
            command.executable,
            workingDirectory: command.workingDirectory,
            environment: environment
        )
        let standardOutput = BoundedOutput(limit: outputLimitBytes)
        let standardError = BoundedOutput(limit: outputLimitBytes)
        defer {
            standardOutput.close()
            standardError.close()
        }

        let process = Process()
        process.executableURL = executable
        process.arguments = command.arguments
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = standardOutput.pipe
        process.standardError = standardError.pipe
        if let workingDirectory = command.workingDirectory {
            process.currentDirectoryURL = URL(fileURLWithPath: workingDirectory, isDirectory: true)
        }

        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        try process.run()
        standardOutput.startDraining()
        standardError.startDraining()
        standardOutput.closeWriter()
        standardError.closeWriter()

        var timedOut = false
        if finished.wait(timeout: .now() + timeoutSeconds) == .timedOut && process.isRunning {
            timedOut = true
            // This signals the launched process, not descendants that it started.
            // Give a cooperative command a short chance to clean up before forcing exit.
            _ = Darwin.kill(process.processIdentifier, SIGTERM)
            if finished.wait(timeout: .now() + 1.0) == .timedOut && process.isRunning {
                _ = Darwin.kill(process.processIdentifier, SIGKILL)
            }
        }
        process.waitUntilExit()
        let output = standardOutput.finish()
        let errorOutput = standardError.finish()

        return CommandOutcome(
            exitCode: process.terminationStatus,
            standardOutput: output,
            standardError: errorOutput,
            timedOut: timedOut
        )
    }

    private static func resolveExecutable(
        _ executable: String,
        workingDirectory: String?,
        environment: [String: String]
    ) throws -> URL {
        guard !executable.isEmpty else {
            throw CommandRunnerError.executableNotFound(executable)
        }

        let candidates: [String]
        if executable.contains("/") {
            candidates = [executable]
        } else {
            let path = environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
            candidates = path.split(separator: ":", omittingEmptySubsequences: false).map {
                String($0) + "/" + executable
            }
        }

        let baseDirectory = workingDirectory.map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        for candidate in candidates {
            let url = candidate.hasPrefix("/")
                ? URL(fileURLWithPath: candidate)
                : baseDirectory.appendingPathComponent(candidate)
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
               !isDirectory.boolValue,
               FileManager.default.isExecutableFile(atPath: url.path) {
                return url.standardizedFileURL
            }
        }
        throw CommandRunnerError.executableNotFound(executable)
    }
}

private final class BoundedOutput: @unchecked Sendable {
    let pipe = Pipe()

    private let limit: Int
    private let lock = NSLock()
    private let draining = DispatchGroup()
    private var captured = Data()
    private var stopping = false

    init(limit: Int) {
        self.limit = limit
    }

    func startDraining() {
        let descriptor = pipe.fileHandleForReading.fileDescriptor
        draining.enter()
        DispatchQueue.global(qos: .utility).async { [self] in
            defer { draining.leave() }
            var buffer = [UInt8](repeating: 0, count: 8_192)
            while true {
                var polling = pollfd(fd: descriptor, events: Int16(POLLIN | POLLHUP), revents: 0)
                let pollResult = Darwin.poll(&polling, 1, isStopping ? 0 : 100)
                if pollResult < 0 {
                    if errno == EINTR { continue }
                    break
                }
                if pollResult == 0 {
                    if isStopping { break }
                    continue
                }

                let bytesRead = buffer.withUnsafeMutableBytes { rawBuffer in
                    Darwin.read(descriptor, rawBuffer.baseAddress, rawBuffer.count)
                }
                if bytesRead > 0 {
                    append(buffer, count: Int(bytesRead))
                    // Once the launched process is gone, retained descendants must
                    // not keep the collector open indefinitely.
                    if isStopping && capturedCount >= limit { break }
                } else if bytesRead == 0 {
                    break
                } else if errno != EINTR {
                    break
                }
            }
        }
    }

    func closeWriter() {
        try? pipe.fileHandleForWriting.close()
    }

    func finish() -> String {
        lock.lock()
        stopping = true
        lock.unlock()
        draining.wait()
        lock.lock()
        defer { lock.unlock() }
        return String(decoding: captured, as: UTF8.self)
    }

    func close() {
        try? pipe.fileHandleForReading.close()
        try? pipe.fileHandleForWriting.close()
    }

    private var isStopping: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopping
    }

    private var capturedCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return captured.count
    }

    private func append(_ buffer: [UInt8], count: Int) {
        lock.lock()
        defer { lock.unlock() }
        let remaining = limit - captured.count
        if remaining > 0 {
            captured.append(contentsOf: buffer.prefix(Swift.min(count, remaining)))
        }
    }
}
