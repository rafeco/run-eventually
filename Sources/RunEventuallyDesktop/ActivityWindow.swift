import Combine
import Foundation
import RunEventuallyCore
import SwiftUI

private struct ActivitySnapshot: Sendable {
    let events: [ActivityEvent]
    let tasks: [TaskDefinition]
    let latestSchedulerEvent: ActivityEvent?
    let schedulerRunning: Bool
    let buildMatches: Bool?
}

@MainActor
private final class ActivityModel: ObservableObject {
    @Published private(set) var snapshot: ActivitySnapshot?
    @Published private(set) var error: String?
    @Published private(set) var refreshedAt: Date?
    @Published private(set) var refreshing = false
    private let launchedBuildDigest = DesktopBuild.schedulerDigest

    func refresh() {
        guard !refreshing else { return }
        refreshing = true
        let defaultPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/RunEventually/state.sqlite").path
        let path = URL(fileURLWithPath: ProcessInfo.processInfo.environment["RUN_EVENTUALLY_DB"] ?? defaultPath)
            .standardizedFileURL.path
        let bundledDigest = launchedBuildDigest
        Task {
            defer { refreshing = false }
            do {
                snapshot = try await Task.detached(priority: .utility) {
                    guard FileManager.default.fileExists(atPath: path) else {
                        return ActivitySnapshot(events: [], tasks: [], latestSchedulerEvent: nil, schedulerRunning: false, buildMatches: nil)
                    }
                    let store = try SQLiteStore(path: path)
                    let runtime = try store.schedulerRuntime()
                    return ActivitySnapshot(events: try store.listActivity(), tasks: try store.listTasks(),
                        latestSchedulerEvent: try store.listActivity(limit: 1, schedulerOnly: true).first,
                        schedulerRunning: try Scheduler.isRunning(databasePath: path),
                        buildMatches: runtime.flatMap { runtime in bundledDigest.map { runtime.executableDigest == $0 } })
                }.value
                error = nil
                refreshedAt = Date()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

struct ActivityWindow: View {
    @StateObject private var model = ActivityModel()
    @State private var live = true
    @State private var taskID: UUID?
    @State private var filter = ActivityFilter.all
    @State private var selectedID: UUID?
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private var taskNames: [UUID: String] {
        Dictionary(uniqueKeysWithValues: (model.snapshot?.tasks ?? []).map { ($0.id, $0.name) })
    }

    private var events: [ActivityEvent] {
        (model.snapshot?.events ?? []).filter { event in
            (taskID == nil || event.taskID == taskID) && filter.includes(event)
        }
    }

    private var currentTaskName: String? {
        model.snapshot?.latestSchedulerEvent?.taskID.flatMap { taskNames[$0] }
    }

    private var statusTitle: String {
        if model.error != nil { return "Scheduler status unavailable" }
        guard let snapshot = model.snapshot else { return "Checking scheduler status…" }
        return snapshot.schedulerRunning ? "Scheduler running" : "Scheduler stopped"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label(statusTitle,
                          systemImage: model.snapshot?.schedulerRunning == true ? "circle.fill" : "pause.circle")
                        .foregroundStyle(model.snapshot?.schedulerRunning == true ? Color.green : Color.secondary)
                        .font(.headline)
                    Spacer()
                    if !live { Text("Updates paused").foregroundStyle(.orange) }
                }
                if let error = model.error {
                    Label("Activity could not refresh: \(error)", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                } else if let snapshot = model.snapshot, snapshot.schedulerRunning {
                    if snapshot.buildMatches == false {
                        Label("App and scheduler are different builds. Use the development restart script to update both.",
                              systemImage: "arrow.triangle.2.circlepath")
                            .foregroundStyle(.orange)
                    }
                    if let event = snapshot.latestSchedulerEvent {
                        Text((currentTaskName.map { "\($0): " } ?? "") + event.message)
                        if [.checkStarted, .runStarted].contains(event.kind) {
                            Text("Started \(timestamp(event.timestamp, seconds: true))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        if let next = event.nextCheckAt {
                            Text("Next scan expected \(timestamp(next, seconds: true))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    } else {
                        Text("Waiting for scheduler activity. An older scheduler needs to be restarted with the updated build.")
                    }
                } else {
                    Text("Saved work will wait until the background scheduler starts.")
                        .foregroundStyle(.secondary)
                }
            }
            .padding(16)
            Divider()
            HStack {
                Picker("Task", selection: $taskID) {
                    Text("All tasks").tag(nil as UUID?)
                    ForEach(model.snapshot?.tasks ?? []) { task in
                        Text(task.name).tag(Optional(task.id))
                    }
                }
                .frame(maxWidth: 320)
                Picker("Show", selection: $filter) {
                    ForEach(ActivityFilter.allCases) { value in
                        Text(value.rawValue).tag(value)
                    }
                }
                .frame(maxWidth: 260)
                Spacer()
                Text("\(events.count) events")
                    .foregroundStyle(.secondary)
            }
            .padding(12)
            Divider()
            if events.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "list.bullet.rectangle").font(.largeTitle)
                    Text("No activity to show").font(.title2)
                    Text("New scans, checks, and task operations will appear here.")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: $selectedID) {
                    ForEach(events) { event in
                        ActivityRow(event: event, taskName: event.taskID.flatMap { taskNames[$0] })
                            .tag(event.id)
                    }
                }
                .listStyle(.inset)
            }
            if let event = events.first(where: { $0.id == selectedID }) {
                Divider()
                VStack(alignment: .leading, spacing: 5) {
                    Text(event.message).textSelection(.enabled)
                    Text("\(timestamp(event.timestamp, seconds: true)) · \(event.kind.title)")
                        .font(.caption).foregroundStyle(.secondary)
                    if let run = event.runID {
                        Text("Run \(run.uuidString)").font(.caption).textSelection(.enabled)
                    }
                }
                .padding(12)
            }
            Divider()
            HStack {
                Text("Newest first · Latest 500 events shown · 5,000 retained")
                Spacer()
                if let time = model.refreshedAt {
                    Text("Updated \(timestamp(time, seconds: true))")
                }
            }
            .font(.caption).foregroundStyle(.secondary).padding(10)
        }
        .frame(minWidth: 760, minHeight: 480)
        .toolbar {
            ToolbarItem {
                Button { live.toggle(); if live { model.refresh() } } label: {
                    Label(live ? "Pause updates" : "Resume updates", systemImage: live ? "pause" : "play")
                }
            }
            ToolbarItem {
                Button { model.refresh() } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                    .disabled(model.refreshing)
            }
        }
        .onAppear { model.refresh() }
        .onReceive(timer) { _ in if live { model.refresh() } }
    }
}

private enum ActivityFilter: String, CaseIterable, Identifiable {
    case all = "All activity", checks = "Readiness checks", runs = "Task execution", problems = "Warnings and errors"
    var id: Self { self }
    func includes(_ event: ActivityEvent) -> Bool {
        switch self {
        case .all: true
        case .checks: event.kind.isCheck
        case .runs: [.runRequested, .runRequestRejected, .workDue, .runHeld, .runRecovered, .eligibilityChecked, .runStarted, .runSucceeded, .runFailed].contains(event.kind)
        case .problems: event.level != .info
        }
    }
}

private struct ActivityRow: View {
    let event: ActivityEvent
    let taskName: String?
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: event.level == .error ? "xmark.circle" : event.level == .warning ? "exclamationmark.triangle" : "circle")
                .foregroundStyle(event.level == .error ? Color.red : event.level == .warning ? Color.orange : Color.secondary)
                .frame(width: 18)
                .accessibilityLabel(event.level.rawValue)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(taskName ?? "Scheduler").fontWeight(.medium)
                    Text(event.kind.title).foregroundStyle(.secondary)
                    Spacer()
                    Text(timestamp(event.timestamp, seconds: true)).font(.caption).foregroundStyle(.secondary)
                }
                Text(event.message).lineLimit(3)
            }
        }
        .padding(.vertical, 4)
    }
}

private extension ActivityKind {
    var title: String {
        switch self {
        case .schedulerStarted: "Started"
        case .schedulerStopping: "Stopping safely"
        case .schedulerStopped: "Stopped"
        case .schedulerError: "Scan failed"
        case .cycleStarted: "Scanning"
        case .cycleFinished: "Scan complete"
        case .waiting: "Waiting"
        case .scheduleChecked: "Schedule checked"
        case .taskCreated: "Task created"
        case .taskUpdated: "Task updated"
        case .runRequested: "Run requested"
        case .runRequestRejected: "Request rejected"
        case .workDue: "Work queued"
        case .runHeld: "Run held"
        case .runRecovered: "Needs review"
        case .eligibilityChecked: "Eligible"
        case .checkStarted: "Checking readiness"
        case .checkPassed: "Ready"
        case .checkBlocked: "Not ready"
        case .checkFailed: "Check failed"
        case .runStarted: "Running"
        case .runSucceeded: "Succeeded"
        case .runFailed: "Failed"
        }
    }
}
