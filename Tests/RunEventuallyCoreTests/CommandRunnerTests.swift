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
