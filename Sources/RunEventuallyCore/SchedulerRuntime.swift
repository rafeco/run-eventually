import CryptoKit
import Darwin
import Foundation

/// Recorded by the running process, rather than inferred from the file currently
/// installed at its path. Atomic executable replacement does not update a process.
public struct SchedulerRuntime: Codable, Sendable, Equatable {
    public let sessionID: UUID
    public let processID: Int32
    public let executableDigest: String
    public let supportsGracefulShutdown: Bool

    public static func executableDigest(at url: URL) throws -> String {
        SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
    }
}
