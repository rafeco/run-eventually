import Foundation
import Testing
@testable import RunEventuallyCore

struct ActivityTests {
    private func fixture() throws -> (URL, String) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("activity-tests-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return (directory, directory.appendingPathComponent("state.sqlite").path)
    }

    @Test func historyPersistsAndUsesInsertionOrderAcrossClockChanges() throws {
        let (directory, path) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = ActivityEvent(kind: .checkStarted, message: "First", timestamp: Date(timeIntervalSince1970: 100))
        let second = ActivityEvent(kind: .checkPassed, message: "Second", schedulerSessionID: UUID(), timestamp: Date(timeIntervalSince1970: 50))
        do {
            let store = try SQLiteStore(path: path)
            try store.recordActivity(first)
            try store.recordActivity(second)
        }
        let reopened = try SQLiteStore(path: path)
        #expect(try reopened.listActivity() == [second, first])
        #expect(try reopened.listActivity(limit: 1) == [second])
        #expect(try reopened.listActivity(schedulerOnly: true) == [second])
    }

    @Test func rejectedRunRequestIsRecordedWithoutQueuingWork() throws {
        let store = try SQLiteStore(path: ":memory:")
        let task = TaskDefinition(name: "paused", command: CommandSpec(executable: "/usr/bin/true"),
            schedule: .once(Date()), isPaused: true, scheduleCursor: .distantPast)
        try store.insertTask(task)
        #expect(throws: SQLiteStoreError.self) { try store.requestRun(taskID: task.id) }
        #expect(try store.listRuns().isEmpty)
        let event = try #require(try store.listActivity().first)
        #expect(event.kind == .runRequestRejected)
        #expect(event.taskID == task.id)
        #expect(event.level == .warning)
    }

    @Test func rollingHistoryIsBounded() throws {
        let store = try SQLiteStore(path: ":memory:")
        for _ in 0..<5_005 {
            try store.recordActivity(ActivityEvent(kind: .scheduleChecked, message: "Scan"))
        }
        #expect(try store.listActivity(limit: 10_000).count == 5_000)
    }

    @Test func checkAndRunOutcomesAreLoggedWithoutCommandOutputOrEnvironment() throws {
        let (directory, path) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let marker = directory.appendingPathComponent("ready")
        let task = TaskDefinition(name: "checked", command: CommandSpec(executable: "/bin/echo", arguments: ["PRIVATE_OUTPUT"], environment: ["SECRET": "PRIVATE_ENV"]),
            schedule: .once(Date().addingTimeInterval(-60)),
            check: CheckSpec(command: CommandSpec(executable: "/bin/test", arguments: ["-e", marker.path])), scheduleCursor: .distantPast)
        let store = try SQLiteStore(path: path)
        try store.insertTask(task)
        do {
            let scheduler = try Scheduler(databasePath: path)
            #expect(try Scheduler.isRunning(databasePath: path))
            #expect(try scheduler.tick() == nil)
            let first = try store.listActivity().reversed().map(\.kind)
            #expect(first.contains(.workDue))
            #expect(first.contains(.checkStarted))
            #expect(first.contains(.checkBlocked))
            #expect(!first.contains(.runStarted))
            try Data().write(to: marker)
            #expect(try scheduler.tick()?.state == .succeeded)
            let events = try store.listActivity().reversed()
            let kinds = events.map(\.kind)
            let passed = try #require(kinds.firstIndex(of: .checkPassed))
            let started = try #require(kinds.firstIndex(of: .runStarted))
            let finished = try #require(kinds.firstIndex(of: .runSucceeded))
            #expect(passed < started && started < finished)
            #expect(events.filter { $0.kind == .checkStarted }.allSatisfy { $0.taskID == task.id && $0.runID != nil })
            #expect(!events.contains { $0.message.contains("PRIVATE_OUTPUT") || $0.message.contains("PRIVATE_ENV") })
        }
        #expect(try !Scheduler.isRunning(databasePath: path))
        #expect(try store.listActivity(schedulerOnly: true).first?.kind == .schedulerStopped)
    }

    @Test func operationStartIsVisibleFromAnotherConnectionBeforeCompletion() async throws {
        let (directory, path) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let task = TaskDefinition(name: "slow", command: CommandSpec(executable: "/bin/sleep", arguments: ["1"]),
            schedule: .once(Date().addingTimeInterval(-60)), scheduleCursor: .distantPast)
        let reader = try SQLiteStore(path: path)
        try reader.insertTask(task)
        let worker = Task.detached {
            let scheduler = try Scheduler(databasePath: path)
            return try scheduler.tick()
        }
        var sawActiveOperation = false
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if try reader.listActivity(schedulerOnly: true).first?.kind == .runStarted {
                sawActiveOperation = true
                #expect(try reader.listRuns(taskID: task.id).first?.state == .running)
                break
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        let result = try await worker.value
        #expect(sawActiveOperation)
        #expect(result?.state == .succeeded)
    }

    @Test func failuresAndInterruptedRecoveryHaveUsefulActivity() throws {
        let (directory, path) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let task = TaskDefinition(name: "failure", command: CommandSpec(executable: "/usr/bin/false"),
            schedule: .once(Date().addingTimeInterval(-60)), scheduleCursor: .distantPast)
        let store = try SQLiteStore(path: path)
        try store.insertTask(task)
        do {
            let scheduler = try Scheduler(databasePath: path)
            #expect(try scheduler.tick()?.state == .failed)
            #expect(try store.listActivity().contains { $0.kind == .runFailed && $0.level == .error })
        }
        let manual = try store.requestRun(taskID: task.id)
        _ = try store.claimPendingRun(id: manual.id, at: Date())
        do {
            let scheduler = try Scheduler(databasePath: path)
            #expect(try scheduler.store.run(id: manual.id)?.state == .outcomeUnknown)
            #expect(try store.listActivity().contains { $0.kind == .runRecovered && $0.runID == manual.id })
        }
    }
}
