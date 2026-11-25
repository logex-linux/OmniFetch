import Foundation
import WebKit

/// Resolves a Channels share URL through the user's own Yuanbao session.
enum WeChatShare {
    private static let yuanbao = URL(string: "https://yuanbao.tencent.com/api/weixin/get_parse_result")!
    private static let preview = URL(string: "https://channels.weixin.qq.com/finder-preview/api/feed/get_feed_info")!

    static func probe(_ shareURL: URL) async throws -> MediaInfo {
        if shareURL.host?.lowercased() == "channels.weixin.qq.com" {
            return try await probePreview(shareURL)
        }
        let cookies = await cookiesForYuanbao()
        guard cookies.contains(where: { $0.name == "hy_user" }),
              cookies.contains(where: { $0.name == "hy_token" }) else {
            throw EngineError.probeFailed("请先在高级选项中登录腾讯元宝，再解析视频号分享链接")
        }
        let cookieHeader = cookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
        let parsed = try await post(yuanbao, body: ["type": "video_channel_url", "url": shareURL.absoluteString, "scene": 1],
                                    headers: ["Cookie": cookieHeader, "Origin": "https://yuanbao.tencent.com",
                                              "Referer": "https://yuanbao.tencent.com/", "x-source": "web"])
        guard (parsed.int("code") ?? -1) == 0,
              let playable = parsed.dict("data")?.str("playable_url"),
              let components = URLComponents(string: playable), components.scheme == "https",
              components.host == "channels.weixin.qq.com" else {
            throw EngineError.probeFailed("元宝未能解析该分享链接，请检查登录状态或链接是否有效")
        }
        guard let url = components.url else { throw EngineError.emptyResult }
        return try await probePreview(url)
    }

    static func previewParameters(_ url: URL) -> (token: String, id: String)? {
        guard let c = URLComponents(url: url, resolvingAgainstBaseURL: false),
              c.scheme?.lowercased() == "https", c.host?.lowercased() == "channels.weixin.qq.com",
              c.user == nil, c.password == nil, c.port == nil || c.port == 443 else { return nil }
        let items = c.queryItems ?? []
        guard let token = items.first(where: { $0.name == "token" })?.value, !token.isEmpty,
              let id = items.first(where: { $0.name == "eid" })?.value, !id.isEmpty else { return nil }
        return (token, id)
    }

    private static func probePreview(_ url: URL) async throws -> MediaInfo {
        guard let params = previewParameters(url) else {
            throw EngineError.probeFailed("视频号链接缺少完整预览信息，请复制微信分享链接或完整预览链接")
        }
        let response = try await post(preview, body: ["baseReq": ["generalToken": params.token], "exportId": params.id],
                                      headers: ["Origin": "https://channels.weixin.qq.com",
                                                "Referer": url.absoluteString])
        return try mediaInfo(response)
    }

    @MainActor private static func cookiesForYuanbao() async -> [HTTPCookie] {
        let all = await WKWebsiteDataStore.default().httpCookieStore.allCookies()
        return all.filter {
            let domain = $0.domain.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased()
            return (domain == "yuanbao.tencent.com" || domain == "tencent.com")
                && ($0.expiresDate == nil || $0.expiresDate! > Date())
                && yuanbao.path.hasPrefix($0.path)
        }
    }

    private static func post(_ url: URL, body: [String: Any], headers: [String: String]) async throws -> [String: Any] {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
        request.setValue(FetchHeaders.desktopUA, forHTTPHeaderField: "User-Agent")
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        let session = URLSession(configuration: config, delegate: NoRedirect(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw EngineError.probeFailed("无 HTTP 响应") }
        if http.statusCode == 401 || http.statusCode == 403 {
            throw EngineError.probeFailed("元宝登录已过期，请重新登录后再解析")
        }
        guard (200..<300).contains(http.statusCode),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw EngineError.probeFailed("视频号接口返回 HTTP \(http.statusCode)")
        }
        return object
    }

    static func mediaInfo(_ response: [String: Any]) throws -> MediaInfo {
        guard (response.int("errCode") ?? -1) == 0, let data = response.dict("data"),
              let feed = data.dict("feedInfo") else {
            throw EngineError.probeFailed("视频号未返回视频信息")
        }
        if let error = data.dict("errMsg"), (error.int("type") ?? 0) != 0 {
            throw EngineError.probeFailed("视频不可用或需要在微信中查看")
        }
        let candidates = [("h264", "H.264", feed.dict("h264VideoInfo")?.str("videoUrl")),
                          ("source", "原始画质", feed.str("videoUrl")),
                          ("h265", "H.265", feed.dict("h265VideoInfo")?.str("videoUrl"))]
        var variants: [String: RemoteFile] = [:]
        var formats: [FormatOption] = []
        var seen = Set<URL>()
        for (id, label, raw) in candidates {
            guard let url = URL.mediaURL(raw), url.scheme?.lowercased() == "https",
                  seen.insert(url).inserted else { continue }
            variants[id] = RemoteFile(url: url, headers: ["Referer": "https://channels.weixin.qq.com/", "User-Agent": FetchHeaders.desktopUA])
            formats.append(FormatOption(id: id, label: label, ext: "mp4"))
        }
        guard let first = formats.first, let remote = variants[first.id] else {
            throw EngineError.probeFailed("视频号没有返回可下载的视频地址")
        }
        let title = feed.str("description").flatMap { $0.isEmpty ? nil : $0 } ?? "微信视频号"
        var info = MediaInfo(title: title, site: "微信视频号", thumbnail: feed.str("coverUrl"), files: [remote],
                             formats: formats, selectedFormatID: first.id, engineID: "wechat")
        info.videoVariants = variants
        return info
    }
}

final class NoRedirect: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
