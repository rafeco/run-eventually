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
    var quietAfterWake = false

    var id: UUID { task.id }
    var pendingRuns: [RunRecord] { runs.filter { $0.state == .pending } }
    var pending: RunRecord? { pendingRuns.last }
    var pendingText: String {
        switch pendingRuns.count {
        case 0: "No pending run"
        case 1: "1 pending run"
        default: "\(pendingRuns.count) pending runs"
        }
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
        if let active { return active.state == .starting ? "Starting" : "Running" }
        if lastResult?.state == .outcomeUnknown { return "Needs review" }
        if let pending { return pending.blockerReason == nil ? "Pending" : "Waiting" }
        if isLaterToday { return "Later Today" }
        if scheduleIsDue { return "Due" }
        if let lastResult { return lastResult.state.displayName }
        return "Scheduled"
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
        if let active = summary.active, let wake = active.lastWakeAt, Date().timeIntervalSince(wake) > 120 {
            let latestOutput = [active.standardOutputPath, active.standardErrorPath].compactMap { path -> Date? in
                guard let path, let attributes = try? FileManager.default.attributesOfItem(atPath: path) else { return nil }
                return attributes[.modificationDate] as? Date
            }.max()
            summary.quietAfterWake = latestOutput.map { $0 <= wake } ?? true
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
                        pendingCount == 0 ? "No pending runs" : "\(pendingCount) pending \(pendingCount == 1 ? "run" : "runs")",
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
    static let failed = Color(red: 0.70, green: 0.15, blue: 0.12)
    static let active = Color(red: 0.09, green: 0.36, blue: 0.83)
    static let neutral = Color(red: 0.90, green: 0.91, blue: 0.93)
    static let neutralText = Color(red: 0.12, green: 0.16, blue: 0.22)
}

private struct JobStatusBadge: View {
    let summary: TaskSummary

    private var background: Color {
        if summary.statusColor == .red { return PillColors.failed }
        if summary.statusColor == .green { return PillColors.ready }
        if summary.active != nil && !summary.task.isPaused { return PillColors.active }
        return PillColors.neutral
    }
    private var foreground: Color {
        summary.statusColor == .red || summary.statusColor == .green
            || (summary.active != nil && !summary.task.isPaused) ? .white : PillColors.neutralText
    }
    var body: some View {
        Label(summary.status, systemImage: summary.statusIcon)
            .font(.caption)
            .foregroundStyle(foreground)
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(background, in: Capsule())
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
            .foregroundStyle(.white)
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

private struct CheckPills: View {
    let summary: TaskSummary
    var body: some View {
        if let pending = summary.pending, !(summary.task.readinessChecks?.isEmpty ?? true) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), alignment: .leading)], alignment: .leading, spacing: 4) {
                ForEach(summary.task.readinessChecks ?? []) { check in
                    CheckPill(check: check, run: pending)
                }
            }
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
            if summary.quietAfterWake {
                Text("No new output since waking · Check run progress")
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
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(summary.task.name)
                    .font(.largeTitle)
                JobStatusBadge(summary: summary)
                if let active = summary.active {
                    if let wake = active.lastWakeAt {
                        Text("Resumed after sleep at \(timestamp(wake, seconds: true))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if summary.quietAfterWake {
                        Text("No new output since waking. The command may still be working; check its logs before stopping.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
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
                if let requestMessage {
                    Text(requestMessage)
                        .font(.callout)
                        .foregroundStyle(requestFailed ? Color.red : Color.secondary)
                }
                Text(summary.scheduleText)
                    .foregroundStyle(.secondary)
                GroupBox("Execution") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Command").font(.caption).foregroundStyle(.secondary)
                        Text(summary.task.command.executable + " " + summary.task.command.arguments.joined(separator: " "))
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                        Text("Working directory").font(.caption).foregroundStyle(.secondary)
                        Text(summary.workingDirectoryText)
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                GroupBox("Readiness checks") {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(summary.task.readinessChecks ?? []) { check in
                            VStack(alignment: .leading, spacing: 4) {
                                CheckPill(check: check, run: summary.checkRun)
                                Text(check.provider.description)
                                    .font(.caption).foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                            }
                            .help("Timeout: \(Int(check.timeoutSeconds)) seconds")
                        }
                        if summary.task.check != nil { Text("Custom command check (also required)") }
                        if (summary.task.readinessChecks?.isEmpty ?? true) && summary.task.check == nil {
                            Text("No readiness checks configured").foregroundStyle(.secondary)
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
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                GroupBox("Pending work") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(summary.pendingText).fontWeight(.medium)
                        ForEach(summary.pendingRuns) { pending in
                            VStack(alignment: .leading, spacing: 5) {
                                Text("\(runTimeLabel(pending)) \(timestamp(pending.firstScheduledAt))")
                                if pending.occurrenceCount > 1 {
                                    Text("Combines \(pending.occurrenceCount) missed occurrences")
                                }
                                if let blocker = pending.blockerReason {
                                    Label("Waiting for checks", systemImage: "clock")
                                        .foregroundStyle(.secondary)
                                    Text("This run stays queued and starts automatically when ready.")
                                        .font(.caption).foregroundStyle(.secondary)
                                    WaitingDetails(message: blocker)
                                }
                                if let checkedAt = pending.lastCheckedAt {
                                    Text("Last checked \(timestamp(checkedAt, seconds: true))")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    if let next = pending.nextCheckAt {
                                        Text("Next check \(timestamp(next, seconds: true))")
                                            .font(.caption).foregroundStyle(.secondary)
                                    } else {
                                        Text("Rechecks on the next scheduler scan")
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                Divider()
                Text("Runs")
                    .font(.title2)
                if summary.runs.isEmpty {
                    Text("No runs recorded yet")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(summary.runs.reversed()) { run in
                        Button {
                            selectedRunID = run.id
                        } label: {
                            RunRow(run: run, isSelected: selectedRun?.id == run.id)
                        }
                        .buttonStyle(.plain)
                    }
                }

                if let selectedRun {
                    Divider()
                    Text("Selected run")
                        .font(.title2)
                    Text("\(selectedRun.state.displayName) · \(runTimeLabel(selectedRun)) \(timestamp(selectedRun.firstScheduledAt, seconds: true))")
                    if let blocker = selectedRun.blockerReason {
                        WaitingDetails(message: blocker)
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
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct RunRow: View {
    let run: RunRecord
    let isSelected: Bool

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(run.state.displayName)
                    .fontWeight(.medium)
                Text("\(runTimeLabel(run)) \(timestamp(run.firstScheduledAt))")
                    .foregroundStyle(.secondary)
                if let finishedAt = run.finishedAt {
                    Text("Finished \(timestamp(finishedAt))")
                        .foregroundStyle(.secondary)
                } else if let startedAt = run.startedAt {
                    Text("Started \(timestamp(startedAt))")
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if run.occurrenceCount > 1 {
                Text("×\(run.occurrenceCount)")
                    .foregroundStyle(.secondary)
            }
        }
        .padding(8)
        .background(isSelected ? Color.accentColor.opacity(0.16) : Color.clear)
        .cornerRadius(6)
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
