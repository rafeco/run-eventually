import Foundation

public enum SchedulePlannerError: Error, Equatable {
    case invalidHour(Int)
    case invalidMinute(Int)
    case invalidTimeZone(String)
    case invalidDate
    case evaluationRangeTooLarge
}

/// Finds the scheduled occurrences in `(cursor, now]` and combines them into
/// one pending run. The caller persists the new cursor with that run.
public enum SchedulePlanner {
    // This is far beyond a useful catch-up period, but bounds work if a corrupt
    // or ancient cursor is presented to the scheduler.
    private static let maximumEvaluationDays = 100_000

    public static func dueWindow(
        for schedule: TaskSchedule,
        after cursor: Date,
        through now: Date
    ) throws -> DueWindow? {
        guard cursor.timeIntervalSinceReferenceDate.isFinite,
              now.timeIntervalSinceReferenceDate.isFinite else {
            throw SchedulePlannerError.invalidDate
        }

        switch schedule {
        case let .once(scheduledAt):
            guard scheduledAt.timeIntervalSinceReferenceDate.isFinite else {
                throw SchedulePlannerError.invalidDate
            }
            guard scheduledAt > cursor, scheduledAt <= now else { return nil }
            return DueWindow(first: scheduledAt, last: scheduledAt, count: 1)

        case let .daily(hour, minute, timeZoneID):
            guard (0...23).contains(hour) else {
                throw SchedulePlannerError.invalidHour(hour)
            }
            guard (0...59).contains(minute) else {
                throw SchedulePlannerError.invalidMinute(minute)
            }
            guard let timeZone = TimeZone(identifier: timeZoneID) else {
                throw SchedulePlannerError.invalidTimeZone(timeZoneID)
            }
            guard cursor < now else { return nil }

            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = timeZone
            let firstDay = calendar.startOfDay(for: cursor)
            let lastDay = calendar.startOfDay(for: now)
            guard let daysApart = calendar.dateComponents(
                [.day], from: firstDay, to: lastDay
            ).day, daysApart >= 0, daysApart < maximumEvaluationDays else {
                throw SchedulePlannerError.evaluationRangeTooLarge
            }

            let matching = DateComponents(hour: hour, minute: minute, second: 0)
            var day = firstDay
            var first: Date?
            var last: Date?
            var count = 0

            while day <= lastDay {
                // Starting just before the day handles schedules at midnight.
                // `.nextTime` maps a missing wall time to the first valid time
                // after a DST gap; `.first` prevents a duplicate in a fall fold.
                if let occurrence = calendar.nextDate(
                    after: day.addingTimeInterval(-1),
                    matching: matching,
                    matchingPolicy: .nextTime,
                    repeatedTimePolicy: .first,
                    direction: .forward
                ), calendar.isDate(occurrence, inSameDayAs: day),
                   occurrence > cursor, occurrence <= now {
                    first = first ?? occurrence
                    last = occurrence
                    count += 1
                }

                // A midnight clock change can make a day's start 01:00. Adding
                // one calendar day to that instant would start the following
                // day at 01:00 too, skipping an early scheduled time there.
                guard let nextDay = calendar.dateInterval(of: .day, for: day)?.end,
                      nextDay > day else {
                    throw SchedulePlannerError.evaluationRangeTooLarge
                }
                day = nextDay
            }

            guard let first, let last else { return nil }
            return DueWindow(first: first, last: last, count: count)
        }
    }
}
