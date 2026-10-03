import Combine
import Foundation
import RunEventuallyCore
import SwiftUI

@main
struct RunEventuallyDesktopApp: App {
    var body: some Scene {
        WindowGroup("Run Eventually") {
            DashboardView()
        }
        .defaultSize(width: 1_050, height: 680)
    }
}

// Include the local zone so UTC input is not mistaken for a shifted schedule.
private func timestamp(_ date: Date, seconds: Bool = false) -> String {
    let formatter = DateFormatter()
    formatter.timeZone = .autoupdatingCurrent
    formatter.setLocalizedDateFormatFromTemplate(seconds ? "yMMMdjmmssz" : "yMMMdjmmz")
    return formatter.string(from: date)
}

private struct TaskSummary: Identifiable, Sendable {
    let task: TaskDefinition
    let runs: [RunRecord]

    var id: UUID { task.id }
    var pending: RunRecord? { runs.last { $0.state == .pending } }
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
        if let pending { return pending.blockerReason == nil ? "Pending" : "Waiting" }
        if lastResult?.state == .outcomeUnknown { return "Needs review" }
        if case .once = task.schedule, let lastResult { return lastResult.state.displayName }
        return "Scheduled"
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
}

private struct DashboardView: View {
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
                        TaskDetail(summary: selectedSummary)
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

private struct TaskRow: View {
    let summary: TaskSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(summary.task.name)
                    .font(.headline)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(summary.status)
                    .font(.caption)
                    .foregroundStyle(summary.pending?.blockerReason == nil ? Color.secondary : Color.orange)
            }
            Text(summary.scheduleText)
                .font(.caption)
                .foregroundStyle(.secondary)
            if let pending = summary.pending {
                Text("Due \(timestamp(pending.firstScheduledAt))")
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
    }
}

private struct TaskDetail: View {
    let summary: TaskSummary
    @State private var selectedRunID: UUID?

    private var selectedRun: RunRecord? {
        summary.runs.first { $0.id == selectedRunID } ?? summary.runs.last
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(summary.task.name)
                    .font(.largeTitle)
                Text(summary.scheduleText)
                    .foregroundStyle(.secondary)
                Text(summary.task.command.executable + " " + summary.task.command.arguments.joined(separator: " "))
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                if let pending = summary.pending {
                    GroupBox("Pending work") {
                        VStack(alignment: .leading, spacing: 5) {
                            Text("Due \(timestamp(pending.firstScheduledAt))")
                            if pending.occurrenceCount > 1 {
                                Text("Combines \(pending.occurrenceCount) missed occurrences")
                            }
                            if let blocker = pending.blockerReason {
                                Text(blocker).foregroundStyle(.orange)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
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
                    Text("\(selectedRun.state.displayName) · Due \(timestamp(selectedRun.firstScheduledAt, seconds: true))")
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
                Text("Due \(timestamp(run.firstScheduledAt))")
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
