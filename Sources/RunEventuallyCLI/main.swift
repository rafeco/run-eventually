import Foundation
import RunEventuallyCore

private enum CLIError: Error, LocalizedError {
    case usage(String)

    var errorDescription: String? {
        switch self {
        case .usage(let detail): detail
        }
    }
}

private let help = """
Run Eventually — local scheduler prototype

Usage:
  run-eventually [--database PATH] add-once ISO8601 NAME [--cwd PATH] [--env KEY=VALUE] -- EXECUTABLE [ARG ...]
  run-eventually [--database PATH] add-daily HH:MM TIME_ZONE NAME [--paused] [--cwd PATH] [--env KEY=VALUE] -- EXECUTABLE [ARG ...]
  run-eventually [--database PATH] set-check TASK_ID [--timeout-seconds N] [--failure-message CODE=MESSAGE] [--cwd PATH] [--env KEY=VALUE] -- EXECUTABLE [ARG ...]
  run-eventually [--database PATH] pause TASK_ID
  run-eventually [--database PATH] resume TASK_ID
  run-eventually [--database PATH] run-now TASK_ID
  run-eventually [--database PATH] list
  run-eventually [--database PATH] runs
  run-eventually [--database PATH] activity
  run-eventually version
  run-eventually [--database PATH] tick
  run-eventually [--database PATH] serve

Commands and checks keep arguments separate from the executable. Time zones use IANA names,
for example America/New_York. This prototype checks due work every minute while
serve is running and catches up on the next start after sleep or shutdown.
"""

private func executable(from parts: [String]) throws -> CommandSpec {
    guard let separator = parts.firstIndex(of: "--"), separator + 1 < parts.count else {
        throw CLIError.usage("Expected -- EXECUTABLE [ARG ...].\n\n\(help)")
    }
    let options = Array(parts[..<separator])
    var workingDirectory: String?
    var environment: [String: String] = [:]
    var index = 0
    while index < options.count {
        let option = options[index]
        guard index + 1 < options.count else {
            throw CLIError.usage("Missing value after \(option).")
        }
        let value = options[index + 1]
        switch option {
        case "--cwd":
            workingDirectory = URL(fileURLWithPath: value).standardizedFileURL.path
        case "--env":
            guard let equals = value.firstIndex(of: "="), equals != value.startIndex else {
                throw CLIError.usage("Environment overrides must use KEY=VALUE.")
            }
            environment[String(value[..<equals])] = String(value[value.index(after: equals)...])
        default:
            throw CLIError.usage("Unknown command option: \(option)")
        }
        index += 2
    }
    return CommandSpec(
        executable: parts[separator + 1],
        arguments: Array(parts.dropFirst(separator + 2)),
        workingDirectory: workingDirectory,
        environment: environment
    )
}

private func parseDate(_ value: String) throws -> Date {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = formatter.date(from: value) { return date }
    formatter.formatOptions = [.withInternetDateTime]
    if let date = formatter.date(from: value) { return date }
    throw CLIError.usage("Invalid ISO8601 timestamp: \(value)")
}

private func taskID(_ value: String) throws -> UUID {
    guard let id = UUID(uuidString: value) else {
        throw CLIError.usage("Invalid task ID: \(value)")
    }
    return id
}

private func main() throws {
    var arguments = Array(CommandLine.arguments.dropFirst())
    let defaultPath = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/RunEventually/state.sqlite").path
    var databasePath = ProcessInfo.processInfo.environment["RUN_EVENTUALLY_DB"] ?? defaultPath
    if arguments.first == "--database" {
        guard arguments.count >= 3 else { throw CLIError.usage(help) }
        databasePath = arguments[1]
        arguments.removeFirst(2)
    }
    databasePath = URL(fileURLWithPath: databasePath).standardizedFileURL.path
    guard let command = arguments.first else { throw CLIError.usage(help) }
    arguments.removeFirst()

    switch command {
    case "add-once":
        guard arguments.count >= 4 else { throw CLIError.usage(help) }
        let scheduled = try parseDate(arguments[0])
        let definition = TaskDefinition(
            name: arguments[1],
            command: try executable(from: Array(arguments.dropFirst(2))),
            schedule: .once(scheduled),
            scheduleCursor: .distantPast
        )
        try SQLiteStore(path: databasePath).insertTask(definition)
        print("Created \(definition.name) (\(definition.id.uuidString))")

    case "add-daily":
        guard arguments.count >= 5 else { throw CLIError.usage(help) }
        let time = arguments[0].split(separator: ":")
        guard time.count == 2,
              let hour = Int(time[0]), let minute = Int(time[1]),
              (0...23).contains(hour), (0...59).contains(minute) else {
            throw CLIError.usage("Invalid daily time; use HH:MM in 24-hour form.")
        }
        let zone = arguments[1]
        guard TimeZone(identifier: zone) != nil else {
            throw CLIError.usage("Unknown time zone: \(zone)")
        }
        let now = Date()
        var commandArguments = Array(arguments.dropFirst(3))
        var isPaused = false
        if let separator = commandArguments.firstIndex(of: "--"),
           let option = commandArguments[..<separator].firstIndex(of: "--paused") {
            isPaused = true
            commandArguments.remove(at: option)
        }
        let definition = TaskDefinition(
            name: arguments[2],
            command: try executable(from: commandArguments),
            schedule: .daily(hour: hour, minute: minute, timeZoneID: zone),
            isPaused: isPaused,
            scheduleCursor: now,
            createdAt: now
        )
        try SQLiteStore(path: databasePath).insertTask(definition)
        print("Created \(definition.name) (\(definition.id.uuidString))")

    case "set-check":
        guard arguments.count >= 3 else { throw CLIError.usage(help) }
        let store = try SQLiteStore(path: databasePath)
        let id = try taskID(arguments[0])
        guard var task = try store.task(id: id) else {
            throw CLIError.usage("Task not found: \(id.uuidString)")
        }
        var checkArguments = Array(arguments.dropFirst())
        var timeout: TimeInterval = 10
        var failureMessages: [String: String] = [:]
        while let separator = checkArguments.firstIndex(of: "--"),
              let option = checkArguments[..<separator].firstIndex(of: "--failure-message") {
            guard option + 1 < separator else { throw CLIError.usage("Expected CODE=MESSAGE after --failure-message.") }
            let pair = checkArguments[option + 1].split(separator: "=", maxSplits: 1)
            guard pair.count == 2, let code = Int32(pair[0]), code != 0, !pair[1].isEmpty else {
                throw CLIError.usage("Failure message must use a nonzero exit code and CODE=MESSAGE.")
            }
            failureMessages[String(code)] = String(pair[1])
            checkArguments.removeSubrange(option...option + 1)
        }
        // Parse only options before the executable separator, leaving command arguments literal.
        if let separator = checkArguments.firstIndex(of: "--"),
           let option = checkArguments[..<separator].firstIndex(of: "--timeout-seconds") {
            guard option + 1 < separator,
                  let value = Double(checkArguments[option + 1]), value.isFinite, value > 0 else {
                throw CLIError.usage("Check timeout must be a positive number of seconds.")
            }
            timeout = value
            checkArguments.removeSubrange(option...option + 1)
        }
        task.check = CheckSpec(command: try executable(from: checkArguments), timeoutSeconds: timeout, failureMessages: failureMessages)
        try store.updateTask(task)
        print("Updated check for \(task.name)")

    case "pause", "resume":
        guard arguments.count == 1 else { throw CLIError.usage(help) }
        let store = try SQLiteStore(path: databasePath)
        let id = try taskID(arguments[0])
        guard var task = try store.task(id: id) else {
            throw CLIError.usage("Task not found: \(id.uuidString)")
        }
        task.isPaused = command == "pause"
        try store.updateTask(task)
        print("\(task.isPaused ? "Paused" : "Resumed") \(task.name)")

    case "run-now":
        guard arguments.count == 1 else { throw CLIError.usage(help) }
        let run = try SQLiteStore(path: databasePath).requestRun(taskID: taskID(arguments[0]))
        print("\(run.state.rawValue): \(run.id.uuidString). The scheduler checks pending work about once a minute.")

    case "list":
        guard arguments.isEmpty else { throw CLIError.usage(help) }
        let store = try SQLiteStore(path: databasePath)
        for task in try store.listTasks() {
            let pending = try store.listRuns(taskID: task.id).filter { $0.state == .pending }
            let status = task.isPaused ? "paused" : "enabled"
            print("\(task.id.uuidString)  \(task.name)  \(status)  \(pending.count) pending")
        }

    case "runs":
        guard arguments.isEmpty else { throw CLIError.usage(help) }
        let store = try SQLiteStore(path: databasePath)
        for run in try store.listRuns(taskID: nil) {
            let due = ISO8601DateFormatter().string(from: run.firstScheduledAt)
            let reason = run.blockerReason.map { "  \($0)" } ?? ""
            print("\(run.id.uuidString)  \(run.state.rawValue)  due \(due)  count \(run.occurrenceCount)\(reason)")
        }

    case "activity":
        guard arguments.isEmpty else { throw CLIError.usage(help) }
        let events = try SQLiteStore(path: databasePath).listActivity(limit: 200)
        for event in events.reversed() {
            let time = ISO8601DateFormatter().string(from: event.timestamp)
            let task = event.taskID.map { " task=\($0.uuidString)" } ?? ""
            print("\(time) [\(event.level.rawValue)] \(event.kind.rawValue)\(task): \(event.message)")
        }

    case "tick", "serve":
        guard arguments.isEmpty else { throw CLIError.usage(help) }
        let scheduler = try Scheduler(databasePath: databasePath)
        let signals = TerminationSignals(handler: scheduler.shutdownHandler())
        defer { withExtendedLifetime(signals) {} }
        try scheduler.announceGracefulShutdownSupport()
        repeat {
            if scheduler.shutdown.isRequested { break }
            if let run = try scheduler.tick() {
                print("\(run.state.rawValue): \(run.id.uuidString) (\(run.taskID.uuidString))")
                if command == "serve" { continue }
            } else if command == "tick" {
                print("No eligible run.")
            }
            if command == "serve" {
                if scheduler.shutdown.isRequested { break }
                try scheduler.recordWaiting(until: Date().addingTimeInterval(60))
                scheduler.shutdown.wait(until: Date().addingTimeInterval(60))
            }
        } while command == "serve"

    case "version":
        guard arguments.isEmpty, let executable = Bundle.main.executableURL else { throw CLIError.usage(help) }
        print(try SchedulerRuntime.executableDigest(at: executable))

    case "help", "--help", "-h":
        print(help)

    default:
        throw CLIError.usage("Unknown command: \(command)\n\n\(help)")
    }
}

do {
    try main()
} catch {
    fputs("Error: \(error.localizedDescription)\n", stderr)
    exit(EXIT_FAILURE)
}
