import Combine
import AppKit
import Foundation
import RunEventuallyCore
import SwiftUI

@main
struct RunEventuallyDesktopApp: App {
    @NSApplicationDelegateAdaptor(DesktopLifecycle.self) private var lifecycle
    var body: some Scene {
        Window("Tasks — Run Eventually", id: "tasks") {
            WindowNavigation(lifecycle: lifecycle) {
                DashboardView()
            }
        }
        .defaultSize(width: 1_050, height: 680)
        .commands { NavigationCommands() }
        Window("Activity — Run Eventually", id: "activity") {
            WindowNavigation(lifecycle: lifecycle) {
                ActivityWindow()
            }
        }
        .defaultSize(width: 1_000, height: 700)
    }
}

@MainActor
private final class DesktopLifecycle: NSObject, NSApplicationDelegate {
    private var signals: TerminationSignals?
    private var openTasks: (() -> Void)?
    private var didOpenInitialTasks = false

    func registerWindowOpener(_ opener: @escaping () -> Void) {
        openTasks = opener
        guard !didOpenInitialTasks else { return }
        didOpenInitialTasks = true
        // Restore may initially create only Activity. Always show Tasks at launch.
        DispatchQueue.main.async { opener() }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openTasks?()
        return true
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Capture at launch: a later build can replace files under a still-open UI.
        _ = DesktopBuild.schedulerDigest
        signals = TerminationSignals(queue: .main) {
            Task { @MainActor in NSApplication.shared.terminate(nil) }
        }
    }
}

private struct WindowNavigation<Content: View>: View {
    @Environment(\.openWindow) private var openWindow
    let lifecycle: DesktopLifecycle
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
            .onAppear {
                lifecycle.registerWindowOpener { openWindow(id: "tasks") }
            }
    }
}

private struct NavigationCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandMenu("View") {
            Button("Task List") { openWindow(id: "tasks") }
                .keyboardShortcut("1", modifiers: .command)
            Button("Activity") { openWindow(id: "activity") }
                .keyboardShortcut("2", modifiers: .command)
        }
    }
}

enum DesktopBuild {
    static let schedulerDigest = try? SchedulerRuntime.executableDigest(
        at: Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/run-eventually")
    )
}

// Include the local zone so UTC input is not mistaken for a shifted schedule.
func timestamp(_ date: Date, seconds: Bool = false) -> String {
    let formatter = DateFormatter()
    formatter.timeZone = .autoupdatingCurrent
    formatter.setLocalizedDateFormatFromTemplate(seconds ? "yMMMdjmmssz" : "yMMMdjmmz")
    return formatter.string(from: date)
}

private func runTimeLabel(_ run: RunRecord) -> String {
    run.trigger == .manual ? "Requested" : "Due"
}

private struct TaskSummary: Identifiable, Sendable {
    let task: TaskDefinition
    let runs: [RunRecord]
    var progress: ExecutionProgress?
    var pendingExplanation: String?
    var waitingForWorker = false
    var nextScanAt: Date?
    var nextAttemptHold: String?

    var id: UUID { task.id }
    var pendingRuns: [RunRecord] { runs.filter { $0.state == .pending } }
    var pending: RunRecord? { pendingRuns.last }
    var pendingText: String {
        switch pendingRuns.count {
        case 0: "No queued runs"
        case 1: "1 queued run"
        default: "\(pendingRuns.count) queued runs"
        }
    }
    var commandText: String {
        let unquoted = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_./:@%+=,-")
        return ([task.command.executable] + task.command.arguments).map { argument in
            if !argument.isEmpty && argument.rangeOfCharacter(from: unquoted.inverted) == nil {
                return argument
            }
            return "'" + argument.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
        }.joined(separator: " ")
    }

    var workingDirectoryText: String {
        task.command.workingDirectory ?? "Not specified; inherits scheduler working directory"
    }
    var active: RunRecord? { runs.last { $0.state == .starting || $0.state == .running } }
    var lastResult: RunRecord? {
        runs.last {
            $0.state == .succeeded || $0.state == .failed || $0.state == .cancelled
                || $0.state == .outcomeUnknown
        }
    }

    var lastSuccessfulRun: RunRecord? { runs.last { $0.state == .succeeded } }
    var nextScheduledAt: Date? {
        try? SchedulePlanner.nextOccurrence(for: task.schedule, after: task.scheduleCursor)
    }
    var scheduleIsDue: Bool {
        guard let next = nextScheduledAt else { return false }
        return next <= Date()
    }
    var isLaterToday: Bool {
        guard let next = nextScheduledAt, next > Date() else { return false }
        var calendar = Calendar(identifier: .gregorian)
        if case .daily(_, _, let zone) = task.schedule, let timeZone = TimeZone(identifier: zone) {
            calendar.timeZone = timeZone
        }
        return calendar.isDate(next, inSameDayAs: Date())
    }
    var checkRun: RunRecord? { active ?? pending }

    var status: String {
        if task.isPaused { return "Paused" }
        if let active {
            switch progress?.phase {
            case .stopping: return "Stopping"
            case .possiblyStalled: return "Possibly stalled"
            case .quiet: return "Running · Quiet"
            default: return active.state == .starting ? "Starting" : "Running"
            }
        }
        if lastResult?.state == .outcomeUnknown { return "Needs review" }
        if pending != nil { return "Queued" }
        if isLaterToday { return "Later Today" }
        if scheduleIsDue { return "Due" }
        if let lastResult { return lastResult.state.displayName }
        return "Scheduled"
    }

    var nextAttemptDescription: String {
        if let hold = nextAttemptHold { return "Next readiness check: " + hold }
        guard let pending else { return "No run is queued." }
        let next = [pending.nextCheckAt, nextScanAt].compactMap { $0 }.max()
        guard let next else { return "Next readiness check: on the next scheduler scan." }
        let remaining = next.timeIntervalSinceNow
        guard remaining > 0 else { return "Readiness check is due now; waiting for the next scheduler scan." }
        let countdown = remaining < 60 ? "in \(max(1, Int(ceil(remaining))))s"
            : "in about \(Int(ceil(remaining / 60)))m"
        return "Next readiness check: at or after \(timestamp(next, seconds: true)) (\(countdown))."
    }

    var statusCountdown: String? {
        guard !task.isPaused, active == nil, lastResult?.state != .outcomeUnknown else { return nil }
        let target: Date?
        if let pending {
            guard nextAttemptHold == nil else { return nil }
            target = [pending.nextCheckAt, nextScanAt].compactMap { $0 }.max()
        } else if isLaterToday || status == "Scheduled" {
            target = nextScheduledAt
        } else { return nil }
        guard let target else { return nil }
        let seconds = target.timeIntervalSinceNow
        guard seconds > 0 else { return nil }
        if seconds < 60 { return "< 1m" }
        let minutes = Int(seconds / 60)
        if minutes < 60 { return "\(minutes)m" }
        let remainder = minutes % 60
        return "\(minutes / 60)h" + (remainder == 0 ? "" : " \(remainder)m")
    }

    var statusColor: Color {
        if task.isPaused { return .secondary }
        if active != nil { return .accentColor }
        if lastResult?.state == .outcomeUnknown { return .red }
        if pending != nil || isLaterToday || scheduleIsDue { return .secondary }
        switch lastResult?.state {
        case .failed, .cancelled: return .red
        case .succeeded: return .green
        default: return .secondary
        }
    }

    var statusIcon: String {
        if task.isPaused { return "pause.circle.fill" }
        if active != nil { return "play.circle.fill" }
        if lastResult?.state == .outcomeUnknown { return "exclamationmark.triangle.fill" }
        if pending != nil || isLaterToday || scheduleIsDue { return "clock" }
        switch lastResult?.state {
        case .failed, .cancelled: return "xmark.circle.fill"
        case .succeeded: return "checkmark.circle.fill"
        default: return "calendar"
        }
    }

    var scheduleText: String {
        switch task.schedule {
        case .once(let date):
            return "Once · \(timestamp(date))"
        case .daily(let hour, let minute, let timeZoneID):
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: timeZoneID) ?? .autoupdatingCurrent
            let date = calendar.nextDate(after: calendar.startOfDay(for: Date()).addingTimeInterval(-1),
                matching: DateComponents(hour: hour, minute: minute), matchingPolicy: .nextTime) ?? Date()
            let formatter = DateFormatter()
            formatter.timeZone = calendar.timeZone
            formatter.setLocalizedDateFormatFromTemplate("jmmz")
            return "Daily at " + formatter.string(from: date)
        }
    }
}

private enum DashboardError: LocalizedError {
    case databaseMissing(String)

    var errorDescription: String? {
        switch self {
        case .databaseMissing(let path):
            return "No scheduler database at \(path). Add a task with the command line tool to get started."
        }
    }
}

private struct SchedulerNotice: Sendable {
    let title: String
    let detail: String
}

private struct DashboardSnapshot: Sendable {
    let summaries: [TaskSummary]
    let schedulerNotice: SchedulerNotice?
    let schedulerPaused: Bool
    let canStopRun: Bool
}

private func readDashboard(at path: String, bundledDigest: String?) throws -> DashboardSnapshot {
    guard FileManager.default.fileExists(atPath: path) else {
        throw DashboardError.databaseMissing(path)
    }
    let store = try SQLiteStore(path: path)
    let tasks = try store.listTasks()
    let runsByTask = Dictionary(grouping: try store.listRuns(), by: \.taskID)
    let running = try Scheduler.isRunning(databasePath: path)
    let runtime = try store.schedulerRuntime()
    let latest = try store.listActivity(limit: 1, schedulerOnly: true).first
    let mismatch = runtime.flatMap { runtime in bundledDigest.map { runtime.executableDigest != $0 } } == true
    let paused = try store.schedulerPaused()
    let notice: SchedulerNotice?
    if paused {
        notice = SchedulerNotice(title: running && runtime?.supportsGlobalPause != true
            ? "Pause requested · Scheduler update pending" : "Paused · All scheduling",
            detail: running && runtime?.supportsGlobalPause != true
                ? "The pause is saved and will take effect when the updated scheduler starts. Running commands are unaffected."
                : "All queued and scheduled work waits until you resume scheduling. Running commands are unaffected.")
    } else if !running {
        notice = SchedulerNotice(title: "Paused · Scheduler stopped", detail: "Queued runs will wait until the scheduler starts.")
    } else if latest?.kind == .schedulerStopping {
        notice = SchedulerNotice(title: mismatch ? "Paused · Updating scheduler" : "Paused · Scheduler restarting",
            detail: mismatch ? "The app and scheduler builds differ. The current operation will finish before the updated scheduler takes over."
                : "The current operation will finish before the scheduler restarts. No new runs will start meanwhile.")
    } else if mismatch {
        notice = SchedulerNotice(title: "Scheduler update pending · Builds differ",
            detail: "The app and running scheduler are different builds. Restart both with the development script to complete the update.")
    } else {
        notice = nil
    }
    let summaries = tasks.map { task in
        var summary = TaskSummary(task: task, runs: runsByTask[task.id] ?? [])
        summary.nextScanAt = latest?.nextCheckAt
        if summary.pending != nil {
            if task.isPaused {
                summary.pendingExplanation = "Queued · Task paused"
                summary.nextAttemptHold = "after this task is resumed."
            } else if paused {
                summary.pendingExplanation = "Queued · All scheduling paused"
                summary.nextAttemptHold = "after scheduling is resumed."
            } else if !running {
                summary.pendingExplanation = "Queued · Scheduler stopped"
                summary.nextAttemptHold = "after the scheduler starts."
            } else if latest?.kind == .schedulerStopping {
                summary.pendingExplanation = "Queued · Scheduler restarting"
                summary.nextAttemptHold = "after the scheduler restarts."
            } else if summary.lastResult?.state == .outcomeUnknown {
                summary.pendingExplanation = "Queued · Previous outcome needs review"
                summary.nextAttemptHold = "after the previous run's unknown outcome is resolved."
            }
            else if runsByTask.values.joined().contains(where: { $0.state == .starting || $0.state == .running }) {
                summary.pendingExplanation = "Queued · Waiting for the running task to finish"
                summary.waitingForWorker = true
                summary.nextAttemptHold = "after the running task finishes (time not yet known)."
            } else {
                summary.pendingExplanation = summary.pending?.blockerReason == nil
                    ? "Queued for the next scan" : "Queued · Waiting for readiness"
            }
        }
        if let active = summary.active {
            let lastOutput = [active.standardOutputPath, active.standardErrorPath].compactMap { path -> Date? in
                guard let path, let attributes = try? FileManager.default.attributesOfItem(atPath: path),
                      let size = attributes[.size] as? NSNumber, size.intValue > 0 else { return nil }
                return attributes[.modificationDate] as? Date
            }.max()
            summary.progress = ExecutionProgress.assess(run: active, lastOutputAt: lastOutput, now: Date())
        }
        return summary
    }
    return DashboardSnapshot(summaries: summaries, schedulerNotice: notice, schedulerPaused: paused,
        canStopRun: running && runtime?.supportsRunCancellation == true)
}

@MainActor
private final class DashboardModel: ObservableObject {
    @Published private(set) var summaries: [TaskSummary] = []
    @Published private(set) var errorMessage: String?
    @Published private(set) var refreshedAt: Date?
    @Published private(set) var isRefreshing = false
    @Published private(set) var schedulerNotice: SchedulerNotice?
    @Published private(set) var schedulerPaused = false
    @Published private(set) var isChangingPause = false
    @Published private(set) var canStopRun = false
    private let bundledDigest = DesktopBuild.schedulerDigest

    let databasePath: String

    init() {
        let defaultPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/RunEventually/state.sqlite").path
        let configured = ProcessInfo.processInfo.environment["RUN_EVENTUALLY_DB"] ?? defaultPath
        databasePath = URL(fileURLWithPath: configured).standardizedFileURL.path
    }

    func refresh() {
        guard !isRefreshing else { return }
        isRefreshing = true
        let path = databasePath
        let digest = bundledDigest
        Task {
            do {
                let snapshot = try await Task.detached(priority: .utility) {
                    try readDashboard(at: path, bundledDigest: digest)
                }.value
                summaries = snapshot.summaries
                schedulerNotice = snapshot.schedulerNotice
                schedulerPaused = snapshot.schedulerPaused
                canStopRun = snapshot.canStopRun
                errorMessage = nil
                refreshedAt = Date()
            } catch {
                errorMessage = error.localizedDescription
            }
            isRefreshing = false
        }
    }

    func setGlobalPause(_ paused: Bool) async {
        guard !isChangingPause else { return }
        isChangingPause = true
        defer { isChangingPause = false }
        let path = databasePath
        do {
            try await Task.detached { try SQLiteStore(path: path).setSchedulerPaused(paused) }.value
            schedulerPaused = paused
            refresh()
        } catch { errorMessage = error.localizedDescription }
    }

    func setTaskPause(taskID: UUID, paused: Bool) async throws {
        let path = databasePath
        try await Task.detached { try SQLiteStore(path: path).setTaskPaused(taskID: taskID, paused: paused) }.value
        refresh()
    }

    func stopRun(runID: UUID) async throws {
        let path = databasePath
        try await Task.detached { try SQLiteStore(path: path).requestStop(runID: runID) }.value
        refresh()
    }

    func requestRun(taskID: UUID) async throws -> RunRecord {
        let path = databasePath
        let run = try await Task.detached(priority: .userInitiated) {
            try SQLiteStore(path: path).requestRun(taskID: taskID)
        }.value
        refresh()
        return run
    }

    func recheck(taskID: UUID) async throws {
        let path = databasePath
        try await Task.detached(priority: .userInitiated) {
            try SQLiteStore(path: path).requestRecheck(taskID: taskID)
        }.value
        refresh()
    }
}

private struct DashboardView: View {
    @Environment(\.openWindow) private var openWindow
    @StateObject private var model = DashboardModel()
    @State private var selectedTaskID: UUID?
    private let refreshTimer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private var selectedSummary: TaskSummary? {
        model.summaries.first { $0.id == selectedTaskID }
    }

    var body: some View {
        VStack(spacing: 0) {
            if let error = model.errorMessage {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle")
                    Text(error)
                        .textSelection(.enabled)
                    Spacer()
                }
                .foregroundStyle(.orange)
                .padding(12)
            }

            if model.errorMessage == nil {
                HStack(spacing: 16) {
                    let pendingCount = model.summaries.reduce(0) { $0 + $1.pendingRuns.count }
                    Label(
                        pendingCount == 0 ? "No queued runs" : "\(pendingCount) queued \(pendingCount == 1 ? "run" : "runs")",
                        systemImage: "clock"
                    )
                    let runningCount = model.summaries.filter { $0.active != nil }.count
                    if runningCount > 0 {
                        Label("\(runningCount) running", systemImage: "play.circle")
                    }
                    Spacer()
                    if let notice = model.schedulerNotice {
                        Label(notice.title, systemImage: "pause.circle")
                            .help(notice.detail)
                            .accessibilityLabel(notice.title + ". " + notice.detail)
                    }
                    Button {
                        Task { await model.setGlobalPause(!model.schedulerPaused) }
                    } label: {
                        Label(model.schedulerPaused ? "Resume all" : "Pause all",
                              systemImage: model.schedulerPaused ? "play" : "pause")
                    }
                    .disabled(model.isChangingPause)
                    .help("Pause all scheduling until resumed. Running commands finish normally.")
                }
                .font(.callout)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                Divider()
            }

            if model.summaries.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "clock.badge.questionmark")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                    Text(model.errorMessage == nil ? "No tasks yet" : "Tasks are unavailable")
                        .font(.title2)
                    Text("This preview shows tasks and runs from the local scheduler database.")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HStack(spacing: 0) {
                    List(selection: $selectedTaskID) {
                        ForEach(model.summaries) { summary in
                            TaskRow(summary: summary, model: model)
                                .tag(summary.id)
                        }
                    }
                    .listStyle(.sidebar)
                    .frame(minWidth: 320, idealWidth: 360, maxWidth: 420)

                    Divider()

                    if let selectedSummary {
                        TaskDetail(summary: selectedSummary, model: model)
                            .id(selectedSummary.id)
                    } else {
                        Text("Select a task to inspect its runs")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }
        }
        .frame(minWidth: 760, minHeight: 480)
        .toolbar {
            ToolbarItem {
                Button {
                    openWindow(id: "activity")
                } label: {
                    Label("Activity", systemImage: "list.bullet.rectangle")
                }
                .help("Watch scheduler scans, readiness checks, and task execution")
            }
            ToolbarItem {
                Button {
                    model.refresh()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(model.isRefreshing)
            }
        }
        .onAppear { model.refresh() }
        .onReceive(refreshTimer) { _ in model.refresh() }
        .onChange(of: model.summaries.map(\.id)) { ids in
            if !ids.contains(selectedTaskID ?? UUID()) {
                selectedTaskID = ids.first
            }
        }
    }
}

private enum PillColors {
    static let ready = Color(red: 0.08, green: 0.42, blue: 0.26)
    static let failed = Color(red: 0.96, green: 0.88, blue: 0.89)
    static let failedText = Color(red: 0.43, green: 0.18, blue: 0.23)
    static let active = Color(red: 0.09, green: 0.36, blue: 0.83)
    static let neutral = Color(red: 0.90, green: 0.91, blue: 0.93)
    static let neutralText = Color(red: 0.12, green: 0.16, blue: 0.22)
}

private struct JobStatusBadge: View {
    let summary: TaskSummary

    private var background: Color {
        if summary.statusColor == .red { return PillColors.failed }
        if summary.statusColor == .green { return PillColors.ready }
        if summary.active != nil && !summary.task.isPaused
            && summary.progress?.phase != .possiblyStalled && summary.progress?.phase != .quiet { return PillColors.active }
        return PillColors.neutral
    }
    private var foreground: Color {
        if summary.statusColor == .red { return PillColors.failedText }
        if summary.statusColor == .green { return .white }
        if summary.active != nil && !summary.task.isPaused
            && summary.progress?.phase != .possiblyStalled && summary.progress?.phase != .quiet { return .white }
        return PillColors.neutralText
    }
    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: summary.statusIcon)
                .accessibilityHidden(true)
            Text(summary.status)
            if let countdown = summary.statusCountdown {
                Text(countdown)
                    .monospacedDigit()
                    .fontWeight(.medium)
            }
        }
        .font(.caption)
        .foregroundStyle(foreground)
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(background, in: Capsule())
        .fixedSize()
        .accessibilityElement(children: .combine)
    }
}

private struct FailureReasonPill: View {
    let run: RunRecord

    private var reason: String {
        if let reason = run.blockerReason, !reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return reason
        }
        if let code = run.exitCode { return "Command exited with code \(code)." }
        return run.state == .cancelled ? "No cancellation reason was recorded." : "No failure reason was recorded. See run output."
    }
    var body: some View {
        Label("\(run.state.displayName) · \(reason)", systemImage: "xmark.circle.fill")
            .font(.caption)
            .foregroundStyle(PillColors.failedText)
            .lineLimit(2)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(PillColors.failed, in: RoundedRectangle(cornerRadius: 10))
            .help(reason)
            .accessibilityElement(children: .combine)
    }
}

private struct WaitingDetails: View {
    let message: String
    var body: some View {
        DisclosureGroup("Waiting details") {
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct CheckPill: View {
    let check: ReadinessCheck
    let run: RunRecord?

    private var observation: ReadinessObservation? {
        run?.readinessObservations?.first { $0.checkID == check.id }
    }
    private var name: String {
        switch check.provider {
        case .network: "Network"
        case .ssh, .smallstep: "SSH"
        case .bigQuery: "Google Cloud"
        }
    }
    private var passedAtLaunch: Bool { run?.state == .running && run?.readinessObservations == nil }
    private var passed: Bool { observation?.status == .ready || passedAtLaunch }
    private var state: String {
        guard let observation else {
            if passedAtLaunch { return "Passed" }
            return run == nil ? "Configured" : "Not checked"
        }
        switch observation.status {
        case .ready: return "Ready"
        case .waiting, .actionRequired: return "Waiting"
        case .checkError: return "Unknown"
        }
    }
    private var helpText: String {
        guard let observation else {
            if passedAtLaunch {
                return "Required checks passed before this run started. Individual results were not saved by the older scheduler; this is not a live recheck."
            }
            return check.provider.description + ": no result from the current run yet."
        }
        return observation.message + " Last checked " + timestamp(observation.checkedAt, seconds: true)
    }
    var body: some View {
        Label("\(name) · \(state)", systemImage: passed ? "checkmark" : "clock")
            .font(.caption)
            .foregroundStyle(passed ? Color.white : PillColors.neutralText)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(passed ? PillColors.ready : PillColors.neutral, in: Capsule())
            .help(helpText)
            .accessibilityElement(children: .combine)
    }
}

private struct ReadinessPillLayout: Layout {
    private let spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrangement(subviews, width: proposal.width ?? .infinity).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let layout = arrangement(subviews, width: bounds.width)
        for (subview, origin) in zip(subviews, layout.origins) {
            subview.place(
                at: CGPoint(x: bounds.minX + origin.x, y: bounds.minY + origin.y),
                anchor: .topLeading,
                proposal: ProposedViewSize(subview.sizeThatFits(.unspecified))
            )
        }
    }

    private func arrangement(_ subviews: Subviews, width: CGFloat) -> (size: CGSize, origins: [CGPoint]) {
        var origins: [CGPoint] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var usedWidth: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            origins.append(CGPoint(x: x, y: y))
            usedWidth = max(usedWidth, x + size.width)
            rowHeight = max(rowHeight, size.height)
            x += size.width + spacing
        }
        return (CGSize(width: usedWidth, height: y + rowHeight), origins)
    }
}

private struct CheckPills: View {
    let summary: TaskSummary
    var body: some View {
        if let pending = summary.pending, !(summary.task.readinessChecks?.isEmpty ?? true) {
            ReadinessPillLayout {
                ForEach(summary.task.readinessChecks ?? []) { check in
                    CheckPill(check: check, run: pending)
                }
            }
        }
    }
}

private func elapsedText(_ duration: TimeInterval) -> String {
    let seconds = max(0, Int(duration))
    if seconds < 60 { return "\(seconds)s" }
    if seconds < 3600 { return "\(seconds / 60)m" }
    return "\(seconds / 3600)h \(seconds % 3600 / 60)m"
}

private struct ExecutionProgressView: View {
    let progress: ExecutionProgress

    private var title: String {
        switch progress.phase {
        case .possiblyStalled: "Possibly stalled"
        case .quiet: "Running, but quiet"
        case .starting: "Starting the command"
        case .stopping: "Stopping the command"
        case .running: progress.lastOutputAt == nil ? "Running · Waiting for first output" : "Running · Recent output"
        }
    }
    var body: some View {
        GroupBox(title) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Elapsed: \(elapsedText(progress.elapsed))")
                if let output = progress.lastOutputAt {
                    Text("Last output: \(elapsedText(progress.quietFor)) ago · \(timestamp(output, seconds: true))")
                } else {
                    Text("No output yet · \(elapsedText(progress.quietFor)) since launch")
                }
                Text(progress.remaining > 0
                    ? "About \(elapsedText(progress.remaining)) until the one-hour run limit"
                    : "Run limit reached · Waiting for the scheduler to finish stopping the command")
                if progress.phase == .possiblyStalled {
                    Text("Output has stopped for a while. A long remote operation can be quiet; inspect its status, or stop this run and review it before retrying.")
                }
                if progress.phase == .quiet || progress.phase == .possiblyStalled {
                    Text("Wake notifications and a running scheduler do not count as task progress.")
                        .font(.caption)
                }
            }
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct TaskPauseButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        let highlighted = isEnabled && (isHovered || configuration.isPressed)
        return configuration.label
            .font(.caption)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .foregroundStyle(highlighted ? PillColors.neutralText : Color.primary)
            .background(highlighted ? PillColors.neutral : Color.clear, in: RoundedRectangle(cornerRadius: 6))
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Color.secondary.opacity(highlighted ? 0.5 : 0.25), lineWidth: 1)
            }
            .scaleEffect(configuration.isPressed && isEnabled ? 0.97 : 1)
            .opacity(isEnabled ? 1 : 0.5)
            .contentShape(RoundedRectangle(cornerRadius: 6))
            .onHover { isHovered = $0 }
            .animation(.easeOut(duration: 0.12), value: highlighted)
    }
}

private struct TaskRow: View {
    let summary: TaskSummary
    @ObservedObject var model: DashboardModel
    @State private var changingPause = false
    @State private var pauseError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(summary.task.name)
                    .font(.headline)
                    .lineLimit(1)
                Spacer(minLength: 8)
                JobStatusBadge(summary: summary)
            }
            Text(summary.scheduleText)
                .font(.subheadline.weight(.medium))
            if let pending = summary.pending {
                Text("\(runTimeLabel(pending)) \(timestamp(pending.firstScheduledAt))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let progress = summary.progress {
                Text("Elapsed \(elapsedText(progress.elapsed)) · \(progress.lastOutputAt == nil ? "No output yet" : "Last output " + elapsedText(progress.quietFor) + " ago")")
                    .font(.caption).foregroundStyle(.secondary)
            } else if summary.pending != nil {
                Text(summary.pendingExplanation ?? "Queued · Waiting to start")
                    .font(.caption).foregroundStyle(.secondary)
            }
            CheckPills(summary: summary)
            if let last = summary.lastSuccessfulRun, let finishedAt = last.finishedAt {
                Text("Last successful run: \(timestamp(finishedAt))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("No successful run yet")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let last = summary.lastResult, last.state != .succeeded {
                if summary.active == nil && summary.pending == nil && (last.state == .failed || last.state == .cancelled) {
                    FailureReasonPill(run: last)
                } else {
                    Text("Last attempt: \(last.state.displayName)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Button {
                changingPause = true
                Task {
                    defer { changingPause = false }
                    do {
                        try await model.setTaskPause(taskID: summary.id, paused: !summary.task.isPaused)
                    } catch { pauseError = error.localizedDescription }
                }
            } label: {
                Label(summary.task.isPaused ? "Resume task" : "Pause task",
                      systemImage: summary.task.isPaused ? "play" : "pause")
            }
            .buttonStyle(TaskPauseButtonStyle())
            .disabled(changingPause)
            .help("Pause this task until resumed. Running commands finish normally.")
        }
        .alert("Could not change task pause", isPresented: Binding(get: { pauseError != nil }, set: { if !$0 { pauseError = nil } })) {
            Button("OK") { pauseError = nil }
        } message: { Text(pauseError ?? "") }
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
        .background(summary.statusColor.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
    }
}

private struct TaskDetail: View {
    let summary: TaskSummary
    @ObservedObject var model: DashboardModel
    @State private var selectedRunID: UUID?
    @State private var isRequestingRun = false
    @State private var requestMessage: String?
    @State private var requestFailed = false
    @State private var isRechecking = false
    @State private var isStopping = false

    private var selectedRun: RunRecord? {
        summary.runs.first { $0.id == selectedRunID } ?? summary.runs.last
    }

    var body: some View {
        VStack(spacing: 0) {
            taskHeader
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Runs")
                        .font(.title2)
                    if summary.runs.isEmpty {
                        Text("No runs recorded yet")
                            .foregroundStyle(.secondary)
                    } else {
                        runsTable
                    }

                    if let selectedRun {
                        Divider()
                        Text("Selected run")
                            .font(.title2)
                        Text("\(selectedRun.state == .pending ? "Queued" : selectedRun.state.displayName) · \(runTimeLabel(selectedRun)) \(timestamp(selectedRun.firstScheduledAt, seconds: true))")
                        if selectedRun.id == summary.active?.id {
                            if let wake = selectedRun.lastWakeAt {
                                Text("Resumed after sleep at \(timestamp(wake, seconds: true))")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            if let progress = summary.progress {
                                ExecutionProgressView(progress: progress)
                            }
                        }
                        if let blocker = selectedRun.blockerReason {
                            WaitingDetails(message: blocker)
                        }
                        if selectedRun.state == .pending {
                            if selectedRun.occurrenceCount > 1 {
                                Text("Combines \(selectedRun.occurrenceCount) missed occurrences")
                            }
                            if let checkedAt = selectedRun.lastCheckedAt {
                                Text("Last checked \(timestamp(checkedAt, seconds: true))")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        if selectedRun.trigger == .manual {
                            Text("Requested with Run now")
                        } else if selectedRun.trigger == .scheduledAndManual {
                            Text("Combines a manual request with scheduled work")
                        }
                        if let startedAt = selectedRun.startedAt {
                            Text("Started \(timestamp(startedAt, seconds: true))")
                        }
                        if let finishedAt = selectedRun.finishedAt {
                            Text("Finished \(timestamp(finishedAt, seconds: true))")
                        }
                        if selectedRun.occurrenceCount > 1 {
                            Text("Last scheduled occurrence \(timestamp(selectedRun.lastScheduledAt, seconds: true))")
                        }
                        if let exitCode = selectedRun.exitCode {
                            Text("Exit code \(exitCode)")
                        }
                        LogView(title: "Standard output", content: selectedRun.standardOutput,
                            path: selectedRun.standardOutputPath, running: selectedRun.state == .running)
                        LogView(title: "Standard error", content: selectedRun.standardError,
                            path: selectedRun.standardErrorPath, running: selectedRun.state == .running)
                    }

                    Divider()
                    taskDetails
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var taskHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Button {
                    isRequestingRun = true
                    requestMessage = nil
                    Task {
                        defer { isRequestingRun = false }
                        do {
                            let run = try await model.requestRun(taskID: summary.id)
                            selectedRunID = run.id
                            requestFailed = false
                            requestMessage = run.state == .pending
                                ? "Run queued. Future scheduled runs are unchanged. The scheduler checks pending work about once a minute; prerequisites still apply."
                                : "This task already has a run in progress."
                        } catch {
                            requestFailed = true
                            requestMessage = error.localizedDescription
                        }
                    }
                } label: {
                    Label(isRequestingRun ? "Queuing…" : "Run now", systemImage: "play.fill")
                }
                .disabled(isRequestingRun || model.schedulerPaused || summary.task.isPaused || summary.active != nil || summary.lastResult?.state == .outcomeUnknown)
                .help("Queue a run using the existing prerequisites. Reuse pending work; resume paused tasks first.")
                if let active = summary.active {
                    Button {
                        isStopping = true
                        Task {
                            defer { isStopping = false }
                            do {
                                try await model.stopRun(runID: active.id)
                                requestFailed = false
                                requestMessage = "Stop requested. The command has a short cleanup period; retry with Run now after it stops."
                            } catch {
                                requestFailed = true
                                requestMessage = error.localizedDescription
                            }
                        }
                    } label: {
                        Label(active.stopRequestedAt == nil ? "Stop run" : "Stopping…", systemImage: "stop")
                    }
                    .disabled(isStopping || active.state != .running || active.stopRequestedAt != nil || !model.canStopRun)
                    .help(model.canStopRun ? "Stop this command and its local child processes. Remote work may continue; review logs before retrying."
                        : "Stop run requires the updated scheduler. The current operation is finishing before the update takes over.")
                }
                if summary.pending?.blockerReason != nil {
                    Button(isRechecking ? "Requesting…" : "Recheck") {
                        isRechecking = true
                        Task {
                            defer { isRechecking = false }
                            do {
                                try await model.recheck(taskID: summary.id)
                                requestFailed = false
                                requestMessage = "Readiness will be checked on the next scheduler scan."
                            } catch {
                                requestFailed = true
                                requestMessage = error.localizedDescription
                            }
                        }
                    }
                    .disabled(isRechecking || model.schedulerPaused || summary.task.isPaused)
                }
                Spacer(minLength: 0)
            }
            .controlSize(.small)

            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(summary.task.name)
                    .font(.title2.weight(.semibold))
                    .lineLimit(2)
                    .textSelection(.enabled)
                Spacer(minLength: 0)
                JobStatusBadge(summary: summary)
            }

            if !(summary.task.readinessChecks?.isEmpty ?? true) {
                ReadinessPillLayout {
                    ForEach(summary.task.readinessChecks ?? []) { check in
                        CheckPill(check: check, run: summary.checkRun)
                    }
                }
            }
            if let progress = summary.progress {
                Text("Elapsed \(elapsedText(progress.elapsed)) · \(progress.lastOutputAt == nil ? "No output yet" : "Last output " + elapsedText(progress.quietFor) + " ago") · \(progress.remaining > 0 ? elapsedText(progress.remaining) + " remaining" : "Run limit reached")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if summary.pending != nil {
                Text(summary.pendingText + " · " + (summary.pendingExplanation ?? "Waiting to start"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Text(summary.nextAttemptDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let requestMessage {
                Text(requestMessage)
                    .font(.caption)
                    .foregroundStyle(requestFailed ? Color.red : Color.secondary)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background)
    }

    private var runsTable: some View {
        GeometryReader { geometry in
            ScrollView(.horizontal) {
                VStack(spacing: 0) {
                    HStack(spacing: 12) {
                        Text("Status")
                            .frame(width: 110, alignment: .leading)
                        Text("Due / requested")
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text("Finished")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .fontWeight(.medium)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .frame(height: 28)
                    .background(.quaternary.opacity(0.5))
                    Divider()
                    ScrollView(.vertical) {
                        LazyVStack(spacing: 0) {
                            ForEach(summary.runs.reversed()) { run in
                                Button {
                                    selectedRunID = run.id
                                } label: {
                                    runTableRow(run)
                                }
                                .buttonStyle(.plain)
                                .accessibilityAddTraits(selectedRun?.id == run.id ? .isSelected : [])
                            }
                        }
                    }
                }
                .frame(width: max(geometry.size.width, 440))
            }
        }
        .font(.caption)
        .frame(height: min(240, 30 + CGFloat(summary.runs.count) * 28))
        .overlay(Rectangle().strokeBorder(.separator, lineWidth: 1))
    }

    private func runTableRow(_ run: RunRecord) -> some View {
        let isSelected = selectedRun?.id == run.id
        return HStack(spacing: 12) {
            HStack(spacing: 4) {
                Text(run.state == .pending ? "Queued" : run.state.displayName)
                if run.occurrenceCount > 1 {
                    Text("×\(run.occurrenceCount)")
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 110, alignment: .leading)
            .help(run.state == .pending ? "Queued" : run.state.displayName)
            Text(timestamp(run.firstScheduledAt))
                .frame(maxWidth: .infinity, alignment: .leading)
                .help("\(runTimeLabel(run)) \(timestamp(run.firstScheduledAt, seconds: true))")
            Text(run.finishedAt.map { timestamp($0) } ?? "—")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .lineLimit(1)
        .padding(.horizontal, 10)
        .frame(height: 28)
        .frame(maxWidth: .infinity)
        .background(runRowColor(run))
        .overlay(Rectangle().strokeBorder(isSelected ? Color.accentColor : .clear, lineWidth: 2))
        .contentShape(Rectangle())
    }

    private func runRowColor(_ run: RunRecord) -> Color {
        switch run.state {
        case .succeeded: .green.opacity(0.12)
        case .failed, .cancelled, .outcomeUnknown: .red.opacity(0.12)
        default: .clear
        }
    }

    private var taskDetails: some View {
        DisclosureGroup("Task details") {
            VStack(alignment: .leading, spacing: 12) {
                Text("Schedule").font(.caption).foregroundStyle(.secondary)
                Text(summary.scheduleText)
                Text("Command").font(.caption).foregroundStyle(.secondary)
                Text(verbatim: summary.commandText)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                Text("Working directory").font(.caption).foregroundStyle(.secondary)
                Text(summary.workingDirectoryText)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                Text("Readiness checks").font(.caption).foregroundStyle(.secondary)
                ForEach(summary.task.readinessChecks ?? []) { check in
                    Text(check.provider.description)
                        .textSelection(.enabled)
                    Text("Timeout: \(Int(check.timeoutSeconds)) seconds")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if summary.task.check != nil {
                    Text("Custom command check (also required)")
                }
                if (summary.task.readinessChecks?.isEmpty ?? true) && summary.task.check == nil {
                    Text("No readiness checks configured").foregroundStyle(.secondary)
                }
            }
            .padding(.top, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct LogView: View {
    let title: String
    let content: String?
    let path: String?
    let running: Bool

    private var displayText: String {
        guard let content, !content.isEmpty else { return "No output captured" }
        return content
    }

    var body: some View {
        GroupBox(title) {
            if let path {
                LiveLogView(path: path, finished: !running)
                    .id(path)
                    .frame(height: 220)
            } else {
            ScrollView([.horizontal, .vertical]) {
                Text(verbatim: displayText)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 140)
            }
        }
    }
}

private extension RunState {
    var displayName: String {
        switch self {
        case .pending: "Pending"
        case .starting: "Starting"
        case .running: "Running"
        case .succeeded: "Succeeded"
        case .failed: "Failed"
        case .cancelled: "Cancelled"
        case .outcomeUnknown: "Outcome unknown"
        }
    }
}
