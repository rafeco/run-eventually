import Foundation

public enum ActivityKind: String, Codable, Sendable {
    case schedulerStarted, schedulerStopping, schedulerStopped, schedulerError
    case cycleStarted, cycleFinished, waiting, scheduleChecked
    case taskCreated, taskUpdated, runRequested, runRequestRejected, workDue, runHeld, runRecovered, eligibilityChecked
    case checkStarted, checkPassed, checkBlocked, checkFailed
    case runStarted, runSucceeded, runFailed

    public var isCheck: Bool {
        switch self {
        case .checkStarted, .checkPassed, .checkBlocked, .checkFailed: true
        default: false
        }
    }
}

public enum ActivityLevel: String, Codable, Sendable {
    case info, warning, error
}

/// Operational summaries, separate from potentially sensitive command output.
/// A scheduler session distinguishes scheduler activity from client mutations.
public struct ActivityEvent: Codable, Identifiable, Sendable, Equatable {
    public let id: UUID
    public let timestamp: Date
    public let kind: ActivityKind
    public let level: ActivityLevel
    public let message: String
    public let taskID: UUID?
    public let runID: UUID?
    public let schedulerSessionID: UUID?
    public let nextCheckAt: Date?

    public init(
        kind: ActivityKind, message: String, level: ActivityLevel = .info,
        taskID: UUID? = nil, runID: UUID? = nil, schedulerSessionID: UUID? = nil,
        nextCheckAt: Date? = nil, timestamp: Date = Date()
    ) {
        id = UUID()
        self.timestamp = timestamp
        self.kind = kind
        self.level = level
        // Keep diagnostics bounded even when a custom blocker explanation is long.
        self.message = String(message.prefix(2_000))
        self.taskID = taskID
        self.runID = runID
        self.schedulerSessionID = schedulerSessionID
        self.nextCheckAt = nextCheckAt
    }
}
