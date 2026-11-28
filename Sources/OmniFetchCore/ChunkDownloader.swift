import Darwin
import Foundation

/// One writer per range. The session's serial delegate queue owns the buffer
/// and file offset. Only task registration and cancellation cross queues.
final class ChunkDownloader: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private static let flushThreshold = 256 * 1024

    private let rangeStart: Int64
    private let rangeEnd: Int64
    private let request: URLRequest
    private let handle: FileHandle
    private let limiter: RateLimiter?
    private let onBytes: @Sendable (Int) -> Void
    private let onResponse: (@Sendable (HTTPURLResponse, Int64?) throws -> Void)?
    private let expectedFileSize: Int64?
    private let allowsFullBodyResponse: Bool

    private var pending = Data()
    private var lastFlush = DispatchTime.now()
    private var transferError: Error?
    private var responseLimit: Int64?
    /// The caller reads this only after run() has returned or thrown.
    private(set) var bytesReceived: Int64 = 0

    private let lock = NSLock()
    private var task: URLSessionDataTask?
    private var continuation: CheckedContinuation<Void, Error>?
    private var cancelRequested = false

    init(rangeStart: Int64, rangeEnd: Int64, request: URLRequest,
         handle: FileHandle, limiter: RateLimiter?, allowsFullBodyResponse: Bool,
         expectedFileSize: Int64? = nil,
         onResponse: (@Sendable (HTTPURLResponse, Int64?) throws -> Void)? = nil,
         onBytes: @escaping @Sendable (Int) -> Void) {
        self.rangeStart = rangeStart
        self.rangeEnd = rangeEnd
        self.request = request
        self.handle = handle
        self.limiter = limiter
        self.allowsFullBodyResponse = allowsFullBodyResponse
        self.onResponse = onResponse
        self.expectedFileSize = expectedFileSize
        self.onBytes = onBytes
    }

    func run(in session: URLSession) async throws {
        try handle.seek(toOffset: UInt64(rangeStart))
        var req = request
        if rangeEnd >= rangeStart {
            req.setValue("bytes=\(rangeStart)-\(rangeEnd)", forHTTPHeaderField: "Range")
        }
        let rangeRequest = req
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                lock.lock()
                guard !cancelRequested else {
                    lock.unlock()
                    cont.resume(throwing: FetchError.cancelled)
                    return
                }
                let task = session.dataTask(with: rangeRequest)
                task.delegate = self
                self.task = task
                continuation = cont
                task.resume()
                lock.unlock()
            }
        } onCancel: {
            self.lock.lock()
            self.cancelRequested = true
            let task = self.task
            self.lock.unlock()
            task?.cancel()
            self.limiter?.wakeWaiters()
        }
    }

    private var cancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelRequested
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse else {
            transferError = FetchError.badStatus(-1)
            completionHandler(.cancel)
            return
        }
        var length: Int64? = http.expectedContentLength >= 0 ? http.expectedContentLength : nil
        switch http.statusCode {
        case 206:
            guard let range = HTTPContentRange(http), range.start == rangeStart,
                  (rangeEnd >= 0 ? range.end <= rangeEnd : range.total == range.end + 1) else {
                transferError = FetchError.rangeUnsupported
                break
            }
            if let expectedFileSize, let total = range.total, total != expectedFileSize {
                transferError = FetchError.rangeUnsupported
            }
            if let version = request.value(forHTTPHeaderField: "If-Range"), version.hasPrefix("\""),
               let current = http.value(forHTTPHeaderField: "ETag"), current != version {
                transferError = FetchError.rangeUnsupported
            }
            responseLimit = range.end - range.start + 1
            length = range.total
        case 200:
            if !allowsFullBodyResponse { transferError = FetchError.rangeUnsupported }
            if rangeEnd >= rangeStart { responseLimit = rangeEnd - rangeStart + 1 }
        default:
            transferError = FetchError.badStatus(http.statusCode)
        }
        if transferError == nil, HTTPProbe.isWebPage(http.mimeType) { transferError = FetchError.unexpectedContent }
        if transferError == nil {
            do { try onResponse?(http, length) } catch { transferError = error }
        }
        completionHandler(transferError == nil ? .allow : .cancel)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard transferError == nil, !cancelled, !data.isEmpty else { return }
        if let responseLimit {
            let remaining = responseLimit - bytesReceived - Int64(pending.count)
            guard Int64(data.count) <= remaining else {
                transferError = FetchError.rangeUnsupported
                dataTask.cancel()
                return
            }
        }
        do {
            if data.count >= Self.flushThreshold {
                try flush()
                try write(data)
            } else {
                pending.append(data)
                if pending.count >= Self.flushThreshold ||
                    DispatchTime.now().uptimeNanoseconds - lastFlush.uptimeNanoseconds >= 250_000_000 {
                    try flush()
                }
            }
        } catch {
            transferError = error
            dataTask.cancel()
        }
    }

    private func write(_ data: Data) throws {
        try data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            guard let base = buffer.baseAddress else { return }
            var offset = 0
            while offset < buffer.count {
                let remaining = buffer.count - offset
                let count = limiter?.allowance(upTo: remaining, cancelled: { self.cancelled }) ?? remaining
                guard count > 0 else { throw FetchError.cancelled }
                // Write directly from the network buffer. A short write has
                // already consumed its quota, so finish it before asking for more.
                let end = offset + count
                while offset < end {
                    let n = Darwin.write(handle.fileDescriptor, base.advanced(by: offset), end - offset)
                    if n < 0 && errno == EINTR { continue }
                    guard n > 0 else { throw FetchError.disk(String(cString: strerror(n == 0 ? EIO : errno))) }
                    offset += n
                    bytesReceived += Int64(n)
                    onBytes(n)
                }
            }
            lastFlush = .now()
        }
    }

    private func flush() throws {
        guard !pending.isEmpty else { return }
        try write(pending)
        pending.removeAll(keepingCapacity: true)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if cancelled {
            transferError = FetchError.cancelled
        } else if transferError == nil {
            do { try flush() } catch { transferError = error }
        }
        // Retry, fallback and pause all wait until this is the last callback
        // that can write the old file. A sibling may reopen it immediately.
        lock.lock()
        let cont = continuation
        continuation = nil
        self.task = nil
        lock.unlock()
        if let failure = transferError ?? error {
            cont?.resume(throwing: failure)
        } else {
            cont?.resume()
        }
    }
}
