import Foundation
import Testing
@testable import RunEventuallyCore

@Suite struct LiveLogTests {
    @Test func bothStreamsAreReadableBeforeExitAndRetainCompleteOutput() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let logs = try CommandLogFiles(directory: root, runID: UUID())
        defer { try? FileManager.default.removeItem(at: root) }
        let release = root.appendingPathComponent("release")
        let execution = Task.detached {
            try CommandRunner.run(CommandSpec(executable: "/bin/sh", arguments: ["-c",
                "printf 'live-out'; printf 'live-err' >&2; while [ ! -f \"$1\" ]; do sleep 0.05; done; printf '%0100000d' 0; printf '%0100000d' 0 >&2",
                "test", release.path]), timeoutSeconds: 10, outputLimitBytes: 128, logFiles: logs)
        }
        var liveOut = ""
        var liveErr = ""
        for _ in 0..<100 {
            liveOut = (try? String(contentsOf: logs.output, encoding: .utf8)) ?? ""
            liveErr = (try? String(contentsOf: logs.error, encoding: .utf8)) ?? ""
            if liveOut == "live-out" && liveErr == "live-err" { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(liveOut == "live-out")
        #expect(liveErr == "live-err")
        FileManager.default.createFile(atPath: release.path, contents: Data())
        let result = try await execution.value
        #expect(result.exitCode == 0)
        #expect(result.standardOutput.utf8.count == 128)
        #expect(try Data(contentsOf: logs.output).count == 100_008)
        #expect(try Data(contentsOf: logs.error).count == 100_008)
    }

    @Test func readerPreservesSplitUTF8AndResumesAfterTemporaryEOF() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("stdout")
        let reader = RunLogReader(path: path.path)
        #expect(try reader.read().isEmpty)
        FileManager.default.createFile(atPath: path.path, contents: Data())
        let writer = try FileHandle(forWritingTo: path)
        defer { try? writer.close() }
        let emoji = Array("🙂".utf8)
        try writer.write(contentsOf: Data(emoji.prefix(2)))
        #expect(try reader.read().isEmpty)
        #expect(try reader.read().isEmpty)
        try writer.write(contentsOf: Data(emoji.suffix(2)))
        #expect(try reader.read() == "🙂")
        try writer.write(contentsOf: Data("later".utf8))
        #expect(try reader.read(maxBytes: 2) == "la")
        #expect(try reader.read() == "ter")
        try writer.write(contentsOf: Data([0xe2]))
        #expect(try reader.read().isEmpty)
        #expect(try reader.read(finished: true) == "�")
    }

    @Test func schedulerPersistsFullLogLocations() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let scheduler = try Scheduler(databasePath: root.appendingPathComponent("state.sqlite").path)
        let now = Date()
        let task = TaskDefinition(name: "Logs", command: CommandSpec(executable: "/bin/sh",
            arguments: ["-c", "printf '%0100000d' 0; printf 'error' >&2"]),
            schedule: .once(now), scheduleCursor: now.addingTimeInterval(-1))
        try scheduler.store.insertTask(task)
        let run = try #require(try scheduler.tick(at: now))
        #expect(run.state == .succeeded)
        let saved = try #require(try scheduler.store.listRuns(taskID: task.id).first)
        let stdout = try #require(saved.standardOutputPath)
        let stderr = try #require(saved.standardErrorPath)
        #expect(try Data(contentsOf: URL(fileURLWithPath: stdout)).count == 100_000)
        #expect(try String(contentsOfFile: stderr, encoding: .utf8) == "error")
    }
}
