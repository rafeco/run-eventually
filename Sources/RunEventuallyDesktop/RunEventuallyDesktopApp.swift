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

    var status: String {
        if task.isPaused { return "Paused" }
        if let active { return active.state == .starting ? "Starting" : "Running" }
        if lastResult?.state == .outcomeUnknown { return "Needs review" }
        if let pending { return pending.blockerReason == nil ? "Pending" : "Waiting" }
        if let lastResult { return lastResult.state.displayName }
        return "Scheduled"
    }

    var statusColor: Color {
        if task.isPaused { return .secondary }
        if active != nil { return .accentColor }
        if lastResult?.state == .outcomeUnknown { return .red }
        if pending != nil { return .yellow }
        switch lastResult?.state {
        case .failed: return .red
        case .succeeded: return .green
        default: return .secondary
        }
    }

    var statusIcon: String {
        if task.isPaused { return "pause.circle.fill" }
        if active != nil { return "play.circle.fill" }
        if lastResult?.state == .outcomeUnknown { return "exclamationmark.triangle.fill" }
        if pending != nil { return "clock.fill" }
        switch lastResult?.state {
        case .failed: return "xmark.circle.fill"
        case .succeeded: return "checkmark.circle.fill"
        default: return "calendar"
        }
    }

    var scheduleText: String {
        switch task.schedule {
        case .once(let date):
            return "Once · \(timestamp(date))"
        case .daily(let hour, let minute, let timeZoneID):
            return "Daily · \(String(format: "%02d:%02d", hour, minute)) · \(timeZoneID)"
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

private func readSummaries(at path: String) throws -> [TaskSummary] {
    guard FileManager.default.fileExists(atPath: path) else {
        throw DashboardError.databaseMissing(path)
    }
    let store = try SQLiteStore(path: path)
    let tasks = try store.listTasks()
    let runsByTask = Dictionary(grouping: try store.listRuns(), by: \.taskID)
    return tasks.map { TaskSummary(task: $0, runs: runsByTask[$0.id] ?? []) }
}

@MainActor
private final class DashboardModel: ObservableObject {
    @Published private(set) var summaries: [TaskSummary] = []
    @Published private(set) var errorMessage: String?
    @Published private(set) var refreshedAt: Date?
    @Published private(set) var isRefreshing = false

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
        Task {
            do {
                summaries = try await Task.detached(priority: .utility) {
                    try readSummaries(at: path)
                }.value
                errorMessage = nil
                refreshedAt = Date()
            } catch {
                errorMessage = error.localizedDescription
            }
            isRefreshing = false
        }
    }

    func requestRun(taskID: UUID) async throws -> RunRecord {
        let path = databasePath
        let run = try await Task.detached(priority: .userInitiated) {
            try SQLiteStore(path: path).requestRun(taskID: taskID)
        }.value
        refresh()
        return run
    }
}

private struct DashboardView: View {
    @Environment(\.openWindow) private var openWindow
    @StateObject private var model = DashboardModel()
    @State private var selectedTaskID: UUID?
    private let refreshTimer = Timer.publish(every: 5, on: .main, in: .common).autoconnect()

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
                    }
                    .font(.callout)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    Divider()
                }
                HStack(spacing: 0) {
                    List(selection: $selectedTaskID) {
                        ForEach(model.summaries) { summary in
                            TaskRow(summary: summary)
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

private struct JobStatusBadge: View {
    let summary: TaskSummary

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: summary.statusIcon)
                .foregroundStyle(summary.statusColor)
                .accessibilityHidden(true)
            Text(summary.status)
        }
        .font(.caption)
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(summary.statusColor.opacity(0.12), in: Capsule())
        .accessibilityElement(children: .combine)
    }
}

private struct TaskRow: View {
    let summary: TaskSummary

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
                .font(.caption)
                .foregroundStyle(.secondary)
            Label(summary.workingDirectoryText, systemImage: "folder")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(summary.workingDirectoryText)
            Text(summary.pendingText)
                .font(.caption)
            if let pending = summary.pending {
                Text("\(runTimeLabel(pending)) \(timestamp(pending.firstScheduledAt))")
                    .font(.caption)
                if let blocker = pending.blockerReason {
                    Text(blocker)
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .lineLimit(2)
                }
            }
            if let last = summary.lastResult {
                Text("Last: \(last.state.displayName)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let finishedAt = last.finishedAt {
                    Text("Finished \(timestamp(finishedAt))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
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

    private var selectedRun: RunRecord? {
        summary.runs.first { $0.id == selectedRunID } ?? summary.runs.last
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(summary.task.name)
                    .font(.largeTitle)
                JobStatusBadge(summary: summary)
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
                .disabled(isRequestingRun || summary.task.isPaused || summary.active != nil || summary.lastResult?.state == .outcomeUnknown)
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
                                    Label(blocker, systemImage: "exclamationmark.triangle")
                                        .foregroundStyle(.orange)
                                        .textSelection(.enabled)
                                }
                                if let checkedAt = pending.lastCheckedAt {
                                    Text("Last checked \(timestamp(checkedAt, seconds: true)) · Rechecks about once a minute")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
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
                        Label(blocker, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                            .textSelection(.enabled)
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
                    LogView(title: "Standard output", content: selectedRun.standardOutput)
                    LogView(title: "Standard error", content: selectedRun.standardError)
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
    private let displayLimit = 16_000

    private var displayText: String {
        guard let content, !content.isEmpty else { return "No output captured" }
        let prefix = String(content.prefix(displayLimit))
        return content.count > displayLimit ? prefix + "\n… Output truncated for display" : prefix
    }

    var body: some View {
        GroupBox(title) {
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
