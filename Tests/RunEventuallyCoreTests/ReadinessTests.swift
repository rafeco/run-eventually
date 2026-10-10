import Foundation
import Testing
@testable import RunEventuallyCore

@Suite struct ReadinessTests {
    private func outcome(_ message: String, code: Int32 = 1, timeout: Bool = false) -> CommandOutcome {
        CommandOutcome(exitCode: code, standardOutput: "", standardError: message, timedOut: timeout)
    }

    @Test func providersClassifyEvidenceWithoutLeakingDiagnostics() {
        let ssh = ReadinessProvider.ssh(host: "work")
        let bq = ReadinessProvider.bigQuery(project: "work-project", dataset: "metrics")
        #expect(ReadinessRunner.classify(outcome("Permission denied (publickey). secret-token"), provider: ssh).status == .actionRequired)
        #expect(ReadinessRunner.classify(outcome("Host key verification failed"), provider: ssh).status == .actionRequired)
        #expect(ReadinessRunner.classify(outcome("No route to host"), provider: ssh).status == .waiting)
        #expect(ReadinessRunner.classify(outcome("invalid_grant secret-token"), provider: bq).status == .actionRequired)
        #expect(ReadinessRunner.classify(outcome("Access Denied"), provider: bq).status == .actionRequired)
        #expect(ReadinessRunner.classify(outcome("backendError"), provider: bq).status == .waiting)
        #expect(ReadinessRunner.classify(outcome("something unexpected"), provider: bq).status == .checkError)
        #expect(ReadinessRunner.classify(outcome("invalid_grant", timeout: true), provider: bq).status == .waiting)
        #expect(ReadinessRunner.classify(outcome("secret-token", code: 0), provider: bq).status == .ready)
        #expect(!ReadinessRunner.classify(outcome("invalid_grant secret-token"), provider: bq).message.contains("secret-token"))
        #expect(ReadinessRunner.classify(outcome("refused"), provider: .network(host: "work", port: 22)).status == .waiting)
    }

    @Test func probesUseTaskContextAndSafeArguments() throws {
        let context = CommandSpec(executable: "/usr/bin/make", workingDirectory: "/project",
            environment: ["PATH": "/project/bin", "CLOUDSDK_CONFIG": "/configured/credentials"])
        let check = ReadinessCheck(provider: .bigQuery(project: "work-project", dataset: "metrics"), timeoutSeconds: 30)
        let command = ReadinessRunner.command(for: check, context: context)
        #expect(command.workingDirectory == "/project")
        #expect(command.environment["CLOUDSDK_CONFIG"] == "/configured/credentials")
        #expect(command.environment["PATH"] == "/project/bin")
        #expect(command.environment["CLOUDSDK_CORE_DISABLE_PROMPTS"] == "1")
        #expect(command.arguments.contains("--headless=true"))
        #expect(Array(command.arguments.suffix(2)) == ["show", "work-project:metrics"])
        #expect(!command.arguments.contains("query"))
        #expect(command.arguments.contains("--apilog=/dev/null"))
        let ssh = ReadinessRunner.command(for: ReadinessCheck(provider: .ssh(host: "work")), context: context)
        #expect(ssh.arguments.contains("BatchMode=yes"))
        #expect(!ssh.arguments.contains { $0.hasPrefix("StrictHostKeyChecking=") })
        #expect(ssh.arguments.last == "true")
        #expect(throws: ReadinessConfigurationError.self) {
            try ReadinessCheck(provider: .ssh(host: "-oProxyCommand=bad")).validate()
        }
        #expect(throws: ReadinessConfigurationError.self) {
            try ReadinessCheck(provider: .network(host: "work", port: 0)).validate()
        }
        let absent = ReadinessRunner.run(check, context: context) { _, _ in
            throw CommandRunnerError.executableNotFound("bq")
        }
        #expect(absent.status == .actionRequired)
    }

    @Test func realProbeUsesConfiguredToolAndDiscardsItsOutput() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let tool = root.appendingPathComponent("bq")
        try Data("#!/bin/sh\nprintf 'invalid_grant secret-token' >&2\nexit 1\n".utf8).write(to: tool)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: tool.path)
        let result = ReadinessRunner.run(ReadinessCheck(provider: .bigQuery(project: "work-project", dataset: nil)),
            context: CommandSpec(executable: "/usr/bin/true", environment: ["PATH": root.path]))
        #expect(result.status == .actionRequired)
        #expect(!result.message.contains("secret-token"))
    }

    @Test func pendingRunsBackOffAndRecheckWithoutCreatingAnotherRun() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date()
        var task = TaskDefinition(name: "Checks", command: CommandSpec(executable: "/bin/echo", arguments: ["ran"]),
            schedule: .once(now), scheduleCursor: now.addingTimeInterval(-1))
        task.readinessChecks = [ReadinessCheck(provider: .network(host: "work", port: 22)),
            ReadinessCheck(provider: .ssh(host: "work"))]
        var ready = false
        var calls = 0
        let scheduler = try Scheduler(databasePath: root.appendingPathComponent("state.sqlite").path) { _, _ in
            calls += 1
            return ReadinessResult(ready ? .ready : .waiting, ready ? "Ready" : "Network unavailable")
        }
        try scheduler.store.insertTask(task)
        #expect(try scheduler.tick(at: now) == nil)
        var pending = try #require(try scheduler.store.listRuns(taskID: task.id).first)
        #expect(pending.state == .pending)
        #expect(pending.readinessStatus == .waiting)
        #expect(pending.nextCheckAt == now.addingTimeInterval(60))
        #expect(try scheduler.tick(at: now.addingTimeInterval(30)) == nil)
        #expect(calls == 1)
        #expect(try scheduler.tick(at: now.addingTimeInterval(60)) == nil)
        pending = try #require(try scheduler.store.run(id: pending.id))
        #expect(pending.nextCheckAt == now.addingTimeInterval(180))
        try scheduler.store.requestRecheck(taskID: task.id)
        ready = true
        let finished = try #require(try scheduler.tick(at: now.addingTimeInterval(61)))
        #expect(calls == 4)
        #expect(finished.id == pending.id)
        #expect(finished.state == .succeeded)
        #expect(finished.readinessStatus == nil)
        #expect(try scheduler.store.listRuns(taskID: task.id).count == 1)
    }

    @Test func actionRequiredAndCustomCheckBothHoldWork() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date()
        var task = TaskDefinition(name: "Checks", command: CommandSpec(executable: "/usr/bin/true"),
            schedule: .once(now), check: CheckSpec(command: CommandSpec(executable: "/usr/bin/false")),
            scheduleCursor: now.addingTimeInterval(-1))
        task.readinessChecks = [ReadinessCheck(provider: .ssh(host: "work"))]
        var needsLogin = true
        let scheduler = try Scheduler(databasePath: root.appendingPathComponent("state.sqlite").path) { _, _ in
            ReadinessResult(needsLogin ? .actionRequired : .ready, needsLogin ? "Renew credentials" : "Ready")
        }
        try scheduler.store.insertTask(task)
        #expect(try scheduler.tick(at: now) == nil)
        let pending = try #require(try scheduler.store.listRuns(taskID: task.id).first)
        #expect(pending.readinessStatus == .actionRequired)
        #expect(pending.nextCheckAt == now.addingTimeInterval(300))
        needsLogin = false
        try scheduler.store.requestRecheck(taskID: task.id)
        #expect(try scheduler.tick(at: now) == nil)
        let afterCustom = try #require(try scheduler.store.run(id: pending.id))
        #expect(afterCustom.readinessStatus == .waiting, "\(afterCustom.blockerReason ?? "none"); next \(String(describing: afterCustom.nextCheckAt))")
        task.check = nil
        try scheduler.store.updateTask(task)
        let finished = try scheduler.tick(at: now)
        let messages = try scheduler.store.listActivity(limit: 10).map(\.message)
        #expect(finished?.state == .succeeded, "\(messages)")
    }

    @Test func editsInvalidateChecksAndPreventStaleClaims() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SQLiteStore(path: root.appendingPathComponent("state.sqlite").path)
        let now = Date()
        let original = TaskDefinition(name: "Task", command: CommandSpec(executable: "/usr/bin/true"),
            schedule: .once(now), scheduleCursor: now.addingTimeInterval(-1))
        try store.insertTask(original)
        let pending = try store.requestRun(taskID: original.id, at: now)
        var changed = original
        changed.readinessChecks = [ReadinessCheck(provider: .ssh(host: "work"))]
        try store.updateTask(changed)
        try store.recordCheckBlocker(runID: pending.id, reason: "stale", status: .waiting,
            nextCheckAt: now.addingTimeInterval(900), expectedTask: original)
        #expect(try store.run(id: pending.id)?.blockerReason == nil)
        #expect(try store.claimPendingRun(id: pending.id, at: now, expectedTask: original) == nil)
        #expect(try store.claimPendingRun(id: pending.id, at: now, expectedTask: changed) != nil)
    }
}
