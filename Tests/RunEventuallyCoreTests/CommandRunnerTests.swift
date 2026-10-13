import Foundation
import Testing
@testable import RunEventuallyCore

@Test func commandRunnerCapturesSuccessAndLiteralArguments() throws {
    let outcome = try CommandRunner.run(
        CommandSpec(executable: "/bin/echo", arguments: ["hello; exit 1"]),
        timeoutSeconds: 5
    )

    #expect(outcome.exitCode == 0)
    #expect(outcome.standardOutput == "hello; exit 1\n")
    #expect(outcome.standardError.isEmpty)
    #expect(!outcome.timedOut)
}

@Test func commandRunnerPreservesNonzeroExitAndStandardError() throws {
    let outcome = try CommandRunner.run(
        CommandSpec(executable: "/bin/sh", arguments: ["-c", "printf 'failed' >&2; exit 7"]),
        timeoutSeconds: 5
    )

    #expect(outcome.exitCode == 7)
    #expect(outcome.standardError == "failed")
    #expect(!outcome.timedOut)
}

@Test func commandRunnerTerminatesTimedOutCommand() throws {
    let start = Date()
    let outcome = try CommandRunner.run(
        CommandSpec(executable: "/bin/sh", arguments: ["-c", "exec /bin/sleep 5"]),
        timeoutSeconds: 0.1
    )

    #expect(outcome.timedOut)
    #expect(outcome.exitCode != 0)
    #expect(Date().timeIntervalSince(start) < 3)
}

@Test func commandRunnerBoundsBothOutputStreams() throws {
    let outcome = try CommandRunner.run(
        CommandSpec(
            executable: "/bin/sh",
            arguments: ["-c", "printf '%050000d' 0; printf '%050000d' 0 >&2"]
        ),
        timeoutSeconds: 5,
        outputLimitBytes: 128
    )

    #expect(outcome.exitCode == 0)
    #expect(outcome.standardOutput.utf8.count == 128)
    #expect(outcome.standardError.utf8.count == 128)
}

@Test func commandRunnerUsesWorkingDirectoryAndEnvironmentOverrides() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("run-eventually-test-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let outcome = try CommandRunner.run(
        CommandSpec(
            executable: "/bin/sh",
            arguments: ["-c", "pwd; printf '%s' \"$RUN_EVENTUALLY_TEST\""],
            workingDirectory: directory.path,
            environment: ["RUN_EVENTUALLY_TEST": "custom value"]
        ),
        timeoutSeconds: 5
    )

    #expect(outcome.exitCode == 0)
    #expect(outcome.standardOutput.hasSuffix("/\(directory.lastPathComponent)\ncustom value"))
}

@Test func commandRunnerResolvesRelativeExecutableInWorkingDirectory() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("run-eventually-test-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createSymbolicLink(
        at: directory.appendingPathComponent("tool"),
        withDestinationURL: URL(fileURLWithPath: "/bin/echo")
    )

    let outcome = try CommandRunner.run(
        CommandSpec(executable: "./tool", arguments: ["relative"], workingDirectory: directory.path),
        timeoutSeconds: 5
    )

    #expect(outcome.exitCode == 0)
    #expect(outcome.standardOutput == "relative\n")
}

@Test func commandRunnerRejectsMissingExecutable() {
    #expect(throws: CommandRunnerError.executableNotFound("missing-run-eventually-command")) {
        try CommandRunner.run(
            CommandSpec(executable: "missing-run-eventually-command"),
            timeoutSeconds: 5
        )
    }
}

@Test func taskDeadlineIncludesSleepAndReportsWakeWithoutWaitingAnHour() throws {
    var samples = 0
    var wakes = 0
    let result = try CommandRunner.run(CommandSpec(executable: "/bin/sleep", arguments: ["10"]),
        timeoutSeconds: 60, onWake: { wakes += 1 }, clock: {
            samples += 1
            return samples == 1 ? ExecutionClockSample(continuous: 0, awake: 0)
                : ExecutionClockSample(continuous: 120, awake: 1)
        })
    #expect(result.timedOut)
    #expect(result.stopReason == .timeoutAfterSleep)
    #expect(wakes == 1)
}

@Test func shortSleepDoesNotCancelWorkingCommand() throws {
    var clock = ExecutionDeadline(start: ExecutionClockSample(continuous: 0, awake: 0), timeout: 3600)
    let woke = clock.observe(ExecutionClockSample(continuous: 31, awake: 1))
    #expect(woke)
    #expect(clock.remaining(at: ExecutionClockSample(continuous: 31, awake: 1)) == 3569)
    #expect(clock.slept)
    let wokeAgain = clock.observe(ExecutionClockSample(continuous: 32, awake: 2))
    #expect(!wokeAgain)
}

@Test func gracefulCancellationStopsChildrenAndAllowsCleanup() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let ready = root.appendingPathComponent("ready")
    let cleaned = root.appendingPathComponent("cleaned")
    let escaped = root.appendingPathComponent("escaped")
    let script = "trap 'touch \"$2\"; exit 0' TERM; (sleep 3; touch \"$3\") & touch \"$1\"; wait"
    let result = try CommandRunner.run(CommandSpec(executable: "/bin/sh", arguments:
        ["-c", script, "test", ready.path, cleaned.path, escaped.path]), timeoutSeconds: 10,
        shouldStop: { FileManager.default.fileExists(atPath: ready.path) })
    #expect(result.stopReason == .cancelled)
    #expect(!result.timedOut)
    #expect(FileManager.default.fileExists(atPath: cleaned.path))
    Thread.sleep(forTimeInterval: 3.1)
    #expect(!FileManager.default.fileExists(atPath: escaped.path))
}
