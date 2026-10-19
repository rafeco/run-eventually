import Foundation
import Testing
@testable import RunEventuallyCore

@Suite struct ExecutionProgressTests {
    let start = Date(timeIntervalSince1970: 10000)
    func run(_ state: RunState = .running) -> RunRecord {
        RunRecord(taskID: UUID(), firstScheduledAt: start, lastScheduledAt: start,
            occurrenceCount: 1, state: state, createdAt: start, startedAt: start)
    }
    @Test func recentOutputQuietAndStalledAreDistinct() throws {
        let now = start.addingTimeInterval(2400)
        let recent = try #require(ExecutionProgress.assess(run: run(), lastOutputAt: now.addingTimeInterval(-10), now: now))
        #expect(recent.phase == .running)
        #expect(recent.elapsed == 2400)
        #expect(recent.remaining == 1200)
        #expect(ExecutionProgress.assess(run: run(), lastOutputAt: now.addingTimeInterval(-120), now: now)?.phase == .quiet)
        #expect(ExecutionProgress.assess(run: run(), lastOutputAt: now.addingTimeInterval(-600), now: now)?.phase == .possiblyStalled)
    }
    @Test func wakesDoNotResetOutputFreshnessAndStoppingTakesPrecedence() throws {
        var active = run()
        let now = start.addingTimeInterval(2400)
        active.lastWakeAt = now
        let stalled = try #require(ExecutionProgress.assess(run: active, lastOutputAt: start.addingTimeInterval(60), now: now))
        #expect(stalled.phase == .possiblyStalled)
        #expect(stalled.quietFor == 2340)
        active.stopRequestedAt = now
        #expect(ExecutionProgress.assess(run: active, lastOutputAt: nil, now: now)?.phase == .stopping)
    }
    @Test func absentStaleAndFutureOutputDoNotInventProgress() {
        #expect(ExecutionProgress.assess(run: run(), lastOutputAt: nil, now: start.addingTimeInterval(600))?.phase == .possiblyStalled)
        #expect(ExecutionProgress.assess(run: run(), lastOutputAt: start.addingTimeInterval(-1), now: start.addingTimeInterval(600))?.lastOutputAt == nil)
        let backwards = ExecutionProgress.assess(run: run(), lastOutputAt: nil, now: start.addingTimeInterval(-5))
        #expect(backwards?.elapsed == 0)
        #expect(backwards?.quietFor == 0)
        #expect(ExecutionProgress.assess(run: run(.succeeded), lastOutputAt: start, now: start) == nil)
        #expect(ExecutionProgress.assess(run: run(.pending), lastOutputAt: nil, now: start) == nil)
        #expect(ExecutionProgress.assess(run: run(.starting), lastOutputAt: nil, now: start.addingTimeInterval(60))?.phase == .possiblyStalled)
    }
}
