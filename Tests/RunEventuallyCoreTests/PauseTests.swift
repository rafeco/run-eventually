import Foundation
import Testing
@testable import RunEventuallyCore

@Suite struct PauseTests {
    @Test func globalPausePersistsAndCatchUpRunsAfterResume() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("state.sqlite").path
        let now = Date()
        let task = TaskDefinition(name: "Paused", command: CommandSpec(executable: "/usr/bin/true"),
            schedule: .once(now), scheduleCursor: now.addingTimeInterval(-1))
        let scheduler = try Scheduler(databasePath: path)
        try scheduler.store.insertTask(task)
        try scheduler.store.setSchedulerPaused(true)
        #expect(try SQLiteStore(path: path).schedulerPaused())
        #expect(try scheduler.tick(at: now) == nil)
        #expect(try scheduler.store.listRuns().isEmpty)
        #expect(try scheduler.store.task(id: task.id)?.scheduleCursor == task.scheduleCursor)
        try scheduler.store.setSchedulerPaused(false)
        #expect(try scheduler.tick(at: now)?.state == .succeeded)
    }

    @Test func pauseDuringProbePreventsClaimAndKeepsTaskPauseIndependent() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("state.sqlite").path
        let now = Date()
        let writer = try SQLiteStore(path: path)
        var task = TaskDefinition(name: "Pause race", command: CommandSpec(executable: "/usr/bin/true"),
            schedule: .once(now), scheduleCursor: now.addingTimeInterval(-1))
        task.readinessChecks = [ReadinessCheck(provider: .ssh(host: "work"))]
        let scheduler = try Scheduler(databasePath: path) { _, _ in
            try! writer.setSchedulerPaused(true)
            return ReadinessResult(.ready, "Ready")
        }
        try scheduler.store.insertTask(task)
        #expect(try scheduler.tick(at: now) == nil)
        let pending = try #require(try writer.listRuns().first)
        #expect(pending.state == .pending)
        #expect(try writer.claimPendingRun(id: pending.id, at: now) == nil)
        try writer.setTaskPaused(taskID: task.id, paused: true)
        try writer.setSchedulerPaused(false)
        #expect(try writer.task(id: task.id)?.isPaused == true)
        #expect(try writer.claimPendingRun(id: pending.id, at: now) == nil)
        try writer.setTaskPaused(taskID: task.id, paused: false)
        #expect(try writer.claimPendingRun(id: pending.id, at: now)?.state == .starting)
    }
}

@Test func requestedStopIsRecordedAsCancellationWithoutAutomaticRetry() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let path = root.appendingPathComponent("state.sqlite").path
    let now = Date()
    let task = TaskDefinition(name: "Cancel", command: CommandSpec(executable: "/bin/sleep", arguments: ["10"]),
        schedule: .once(now), scheduleCursor: now.addingTimeInterval(-1))
    let scheduler = try Scheduler(databasePath: path)
    let writer = try SQLiteStore(path: path)
    try writer.insertTask(task)
    let finished = DispatchSemaphore(value: 0)
    Thread.detachNewThread {
        defer { finished.signal() }
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if let run = try? writer.listRuns().first(where: { $0.state == .running }) {
                try? writer.requestStop(runID: run.id)
                return
            }
            Thread.sleep(forTimeInterval: 0.01)
        }
    }
    let cancelled = try #require(try scheduler.tick(at: now))
    #expect(cancelled.state == .cancelled)
    #expect(cancelled.stopRequestedAt != nil)
    #expect(cancelled.blockerReason?.contains("Stopped at your request") == true)
    #expect(try scheduler.tick(at: now) == nil)
    #expect(try writer.listRuns().count == 1)
    #expect(finished.wait(timeout: .now() + 1) == .success)
}
