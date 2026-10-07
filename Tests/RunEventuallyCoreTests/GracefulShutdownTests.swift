import Foundation
import Testing
@testable import RunEventuallyCore

struct GracefulShutdownTests {
    @Test func requestedShutdownRejectsNewWorkAndWakesWaiter() async {
        let control = GracefulShutdown()
        let waiter = Task.detached { control.wait(until: Date().addingTimeInterval(60)) }
        #expect(control.request())
        #expect(!control.request())
        var admitted = false
        let result = control.admit { admitted = true; return 1 }
        #expect(result == nil)
        #expect(!admitted)
        await waiter.value
    }

    @Test func stoppedSchedulerLeavesDueIntentUntouched() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("shutdown-tests-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let scheduler = try Scheduler(databasePath: directory.appendingPathComponent("state.sqlite").path)
        let task = TaskDefinition(name: "pending", command: CommandSpec(executable: "/usr/bin/true"),
            schedule: .once(Date().addingTimeInterval(-60)), scheduleCursor: .distantPast)
        try scheduler.store.insertTask(task)
        scheduler.shutdownHandler()()
        #expect(try scheduler.tick() == nil)
        #expect(try scheduler.store.listRuns().isEmpty)
        #expect(try scheduler.store.task(id: task.id)?.scheduleCursor == .distantPast)
        #expect(try scheduler.store.listActivity().first?.kind == .schedulerStopping)
    }

    @Test func runtimeIsOwnedByItsSession() throws {
        let store = try SQLiteStore(path: ":memory:")
        let runtime = SchedulerRuntime(sessionID: UUID(), processID: 123, executableDigest: "digest", supportsGracefulShutdown: true)
        try store.setSchedulerRuntime(runtime)
        try store.clearSchedulerRuntime(sessionID: UUID())
        #expect(try store.schedulerRuntime() == runtime)
        try store.clearSchedulerRuntime(sessionID: runtime.sessionID)
        #expect(try store.schedulerRuntime() == nil)
    }
}
