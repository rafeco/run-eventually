import Foundation

/// Complete output lives on disk; RunRecord's strings remain small legacy previews.
public struct CommandLogFiles: Sendable {
    public let output: URL
    public let error: URL

    public init(directory: URL, runID: UUID) throws {
        let folder = directory.appendingPathComponent(runID.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        output = folder.appendingPathComponent("stdout.log")
        error = folder.appendingPathComponent("stderr.log")
    }

    func openWriters() throws -> (output: FileHandle, error: FileHandle) {
        func open(_ url: URL) throws -> FileHandle {
            guard FileManager.default.createFile(atPath: url.path, contents: nil,
                attributes: [.posixPermissions: 0o600]) else {
                throw CocoaError(.fileWriteUnknown)
            }
            return try FileHandle(forWritingTo: url)
        }
        let stdout = try open(output)
        do { return (stdout, try open(error)) }
        catch { try? stdout.close(); throw error }
    }

    func preview(at url: URL, limit: Int) throws -> String {
        let reader = try FileHandle(forReadingFrom: url)
        defer { try? reader.close() }
        return String(decoding: try reader.read(upToCount: limit) ?? Data(), as: UTF8.self)
    }
}
