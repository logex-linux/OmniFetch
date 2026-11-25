import Foundation

public enum HTTPClient {
    public static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 60
        config.httpMaximumConnectionsPerHost = 8
        config.httpAdditionalHeaders = ["Accept-Language": "zh-CN,zh;q=0.9,en;q=0.8"]
        return URLSession(configuration: config)
    }()

    public static func data(url: URL,
                            headers: [String: String] = [:],
                            method: String = "GET") async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue(FetchHeaders.desktopUA, forHTTPHeaderField: "User-Agent")
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw EngineError.probeFailed("无 HTTP 响应")
        }
        return (data, http)
    }

    public static func json(url: URL, headers: [String: String] = [:]) async throws -> [String: Any] {
        let (data, http) = try await data(url: url, headers: headers)
        guard http.statusCode < 400 else {
            throw EngineError.probeFailed("HTTP \(http.statusCode)")
        }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw EngineError.probeFailed("响应不是 JSON")
        }
        return object
    }

    /// Follows redirects (b23.tv, xhslink.com) and returns the final URL.
    public static func resolveRedirect(_ url: URL) async -> URL {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(FetchHeaders.desktopUA, forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 15
        guard let (bytes, response) = try? await session.bytes(for: request) else { return url }
        bytes.task.cancel()
        return response.url ?? url
    }
}

public enum FetchHeaders {
    public static let desktopUA =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36"
}

public extension Dictionary where Key == String, Value == Any {
    func dict(_ key: String) -> [String: Any]? { self[key] as? [String: Any] }
    func array(_ key: String) -> [[String: Any]]? { self[key] as? [[String: Any]] }
    func str(_ key: String) -> String? { self[key] as? String }
    func int(_ key: String) -> Int? {
        if let value = self[key] as? Int { return value }
        if let value = self[key] as? Double { return Int(value) }
        if let value = self[key] as? String { return Int(value) }
        return nil
    }
    func int64(_ key: String) -> Int64? {
        if let value = self[key] as? Int64 { return value }
        if let value = self[key] as? Int { return Int64(value) }
        if let value = self[key] as? Double { return Int64(value) }
        if let value = self[key] as? String { return Int64(value) }
        return nil
    }
}
