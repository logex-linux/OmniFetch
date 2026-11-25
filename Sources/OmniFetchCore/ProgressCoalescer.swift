import Foundation

/// Coalesces progress callbacks from every running task into a single flush
/// per interval, so the main thread is woken at most 10×/s no matter how many
/// downloads or chunks are reporting.
final class ProgressCoalescer: @unchecked Sendable {
    typealias Sink = @Sendable (UUID, Int64, Int64) -> Void

    private let sink: Sink
    private let interval: TimeInterval
    private let lock = NSLock()
    private var pending: [UUID: (downloaded: Int64, total: Int64)] = [:]
    private var scheduled = false

    init(interval: TimeInterval = 0.1, sink: @escaping Sink) {
        self.interval = interval
        self.sink = sink
    }

    func submit(id: UUID, downloaded: Int64, total: Int64) {
        lock.lock()
        pending[id] = (downloaded, total)
        let needsSchedule = !scheduled
        if needsSchedule { scheduled = true }
        lock.unlock()

        guard needsSchedule else { return }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + interval) { [weak self] in
            self?.drain()
        }
    }

    private func drain() {
        lock.lock()
        let batch = pending
        pending.removeAll()
        scheduled = false
        lock.unlock()

        for (id, value) in batch {
            sink(id, value.downloaded, value.total)
        }
    }
}
