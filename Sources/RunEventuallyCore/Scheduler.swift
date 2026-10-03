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

    public init(databasePath: String) throws {
        let store = try SQLiteStore(path: databasePath)
        let lockPath = databasePath + ".scheduler.lock"
        let descriptor = lockPath.withCString { open($0, O_CREAT | O_RDWR, 0o600) }
        guard descriptor >= 0 else { throw SchedulerError.cannotCreateLock(lockPath) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            throw SchedulerError.alreadyRunning
        }
        self.store = store
        self.lockDescriptor = descriptor
        try store.markInterruptedRunsUnknown()
    }

    deinit {
        flock(lockDescriptor, LOCK_UN)
        close(lockDescriptor)
    }

    /// Materializes all due schedules, then attempts at most one eligible run.
    /// A caller can invoke this again immediately after an execution to drain
    /// other pending work, or periodically to retry blocked prerequisites.
    @discardableResult
    public func tick(at now: Date = Date()) throws -> RunRecord? {
        let tasks = try store.listTasks()
        for task in tasks where !task.isPaused {
            _ = try store.materializeDue(taskID: task.id, through: now)
        }

        for task in tasks where !task.isPaused {
            let pending = try store.listRuns(taskID: task.id)
                .filter { $0.state == .pending }
                .sorted { $0.firstScheduledAt < $1.firstScheduledAt }
            guard var run = pending.first else { continue }

            if let check = task.check {
                let result: CommandOutcome
                do {
                    result = try CommandRunner.run(
                        check.command,
                        timeoutSeconds: check.timeoutSeconds,
                        outputLimitBytes: 0
                    )
                } catch {
                    run.blockerReason = "Prerequisite check could not start: \(error.localizedDescription)"
                    try store.upsertRun(run)
                    continue
                }
                guard result.exitCode == 0 && !result.timedOut else {
                    run.blockerReason = result.timedOut
                        ? "Prerequisite check timed out."
                        : "Prerequisite check returned exit code \(result.exitCode)."
                    try store.upsertRun(run)
                    continue
                }
            }

            guard var claimed = try store.claimPendingRun(id: run.id, at: Date()) else { continue }
            claimed.blockerReason = nil
            claimed.state = .running
            claimed.startedAt = Date()
            try store.upsertRun(claimed)

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
            return claimed
        }
        return nil
    }
}
