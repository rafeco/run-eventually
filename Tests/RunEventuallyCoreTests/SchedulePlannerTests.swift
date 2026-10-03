import Foundation
import Testing
@testable import RunEventuallyCore

private func instant(_ iso8601: String) -> Date {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.date(from: iso8601)!
}

@Test func oneTimeScheduleHasExclusiveCursorAndInclusiveNow() throws {
    let due = instant("2025-01-01T12:00:00Z")
    let schedule = TaskSchedule.once(due)

    #expect(try SchedulePlanner.dueWindow(
        for: schedule, after: instant("2025-01-01T11:59:59Z"), through: due
    ) == DueWindow(first: due, last: due, count: 1))
    #expect(try SchedulePlanner.dueWindow(
        for: schedule, after: due, through: instant("2025-01-02T00:00:00Z")
    ) == nil)
    #expect(try SchedulePlanner.dueWindow(
        for: schedule, after: instant("2025-01-01T00:00:00Z"),
        through: instant("2025-01-01T11:59:59Z")
    ) == nil)
}

@Test func dailyScheduleCoalescesMissedOccurrences() throws {
    let schedule = TaskSchedule.daily(hour: 6, minute: 30, timeZoneID: "UTC")
    let window = try SchedulePlanner.dueWindow(
        for: schedule,
        after: instant("2025-01-01T06:30:00Z"),
        through: instant("2025-01-04T08:00:00Z")
    )

    #expect(window == DueWindow(
        first: instant("2025-01-02T06:30:00Z"),
        last: instant("2025-01-04T06:30:00Z"),
        count: 3
    ))
    #expect(try SchedulePlanner.dueWindow(
        for: schedule,
        after: instant("2025-01-04T06:30:00Z"),
        through: instant("2025-01-04T08:00:00Z")
    ) == nil)
    let exact = instant("2025-01-05T06:30:00Z")
    #expect(try SchedulePlanner.dueWindow(
        for: schedule,
        after: instant("2025-01-05T06:29:59Z"), through: exact
    ) == DueWindow(first: exact, last: exact, count: 1))
}

@Test func dailyScheduleUsesNamedTimeZone() throws {
    let schedule = TaskSchedule.daily(hour: 6, minute: 30, timeZoneID: "Asia/Tokyo")
    let window = try SchedulePlanner.dueWindow(
        for: schedule,
        after: instant("2025-01-01T20:00:00Z"),
        through: instant("2025-01-02T22:00:00Z")
    )

    #expect(window == DueWindow(
        first: instant("2025-01-01T21:30:00Z"),
        last: instant("2025-01-02T21:30:00Z"),
        count: 2
    ))
}

@Test func springGapRunsAtFirstValidTime() throws {
    let schedule = TaskSchedule.daily(hour: 2, minute: 30, timeZoneID: "America/New_York")
    let window = try SchedulePlanner.dueWindow(
        for: schedule,
        after: instant("2025-03-08T08:00:00Z"),
        through: instant("2025-03-10T07:00:00Z")
    )

    #expect(window == DueWindow(
        first: instant("2025-03-09T07:00:00Z"), // 03:00 local, after the gap
        last: instant("2025-03-10T06:30:00Z"),
        count: 2
    ))
}

@Test func fallFoldRunsOnlyAtFirstOccurrence() throws {
    let schedule = TaskSchedule.daily(hour: 1, minute: 30, timeZoneID: "America/New_York")
    let first = instant("2025-11-02T05:30:00Z")

    #expect(try SchedulePlanner.dueWindow(
        for: schedule,
        after: instant("2025-11-02T04:00:00Z"),
        through: instant("2025-11-02T07:00:00Z")
    ) == DueWindow(first: first, last: first, count: 1))
    #expect(try SchedulePlanner.dueWindow(
        for: schedule,
        after: first,
        through: instant("2025-11-02T07:00:00Z")
    ) == nil)
}

@Test func midnightClockChangeKeepsNextDaysEarlyOccurrence() throws {
    let schedule = TaskSchedule.daily(hour: 0, minute: 30, timeZoneID: "America/Santiago")
    let window = try SchedulePlanner.dueWindow(
        for: schedule,
        after: instant("2025-09-06T05:00:00Z"),
        through: instant("2025-09-08T04:00:00Z")
    )

    #expect(window == DueWindow(
        first: instant("2025-09-07T04:00:00Z"), // 01:00 local after the gap
        last: instant("2025-09-08T03:30:00Z"),
        count: 2
    ))
}

@Test func invalidDailyConfigurationIsRejected() {
    let cursor = instant("2025-01-01T00:00:00Z")
    let now = instant("2025-01-02T00:00:00Z")

    #expect(throws: SchedulePlannerError.invalidHour(24)) {
        try SchedulePlanner.dueWindow(
            for: .daily(hour: 24, minute: 0, timeZoneID: "UTC"),
            after: cursor, through: now
        )
    }
    #expect(throws: SchedulePlannerError.invalidMinute(-1)) {
        try SchedulePlanner.dueWindow(
            for: .daily(hour: 6, minute: -1, timeZoneID: "UTC"),
            after: cursor, through: now
        )
    }
    #expect(throws: SchedulePlannerError.invalidTimeZone("Not/A_Zone")) {
        try SchedulePlanner.dueWindow(
            for: .daily(hour: 6, minute: 30, timeZoneID: "Not/A_Zone"),
            after: cursor, through: now
        )
    }
}

@Test func excessivelyOldCursorFailsInBoundedTime() {
    #expect(throws: SchedulePlannerError.evaluationRangeTooLarge) {
        try SchedulePlanner.dueWindow(
            for: .daily(hour: 6, minute: 30, timeZoneID: "UTC"),
            after: instant("1700-01-01T00:00:00Z"),
            through: instant("2025-01-01T00:00:00Z")
        )
    }
}
