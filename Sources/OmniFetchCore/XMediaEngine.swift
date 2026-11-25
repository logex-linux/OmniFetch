import Foundation

/// Optional official X API lookup for posts whose photos and video variants
/// are visible to the configured app. The token never travels to a media CDN.
public struct XMediaEngine: DownloadEngine {
    public let id = "xapi"
    public var displayName: String { "X 官方 API" }
    public init() {}

    private var bearer: String? {
        ProcessInfo.processInfo.environment["OMNIFETCH_X_BEARER_TOKEN"].flatMap { $0.isEmpty ? nil : $0 }
    }

    static func postID(_ url: URL) -> String? {
        guard url.isOn("x.com") || url.isOn("twitter.com") else { return nil }
        let p = url.pathComponents
        guard let i = p.firstIndex(where: { $0 == "status" || $0 == "statuses" }), i + 1 < p.count else { return nil }
        let id = p[i + 1]
        return !id.isEmpty && id.utf8.count <= 20 && id.utf8.allSatisfy { 48...57 ~= $0 } ? id : nil
    }

    public func canHandle(_ url: URL) -> Bool { Self.postID(url) != nil && bearer != nil }

    public func probe(url: URL, options: DownloadOptions) async throws -> MediaInfo {
        guard let id = Self.postID(url), let token = bearer, !options.audioOnly else {
            return try await GalleryDLEngine().probe(url: url, options: options)
        }
        let api = URL(string: "https://api.x.com/2/tweets/\(id)?expansions=attachments.media_keys&media.fields=type,url,variants,preview_image_url")!
        var req = URLRequest(url: api)
        req.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 12
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        let session = URLSession(configuration: config, delegate: NoRedirect(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        do {
            let (data, response) = try await session.data(for: req)
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw EngineError.probeFailed("X API 未返回帖子媒体")
            }
            return try Self.mediaInfo(json, page: url, options: options)
        } catch {
            try Task.checkCancellation()
            return try await GalleryDLEngine().probe(url: url, options: options)
        }
    }

    static func mediaInfo(_ json: [String: Any], page: URL, options: DownloadOptions) throws -> MediaInfo {
        guard let post = json.dict("data"), post.str("id") == postID(page),
              var keys = post.dict("attachments")?["media_keys"] as? [String], !keys.isEmpty,
              let media = json.dict("includes")?.array("media") else { throw EngineError.emptyResult }
        let p = page.pathComponents
        if p.count >= 2, ["photo", "video"].contains(p[p.count - 2]), let index = Int(p.last ?? "") {
            guard index > 0 && index <= keys.count else { throw EngineError.emptyResult }
            keys = [keys[index - 1]]
        }
        var files: [RemoteFile] = []
        var formats: [FormatOption] = []
        var variants: [String: RemoteFile] = [:]
        var selected: String?
        var thumbnail: String?
        for key in keys {
            guard let item = media.first(where: { $0.str("media_key") == key }) else { throw EngineError.emptyResult }
            if item.str("type") == "photo", let url = URL.mediaURL(item.str("url")) {
                let ext = url.pathExtension.lowercased()
                files.append(RemoteFile(url: url, kind: .image, fileExtension: ["jpg","jpeg","png","webp"].contains(ext) ? ext : "jpg"))
                thumbnail = thumbnail ?? url.absoluteString
                continue
            }
            let choices = (item.array("variants") ?? []).compactMap { entry -> (URL, Int, Int)? in
                guard entry.str("content_type") == "video/mp4", let url = URL.mediaURL(entry.str("url")) else { return nil }
                let dims = url.path.split(separator: "/").first { part in
                    part.range(of: #"^[0-9]+x[0-9]+$"#, options: .regularExpression) != nil
                }
                let height = dims?.split(separator: "x").last.flatMap { Int($0) } ?? 0
                return (url, height, entry.int("bit_rate") ?? 0)
            }.sorted { $0.2 > $1.2 }
            guard !choices.isEmpty else { throw EngineError.emptyResult }
            let cap = Quality.targetHeight(options.quality)
            let pick = choices.firstIndex { value in cap.map { value.1 > 0 && value.1 <= $0 } ?? true } ?? choices.count - 1
            files.append(RemoteFile(url: choices[pick].0))
            thumbnail = thumbnail ?? item.str("preview_image_url")
            if keys.count == 1 {
                for (i, value) in choices.enumerated() {
                    let id = "mp4-\(i)", height = value.1 > 0 ? value.1 : nil
                    formats.append(FormatOption(id: id, label: height.map { "\($0)p" } ?? "\(value.2 / 1000) kb/s",
                                                ext: "mp4", height: height, includesAudio: item.str("type") == "video"))
                    variants[id] = RemoteFile(url: value.0)
                }
                selected = formats.contains { $0.id == options.formatID } ? options.formatID : formats[pick].id
            }
        }
        let title = post.str("text")?.split(whereSeparator: \.isNewline).first.map { String($0.prefix(120)) } ?? "X 帖子"
        let album = files.count > 1 || files.first?.kind == .image
        var extra = ["webpage": page.absoluteString]
        if album { extra["kind"] = "attachments"; extra["count"] = String(files.count) }
        var info = MediaInfo(title: title, site: "X / Twitter", thumbnail: thumbnail, files: files,
                             formats: formats, selectedFormatID: selected, engineID: "xapi", extra: extra)
        if !variants.isEmpty {
            info.videoVariants = variants
            info.files = info.files(for: selected)
        }
        return info
    }

    public func download(_ request: DownloadRequest,
                         onProgress: @escaping @Sendable (Int64, Int64) -> Void) async throws -> URL {
        if request.info.isItemCollection { return try await NativeAlbum.download(request, onProgress: onProgress) }
        return try await DirectMediaEngine().download(request, onProgress: onProgress)
    }
}
