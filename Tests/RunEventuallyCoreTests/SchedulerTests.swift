import Foundation
import Testing
@testable import RunEventuallyCore

struct SchedulerTests {
    private func temporaryDatabase() throws -> (directory: URL, path: String) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("run-eventually-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return (directory, directory.appendingPathComponent("state.sqlite").path)
    }

    @Test func overdueTaskExecutesOnceAndSurvivesRestart() throws {
        let fixture = try temporaryDatabase()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let due = Date().addingTimeInterval(-120)
        let task = TaskDefinition(
            name: "example",
            command: CommandSpec(executable: "/bin/echo", arguments: ["hello"]),
            schedule: .once(due),
            scheduleCursor: .distantPast
        )
        try SQLiteStore(path: fixture.path).insertTask(task)

        do {
            let scheduler = try Scheduler(databasePath: fixture.path)
            let result = try #require(try scheduler.tick())
            #expect(result.state == .succeeded)
            #expect(result.firstScheduledAt == due)
            #expect(result.standardOutput?.trimmingCharacters(in: .whitespacesAndNewlines) == "hello")
        }

        let restarted = try Scheduler(databasePath: fixture.path)
        #expect(try restarted.tick() == nil)
        let runs = try restarted.store.listRuns(taskID: task.id)
        #expect(runs.count == 1)
        #expect(runs.first?.state == .succeeded)
    }

    @Test func missingPrerequisiteLeavesRunPendingThenReleasesIt() throws {
        let fixture = try temporaryDatabase()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let marker = fixture.directory.appendingPathComponent("ready")
        let task = TaskDefinition(
            name: "checked",
            command: CommandSpec(executable: "/bin/echo", arguments: ["executed"]),
            schedule: .once(Date().addingTimeInterval(-60)),
            check: CheckSpec(command: CommandSpec(executable: "/bin/test", arguments: ["-e", marker.path])),
            scheduleCursor: .distantPast
        )
        try SQLiteStore(path: fixture.path).insertTask(task)
        let scheduler = try Scheduler(databasePath: fixture.path)

        #expect(try scheduler.tick() == nil)
        var pending = try #require(try scheduler.store.listRuns(taskID: task.id).first)
        #expect(pending.state == .pending)
        #expect(pending.blockerReason != nil)
        #expect(pending.startedAt == nil)

        try Data().write(to: marker)
        pending = try #require(try scheduler.tick())
        #expect(pending.state == .succeeded)
        #expect(pending.blockerReason == nil)
        #expect(try scheduler.store.listRuns(taskID: task.id).count == 1)
    }

    @Test func startupPreservesAmbiguousAttemptAsUnknown() throws {
        let fixture = try temporaryDatabase()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let task = TaskDefinition(
            name: "ambiguous",
            command: CommandSpec(executable: "/bin/echo", arguments: ["should not run"]),
            schedule: .once(Date().addingTimeInterval(-60)),
            scheduleCursor: .distantPast
        )
        let store = try SQLiteStore(path: fixture.path)
        try store.insertTask(task)
        let due = try #require(try store.materializeDue(taskID: task.id, through: Date()))
        let claimed = try #require(try store.claimPendingRun(id: due.id, at: Date()))
        #expect(claimed.state == .starting)

        let scheduler = try Scheduler(databasePath: fixture.path)
        #expect(try scheduler.tick() == nil)
        let after = try #require(try scheduler.store.run(id: due.id))
        #expect(after.state == .outcomeUnknown)
    }

    @Test func onlyOneSchedulerCanOwnDatabase() throws {
        let fixture = try temporaryDatabase()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let first = try Scheduler(databasePath: fixture.path)
        #expect(throws: SchedulerError.self) {
            _ = try Scheduler(databasePath: fixture.path)
        }
        _ = first.store
    }
}
