import Foundation

/// Incremental reads keep UTF-8 characters intact across writes and read boundaries.
public final class RunLogReader {
    private let url: URL
    private var handle: FileHandle?
    private var remainder = Data()

    public init(path: String) { url = URL(fileURLWithPath: path) }
    deinit { try? handle?.close() }

    public func read(maxBytes: Int = 262_144, finished: Bool = false) throws -> String {
        if handle == nil {
            guard FileManager.default.fileExists(atPath: url.path) else { return "" }
            handle = try FileHandle(forReadingFrom: url)
        }
        let incoming = try handle?.read(upToCount: maxBytes) ?? Data()
        remainder.append(incoming)
        var count = remainder.count
        if !(finished && incoming.isEmpty), count > 0 {
            // Only an incomplete final character is deferred. Invalid bytes elsewhere
            // use the normal replacement character and cannot stall the reader.
            let bytes = Array(remainder.suffix(4))
            if let lead = bytes.lastIndex(where: { $0 & 0xc0 != 0x80 }) {
                let byte = bytes[lead]
                let length = byte >= 0xc2 && byte <= 0xdf ? 2
                    : byte >= 0xe0 && byte <= 0xef ? 3
                    : byte >= 0xf0 && byte <= 0xf4 ? 4 : 1
                let available = bytes.count - lead
                if available < length { count -= available }
            }
        }
        let text = String(decoding: remainder.prefix(count), as: UTF8.self)
        remainder.removeFirst(count)
        return text
    }
}
