import Darwin
import Dispatch
import Foundation

public enum CommandStopReason: Sendable { case timeout, timeoutAfterSleep, cancelled }

public struct CommandOutcome: Sendable {
    public let exitCode: Int32
    public let standardOutput: String
    public let standardError: String
    public let timedOut: Bool
    public let stopReason: CommandStopReason?

    public init(exitCode: Int32, standardOutput: String, standardError: String, timedOut: Bool, stopReason: CommandStopReason? = nil) {
        self.exitCode = exitCode
        self.standardOutput = standardOutput
        self.standardError = standardError
        self.timedOut = timedOut
        self.stopReason = stopReason
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
    /// process cannot block on a full pipe or consume unbounded memory. With
    /// logFiles, both streams go directly to complete, live-readable files;
    /// outputLimitBytes limits only the returned compatibility previews.
    public static func run(
        _ command: CommandSpec,
        timeoutSeconds: TimeInterval,
        outputLimitBytes: Int = 65_536,
        logFiles: CommandLogFiles? = nil,
        shouldStop: () -> Bool = { false },
        onWake: () -> Void = {},
        clock: () -> ExecutionClockSample = ExecutionClockSample.now
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
        let writers = try logFiles?.openWriters()
        defer {
            try? writers?.output.close()
            try? writers?.error.close()
        }
        process.standardOutput = writers?.output ?? standardOutput.pipe.fileHandleForWriting
        process.standardError = writers?.error ?? standardError.pipe.fileHandleForWriting
        if let workingDirectory = command.workingDirectory {
            process.currentDirectoryURL = URL(fileURLWithPath: workingDirectory, isDirectory: true)
        }

        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        try process.run()
        if writers == nil {
            standardOutput.startDraining()
            standardError.startDraining()
        }
        standardOutput.closeWriter()
        standardError.closeWriter()

        var deadline = ExecutionDeadline(start: clock(), timeout: timeoutSeconds)
        var stopReason: CommandStopReason?
        let pid = process.processIdentifier
        // Foundation launches macOS Process children in their own process group.
        // Verify isolation before signaling descendants; never signal our group.
        let isolatedGroup = getpgid(pid) == pid && pid != getpgrp()
        while process.isRunning {
            let sample = clock()
            if deadline.observe(sample) { onWake() }
            if shouldStop() { stopReason = .cancelled }
            else if deadline.remaining(at: sample) <= 0 {
                stopReason = deadline.slept ? .timeoutAfterSleep : .timeout
            }
            if stopReason != nil {
                let graceDeadline = ExecutionClockSample.now().continuous + 1
                _ = Darwin.kill(isolatedGroup ? -pid : pid, SIGTERM)
                _ = finished.wait(timeout: .now() + 1.0)
                if isolatedGroup {
                    while Darwin.kill(-pid, 0) == 0 && ExecutionClockSample.now().continuous < graceDeadline {
                        Thread.sleep(forTimeInterval: 0.05)
                    }
                }
                // Parent exit does not prove its children exited. Close the whole
                // verified group so orphaned SSH/Python processes cannot hold work.
                if isolatedGroup {
                    if Darwin.kill(-pid, 0) == 0 { _ = Darwin.kill(-pid, SIGKILL) }
                } else if process.isRunning {
                    _ = Darwin.kill(pid, SIGKILL)
                }
                break
            }
            if finished.wait(timeout: .now() + min(1, max(0.001, deadline.remaining(at: sample)))) == .success { break }
        }
        process.waitUntilExit()
        let output = try logFiles.map { try $0.preview(at: $0.output, limit: outputLimitBytes) }
            ?? standardOutput.finish()
        let errorOutput = try logFiles.map { try $0.preview(at: $0.error, limit: outputLimitBytes) }
            ?? standardError.finish()

        return CommandOutcome(
            exitCode: process.terminationStatus,
            standardOutput: output,
            standardError: errorOutput,
            timedOut: stopReason == .timeout || stopReason == .timeoutAfterSleep,
            stopReason: stopReason
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
        // Readers must make progress even when callers occupy the cooperative
        // Swift task pool while waiting synchronously for command completion.
        Thread.detachNewThread { [self] in
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
