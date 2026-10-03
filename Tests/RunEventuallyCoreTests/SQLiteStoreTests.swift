import Foundation
import Testing
@testable import RunEventuallyCore

@Suite struct SQLiteStoreTests {
    @Test
    func testTasksAndRunsSurviveReopeningDatabase() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("nested/scheduler.sqlite").path
        let task = makeTask(name: "Daily report")
        let run = RunRecord(
            taskID: task.id,
            firstScheduledAt: date("2026-01-01T06:30:00Z"),
            lastScheduledAt: date("2026-01-01T06:30:00Z"),
            occurrenceCount: 1,
            state: .succeeded,
            standardOutput: "Report ready"
        )

        do {
            let store = try SQLiteStore(path: path)
            try store.insertTask(task)
            try store.upsertRun(run)
            #expect(try store.listTasks() == [task])
            #expect(try store.listRuns(taskID: task.id) == [run])
        }

        let reopened = try SQLiteStore(path: path)
        #expect(try reopened.task(id: task.id) == task)
        #expect(try reopened.run(id: run.id) == run)
        #expect(try reopened.listRuns() == [run])
        #expect(try reopened.listRuns(taskID: UUID()).isEmpty)

        var renamed = task
        renamed.name = "Renamed report"
        try reopened.updateTask(renamed)
        #expect(try reopened.task(id: task.id)?.name == "Renamed report")
    }

    @Test
    func testMissedDaysCoalesceAndAdvanceCursorOnce() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SQLiteStore(path: root.appendingPathComponent("runs.sqlite").path)
        let task = makeTask()
        try store.insertTask(task)

        let first = try #require(try store.materializeDue(
            taskID: task.id,
            through: date("2026-01-03T08:00:00Z")
        ))
        #expect(first.state == .pending)
        #expect(first.occurrenceCount == 3)
        #expect(first.firstScheduledAt == date("2026-01-01T06:30:00Z"))
        #expect(first.lastScheduledAt == date("2026-01-03T06:30:00Z"))
        #expect(try store.task(id: task.id)?.scheduleCursor == first.lastScheduledAt)

        let extended = try #require(try store.materializeDue(
            taskID: task.id,
            through: date("2026-01-05T08:00:00Z")
        ))
        #expect(extended.id == first.id)
        #expect(extended.occurrenceCount == 5)
        #expect(extended.firstScheduledAt == first.firstScheduledAt)
        #expect(extended.lastScheduledAt == date("2026-01-05T06:30:00Z"))
        #expect(try store.listRuns(taskID: task.id).count == 1)
        #expect(try store.materializeDue(
            taskID: task.id,
            through: date("2026-01-05T08:00:00Z")
        ) == nil)
        #expect(try store.task(id: task.id)?.scheduleCursor == extended.lastScheduledAt)
    }

    @Test
    func testPausePreservesCursorAndPreventsClaim() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SQLiteStore(path: root.appendingPathComponent("runs.sqlite").path)
        var task = makeTask()
        task.isPaused = true
        try store.insertTask(task)

        #expect(try store.materializeDue(
            taskID: task.id,
            through: date("2026-01-02T08:00:00Z")
        ) == nil)
        #expect(try store.task(id: task.id)?.scheduleCursor == task.scheduleCursor)
        #expect(try store.listRuns(taskID: task.id).isEmpty)

        task.isPaused = false
        try store.updateTask(task)
        let pending = try #require(try store.materializeDue(
            taskID: task.id,
            through: date("2026-01-02T08:00:00Z")
        ))
        #expect(pending.occurrenceCount == 2)

        task = try #require(try store.task(id: task.id))
        task.isPaused = true
        try store.updateTask(task)
        #expect(try store.claimPendingRun(id: pending.id, at: date("2026-01-02T08:01:00Z")) == nil)
        #expect(try store.run(id: pending.id)?.state == .pending)
    }

    @Test
    func testClaimBlocksFollowUpUntilPreviousOutcomeIsResolved() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SQLiteStore(path: root.appendingPathComponent("runs.sqlite").path)
        let task = makeTask()
        try store.insertTask(task)

        let first = try #require(try store.materializeDue(
            taskID: task.id,
            through: date("2026-01-01T08:00:00Z")
        ))
        let claimed = try #require(try store.claimPendingRun(
            id: first.id,
            at: date("2026-01-01T08:01:00Z")
        ))
        #expect(claimed.state == .starting)
        #expect(claimed.startedAt == date("2026-01-01T08:01:00Z"))
        #expect(try store.claimPendingRun(id: first.id, at: date("2026-01-01T08:02:00Z")) == nil)

        let followUp = try #require(try store.materializeDue(
            taskID: task.id,
            through: date("2026-01-03T08:00:00Z")
        ))
        #expect(followUp.id != first.id)
        #expect(followUp.occurrenceCount == 2)
        #expect(try store.listRuns(taskID: task.id).count == 2)
        #expect(try store.claimPendingRun(id: followUp.id, at: date("2026-01-03T08:01:00Z")) == nil)

        try store.markInterruptedRunsUnknown()
        #expect(try store.run(id: first.id)?.state == .outcomeUnknown)
        #expect(try store.claimPendingRun(id: followUp.id, at: date("2026-01-03T08:02:00Z")) == nil)

        var resolved = try #require(try store.run(id: first.id))
        resolved.state = .succeeded
        resolved.finishedAt = date("2026-01-03T08:03:00Z")
        try store.upsertRun(resolved)
        let next = try #require(try store.claimPendingRun(
            id: followUp.id,
            at: date("2026-01-03T08:04:00Z")
        ))
        #expect(next.state == .starting)
    }

    @Test
    func testStartupRecoveryOnlyMarksInterruptedRunsUnknown() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SQLiteStore(path: root.appendingPathComponent("runs.sqlite").path)
        let states: [RunState] = [.starting, .running, .succeeded, .pending]
        var records: [RunRecord] = []

        for state in states {
            let task = makeTask(name: state.rawValue)
            try store.insertTask(task)
            let run = RunRecord(
                taskID: task.id,
                firstScheduledAt: date("2026-01-01T06:30:00Z"),
                lastScheduledAt: date("2026-01-01T06:30:00Z"),
                occurrenceCount: 1,
                state: state
            )
            try store.upsertRun(run)
            records.append(run)
        }

        try store.markInterruptedRunsUnknown()
        #expect(try store.run(id: records[0].id)?.state == .outcomeUnknown)
        #expect(try store.run(id: records[1].id)?.state == .outcomeUnknown)
        #expect(try store.run(id: records[2].id)?.state == .succeeded)
        #expect(try store.run(id: records[3].id)?.state == .pending)
    }

    private func makeTask(name: String = "Daily job") -> TaskDefinition {
        TaskDefinition(
            name: name,
            command: CommandSpec(
                executable: "/usr/bin/make",
                arguments: ["daily"],
                workingDirectory: "/tmp/project",
                environment: ["MODE": "test"]
            ),
            schedule: .daily(hour: 6, minute: 30, timeZoneID: "UTC"),
            check: CheckSpec(command: CommandSpec(executable: "/usr/bin/true")),
            scheduleCursor: date("2026-01-01T00:00:00Z"),
            createdAt: date("2026-01-01T00:00:00Z")
        )
    }

    private func date(_ value: String) -> Date {
        ISO8601DateFormatter().date(from: value)!
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("run-eventually-store-tests-\(UUID().uuidString)")
    }
}
