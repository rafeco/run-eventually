import Foundation
import Testing
@testable import RunEventuallyCore

@Suite struct ManualRunTests {
    private func fixture() throws -> (URL, String, TaskDefinition, Date) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let now = Date()
        let task = TaskDefinition(
            name: "Manual example",
            command: CommandSpec(executable: "/bin/echo", arguments: ["ran"]),
            schedule: .once(now.addingTimeInterval(3600)),
            scheduleCursor: now,
            createdAt: now
        )
        let path = root.appendingPathComponent("state.sqlite").path
        try SQLiteStore(path: path).insertTask(task)
        return (root, path, task, now)
    }

    @Test func concurrentRequestsShareOneDurableRunWithoutMovingSchedule() async throws {
        let (root, path, task, now) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let ids = try await withThrowingTaskGroup(of: UUID.self) { group in
            for _ in 0..<8 {
                group.addTask { try SQLiteStore(path: path).requestRun(taskID: task.id, at: now).id }
            }
            var results = Set<UUID>()
            for try await id in group { results.insert(id) }
            return results
        }
        #expect(ids.count == 1)
        let reopened = try SQLiteStore(path: path)
        #expect(try reopened.task(id: task.id)?.scheduleCursor == task.scheduleCursor)
        let runs = try reopened.listRuns()
        #expect(runs.count == 1)
        #expect(runs.first?.trigger == .manual)
        #expect(runs.first?.occurrenceCount == 0)
    }

    @Test func overdueScheduleIsReusedAndCompletedTaskCanRunAgain() throws {
        let (root, path, original, now) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SQLiteStore(path: path)
        var task = original
        task.schedule = .once(now.addingTimeInterval(-60))
        task.scheduleCursor = .distantPast
        try store.updateTask(task)
        var run = try store.requestRun(taskID: task.id, at: now)
        #expect(run.trigger == .scheduled)
        #expect(run.occurrenceCount == 1)
        #expect(try store.requestRun(taskID: task.id, at: now).id == run.id)
        run.state = .succeeded
        run.finishedAt = now
        try store.upsertRun(run)
        let cursor = try #require(try store.task(id: task.id)).scheduleCursor
        let again = try store.requestRun(taskID: task.id, at: now)
        #expect(again.id != run.id)
        #expect(again.trigger == .manual)
        #expect(try store.task(id: task.id)?.scheduleCursor == cursor)
    }

    @Test func pausedTaskRejectsRequest() throws {
        let (root, path, original, now) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SQLiteStore(path: path)
        var task = original
        task.isPaused = true
        try store.updateTask(task)
        #expect(throws: SQLiteStoreError.self) { try store.requestRun(taskID: task.id, at: now) }
        #expect(try store.listRuns().isEmpty)
    }

    @Test func blockerShowsConfiguredActionWithoutPersistingCredentialOutput() throws {
        let (root, path, original, now) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SQLiteStore(path: path)
        var task = original
        task.check = CheckSpec(
            command: CommandSpec(executable: "/bin/sh", arguments: ["-c", "echo secret-token; echo raw-auth-error >&2; exit 13"]),
            failureMessages: ["13": "Google credentials unavailable. Run make auth."]
        )
        try store.updateTask(task)
        let requested = try store.requestRun(taskID: task.id, at: now)
        let scheduler = try Scheduler(databasePath: path)
        #expect(try scheduler.tick(at: now) == nil)
        let waiting = try #require(try store.run(id: requested.id))
        #expect(waiting.blockerReason == "Google credentials unavailable. Run make auth.")
        #expect(waiting.lastCheckedAt != nil)
        #expect(waiting.startedAt == nil)
        #expect(waiting.standardOutput == nil)
        #expect(waiting.standardError == nil)
    }

    @Test func activeRunIsReusedAndUnknownOutcomeRejectsNewWork() throws {
        let (root, path, task, now) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SQLiteStore(path: path)
        let pending = try store.requestRun(taskID: task.id, at: now)
        var active = try #require(try store.claimPendingRun(id: pending.id, at: now))
        #expect(try store.requestRun(taskID: task.id, at: now).id == active.id)
        active.state = .outcomeUnknown
        try store.upsertRun(active)
        #expect(throws: SQLiteStoreError.self) { try store.requestRun(taskID: task.id, at: now) }
        #expect(try store.listRuns().count == 1)
    }

    @Test func manualRunWaitsForPrerequisiteThenExecutesOnce() throws {
        let (root, path, original, now) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SQLiteStore(path: path)
        var task = original
        let ready = root.appendingPathComponent("ready")
        task.check = CheckSpec(command: CommandSpec(executable: "/bin/test", arguments: ["-e", ready.path]))
        try store.updateTask(task)
        let request = try store.requestRun(taskID: task.id, at: now)
        let scheduler = try Scheduler(databasePath: path)
        #expect(try scheduler.tick(at: now) == nil)
        #expect(try store.run(id: request.id)?.state == .pending)
        #expect(try store.run(id: request.id)?.blockerReason != nil)
        try Data().write(to: ready)
        let result = try #require(try scheduler.tick(at: now))
        #expect(result.id == request.id)
        #expect(result.state == .succeeded)
        #expect(result.trigger == .manual)
        #expect(try scheduler.tick(at: now) == nil)
    }

    @Test func scheduledWorkCoalescesWithManualRequestWithoutStaleCheckLosingIt() throws {
        let (root, path, original, now) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SQLiteStore(path: path)
        var task = original
        let due = now.addingTimeInterval(10)
        task.schedule = .once(due)
        try store.updateTask(task)
        let request = try store.requestRun(taskID: task.id, at: now)
        let scheduled = try #require(try store.materializeDue(taskID: task.id, through: due))
        #expect(scheduled.id == request.id)
        #expect(scheduled.trigger == .scheduledAndManual)
        #expect(scheduled.firstScheduledAt == due)
        #expect(scheduled.occurrenceCount == 1)
        try store.recordCheckBlocker(runID: request.id, reason: "Waiting for VPN")
        let latest = try #require(try store.run(id: request.id))
        #expect(latest.firstScheduledAt == due)
        #expect(latest.occurrenceCount == 1)
        #expect(latest.blockerReason == "Waiting for VPN")
        #expect(try store.listRuns().count == 1)
    }

    @Test func legacyRunWithoutTriggerStillDecodes() throws {
        let now = Date()
        let run = RunRecord(taskID: UUID(), firstScheduledAt: now, lastScheduledAt: now, occurrenceCount: 1)
        var payload = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(run)) as? [String: Any])
        payload.removeValue(forKey: "trigger")
        let legacy = try JSONDecoder().decode(RunRecord.self, from: JSONSerialization.data(withJSONObject: payload))
        #expect(legacy.trigger == nil)
        #expect(legacy.id == run.id)
    }

    @Test func manualRunAfterDailyCreationDoesNotConsumeTomorrowMorning() throws {
        let (root, path, original, _) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let formatter = ISO8601DateFormatter()
        let created = try #require(formatter.date(from: "2026-10-04T09:00:00-04:00"))
        let requested = try #require(formatter.date(from: "2026-10-04T09:15:00-04:00"))
        let tomorrow = try #require(formatter.date(from: "2026-10-05T06:30:00-04:00"))
        let store = try SQLiteStore(path: path)
        var task = original
        task.schedule = .daily(hour: 6, minute: 30, timeZoneID: "America/New_York")
        task.createdAt = created
        task.scheduleCursor = created
        try store.updateTask(task)
        let manual = try store.requestRun(taskID: task.id, at: requested)
        let scheduler = try Scheduler(databasePath: path)
        let today = try #require(try scheduler.tick(at: requested))
        #expect(today.id == manual.id)
        #expect(today.state == .succeeded)
        #expect(today.trigger == .manual)
        #expect(try store.task(id: task.id)?.scheduleCursor == created)
        let morning = try #require(try scheduler.tick(at: tomorrow))
        #expect(morning.id != manual.id)
        #expect(morning.trigger == .scheduled)
        #expect(morning.firstScheduledAt == tomorrow)
        #expect(morning.occurrenceCount == 1)
        #expect(morning.state == .succeeded)
        #expect(try scheduler.tick(at: tomorrow) == nil)
        #expect(try store.listRuns(taskID: task.id).count == 2)
    }
}
