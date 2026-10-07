import Darwin
import Dispatch
import Foundation

/// The condition wakes an idle service immediately. Admission serializes stop
/// requests with accepting a check or durably claiming a command launch.
public final class GracefulShutdown: @unchecked Sendable {
    private let condition = NSCondition()
    private var requested = false

    public var isRequested: Bool {
        condition.lock()
        defer { condition.unlock() }
        return requested
    }

    @discardableResult
    public func request(onRequest: () -> Void = {}) -> Bool {
        condition.lock()
        defer { condition.unlock() }
        guard !requested else { return false }
        requested = true
        // Observers cannot proceed to exit until the stop event is persisted.
        onRequest()
        condition.broadcast()
        return true
    }

    public func admit<T>(_ operation: () throws -> T) rethrows -> T? {
        condition.lock()
        defer { condition.unlock() }
        guard !requested else { return nil }
        return try operation()
    }

    public func wait(until deadline: Date) {
        condition.lock()
        defer { condition.unlock() }
        while !requested && Date() < deadline {
            if !condition.wait(until: deadline) { break }
        }
    }
}

// No Foundation, locks, allocation, or database operations in the raw handler.
// A caught signal resets to default on exec; SIG_IGN would survive exec and make
// child commands ignore termination. Dispatch performs the actual shutdown work.
private func receiveTerminationSignal(_ number: Int32) {}

public final class TerminationSignals {
    private struct Disposition { let handler: sig_t? }
    private var sources: [DispatchSourceSignal] = []
    private var previous: [Int32: Disposition] = [:]

    public init(queue: DispatchQueue = .global(qos: .utility), handler: @escaping @Sendable () -> Void) {
        for number in [SIGTERM, SIGINT] {
            previous[number] = Disposition(handler: signal(number, receiveTerminationSignal))
            let source = DispatchSource.makeSignalSource(signal: number, queue: queue)
            source.setEventHandler(handler: handler)
            source.resume()
            sources.append(source)
        }
    }

    deinit {
        for source in sources { source.cancel() }
        for (number, disposition) in previous { signal(number, disposition.handler) }
    }
}
