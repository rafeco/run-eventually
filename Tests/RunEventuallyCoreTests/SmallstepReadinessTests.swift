import Foundation
import Testing
@testable import RunEventuallyCore

@Suite struct SmallstepReadinessTests {
    let check = ReadinessCheck(provider: .smallstep(subject: "person@example.com", principal: "person"))
    let context = CommandSpec(executable: "/usr/bin/true", environment: ["SSH_AUTH_SOCK": "/agent"])
    let now = Date(timeIntervalSince1970: 1_700_000_000)

    func output(_ text: String, code: Int32 = 0, timedOut: Bool = false) -> CommandOutcome {
        CommandOutcome(exitCode: code, standardOutput: text, standardError: "", timedOut: timedOut)
    }
    func certificate(type: String = "user", principal: String = "person", after: Double = -60, before: Double = 300) -> String {
        let formatter = ISO8601DateFormatter()
        return """
        {"Type":"\(type)","Principals":["\(principal)"],"ValidAfter":"\(formatter.string(from: now.addingTimeInterval(after)))","ValidBefore":"\(formatter.string(from: now.addingTimeInterval(before)))"}
        """
    }

    @Test func onlyLocalReadsAndOneTotalTimeout() throws {
        var calls = 0
        var file: String?
        let result = try SmallstepReadiness.run(check, context: context, now: now) { command, timeout in
            calls += 1
            #expect(command.executable == "step")
            #expect(command.environment["SSH_AUTH_SOCK"] == "/agent")
            #expect(timeout > 0 && timeout <= check.timeoutSeconds)
            if calls == 1 {
                #expect(command.arguments == ["ssh", "list", "--raw", "person@example.com"])
                return output("ssh-ed25519-cert-v01@openssh.com AAAA person@example.com\n")
            }
            #expect(Array(command.arguments.prefix(3)) == ["ssh", "inspect", "--format=json"])
            file = command.arguments.last
            let contents = try String(contentsOfFile: file!, encoding: .utf8)
            #expect(contents.contains("AAAA"))
            return output(certificate())
        }
        #expect(result.status == .ready)
        #expect(calls == 2)
        #expect(!FileManager.default.fileExists(atPath: file!))
        #expect(!result.message.contains("AAAA"))
        let encoded = try JSONEncoder().encode(check)
        #expect(try JSONDecoder().decode(ReadinessCheck.self, from: encoded) == check)
    }

    @Test func missingExpiredWrongPrincipalAndHostCertificatesRequireAction() throws {
        for listing in ["", "ssh-ed25519 AAAA person@example.com", "ssh-ed25519-cert-v01@openssh.com AAAA other@example.com"] {
            var calls = 0
            let result = try SmallstepReadiness.run(check, context: context, now: now) { _, _ in
                calls += 1
                return output(listing)
            }
            #expect(result.status == .actionRequired)
            #expect(calls == 1)
        }
        for cert in [certificate(before: -1), certificate(before: 59), certificate(after: 20),
                     certificate(principal: "other"), certificate(type: "host")] {
            let result = try SmallstepReadiness.run(check, context: context, now: now) { command, _ in
                output(command.arguments[1] == "list" ? "ssh-ed25519-cert-v01@openssh.com AAAA person@example.com" : cert)
            }
            #expect(result.status == .actionRequired)
        }
        let absent = try SmallstepReadiness.run(check, context: context, now: now) { _, _ in
            output("Could not connect to SSH agent", code: 1)
        }
        #expect(absent.status == .actionRequired)
    }

    @Test func inconclusiveReadsFailClosedAndMultipleCertificatesCanSucceed() throws {
        for response in [output("malformed secret"), output("", code: 1), output("", timedOut: true)] {
            let result = try SmallstepReadiness.run(check, context: context, now: now) { command, _ in
                command.arguments[1] == "list" ? output("ssh-ed25519-cert-v01@openssh.com AAAA person@example.com") : response
            }
            #expect(result.status == .checkError)
            #expect(!result.message.contains("secret"))
        }
        var calls = 0
        let result = try SmallstepReadiness.run(check, context: context, now: now) { _, _ in
            calls += 1
            if calls == 1 { return output(String(repeating: "ssh-ed25519-cert-v01@openssh.com AAAA person@example.com\n", count: 2)) }
            return output(calls == 2 ? certificate(before: -1) : certificate())
        }
        #expect(result.status == .ready)
        #expect(calls == 3)
        #expect(throws: ReadinessConfigurationError.self) {
            try ReadinessCheck(provider: .smallstep(subject: "-bad", principal: "person")).validate()
        }
    }
}
