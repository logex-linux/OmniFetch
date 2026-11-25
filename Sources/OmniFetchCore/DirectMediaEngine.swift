import AVFoundation
import Foundation

/// Plain media URLs (mp4/mov/webm/…) and WeChat Channels CDN links.
public struct DirectMediaEngine: DownloadEngine {
    public let id = "direct"
    public var displayName: String { "直链下载" }

    private static let mediaExtensions: Set<String> = [
        "mp4", "m4v", "mov", "webm", "flv", "mkv", "ts", "m4a", "mp3", "aac", "wav", "ogg"
    ]

    public init() {}

    public func canHandle(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return false }
        if url.path.hasPrefix("/wiki/") && (url.isOn("wikimedia.org") || url.isOn("wikipedia.org")) { return false }
        let ext = url.pathExtension.lowercased()
        return Self.mediaExtensions.contains(ext) || Self.imageExtensions.contains(ext)
    }

    private static let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "gif", "webp", "avif", "heic"]

    public func probe(url: URL, options: DownloadOptions) async throws -> MediaInfo {
        var info = try await prepareDownload(url: url, options: options)
        let result = try? await HTTPProbe.probe(url: url, headers: info.files[0].headers)
        try Task.checkCancellation()
        if HTTPProbe.isWebPage(result?.contentType) { throw FetchError.unexpectedContent }
        info.files[0].totalBytes = result?.contentLength
        info.formats[0].filesize = result?.contentLength
        return info
    }

    /// FileFetcher negotiates size and ranges when transferring a direct URL.
    /// Only a separate preview needs to request those headers ahead of time.
    public func prepareDownload(url: URL, options: DownloadOptions) async throws -> MediaInfo {
        var headers = options.extraHeaders
        if let referer = options.referer { headers["Referer"] = referer }
        if let ua = options.userAgent { headers["User-Agent"] = ua }
        if let cookie = options.cookieHeader, !cookie.isEmpty { headers["Cookie"] = cookie }

        let rawName = url.lastPathComponent.removingPercentEncoding ?? url.lastPathComponent
        let base = (rawName as NSString).deletingPathExtension
        let title = base.isEmpty ? "视频 \(Int(Date().timeIntervalSince1970))" : base
        let ext = url.pathExtension.lowercased()

        let remote = RemoteFile(url: url, headers: headers,
                                kind: Self.imageExtensions.contains(ext) ? .image :
                                      (["m4a", "mp3", "aac", "wav", "ogg"].contains(ext) ? .audio : .video),
                                fileExtension: ext)
        return MediaInfo(title: title,
                         site: url.host,
                         files: [remote],
                         formats: [FormatOption(id: "source", label: "原始画质", ext: ext)],
                         selectedFormatID: "source",
                         suggestedExtension: ext,
                         engineID: id)
    }

    public func download(_ request: DownloadRequest,
                         onProgress: @escaping @Sendable (Int64, Int64) -> Void) async throws -> URL {
        var files = request.info.files(for: request.options.formatID)
        guard !files.isEmpty else { throw EngineError.emptyResult }
        for index in files.indices {
            files[index].headers.merge(request.options.extraHeaders) { current, _ in current }
        }
        if let image = files.first, image.kind == .image {
            return try await DirectPipeline.fetchSingle(image, directory: request.destinationDirectory,
                                                        baseName: request.baseName, connections: 1,
                                                        bandwidth: request.options.bandwidth, onProgress: onProgress)
        }
        return try await DirectPipeline.download(files: files,
                                                 options: request.options,
                                                 destinationDirectory: request.destinationDirectory,
                                                 baseName: request.baseName,
                                                 onProgress: onProgress)
    }
}

/// Official Channels sharing pages, authorized preview links and direct media.
public struct WeChatChannelsEngine: DownloadEngine {
    public let id = "wechat"
    public var displayName: String { "微信视频号" }

    private static let hosts = [
        "finder.video.qq.com", "mpvideo.qpic.cn", "wxapp.tc.qq.com",
        "res.wx.qq.com", "channels.weixin.qq.com"
    ]

    public init() {}

    public func canHandle(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        if host == "weixin.qq.com" { return url.path.hasPrefix("/sph/") }
        return Self.hosts.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    public func probe(url: URL, options: DownloadOptions) async throws -> MediaInfo {
        let host = url.host?.lowercased() ?? ""
        if (host == "weixin.qq.com" && url.path.hasPrefix("/sph/")) || host == "channels.weixin.qq.com" {
            return try await WeChatShare.probe(url)
        }
        if host == "weixin.qq.com" || host.hasSuffix(".weixin.qq.com") {
            throw EngineError.probeFailed("无法识别此视频号链接，请使用分享链接或 CDN 直链")
        }

        var headers = options.extraHeaders
        headers["Referer"] = options.referer ?? "https://channels.weixin.qq.com/"
        headers["User-Agent"] = options.userAgent ?? Self.mobileUserAgent
        headers["Accept"] = "*/*"
        if let cookie = options.cookieHeader, !cookie.isEmpty { headers["Cookie"] = cookie }

        var size: Int64?
        do {
            let result = try await HTTPProbe.probe(url: url, headers: headers)
            let type = result.contentType?.lowercased() ?? ""
            if type.contains("text/html") || type.contains("application/json") {
                throw EngineError.probeFailed("链接返回网页或错误信息，不是视频直链；请重新获取 CDN 地址")
            }
            size = result.contentLength
        } catch let error as EngineError {
            throw error
        } catch FetchError.badStatus(let status) where status == 401 || status == 403 || status == 404 {
            throw EngineError.probeFailed("视频地址不可访问（HTTP \(status)），请重新获取直链")
        } catch {
            if Task.isCancelled { throw CancellationError() }
            // Some CDNs reject range probes but allow full-body downloads.
        }

        let stamp = ISO8601DateFormatter().string(from: Date()).prefix(10)
        let title = "微信视频号 \(stamp)"
        let ext = url.pathExtension.isEmpty ? "mp4" : url.pathExtension.lowercased()
        let remote = RemoteFile(url: url, headers: headers, kind: .video,
                                fileExtension: ext, totalBytes: size)
        return MediaInfo(title: title, site: "微信视频号", files: [remote],
                         formats: [FormatOption(id: "source", label: "原始画质", ext: ext, filesize: size)],
                         selectedFormatID: "source", suggestedExtension: ext, engineID: id)
    }

    public func download(_ request: DownloadRequest,
                         onProgress: @escaping @Sendable (Int64, Int64) -> Void) async throws -> URL {
        let files = request.info.files(for: request.options.formatID)
        guard let media = files.first else { throw EngineError.emptyResult }
        let output = try MediaOutput(request)
        let local: URL
        if ["m3u8", "mpd"].contains(media.url.pathExtension.lowercased()) {
            var options = request.options
            options.formatID = nil
            options.cookieHeader = nil
            options.cookiesFromBrowser = ""
            options.referer = media.headers["Referer"]
            let engine = YTDLPEngine()
            let stream = try await engine.probeVideo(url: media.url, options: options)
            let child = DownloadRequest(info: stream, options: options, destinationDirectory: output.staging, baseName: "media")
            local = try await engine.download(child, onProgress: onProgress)
        } else {
            local = try await DirectPipeline.download(files: files, options: request.options, destinationDirectory: output.staging,
                                                      baseName: "media", onProgress: onProgress)
        }
        let type: AVMediaType = request.options.audioOnly ? .audio : .video
        let tracks = try? await AVURLAsset(url: local).loadTracks(withMediaType: type)
        try Task.checkCancellation()
        guard tracks?.isEmpty == false else {
            try? FileManager.default.removeItem(at: local)
            throw EngineError.probeFailed("视频号返回的文件无法播放，请检查链接有效期或内容访问权限")
        }
        return try output.publish(file: local)
    }

    static let mobileUserAgent =
        "Mozilla/5.0 (iPhone; CPU iPhone OS 17_4 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148 MicroMessenger/8.0.49"
}
