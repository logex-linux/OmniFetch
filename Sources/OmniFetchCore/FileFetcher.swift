import Foundation

/// Progress sink that keeps UI updates around 10 per second regardless of
/// how fast chunks arrive.
private final class ProgressGate: @unchecked Sendable {
    private let emit: @Sendable (Int64, Int64) -> Void
    private let lock = NSLock()
    private var downloaded: Int64 = 0
    private var total: Int64
    private var lastEmit: DispatchTime = .now()

    init(total: Int64, emit: @escaping @Sendable (Int64, Int64) -> Void) {
        self.total = total
        self.emit = emit
    }

    var expectedTotal: Int64 {
        lock.lock(); defer { lock.unlock() }
        return total
    }

    func setTotal(_ length: Int64) {
        lock.lock(); total = length; lock.unlock()
    }

    func add(_ count: Int) {
        lock.lock()
        downloaded += Int64(count)
        let now = DispatchTime.now()
        let elapsed = Double(now.uptimeNanoseconds - lastEmit.uptimeNanoseconds) / 1_000_000_000
        var fire = false
        if elapsed >= 0.1 {
            lastEmit = now
            fire = true
        }
        let d = downloaded
        let t = total
        lock.unlock()
        if fire { emit(d, t) }
    }

    func flush() {
        lock.lock()
        let d = downloaded, t = total
        lock.unlock()
        emit(d, t)
    }
}

private struct ResumeSidecar: Codable {
    var url: String
    var total: Int64
    var etag: String?     // remote version at the time the bytes were written
    var chunks: [Int64]   // bytes already written per chunk index
}

public actor FileFetcher {
    public static let shared = FileFetcher()

    /// One bucket for every file, chunk and task: the settings value is a
    /// global cap, so a DASH download or 3 parallel tasks cannot exceed it.
    private let sharedLimiter = RateLimiter(bytesPerSecond: nil)

    public init() {}

    /// Downloads a remote file, trying the CDN backups when the primary URL
    /// fails. Cancellation never triggers a failover.
    public func fetch(_ file: RemoteFile,
                      to destination: URL,
                      connections: Int,
                      bandwidth: Int?,
                      onProgress: @escaping @Sendable (Int64, Int64) -> Void) async throws -> URL {
        let session = TransferSession.make()
        defer { session.invalidateAndCancel() }
        return try await fetch(file, to: destination, connections: connections, bandwidth: bandwidth,
                               session: session, onProgress: onProgress)
    }

    func fetch(_ file: RemoteFile, to destination: URL, connections: Int, bandwidth: Int?,
               session: URLSession,
               onProgress: @escaping @Sendable (Int64, Int64) -> Void) async throws -> URL {
        sharedLimiter.setRate(bytesPerSecond: bandwidth.map { Int64($0) })
        let candidates = ([file.url] + (file.alternateURLs ?? [])).reduce(into: [URL]()) { result, url in
            if !result.contains(url) { result.append(url) }
        }
        var lastError: Error?
        for (index, candidate) in candidates.enumerated() {
            try Task.checkCancellation()
            var attempt = file
            attempt.url = candidate
            if candidate.host?.lowercased() != file.url.host?.lowercased() {
                attempt.headers = Self.withoutCredentials(attempt.headers)
            }
            do {
                return try await fetchOnce(attempt, to: destination, connections: connections,
                                           session: session, onProgress: onProgress)
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as FetchError {
                if case .cancelled = error { throw error }
                lastError = error
            } catch {
                lastError = error
            }
            if index < candidates.count - 1 {
                Log.write("source \(candidate.host ?? "?") failed (\(lastError?.localizedDescription ?? "?")); trying backup")
            }
        }
        throw lastError ?? FetchError.emptyFile
    }

    /// Downloads a remote file with parallel HTTP ranges and resumable chunks.
    /// Falls back to a single sequential stream when the server turns out not
    /// to honour `Range` for the individual chunks.
    private func fetchOnce(_ file: RemoteFile,
                           to destination: URL,
                           connections: Int,
                           session: URLSession,
                           onProgress: @escaping @Sendable (Int64, Int64) -> Void) async throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: destination.deletingLastPathComponent(),
                               withIntermediateDirectories: true)

        var headers = file.headers
        if headers["User-Agent"] == nil {
            headers["User-Agent"] = Self.defaultUserAgent
        }
        if !headers.keys.contains(where: { $0.caseInsensitiveCompare("Accept-Encoding") == .orderedSame }) {
            headers["Accept-Encoding"] = "identity"
        }
        // A new single-stream file can learn its size and ETag from the body
        // request itself. Existing partial files still validate their sidecar.
        let small = file.totalBytes.map { $0 > 0 && $0 < 8 * 1024 * 1024 } ?? false
        if (connections == 1 || small), !fm.fileExists(atPath: destination.path) {
            do {
                return try await downloadStream(file: file, headers: headers, to: destination,
                                                expectedTotal: file.totalBytes, session: session,
                                                checkpoint: true, onProgress: onProgress)
            } catch {
                try Task.checkCancellation()
                if case FetchError.disk = error { throw error }
                // A host may require Range, or the stream may have broken after
                // committing bytes. The normal path can pick up its checkpoint.
            }
        }

        let probe: HTTPProbeResult?
        do {
            probe = try await HTTPProbe.probe(url: file.url, headers: headers, session: session)
        } catch {
            // A cancelled probe is not a failed probe; do not fall through to
            // a download the user just paused.
            if Task.isCancelled { throw CancellationError() }
            Log.write("probe failed for \(file.url.host ?? "?") : \(error.localizedDescription)")
            probe = nil
        }

        if HTTPProbe.isWebPage(probe?.contentType) { throw FetchError.unexpectedContent }

        // Follow redirects once here; a per-chunk redirect loses the Range
        // header when it crosses hosts, which forces a slow single stream.
        var target = file
        if let resolved = probe?.finalURL, resolved != file.url {
            if resolved.host?.lowercased() != file.url.host?.lowercased() { headers = Self.withoutCredentials(headers) }
            target.url = resolved
        }

        guard let total = probe?.contentLength ?? file.totalBytes, total > 0 else {
            return try await downloadStream(file: target, headers: headers, to: destination,
                                            expectedTotal: nil, session: session, onProgress: onProgress)
        }

        if probe?.acceptsRanges == false {
            return try await downloadStream(file: target, headers: headers, to: destination,
                                            expectedTotal: total, session: session, onProgress: onProgress)
        }

        do {
            return try await fetchRanged(file: file,
                                         requestURL: target.url,
                                         headers: headers,
                                         total: total,
                                         etag: probe?.etag,
                                         session: session,
                                         connections: connections,
                                         destination: destination,
                                         onProgress: onProgress)
        } catch let error as FetchError where Self.shouldFallBackToStream(error) {
            Log.write("range download failed (\(error.localizedDescription)); retrying as single stream")
            return try await downloadStream(file: target, headers: headers, to: destination,
                                            expectedTotal: total, session: session, onProgress: onProgress)
        }
    }

    /// Pick up a pre-staging-layout partial only if its persisted source matches.
    static func adoptPartial(_ old: URL, at new: URL, for file: RemoteFile) {
        let fm = FileManager.default
        let sidecar = old.appendingPathExtension("omni-resume")
        guard !fm.fileExists(atPath: new.path), let data = try? Data(contentsOf: sidecar),
              let record = try? JSONDecoder().decode(ResumeSidecar.self, from: data),
              record.url == file.url.absoluteString else { return }
        do {
            try fm.moveItem(at: old, to: new)
            try fm.moveItem(at: sidecar, to: new.appendingPathExtension("omni-resume"))
        } catch { /* FileFetcher checks the new pair before using it. */ }
    }

    private static func withoutCredentials(_ headers: [String: String]) -> [String: String] {
        headers.filter { !["authorization", "cookie", "proxy-authorization"].contains($0.key.lowercased()) }
    }

    private static func shouldFallBackToStream(_ error: FetchError) -> Bool {
        switch error {
        case .rangeUnsupported, .badStatus(200), .badStatus(416): return true
        default: return false
        }
    }

    private func fetchRanged(file: RemoteFile,
                             requestURL: URL,
                             headers: [String: String],
                             total: Int64,
                             etag: String?,
                             session: URLSession,
                             connections: Int,
                             destination: URL,
                             onProgress: @escaping @Sendable (Int64, Int64) -> Void) async throws -> URL {
        let fm = FileManager.default
        var chunkCount = 1
        if total >= 8 * 1024 * 1024 {
            chunkCount = max(1, min(16, connections))
            if total < 32 * 1024 * 1024 { chunkCount = min(chunkCount, 4) }
        }

        let gate = ProgressGate(total: total, emit: onProgress)
        let limiter = sharedLimiter

        // Bytes that actually exist on disk before preallocation; a sidecar
        // claiming more than this would leave zero-filled holes (the file was
        // truncated or replaced outside the app).
        var existingSize: Int64 = 0
        if let attributes = try? fm.attributesOfItem(atPath: destination.path),
           let size = attributes[.size] as? NSNumber {
            existingSize = size.int64Value
        }

        let sidecarURL = destination.appendingPathExtension("omni-resume")
        var previous = Self.loadSidecar(sidecarURL,
                                        urlString: file.url.absoluteString,
                                        total: total,
                                        etag: etag,
                                        chunkCount: chunkCount)
        if let resume = previous,
           !Self.sidecarFits(resume, total: total, chunkCount: chunkCount, fileSize: existingSize) {
            Log.write("resume sidecar does not match \(destination.lastPathComponent); restarting")
            previous = nil
        }

        let resumedBytes = previous?.chunks.reduce(0, +) ?? 0
        try Self.checkCapacity(for: total - resumedBytes, at: destination)
        if !fm.fileExists(atPath: destination.path) {
            fm.createFile(atPath: destination.path, contents: nil)
        }
        let allocator = try FileHandle(forWritingTo: destination)
        try allocator.truncate(atOffset: UInt64(total))
        try allocator.close()

        var ranges: [(start: Int64, end: Int64, already: Int64)] = []
        let base = total / Int64(chunkCount)
        for index in 0..<chunkCount {
            let start = Int64(index) * base
            let end = index == chunkCount - 1 ? total - 1 : start + base - 1
            let already = previous?.chunks[index] ?? 0
            ranges.append((start, end, already))
            gate.add(Int(already))
        }

        // Seed the coordinator with resumed bytes, otherwise the next sidecar
        // snapshot would forget them and the following resume would restart
        // completed chunks.
        let coordinator = ChunkCoordinator(seeded: ranges.map(\.already))
        let sidecarWriter = SidecarWriter(url: sidecarURL, source: file.url, coordinator: coordinator,
                                          count: chunkCount)
        sidecarWriter.start(total: total, etag: etag)

        var succeeded = false
        defer { sidecarWriter.stop(persist: !succeeded) }

        var request = URLRequest(url: requestURL)
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        if let etag, etag.hasPrefix("\"") { request.setValue(etag, forHTTPHeaderField: "If-Range") }
        let rangeRequest = request
        let expectsPartial = chunkCount > 1
        try await withThrowingTaskGroup(of: Void.self) { group in
            for (index, range) in ranges.enumerated() {
                let start = range.start + range.already
                if start > range.end { continue }
                group.addTask {
                    try await Self.downloadRange(
                        index: index,
                        start: start,
                        end: range.end,
                        expectsPartial: expectsPartial,
                        total: total,
                        request: rangeRequest,
                        destination: destination,
                        session: session,
                        limiter: limiter,
                        gate: gate,
                        coordinator: coordinator
                    )
                }
            }
            for try await _ in group {}
        }

        let attributes = try? fm.attributesOfItem(atPath: destination.path)
        let size = (attributes?[.size] as? NSNumber)?.int64Value ?? total
        if size != total {
            throw FetchError.disk("文件大小不一致（期望 \(total)，实际 \(size)）")
        }
        gate.flush()
        succeeded = true
        return destination
    }

    // Most volumes have ample immediately free space. Query purgeable capacity
    // only when that inexpensive check cannot establish there is room.
    private static func checkCapacity(for required: Int64, at destination: URL) throws {
        guard required > 0 else { return }
        let dir = destination.deletingLastPathComponent()
        let fs = try? FileManager.default.attributesOfFileSystem(forPath: dir.path)
        if let free = fs?[.systemFreeSize] as? NSNumber, free.int64Value >= required { return }
        let volume = try? dir.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        if let free = volume?.volumeAvailableCapacityForImportantUsage, free > 0, free < required {
            throw FetchError.disk("磁盘空间不足：需要 \(ByteCountFormatter.string(fromByteCount: required, countStyle: .file))，可用 \(ByteCountFormatter.string(fromByteCount: free, countStyle: .file))")
        }
    }

    // MARK: - Range worker

    private static func downloadRange(index: Int,
                                      start: Int64,
                                      end: Int64,
                                      expectsPartial: Bool,
                                      total: Int64,
                                      request: URLRequest,
                                      destination: URL,
                                      session: URLSession,
                                      limiter: RateLimiter?,
                                      gate: ProgressGate,
                                      coordinator: ChunkCoordinator) async throws {
        let handle = try FileHandle(forWritingTo: destination)
        defer { try? handle.close() }

        var cursor = start
        var failures = 0
        while cursor <= end {
            try Task.checkCancellation()
            let downloader = ChunkDownloader(
                rangeStart: cursor,
                rangeEnd: end,
                request: request,
                handle: handle,
                limiter: limiter,
                allowsFullBodyResponse: !expectsPartial && cursor == 0,
                expectedFileSize: total,
                onBytes: { count in
                    gate.add(count)
                    coordinator.add(index: index, bytes: count)
                }
            )
            let failure: Error?
            do {
                try await downloader.run(in: session)
                failure = nil
            } catch {
                try Task.checkCancellation()
                if !Self.isRetryable(error) { throw error }
                failure = error
            }
            cursor += downloader.bytesReceived
            if cursor > end { return }
            if let failure {
                failures += 1
                if failures >= 5 { throw failure }
                let delay = min(4.0, 0.4 * pow(2.0, Double(failures - 1)))
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            } else {
                // A valid 206 may cover only part of the requested range.
                guard downloader.bytesReceived > 0 else { throw FetchError.rangeUnsupported }
                failures = 0
            }
        }
    }

    private static func isRetryable(_ error: Error) -> Bool {
        if case FetchError.rangeUnsupported = error { return false }
        if case FetchError.disk = error { return false }
        if case FetchError.unexpectedContent = error { return false }
        if case FetchError.cancelled = error { return false }
        if case FetchError.badStatus(let code) = error {
            let clientError = code >= 400 && code < 500
            return !clientError || code == 408 || code == 429
        }
        return true
    }

    // MARK: - Fallback single stream

    private func downloadStream(file: RemoteFile,
                                headers: [String: String],
                                to destination: URL,
                                expectedTotal: Int64?,
                                session: URLSession,
                                checkpoint: Bool = false,
                                onProgress: @escaping @Sendable (Int64, Int64) -> Void) async throws -> URL {
        let gate = ProgressGate(total: expectedTotal ?? file.totalBytes ?? 0, emit: onProgress)
        let limiter = sharedLimiter
        // A stream always restarts at byte 0: drop the partial file and any
        // ranged sidecar, whose chunk offsets no longer describe this file.
        try? FileManager.default.removeItem(at: destination.appendingPathExtension("omni-resume"))
        FileManager.default.createFile(atPath: destination.path, contents: nil)
        let handle = try FileHandle(forWritingTo: destination)
        try handle.truncate(atOffset: 0)
        defer { try? handle.close() }

        var request = URLRequest(url: file.url)
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        request.timeoutInterval = 30

        let coordinator = ChunkCoordinator(seeded: [0])
        let writer = checkpoint ? SidecarWriter(url: destination.appendingPathExtension("omni-resume"),
                                                source: file.url, coordinator: coordinator, count: 1) : nil
        var succeeded = false
        let downloader = ChunkDownloader(rangeStart: 0, rangeEnd: -1, request: request,
                                         handle: handle, limiter: limiter, allowsFullBodyResponse: true,
                                         onResponse: { response, length in
            guard let length else { return }
            if let writer, length > 0 {
                if let expectedTotal, expectedTotal > 0, expectedTotal != length {
                    // The preview may be stale or this response may be short.
                    // Re-probe before accepting a different representation.
                    throw FetchError.rangeUnsupported
                }
                try Self.checkCapacity(for: length, at: destination)
                gate.setTotal(length)
                writer.start(total: length, etag: response.value(forHTTPHeaderField: "ETag"))
            } else if gate.expectedTotal == 0, length > 0 {
                gate.setTotal(length)
            }
        }, onBytes: { count in
            if writer != nil { coordinator.add(index: 0, bytes: count) }
            gate.add(count)
        })
        defer {
            if let writer {
                let canResume = writer.hasLength && downloader.bytesReceived > 0
                writer.stop(persist: !succeeded && canResume)
                if !succeeded && !canResume { try? FileManager.default.removeItem(at: destination) }
            }
        }
        try await downloader.run(in: session)
        // A server that closes cleanly after fewer bytes than it announced
        // must not be reported as a complete download.
        let written = downloader.bytesReceived
        let expected = gate.expectedTotal
        guard written > 0 else { throw FetchError.emptyFile }
        if expected > 0, written != expected {
            throw FetchError.disk("下载不完整（期望 \(expected) 字节，实际 \(written)）")
        }
        succeeded = true
        gate.flush()
        return destination
    }

    // MARK: - Sidecar

    /// Every byte a sidecar claims must already be inside the file on disk.
    private static func sidecarFits(_ sidecar: ResumeSidecar, total: Int64,
                                    chunkCount: Int, fileSize: Int64) -> Bool {
        guard chunkCount > 0 else { return false }
        let base = total / Int64(chunkCount)
        for index in 0..<chunkCount {
            let start = Int64(index) * base
            let length = index == chunkCount - 1 ? total - start : base
            let claimed = sidecar.chunks[index]
            guard claimed >= 0, claimed <= length else { return false }
            // A chunk with nothing claimed needs no bytes on disk yet.
            if claimed > 0 && start + claimed > fileSize { return false }
        }
        return true
    }

    private static func loadSidecar(_ url: URL, urlString: String,
                                    total: Int64, etag: String?,
                                    chunkCount: Int) -> ResumeSidecar? {
        guard let data = try? Data(contentsOf: url),
              let sidecar = try? JSONDecoder().decode(ResumeSidecar.self, from: data),
              sidecar.url == urlString,
              sidecar.total == total,
              sidecar.chunks.count == chunkCount else { return nil }
        // A changed ETag means the remote file is a different version; splicing
        // its new bytes onto the old half would produce a corrupt file.
        if let old = sidecar.etag, let new = etag, old != new {
            Log.write("remote file changed (etag \(old) -> \(new)); restarting download")
            return nil
        }
        return sidecar
    }

    static let defaultUserAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Safari/605.1.15"
}

final class ChunkCoordinator: @unchecked Sendable {
    private var bytes: [Int: Int64] = [:]
    private let lock = NSLock()

    init(seeded: [Int64] = []) {
        for (index, value) in seeded.enumerated() where value > 0 {
            bytes[index] = value
        }
    }

    func add(index: Int, bytes count: Int) {
        lock.lock(); bytes[index, default: 0] += Int64(count); lock.unlock()
    }

    func snapshot(count: Int) -> [Int64] {
        lock.lock(); defer { lock.unlock() }
        return (0..<count).map { bytes[$0] ?? 0 }
    }
}

private final class SidecarWriter: @unchecked Sendable {
    private let url: URL
    private let source: URL
    private let coordinator: ChunkCoordinator
    private let count: Int
    private let queue = DispatchQueue(label: "omnifetch.checkpoint", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var total: Int64 = 0
    private var etag: String?

    var hasLength: Bool { total > 0 }

    init(url: URL, source: URL, coordinator: ChunkCoordinator, count: Int) {
        self.url = url
        self.source = source
        self.coordinator = coordinator
        self.count = count
    }

    func start(total: Int64, etag: String?) {
        self.total = total
        self.etag = etag
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 2, repeating: 2)
        timer.setEventHandler { [weak self] in self?.write() }
        self.timer = timer
        timer.resume()
    }

    private func write() {
        let sidecar = ResumeSidecar(url: source.absoluteString, total: total, etag: etag,
                                    chunks: coordinator.snapshot(count: count))
        if let data = try? JSONEncoder().encode(sidecar) {
            try? data.write(to: url, options: .atomic)
        }
    }

    func stop(persist: Bool) {
        timer?.cancel()
        queue.sync {
            if persist && total > 0 {
                write()
            } else {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }
}
