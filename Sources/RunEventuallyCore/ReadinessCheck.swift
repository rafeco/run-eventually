import Foundation

public enum ReadinessStatus: String, Codable, Sendable {
    case ready, waiting, actionRequired, checkError

    public var displayName: String {
        switch self {
        case .ready: "Ready"
        case .waiting: "Waiting"
        case .actionRequired: "Action required"
        case .checkError: "Check error"
        }
    }
}

public enum ReadinessProvider: Codable, Sendable, Equatable {
    case network(host: String, port: UInt16)
    case ssh(host: String)
    case bigQuery(project: String, dataset: String?)

    public var description: String {
        switch self {
        case .network(let host, let port): "Network / VPN: \(host):\(port)"
        case .ssh(let host): "SSH: \(host)"
        case .bigQuery(let project, let dataset): "BigQuery: \(project)\(dataset.map { ":" + $0 } ?? "")"
        }
    }
}

public struct ReadinessCheck: Codable, Identifiable, Sendable, Equatable {
    public var id: UUID
    public var provider: ReadinessProvider
    public var timeoutSeconds: TimeInterval

    public init(id: UUID = UUID(), provider: ReadinessProvider, timeoutSeconds: TimeInterval = 10) {
        self.id = id
        self.provider = provider
        self.timeoutSeconds = timeoutSeconds
    }

    public func validate() throws {
        guard timeoutSeconds.isFinite, timeoutSeconds > 0, timeoutSeconds <= 120 else {
            throw ReadinessConfigurationError.invalid("Check timeout must be between 0 and 120 seconds.")
        }
        func valid(_ value: String, allowed: CharacterSet) -> Bool {
            !value.isEmpty && !value.hasPrefix("-") && value.unicodeScalars.allSatisfy { allowed.contains($0) }
        }
        let hostCharacters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-_:@%"))
        switch provider {
        case .network(let host, let port):
            guard port > 0, valid(host, allowed: hostCharacters), !host.contains("@") else {
                throw ReadinessConfigurationError.invalid("Network check needs a host and a port from 1 to 65535.")
            }
        case .ssh(let host):
            guard valid(host, allowed: hostCharacters) else {
                throw ReadinessConfigurationError.invalid("SSH check needs a host alias or user@host.")
            }
        case .bigQuery(let project, let dataset):
            let identifiers = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
            guard valid(project, allowed: identifiers), dataset.map({ valid($0, allowed: identifiers) }) ?? true else {
                throw ReadinessConfigurationError.invalid("BigQuery check needs a project ID and optional dataset ID.")
            }
        }
    }
}

public enum ReadinessConfigurationError: Error, LocalizedError {
    case invalid(String)
    public var errorDescription: String? { if case .invalid(let message) = self { return message }; return nil }
}

public struct ReadinessResult: Sendable, Equatable {
    public var status: ReadinessStatus
    public var message: String
    public init(_ status: ReadinessStatus, _ message: String) { self.status = status; self.message = message }
}

public enum ReadinessRunner {
    /// Context inherits the task's directory, PATH and credential configuration.
    /// Raw provider output is used only for classification and never persisted.
    public static func run(_ check: ReadinessCheck, context: CommandSpec,
        execute: (CommandSpec, TimeInterval) throws -> CommandOutcome = {
            try CommandRunner.run($0, timeoutSeconds: $1, outputLimitBytes: 8_192)
        }
    ) -> ReadinessResult {
        do {
            try check.validate()
            let command = command(for: check, context: context)
            return classify(try execute(command, check.timeoutSeconds), provider: check.provider)
        } catch is ReadinessConfigurationError {
            return ReadinessResult(.actionRequired, "Invalid readiness configuration. Edit this check.")
        } catch CommandRunnerError.executableNotFound {
            return ReadinessResult(.actionRequired, "Required check tool is missing. Install it or correct the task's PATH.")
        } catch {
            return ReadinessResult(.checkError, "The readiness probe could not start. Check its execution environment.")
        }
    }

    public static func command(for check: ReadinessCheck, context: CommandSpec) -> CommandSpec {
        var command = context
        command.environment["LC_ALL"] = "C"
        switch check.provider {
        case .network(let host, let port):
            command.executable = "/usr/bin/nc"
            let timeout = String(max(1, Int(ceil(check.timeoutSeconds))))
            command.arguments = ["-z", "-G", timeout, "-w", timeout, host, String(port)]
        case .ssh(let host):
            command.executable = "/usr/bin/ssh"
            command.arguments = ["-T", "-a", "-x", "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=yes",
                "-o", "UpdateHostKeys=no", "-o", "ClearAllForwardings=yes", "-o", "PermitLocalCommand=no",
                "-o", "RemoteCommand=none", "-o", "ConnectTimeout=\(max(1, Int(ceil(check.timeoutSeconds))))", host, "true"]
        case .bigQuery(let project, let dataset):
            command.executable = "bq"
            command.environment["CLOUDSDK_CORE_DISABLE_PROMPTS"] = "1"
            command.arguments = ["--headless=true", "--quiet", "--format=json", "--httplib2_debuglevel=0", "--apilog=/dev/null",
                "--project_id=\(project)"]
            command.arguments += dataset.map { ["show", "\(project):\($0)"] } ?? ["ls", "--max_results=1"]
        }
        return command
    }

    static func classify(_ outcome: CommandOutcome, provider: ReadinessProvider) -> ReadinessResult {
        if outcome.timedOut { return ReadinessResult(.waiting, "Waiting for \(provider.description); the connection check timed out.") }
        if outcome.exitCode == 0 { return ReadinessResult(.ready, "\(provider.description) is ready.") }
        let diagnostic = (outcome.standardOutput + "\n" + outcome.standardError).lowercased()
        func contains(_ phrases: [String]) -> Bool { phrases.contains { diagnostic.contains($0) } }
        switch provider {
        case .network:
            return ReadinessResult(.waiting, "Waiting for \(provider.description). Connect the required network or VPN, or wait for the endpoint.")
        case .ssh:
            if contains(["permission denied", "authentication failed", "no supported authentication methods"]) {
                return ReadinessResult(.actionRequired, "SSH authentication was rejected. Renew credentials and verify access in Terminal.")
            }
            if contains(["host key verification failed", "remote host identification has changed"]) {
                return ReadinessResult(.actionRequired, "SSH host verification needs attention. Verify the host using your normal SSH process.")
            }
            if contains(["bad configuration option", "bad owner or permissions"]) {
                return ReadinessResult(.actionRequired, "SSH configuration needs attention. Correct the reported configuration or file permissions using your normal SSH process.")
            }
            if contains(["connection refused", "connection timed out", "no route to host", "network is unreachable", "could not resolve hostname", "connection reset"]) {
                return ReadinessResult(.waiting, "Waiting for the SSH endpoint. Check the network or VPN and remote service.")
            }
        case .bigQuery:
            if contains(["invalid_grant", "invalid_rapt", "reauthentication is needed", "invalid authentication credentials", "invalid credentials", "gcloud auth login", "not have any active accounts", "do not currently have an active account", "login required", "access token has expired", "token has been expired or revoked"]) {
                return ReadinessResult(.actionRequired, "BigQuery sign-in needs attention. Renew the credentials used by this task; for a user CLI login, run gcloud auth login.")
            }
            if contains(["access denied", "permission denied", "forbidden"]) {
                return ReadinessResult(.actionRequired, "BigQuery access was denied. Verify the task's account and project or dataset permissions.")
            }
            if contains(["not found: dataset", "not found: project", "project was not found"]) {
                return ReadinessResult(.actionRequired, "The BigQuery target was not found. Correct the project or dataset, or verify access.")
            }
            if contains(["temporarily unavailable", "service unavailable", "backenderror", "connection refused", "connection reset", "timed out", "network is unreachable", "name resolution", "too many requests", "ratelimitexceeded"]) {
                return ReadinessResult(.waiting, "Waiting for BigQuery connectivity or service availability.")
            }
        }
        return ReadinessResult(.checkError, "\(provider.description) returned an unrecognized failure. Readiness could not be established.")
    }
}
