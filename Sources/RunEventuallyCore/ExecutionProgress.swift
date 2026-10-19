import Foundation

/// A UI assessment of output freshness, not proof that a command is hung.
public struct ExecutionProgress: Sendable, Equatable {
    public enum Phase: Sendable { case starting, running, quiet, possiblyStalled, stopping }
    public let phase: Phase
    public let elapsed: TimeInterval
    public let quietFor: TimeInterval
    public let remaining: TimeInterval
    public let lastOutputAt: Date?

    public static func assess(run: RunRecord, lastOutputAt: Date?, now: Date,
        timeLimit: TimeInterval = 3600) -> ExecutionProgress? {
        guard run.state == .starting || run.state == .running else { return nil }
        let start = run.startedAt ?? run.createdAt
        let elapsed = max(0, now.timeIntervalSince(start))
        let output = lastOutputAt.flatMap { $0 >= start ? $0 : nil }
        let quiet = max(0, now.timeIntervalSince(output ?? start))
        let phase: Phase
        if run.stopRequestedAt != nil { phase = .stopping }
        else if (run.state == .starting && elapsed >= 60) || quiet >= 600 { phase = .possiblyStalled }
        else if run.state == .starting { phase = .starting }
        else if quiet >= 120 { phase = .quiet }
        else { phase = .running }
        return ExecutionProgress(phase: phase, elapsed: elapsed, quietFor: quiet,
            remaining: max(0, timeLimit - elapsed), lastOutputAt: output)
    }
}
