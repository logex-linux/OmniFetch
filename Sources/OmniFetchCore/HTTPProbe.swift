import Foundation

public struct HTTPProbeResult: Sendable {
    public var statusCode: Int
    public var contentLength: Int64?
    public var acceptsRanges: Bool
    public var contentType: String?
    public var etag: String?
    /// URL after redirects. Range requests must target it directly: URLSession
    /// drops the Range header when a redirect crosses hosts.
    public var finalURL: URL?
}

struct HTTPContentRange {
    let start: Int64
    let end: Int64
    let total: Int64?

    init?(_ response: HTTPURLResponse) {
        guard let field = response.value(forHTTPHeaderField: "Content-Range") else { return nil }
        let parts = field.split(separator: " ", maxSplits: 1)
        guard parts.count == 2, parts[0].lowercased() == "bytes" else { return nil }
        let range = parts[1].split(separator: "/")
        guard range.count == 2 else { return nil }
        let bounds = range[0].split(separator: "-", omittingEmptySubsequences: false)
        guard bounds.count == 2, let first = Int64(bounds[0]), let last = Int64(bounds[1]),
              first >= 0, last >= first, last < Int64.max else { return nil }
        total = Int64(range[1])
        guard range[1] == "*" || total.map({ $0 > last }) == true else { return nil }
        start = first
        end = last
    }
}

public enum FetchError: LocalizedError {
    case badStatus(Int)
    case rangeUnsupported
    case emptyFile
    case unexpectedContent
    case cancelled
    case disk(String)
    case invalidURL(String)

    public var errorDescription: String? {
        switch self {
        case .badStatus(let code): return "服务器返回 HTTP \(code)"
        case .rangeUnsupported: return "服务器不支持分片下载"
        case .emptyFile: return "文件为空"
        case .unexpectedContent: return "服务器返回了网页或错误信息，请检查分享链接或访问权限"
        case .cancelled: return "已取消"
        case .disk(let msg): return "磁盘错误：\(msg)"
        case .invalidURL(let raw): return "无效链接：\(raw)"
        }
    }
}

/// The probe and all ranges of a file share a connection pool and an isolated
/// cookie store. The serial delegate queue preserves each writer's callback order.
enum TransferSession {
    static func make() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.httpMaximumConnectionsPerHost = 16
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 3600
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        config.networkServiceType = .responsiveData
        return URLSession(configuration: config)
    }
}

public enum HTTPProbe {
    static func isWebPage(_ header: String?) -> Bool {
        guard let type = header?.split(separator: ";", maxSplits: 1).first?.trimmingCharacters(in: .whitespaces).lowercased()
        else { return false }
        return ["text/html", "application/xhtml+xml", "application/json", "application/problem+json"].contains(type)
    }

    public static func probe(url: URL, headers: [String: String],
                             timeout: TimeInterval = 15) async throws -> HTTPProbeResult {
        let session = TransferSession.make()
        defer { session.invalidateAndCancel() }
        return try await probe(url: url, headers: headers, timeout: timeout, session: session)
    }

    static func probe(url: URL, headers: [String: String], timeout: TimeInterval = 15,
                      session: URLSession) async throws -> HTTPProbeResult {
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        request.setValue("bytes=0-0", forHTTPHeaderField: "Range")
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            bytes.task.cancel()
            throw FetchError.badStatus(-1)
        }

        // CFNetwork can finish a one-byte response and reuse the socket. A slow
        // probe body must not delay launching the actual transfer.
        if http.statusCode != 206 || http.expectedContentLength != 1 {
            bytes.task.cancel()
        }
        guard http.statusCode < 400 else { throw FetchError.badStatus(http.statusCode) }
        let range = HTTPContentRange(http)
        var total = range?.total
        if total == nil, http.statusCode == 200, http.expectedContentLength > 0 {
            total = http.expectedContentLength
        }
        return HTTPProbeResult(statusCode: http.statusCode, contentLength: total,
                               acceptsRanges: http.statusCode == 206 && range?.start == 0,
                               contentType: http.value(forHTTPHeaderField: "Content-Type"),
                               etag: http.value(forHTTPHeaderField: "ETag"), finalURL: http.url)
    }
}

/// All native transfers share one bucket. A wait releases the condition lock
/// so another transfer can change the rate or interrupt a cancelled writer.
public final class RateLimiter: @unchecked Sendable {
    private let condition = NSCondition()
    private var bytesPerSecond: Int64?
    private var tokens: Double
    private var lastRefill = DispatchTime.now()

    public init(bytesPerSecond: Int64?) {
        self.bytesPerSecond = bytesPerSecond.map { max(1, $0) }
        tokens = Double(self.bytesPerSecond ?? 0) * 0.25
    }

    public func setRate(bytesPerSecond: Int64?) {
        let rate = bytesPerSecond.map { max(1, $0) }
        condition.lock()
        defer { condition.unlock() }
        guard rate != self.bytesPerSecond else { return }
        self.bytesPerSecond = rate
        tokens = 0
        lastRefill = .now()
        condition.broadcast()
    }

    func wakeWaiters() {
        condition.lock()
        condition.broadcast()
        condition.unlock()
    }

    public func consume(_ count: Int) {
        var remaining = count
        while remaining > 0 {
            remaining -= allowance(upTo: remaining, cancelled: { false })
        }
    }

    /// A slow transfer can commit and report a quarter-second of data at a
    /// time, even when CFNetwork delivers a much larger buffer in one callback.
    func allowance(upTo count: Int, cancelled: () -> Bool) -> Int {
        condition.lock()
        defer { condition.unlock() }
        while let rate = bytesPerSecond {
            if cancelled() { return 0 }
            let now = DispatchTime.now()
            let elapsed = Double(now.uptimeNanoseconds - lastRefill.uptimeNanoseconds) / 1_000_000_000
            let speed = Double(rate)
            let burst = max(1, speed * 0.25)
            tokens = min(burst, tokens + elapsed * speed)
            lastRefill = now
            let grant = min(count, max(1, Int(rate / 4)))
            if tokens >= Double(grant) {
                tokens -= Double(grant)
                return grant
            }
            _ = condition.wait(until: Date(timeIntervalSinceNow: (Double(grant) - tokens) / speed))
        }
        return count
    }
}
