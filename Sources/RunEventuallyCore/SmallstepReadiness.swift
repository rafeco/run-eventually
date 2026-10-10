import Foundation

/// Only reads local public certificates. Never calls SSH, a CA, or a login helper.
enum SmallstepReadiness {
    private struct Certificate: Decodable {
        let type: String
        let principals: [String]
        let validAfter: String
        let validBefore: String
        enum CodingKeys: String, CodingKey {
            case type = "Type", principals = "Principals", validAfter = "ValidAfter", validBefore = "ValidBefore"
        }
    }

    static func run(_ check: ReadinessCheck, context: CommandSpec, now: Date = Date(),
        execute: (CommandSpec, TimeInterval) throws -> CommandOutcome
    ) throws -> ReadinessResult {
        guard case .smallstep(let subject, let principal) = check.provider else {
            return ReadinessResult(.checkError, "Invalid certificate provider.")
        }
        let deadline = ProcessInfo.processInfo.systemUptime + check.timeoutSeconds
        let action = ReadinessResult(.actionRequired,
            "No usable Smallstep certificate for \(subject) and principal \(principal). Renew SSH credentials using your normal interactive login, then recheck.")
        let error = ReadinessResult(.checkError, "Could not inspect local Smallstep certificates. Check step and the task's SSH agent environment.")
        var command = ReadinessRunner.command(for: check, context: context)
        let listing = try execute(command, check.timeoutSeconds)
        if listing.timedOut { return error }
        guard listing.exitCode == 0 else {
            let diagnostic = (listing.standardOutput + listing.standardError).lowercased()
            if diagnostic.contains("agent") || diagnostic.contains("no identities") { return action }
            return error
        }
        // Subject selection is performed by step against the agent's identity comment.
        // Recheck it here so a mismatched identity cannot make this check pass.
        let certificates = listing.standardOutput.split(whereSeparator: \.isNewline).filter {
            let fields = $0.split(maxSplits: 2, whereSeparator: \.isWhitespace)
            return fields.count == 3 && fields[0].contains("-cert-v01@openssh.com") && fields[2] == subject
        }
        guard !certificates.isEmpty else { return action }
        guard certificates.count <= 32 else { return error }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("run-eventually-cert-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("identity.pub")
        let formatter = ISO8601DateFormatter()
        var inconclusive = false
        for certificate in certificates {
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { return error }
            try Data((String(certificate) + "\n").utf8).write(to: path, options: .atomic)
            command.arguments = ["ssh", "inspect", "--format=json", path.path]
            let inspection = try execute(command, remaining)
            if inspection.timedOut { return error }
            guard inspection.exitCode == 0,
                let data = inspection.standardOutput.data(using: .utf8),
                let parsed = try? JSONDecoder().decode(Certificate.self, from: data),
                let after = formatter.date(from: parsed.validAfter),
                let before = formatter.date(from: parsed.validBefore) else {
                inconclusive = true
                continue
            }
            // A short margin avoids admitting a task with an almost expired certificate.
            if parsed.type == "user", parsed.principals.contains(principal), after <= now,
                before > now.addingTimeInterval(60) {
                return ReadinessResult(.ready, "Smallstep certificate for \(subject) and principal \(principal) is valid. Remote access is checked by the task.")
            }
        }
        return inconclusive ? error : action
    }
}
