import Foundation
import SQLite3

public enum SQLiteStoreError: Error, LocalizedError {
    case database(code: Int32, message: String)
    case missingTask(UUID)
    case taskPaused
    case outcomeNeedsReview

    public var errorDescription: String? {
        switch self {
        case let .database(code, message):
            return "SQLite error \(code): \(message)"
        case let .missingTask(id):
            return "Task \(id) does not exist"
        case .taskPaused:
            return "Resume the task before requesting a run."
        case .outcomeNeedsReview:
            return "The previous run has an unknown outcome. Resolve it before requesting another run."
        }
    }
}

/// The scheduler's durable source of truth. Every read and write is serialized on
/// this connection; `BEGIN IMMEDIATE` also protects multi-step operations against
/// other store instances using the same database file.
public final class SQLiteStore: @unchecked Sendable {
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private let lock = NSLock()
    private var database: OpaquePointer?
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(path: String) throws {
        if path != ":memory:" {
            let directory = URL(fileURLWithPath: path).deletingLastPathComponent()
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        }

        var opened: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        let result = sqlite3_open_v2(path, &opened, flags, nil)
        guard result == SQLITE_OK, let opened else {
            let message = opened.map { String(cString: sqlite3_errmsg($0)) } ?? "Unable to open database"
            if let opened { sqlite3_close(opened) }
            throw SQLiteStoreError.database(code: result, message: message)
        }

        database = opened
        do {
            try execute("PRAGMA busy_timeout = 5000")
            try execute("PRAGMA foreign_keys = ON")
            if path != ":memory:" {
                try execute("PRAGMA journal_mode = WAL")
            }
            try execute("""
                CREATE TABLE IF NOT EXISTS tasks (
                    id TEXT PRIMARY KEY NOT NULL,
                    created_at REAL NOT NULL,
                    payload BLOB NOT NULL
                )
                """)
            try execute("""
                CREATE TABLE IF NOT EXISTS runs (
                    id TEXT PRIMARY KEY NOT NULL,
                    task_id TEXT NOT NULL REFERENCES tasks(id),
                    state TEXT NOT NULL,
                    created_at REAL NOT NULL,
                    payload BLOB NOT NULL
                )
                """)
            try execute("CREATE INDEX IF NOT EXISTS runs_by_task ON runs(task_id, created_at)")
            try execute("""
                CREATE TABLE IF NOT EXISTS scheduler_runtime (
                    singleton INTEGER PRIMARY KEY CHECK(singleton = 1),
                    payload BLOB NOT NULL
                )
                """)
            try execute("""
                CREATE TABLE IF NOT EXISTS activity (
                    sequence INTEGER PRIMARY KEY AUTOINCREMENT,
                    scheduler_session TEXT,
                    payload BLOB NOT NULL
                )
                """)
            try execute("""
                CREATE UNIQUE INDEX IF NOT EXISTS one_pending_run_per_task
                ON runs(task_id) WHERE state = 'pending'
                """)
            try execute("""
                CREATE UNIQUE INDEX IF NOT EXISTS one_unresolved_run_per_task
                ON runs(task_id) WHERE state IN ('starting', 'running', 'outcomeUnknown')
                """)
        } catch {
            sqlite3_close(opened)
            database = nil
            throw error
        }
    }

    deinit {
        if let database { sqlite3_close(database) }
    }

    public func insertTask(_ task: TaskDefinition) throws {
        try lock.withLock {
            try transaction {
                let statement = try prepare("INSERT INTO tasks(id, created_at, payload) VALUES (?, ?, ?)")
                defer { sqlite3_finalize(statement) }
                try bind(task.id.uuidString, to: statement, at: 1)
                try bind(task.createdAt.timeIntervalSince1970, to: statement, at: 2)
                try bind(encoder.encode(task), to: statement, at: 3)
                try stepDone(statement)
                try appendActivityUnlocked(ActivityEvent(
                    kind: .taskCreated, message: task.isPaused ? "Task created paused." : "Task created and enabled.",
                    taskID: task.id
                ))
            }
        }
    }

    public func updateTask(_ task: TaskDefinition) throws {
        try lock.withLock {
            try transaction {
                let previous = try loadTask(id: task.id)
                try saveTask(task)
                let message = previous?.isPaused != task.isPaused
                    ? (task.isPaused ? "Task paused. Running commands are unaffected." : "Task resumed.")
                    : (previous?.check != task.check ? "Readiness check updated." : "Task definition updated.")
                try appendActivityUnlocked(ActivityEvent(kind: .taskUpdated, message: message, taskID: task.id))
            }
        }
    }

    public func recordActivity(_ event: ActivityEvent) throws {
        try lock.withLock { try transaction { try appendActivityUnlocked(event) } }
    }

    public func schedulerRuntime() throws -> SchedulerRuntime? {
        try lock.withLock {
            try readOne("SELECT payload FROM scheduler_runtime WHERE singleton = 1", as: SchedulerRuntime.self)
        }
    }

    public func setSchedulerRuntime(_ runtime: SchedulerRuntime) throws {
        try lock.withLock {
            let statement = try prepare("INSERT OR REPLACE INTO scheduler_runtime(singleton, payload) VALUES (1, ?)")
            defer { sqlite3_finalize(statement) }
            try bind(encoder.encode(runtime), to: statement, at: 1)
            try stepDone(statement)
        }
    }

    public func clearSchedulerRuntime(sessionID: UUID) throws {
        try lock.withLock {
            try transaction {
                let runtime = try readOne("SELECT payload FROM scheduler_runtime WHERE singleton = 1", as: SchedulerRuntime.self)
                if runtime?.sessionID == sessionID { try execute("DELETE FROM scheduler_runtime") }
            }
        }
    }

    /// Newest first in insertion order, independent of wall-clock adjustments.
    public func listActivity(limit: Int = 500, schedulerOnly: Bool = false) throws -> [ActivityEvent] {
        try lock.withLock {
            let count = min(max(limit, 1), 5_000)
            let filter = schedulerOnly ? "WHERE scheduler_session IS NOT NULL" : ""
            return try readMany("SELECT payload FROM activity \(filter) ORDER BY sequence DESC LIMIT \(count)", as: ActivityEvent.self)
        }
    }

    private func appendActivityUnlocked(_ event: ActivityEvent) throws {
        let statement = try prepare("INSERT INTO activity(scheduler_session, payload) VALUES (?, ?)")
        defer { sqlite3_finalize(statement) }
        if let session = event.schedulerSessionID {
            try bind(session.uuidString, to: statement, at: 1)
        }
        try bind(encoder.encode(event), to: statement, at: 2)
        try stepDone(statement)
        // A bounded rolling history prevents minute polling from growing forever.
        try execute("DELETE FROM activity WHERE sequence <= (SELECT MAX(sequence) - 5000 FROM activity)")
    }

    public func task(id: UUID) throws -> TaskDefinition? {
        try lock.withLock { try loadTask(id: id) }
    }

    public func listTasks() throws -> [TaskDefinition] {
        try lock.withLock {
            try readMany("SELECT payload FROM tasks ORDER BY created_at, id", as: TaskDefinition.self)
        }
    }

    public func run(id: UUID) throws -> RunRecord? {
        try lock.withLock { try loadRun(id: id) }
    }

    public func listRuns(taskID: UUID? = nil) throws -> [RunRecord] {
        try lock.withLock {
            if let taskID {
                return try readMany(
                    "SELECT payload FROM runs WHERE task_id = ? ORDER BY created_at, id",
                    binding: { try self.bind(taskID.uuidString, to: $0, at: 1) },
                    as: RunRecord.self
                )
            }
            return try readMany("SELECT payload FROM runs ORDER BY created_at, id", as: RunRecord.self)
        }
    }

    public func upsertRun(_ run: RunRecord) throws {
        try lock.withLock { try saveRun(run) }
    }

    /// A check may finish after another client has coalesced more due work.
    /// Update its blocker without overwriting the latest occurrence data.
    public func recordCheckBlocker(runID: UUID, reason: String) throws {
        try lock.withLock {
            try transaction {
                guard var run = try loadRun(id: runID), run.state == .pending else { return }
                run.blockerReason = reason
                run.lastCheckedAt = Date()
                try saveRun(run)
            }
        }
    }

    /// Records every due occurrence and advances the cursor in one transaction.
    /// Any number of missed occurrences become one pending run, including when a
    /// previous run is still in progress or has an unknown outcome.
    public func materializeDue(taskID: UUID, through now: Date) throws -> RunRecord? {
        try lock.withLock {
            try transaction { try materializeDueUnlocked(taskID: taskID, through: now) }
        }
    }

    /// Queues work without launching a process. Concurrent requests share a run;
    /// overdue scheduled intent is materialized before creating manual work.
    public func requestRun(taskID: UUID, at now: Date = Date()) throws -> RunRecord {
        do {
            return try performRunRequest(taskID: taskID, at: now)
        } catch {
            // Record rejection after the failed transaction rolls back and releases
            // the connection lock, preserving the original error if logging fails.
            try? recordActivity(ActivityEvent(kind: .runRequestRejected,
                message: "Run now rejected: \(error.localizedDescription)", level: .warning, taskID: taskID))
            throw error
        }
    }

    private func performRunRequest(taskID: UUID, at now: Date) throws -> RunRecord {
        try lock.withLock {
            try transaction {
                guard let task = try loadTask(id: taskID) else {
                    throw SQLiteStoreError.missingTask(taskID)
                }
                guard !task.isPaused else { throw SQLiteStoreError.taskPaused }
                if let unresolved: RunRecord = try readOne(
                    "SELECT payload FROM runs WHERE task_id = ? AND state IN ('starting', 'running', 'outcomeUnknown')",
                    binding: { try self.bind(taskID.uuidString, to: $0, at: 1) },
                    as: RunRecord.self
                ) {
                    guard unresolved.state != .outcomeUnknown else {
                        throw SQLiteStoreError.outcomeNeedsReview
                    }
                    try appendActivityUnlocked(ActivityEvent(kind: .runRequested,
                        message: "Run now reused the active run.", taskID: taskID, runID: unresolved.id))
                    return unresolved
                }
                _ = try materializeDueUnlocked(taskID: taskID, through: now)
                if let pending = try loadPendingRun(taskID: taskID) {
                    try appendActivityUnlocked(ActivityEvent(kind: .runRequested,
                        message: "Run now reused pending work; readiness checks still apply.", taskID: taskID, runID: pending.id))
                    return pending
                }
                let manual = RunRecord(
                    taskID: taskID,
                    firstScheduledAt: now,
                    lastScheduledAt: now,
                    occurrenceCount: 0,
                    createdAt: now,
                    trigger: .manual
                )
                try saveRun(manual)
                try appendActivityUnlocked(ActivityEvent(kind: .runRequested,
                    message: "Run now queued; readiness checks still apply.", taskID: taskID, runID: manual.id))
                return manual
            }
        }
    }

    private func materializeDueUnlocked(taskID: UUID, through now: Date) throws -> RunRecord? {
        guard var task = try loadTask(id: taskID), !task.isPaused else { return nil }
        guard let due = try SchedulePlanner.dueWindow(
            for: task.schedule,
            after: task.scheduleCursor,
            through: now
        ) else { return nil }

        var pending = try loadPendingRun(taskID: taskID) ?? RunRecord(
            taskID: taskID,
            firstScheduledAt: due.first,
            lastScheduledAt: due.last,
            occurrenceCount: 0
        )
        if pending.trigger == .manual {
            pending.firstScheduledAt = due.first
            pending.lastScheduledAt = due.last
            pending.trigger = .scheduledAndManual
        } else {
            pending.firstScheduledAt = min(pending.firstScheduledAt, due.first)
        }
        pending.lastScheduledAt = max(pending.lastScheduledAt, due.last)
        pending.occurrenceCount += due.count
        try saveRun(pending)

        task.scheduleCursor = due.last
        try saveTask(task)
        try appendActivityUnlocked(ActivityEvent(kind: .workDue,
            message: "Scheduled work queued: \(pending.occurrenceCount) occurrence(s) in one pending run.",
            taskID: taskID, runID: pending.id))
        return pending
    }

    /// Only one attempt for a task may be in progress or awaiting an outcome.
    /// A claim never consumes a pending run while the task is paused.
    public func claimPendingRun(id: UUID, at: Date) throws -> RunRecord? {
        try lock.withLock {
            try transaction {
                guard var run = try loadRun(id: id), run.state == .pending,
                      let task = try loadTask(id: run.taskID), !task.isPaused,
                      try !hasUnresolvedRun(taskID: run.taskID)
                else { return nil }

                run.state = .starting
                run.startedAt = at
                run.blockerReason = nil
                try saveRun(run)
                return run
            }
        }
    }

    /// Call after the service obtains its exclusive process lock on startup.
    /// The command may have completed before the service stopped, so its outcome
    /// cannot safely be inferred or automatically retried.
    public func markInterruptedRunsUnknown() throws {
        try lock.withLock {
            try transaction {
                let interrupted = try readMany(
                    "SELECT payload FROM runs WHERE state IN ('starting', 'running')",
                    as: RunRecord.self
                )
                for var run in interrupted {
                    run.state = .outcomeUnknown
                    try saveRun(run)
                    try appendActivityUnlocked(ActivityEvent(kind: .runRecovered,
                        message: "Interrupted run has an unknown outcome. Review it before another execution.",
                        level: .warning, taskID: run.taskID, runID: run.id))
                }
            }
        }
    }

    private func saveTask(_ task: TaskDefinition) throws {
        let statement = try prepare("UPDATE tasks SET created_at = ?, payload = ? WHERE id = ?")
        defer { sqlite3_finalize(statement) }
        try bind(task.createdAt.timeIntervalSince1970, to: statement, at: 1)
        try bind(encoder.encode(task), to: statement, at: 2)
        try bind(task.id.uuidString, to: statement, at: 3)
        try stepDone(statement)
        guard sqlite3_changes(database) == 1 else { throw SQLiteStoreError.missingTask(task.id) }
    }

    private func saveRun(_ run: RunRecord) throws {
        let statement = try prepare("""
            INSERT INTO runs(id, task_id, state, created_at, payload) VALUES (?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                task_id = excluded.task_id,
                state = excluded.state,
                created_at = excluded.created_at,
                payload = excluded.payload
            """)
        defer { sqlite3_finalize(statement) }
        try bind(run.id.uuidString, to: statement, at: 1)
        try bind(run.taskID.uuidString, to: statement, at: 2)
        try bind(run.state.rawValue, to: statement, at: 3)
        try bind(run.createdAt.timeIntervalSince1970, to: statement, at: 4)
        try bind(encoder.encode(run), to: statement, at: 5)
        try stepDone(statement)
    }

    private func loadTask(id: UUID) throws -> TaskDefinition? {
        try readOne(
            "SELECT payload FROM tasks WHERE id = ?",
            binding: { try self.bind(id.uuidString, to: $0, at: 1) },
            as: TaskDefinition.self
        )
    }

    private func loadRun(id: UUID) throws -> RunRecord? {
        try readOne(
            "SELECT payload FROM runs WHERE id = ?",
            binding: { try self.bind(id.uuidString, to: $0, at: 1) },
            as: RunRecord.self
        )
    }

    private func loadPendingRun(taskID: UUID) throws -> RunRecord? {
        try readOne(
            "SELECT payload FROM runs WHERE task_id = ? AND state = 'pending'",
            binding: { try self.bind(taskID.uuidString, to: $0, at: 1) },
            as: RunRecord.self
        )
    }

    private func hasUnresolvedRun(taskID: UUID) throws -> Bool {
        let statement = try prepare("""
            SELECT 1 FROM runs WHERE task_id = ?
            AND state IN ('starting', 'running', 'outcomeUnknown') LIMIT 1
            """)
        defer { sqlite3_finalize(statement) }
        try bind(taskID.uuidString, to: statement, at: 1)
        let result = sqlite3_step(statement)
        if result == SQLITE_ROW { return true }
        if result == SQLITE_DONE { return false }
        throw databaseError(code: result)
    }

    private func readOne<T: Decodable>(
        _ sql: String,
        binding: (OpaquePointer) throws -> Void = { _ in },
        as type: T.Type
    ) throws -> T? {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        try binding(statement)
        let result = sqlite3_step(statement)
        if result == SQLITE_DONE { return nil }
        guard result == SQLITE_ROW else { throw databaseError(code: result) }
        return try decodeColumn(statement, as: type)
    }

    private func readMany<T: Decodable>(
        _ sql: String,
        binding: (OpaquePointer) throws -> Void = { _ in },
        as type: T.Type
    ) throws -> [T] {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        try binding(statement)
        var resultRows: [T] = []
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { return resultRows }
            guard result == SQLITE_ROW else { throw databaseError(code: result) }
            try resultRows.append(decodeColumn(statement, as: type))
        }
    }

    private func decodeColumn<T: Decodable>(_ statement: OpaquePointer, as type: T.Type) throws -> T {
        let length = Int(sqlite3_column_bytes(statement, 0))
        guard let pointer = sqlite3_column_blob(statement, 0) else {
            throw databaseError(code: SQLITE_CORRUPT)
        }
        return try decoder.decode(type, from: Data(bytes: pointer, count: length))
    }

    private func transaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do {
            let value = try body()
            try execute("COMMIT")
            return value
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    private func execute(_ sql: String) throws {
        let result = sqlite3_exec(database, sql, nil, nil, nil)
        guard result == SQLITE_OK else { throw databaseError(code: result) }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        let result = sqlite3_prepare_v2(database, sql, -1, &statement, nil)
        guard result == SQLITE_OK, let statement else { throw databaseError(code: result) }
        return statement
    }

    private func bind(_ value: String, to statement: OpaquePointer, at index: Int32) throws {
        let result = value.withCString {
            sqlite3_bind_text(statement, index, $0, -1, Self.transient)
        }
        guard result == SQLITE_OK else { throw databaseError(code: result) }
    }

    private func bind(_ value: Double, to statement: OpaquePointer, at index: Int32) throws {
        let result = sqlite3_bind_double(statement, index, value)
        guard result == SQLITE_OK else { throw databaseError(code: result) }
    }

    private func bind(_ value: Data, to statement: OpaquePointer, at index: Int32) throws {
        let result = value.withUnsafeBytes {
            sqlite3_bind_blob(statement, index, $0.baseAddress, Int32($0.count), Self.transient)
        }
        guard result == SQLITE_OK else { throw databaseError(code: result) }
    }

    private func stepDone(_ statement: OpaquePointer) throws {
        let result = sqlite3_step(statement)
        guard result == SQLITE_DONE else { throw databaseError(code: result) }
    }

    private func databaseError(code: Int32) -> SQLiteStoreError {
        SQLiteStoreError.database(
            code: code,
            message: database.map { String(cString: sqlite3_errmsg($0)) } ?? "Database unavailable"
        )
    }
}
