import Darwin
import Foundation

public enum SchedulerError: Error, LocalizedError {
    case alreadyRunning
    case cannotCreateLock(String)

    public var errorDescription: String? {
        switch self {
        case .alreadyRunning:
            return "Another scheduler is already running for this database."
        case .cannotCreateLock(let path):
            return "Cannot create scheduler lock at \(path)."
        }
    }
}

/// Owns execution for one database. Other processes may inspect or add tasks,
/// but only the holder of the lock may recover and launch runs.
public final class Scheduler {
    public let store: SQLiteStore
    private let lockDescriptor: Int32
    private let sessionID: UUID
    public let shutdown = GracefulShutdown()

    public init(databasePath: String) throws {
        let store = try SQLiteStore(path: databasePath)
        let lockPath = databasePath + ".scheduler.lock"
        let descriptor = lockPath.withCString { open($0, O_CREAT | O_RDWR, 0o600) }
        guard descriptor >= 0 else { throw SchedulerError.cannotCreateLock(lockPath) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            throw SchedulerError.alreadyRunning
        }
        let session = UUID()
        do {
            try store.markInterruptedRunsUnknown()
            try store.recordActivity(ActivityEvent(kind: .schedulerStarted,
                message: "Scheduler started; interrupted runs checked for recovery.", schedulerSessionID: session))
        } catch {
            flock(descriptor, LOCK_UN)
            close(descriptor)
            throw error
        }
        self.store = store
        self.lockDescriptor = descriptor
        self.sessionID = session
    }

    deinit {
        try? record(.schedulerStopped, "Scheduler stopped.")
        try? store.clearSchedulerRuntime(sessionID: sessionID)
        flock(lockDescriptor, LOCK_UN)
        close(lockDescriptor)
    }

    /// Materializes all due schedules, then attempts at most one eligible run.
    /// A caller can invoke this again immediately after an execution to drain
    /// other pending work, or periodically to retry blocked prerequisites.
    @discardableResult
    public func tick(at now: Date = Date()) throws -> RunRecord? {
        guard !shutdown.isRequested else { return nil }
        do {
            try record(.cycleStarted, "Checking schedules and pending work.")
            let result = try reconcile(at: now)
            try record(.cycleFinished, result == nil
                ? "Scan complete; no task was eligible to start."
                : "Scan complete; task execution finished.")
            return result
        } catch {
            try? record(.schedulerError, "Scheduler scan failed: \(error.localizedDescription)", level: .error)
            throw error
        }
    }

    /// Register signal handling before advertising this capability to the updater.
    public func announceGracefulShutdownSupport() throws {
        guard let executable = Bundle.main.executableURL else {
            throw SchedulerError.cannotCreateLock("Unable to locate running executable")
        }
        try store.setSchedulerRuntime(SchedulerRuntime(sessionID: sessionID, processID: getpid(),
            executableDigest: try SchedulerRuntime.executableDigest(at: executable), supportsGracefulShutdown: true))
    }

    public func shutdownHandler() -> @Sendable () -> Void {
        let control = shutdown
        let store = store
        let session = sessionID
        return {
            control.request {
                try? store.recordActivity(ActivityEvent(kind: .schedulerStopping,
                    message: "Stopping after the current operation finishes; no new work will start.", schedulerSessionID: session))
            }
        }
    }

    public func recordWaiting(until date: Date) throws {
        try store.recordActivity(ActivityEvent(kind: .waiting,
            message: "Waiting for the next scheduler scan.", schedulerSessionID: sessionID, nextCheckAt: date))
    }

    /// Probe the scheduler's existing exclusive lock without starting a scheduler
    /// or creating a lock file. A held lock is evidence of ownership, not progress.
    public static func isRunning(databasePath: String) throws -> Bool {
        let path = databasePath + ".scheduler.lock"
        let descriptor = path.withCString { open($0, O_RDWR) }
        guard descriptor >= 0 else {
            if errno == ENOENT { return false }
            throw SchedulerError.cannotCreateLock(path)
        }
        defer { close(descriptor) }
        if flock(descriptor, LOCK_EX | LOCK_NB) == 0 {
            flock(descriptor, LOCK_UN)
            return false
        }
        if errno == EWOULDBLOCK || errno == EAGAIN { return true }
        throw SchedulerError.cannotCreateLock(path)
    }

    private func record(
        _ kind: ActivityKind, _ message: String, level: ActivityLevel = .info,
        taskID: UUID? = nil, runID: UUID? = nil
    ) throws {
        try store.recordActivity(ActivityEvent(kind: kind, message: message, level: level,
            taskID: taskID, runID: runID, schedulerSessionID: sessionID))
    }

    private func reconcile(at now: Date) throws -> RunRecord? {
        let tasks = try store.listTasks()
        for task in tasks {
            if shutdown.isRequested { return nil }
            if task.isPaused {
                try record(.scheduleChecked, "Schedule skipped because the task is paused.", taskID: task.id)
            } else {
                let due = try store.materializeDue(taskID: task.id, through: now)
                try record(.scheduleChecked, due == nil
                    ? "Schedule checked; no new occurrences are due."
                    : "Schedule checked; due work added to the queue.", taskID: task.id, runID: due?.id)
            }
        }

        for task in tasks where !task.isPaused {
            if shutdown.isRequested { return nil }
            let runs = try store.listRuns(taskID: task.id)
            let pending = runs
                .filter { $0.state == .pending }
                .sorted { $0.firstScheduledAt < $1.firstScheduledAt }
            guard let run = pending.first else { continue }

            if let unresolved = runs.first(where: { $0.state == .starting || $0.state == .running || $0.state == .outcomeUnknown }) {
                try record(.runHeld, unresolved.state == .outcomeUnknown
                    ? "Pending work held because a previous outcome needs review."
                    : "Pending work held because another run is active.",
                    level: .warning, taskID: task.id, runID: run.id)
                continue
            }

            if let check = task.check {
                guard try shutdown.admit({
                    try record(.checkStarted, "Running the readiness check.", taskID: task.id, runID: run.id)
                    return true
                }) == true else { return nil }
                let result: CommandOutcome
                do {
                    result = try CommandRunner.run(
                        check.command,
                        timeoutSeconds: check.timeoutSeconds,
                        outputLimitBytes: 0
                    )
                } catch {
                    try store.recordCheckBlocker(runID: run.id, reason: "Prerequisite check could not start: \(error.localizedDescription)")
                    try record(.checkFailed, "Readiness check could not start: \(error.localizedDescription)",
                        level: .error, taskID: task.id, runID: run.id)
                    continue
                }
                guard result.exitCode == 0 && !result.timedOut else {
                    let reason = result.timedOut
                        ? "Prerequisite check timed out."
                        : (check.failureMessages?[String(result.exitCode)] ?? "Prerequisite check returned exit code \(result.exitCode).")
                    try store.recordCheckBlocker(runID: run.id, reason: reason)
                    try record(result.timedOut || result.exitCode != 1 ? .checkFailed : .checkBlocked,
                        reason, level: result.timedOut || result.exitCode != 1 ? .error : .warning,
                        taskID: task.id, runID: run.id)
                    continue
                }
                try record(.checkPassed, "Readiness check passed.", taskID: task.id, runID: run.id)
            } else {
                try record(.eligibilityChecked, "No readiness check is configured; work is eligible for launch.", taskID: task.id, runID: run.id)
            }

            if shutdown.isRequested { return nil }
            guard var claimed = try shutdown.admit({ try store.claimPendingRun(id: run.id, at: Date()) }) ?? nil else {
                try record(.runHeld, "Launch skipped; this run is no longer eligible to claim.", taskID: task.id, runID: run.id)
                continue
            }
            claimed.blockerReason = nil
            claimed.state = .running
            claimed.startedAt = Date()
            try store.upsertRun(claimed)
            try record(.runStarted, "Running the task command.", taskID: task.id, runID: run.id)

            do {
                let result = try CommandRunner.run(task.command, timeoutSeconds: 3_600)
                claimed.exitCode = result.exitCode
                claimed.standardOutput = result.standardOutput
                claimed.standardError = result.standardError
                claimed.finishedAt = Date()
                claimed.state = result.exitCode == 0 && !result.timedOut ? .succeeded : .failed
                if result.timedOut { claimed.blockerReason = "Command timed out." }
            } catch {
                claimed.finishedAt = Date()
                claimed.state = .failed
                claimed.blockerReason = "Command could not start: \(error.localizedDescription)"
            }
            try store.upsertRun(claimed)
            try record(claimed.state == .succeeded ? .runSucceeded : .runFailed,
                claimed.blockerReason ?? "Command finished with exit code \(claimed.exitCode.map(String.init) ?? "unknown").",
                level: claimed.state == .succeeded ? .info : .error, taskID: task.id, runID: run.id)
            return claimed
        }
        return nil
    }
}
