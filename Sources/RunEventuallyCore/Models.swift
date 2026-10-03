import Foundation

public enum TaskSchedule: Codable, Sendable, Equatable {
    case once(Date)
    case daily(hour: Int, minute: Int, timeZoneID: String)
}

public struct CommandSpec: Codable, Sendable, Equatable {
    public var executable: String
    public var arguments: [String]
    public var workingDirectory: String?
    public var environment: [String: String]

    public init(
        executable: String,
        arguments: [String] = [],
        workingDirectory: String? = nil,
        environment: [String: String] = [:]
    ) {
        self.executable = executable
        self.arguments = arguments
        self.workingDirectory = workingDirectory
        self.environment = environment
    }
}

public struct CheckSpec: Codable, Sendable, Equatable {
    public var command: CommandSpec
    public var timeoutSeconds: TimeInterval

    public init(command: CommandSpec, timeoutSeconds: TimeInterval = 10) {
        self.command = command
        self.timeoutSeconds = timeoutSeconds
    }
}

public struct TaskDefinition: Codable, Sendable, Identifiable, Equatable {
    public var id: UUID
    public var name: String
    public var command: CommandSpec
    public var schedule: TaskSchedule
    public var check: CheckSpec?
    public var isPaused: Bool
    public var scheduleCursor: Date
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        name: String,
        command: CommandSpec,
        schedule: TaskSchedule,
        check: CheckSpec? = nil,
        isPaused: Bool = false,
        scheduleCursor: Date,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.command = command
        self.schedule = schedule
        self.check = check
        self.isPaused = isPaused
        self.scheduleCursor = scheduleCursor
        self.createdAt = createdAt
    }
}

public enum RunState: String, Codable, Sendable {
    case pending
    case starting
    case running
    case succeeded
    case failed
    case cancelled
    case outcomeUnknown
}

public struct RunRecord: Codable, Sendable, Identifiable, Equatable {
    public var id: UUID
    public var taskID: UUID
    public var firstScheduledAt: Date
    public var lastScheduledAt: Date
    public var occurrenceCount: Int
    public var state: RunState
    public var createdAt: Date
    public var startedAt: Date?
    public var finishedAt: Date?
    public var exitCode: Int32?
    public var blockerReason: String?
    public var standardOutput: String?
    public var standardError: String?

    public init(
        id: UUID = UUID(),
        taskID: UUID,
        firstScheduledAt: Date,
        lastScheduledAt: Date,
        occurrenceCount: Int,
        state: RunState = .pending,
        createdAt: Date = Date(),
        startedAt: Date? = nil,
        finishedAt: Date? = nil,
        exitCode: Int32? = nil,
        blockerReason: String? = nil,
        standardOutput: String? = nil,
        standardError: String? = nil
    ) {
        self.id = id
        self.taskID = taskID
        self.firstScheduledAt = firstScheduledAt
        self.lastScheduledAt = lastScheduledAt
        self.occurrenceCount = occurrenceCount
        self.state = state
        self.createdAt = createdAt
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.exitCode = exitCode
        self.blockerReason = blockerReason
        self.standardOutput = standardOutput
        self.standardError = standardError
    }
}

public struct DueWindow: Sendable, Equatable {
    public var first: Date
    public var last: Date
    public var count: Int

    public init(first: Date, last: Date, count: Int) {
        self.first = first
        self.last = last
        self.count = count
    }
}
