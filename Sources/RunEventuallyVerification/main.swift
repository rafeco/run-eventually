import Foundation
import RunEventuallyCore

private struct VerificationFailure: Error, LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

private func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    guard try condition() else { throw VerificationFailure(message: message) }
}

private func date(_ text: String) -> Date {
    ISO8601DateFormatter().date(from: text)!
}

private func temporaryDatabase() throws -> (URL, String) {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("run-eventually-verify-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return (directory, directory.appendingPathComponent("state.sqlite").path)
}

private func verifySchedules() throws {
    let once = date("2026-01-01T06:30:00Z")
    let one = try SchedulePlanner.dueWindow(
        for: .once(once), after: date("2026-01-01T00:00:00Z"), through: once
    )
    try require(one == DueWindow(first: once, last: once, count: 1), "One-time due boundary failed")
    let none = try SchedulePlanner.dueWindow(for: .once(once), after: once, through: once)
    try require(none == nil, "One-time schedule duplicated its occurrence")

    let daily = try SchedulePlanner.dueWindow(
        for: .daily(hour: 6, minute: 30, timeZoneID: "UTC"),
        after: date("2026-01-01T06:30:00Z"),
        through: date("2026-01-04T08:00:00Z")
    )
    try require(daily?.count == 3, "Daily catch-up did not combine missed occurrences")
    try require(daily?.first == date("2026-01-02T06:30:00Z"), "Incorrect oldest due time")
    try require(daily?.last == date("2026-01-04T06:30:00Z"), "Incorrect latest due time")

    let spring = try SchedulePlanner.dueWindow(
        for: .daily(hour: 2, minute: 30, timeZoneID: "America/New_York"),
        after: date("2025-03-08T08:00:00Z"),
        through: date("2025-03-10T07:00:00Z")
    )
    try require(spring?.count == 2, "Spring daylight-saving gap lost a day")
    try require(spring?.first == date("2025-03-09T07:00:00Z"), "Spring gap did not move to first valid time")

    let fall = try SchedulePlanner.dueWindow(
        for: .daily(hour: 1, minute: 30, timeZoneID: "America/New_York"),
        after: date("2025-11-02T04:00:00Z"),
        through: date("2025-11-02T07:00:00Z")
    )
    try require(fall?.count == 1, "Fall daylight-saving fold duplicated a run")
    print("PASS calendar boundaries, catch-up, and daylight-saving changes")
}

private func verifyStorage() throws {
    let (directory, path) = try temporaryDatabase()
    defer { try? FileManager.default.removeItem(at: directory) }
    let task = TaskDefinition(
        name: "storage",
        command: CommandSpec(executable: "/bin/echo", arguments: ["stored"]),
        schedule: .daily(hour: 6, minute: 30, timeZoneID: "UTC"),
        scheduleCursor: date("2026-01-01T00:00:00Z")
    )
    let store = try SQLiteStore(path: path)
    try store.insertTask(task)
    guard let first = try store.materializeDue(taskID: task.id, through: date("2026-01-03T08:00:00Z")) else {
        throw VerificationFailure(message: "No initial catch-up run")
    }
    try require(first.occurrenceCount == 3, "Initial catch-up count is wrong")
    guard let claimed = try store.claimPendingRun(id: first.id, at: date("2026-01-03T08:01:00Z")) else {
        throw VerificationFailure(message: "Could not claim initial run")
    }
    try require(claimed.state == .starting, "Claim did not persist starting state")
    guard let followUp = try store.materializeDue(taskID: task.id, through: date("2026-01-05T08:00:00Z")) else {
        throw VerificationFailure(message: "No follow-up run while first was active")
    }
    try require(followUp.id != first.id && followUp.occurrenceCount == 2,
                "Active run swallowed later occurrences")
    try require(try store.claimPendingRun(id: followUp.id, at: Date()) == nil,
                "Follow-up started before active run resolved")
    try store.markInterruptedRunsUnknown()
    try require(try store.run(id: first.id)?.state == .outcomeUnknown,
                "Interrupted run was not marked unknown")

    let reopened = try SQLiteStore(path: path)
    try require(try reopened.listRuns(taskID: task.id).count == 2,
                "Run records did not survive reopening SQLite")
    try require(try reopened.task(id: task.id)?.scheduleCursor == followUp.lastScheduledAt,
                "Schedule cursor was not persisted")
    print("PASS durable catch-up, non-overlap, and restart recovery")
}

private func verifyRunner() throws {
    let output = try CommandRunner.run(
        CommandSpec(executable: "/bin/echo", arguments: ["hello world"]),
        timeoutSeconds: 5,
        outputLimitBytes: 5
    )
    try require(output.exitCode == 0, "Echo failed")
    try require(output.standardOutput == "hello", "Output capture was not bounded")

    let failure = try CommandRunner.run(
        CommandSpec(executable: "/bin/sh", arguments: ["-c", "exit 7"]),
        timeoutSeconds: 5
    )
    try require(failure.exitCode == 7, "Nonzero exit was not reported")

    let timeout = try CommandRunner.run(
        CommandSpec(executable: "/bin/sleep", arguments: ["3"]),
        timeoutSeconds: 0.1
    )
    try require(timeout.timedOut, "Execution timeout did not fire")
    print("PASS process output, exit status, and timeout")
}

private func verifyScheduler() throws {
    let (directory, path) = try temporaryDatabase()
    defer { try? FileManager.default.removeItem(at: directory) }
    let marker = directory.appendingPathComponent("ready")
    let task = TaskDefinition(
        name: "gated",
        command: CommandSpec(executable: "/bin/echo", arguments: ["executed"]),
        schedule: .once(Date().addingTimeInterval(-60)),
        check: CheckSpec(command: CommandSpec(executable: "/bin/test", arguments: ["-e", marker.path])),
        scheduleCursor: .distantPast
    )
    try SQLiteStore(path: path).insertTask(task)
    do {
        let scheduler = try Scheduler(databasePath: path)
        try require(try scheduler.tick() == nil, "Blocked task started")
        try require(try scheduler.store.listRuns(taskID: task.id).first?.state == .pending,
                    "Blocked task did not remain pending")
        try Data().write(to: marker)
        guard let result = try scheduler.tick() else {
            throw VerificationFailure(message: "Ready task did not start")
        }
        try require(result.state == .succeeded, "Ready task failed")
        do {
            _ = try Scheduler(databasePath: path)
            throw VerificationFailure(message: "Two schedulers acquired one database")
        } catch SchedulerError.alreadyRunning {
            // The first scheduler still owns the process lock.
        }
    }
    let restarted = try Scheduler(databasePath: path)
    try require(try restarted.tick() == nil, "Restart duplicated a completed run")
    try require(try restarted.store.listRuns(taskID: task.id).count == 1,
                "Restart changed completed history")
    print("PASS prerequisite release, scheduler lock, and restart deduplication")
}

do {
    try verifySchedules()
    try verifyStorage()
    try verifyRunner()
    try verifyScheduler()
    print("All verification checks passed.")
} catch {
    fputs("Verification failed: \(error.localizedDescription)\n", stderr)
    exit(EXIT_FAILURE)
}
