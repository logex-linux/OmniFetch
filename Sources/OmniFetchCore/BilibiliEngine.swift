import Foundation

/// Native Bilibili support modelled on 哔哩哔哩下载姬 (downkyi):
/// resolve BV/av id → view API → DASH playurl → parallel video+audio → remux.
public struct BilibiliEngine: DownloadEngine {
    public let id = "bilibili"
    public var displayName: String { "哔哩哔哩" }

    public init() {}

    public func canHandle(_ url: URL) -> Bool {
        if url.isOn("b23.tv") { return true }
        return url.isOn("bilibili.com") && (try? Self.parseIdentifier(url)) != nil
    }

    public func probe(url: URL, options: DownloadOptions) async throws -> MediaInfo {
        var target = url
        if url.isOn("b23.tv") {
            target = await HTTPClient.resolveRedirect(url)
            try Task.checkCancellation()
            if target.isOn("bilibili.com"), (try? Self.parseIdentifier(target)) == nil {
                return try await EngineRegistry.shared.engine(for: target).probe(url: target, options: options)
            }
            guard target.isOn("bilibili.com") else { throw EngineError.probeFailed("B 站短链没有指向可用的内容页") }
        }

        let identifier = try Self.parseIdentifier(target)
        let pageNumber = Self.pageNumber(from: target)
        let headers = Self.apiHeaders(options: options)

        let view = try await HTTPClient.json(
            url: URL(string: "https://api.bilibili.com/x/web-interface/view?\(identifier.query)")!,
            headers: headers
        )
        guard view.int("code") == 0, let data = view.dict("data") else {
            throw EngineError.probeFailed(view.str("message") ?? "视频信息获取失败")
        }

        let title = data.str("title") ?? "Bilibili 视频"
        let cover = data.str("pic")
        let pages = data.array("pages") ?? []
        let selectedPage: [String: Any]?
        if pageNumber > 1 {
            // Asking for a part that does not exist must not silently download
            // the first part instead.
            guard let match = pages.first(where: { $0.int("page") == pageNumber }) else {
                throw EngineError.probeFailed("该视频没有第 \(pageNumber) P")
            }
            selectedPage = match
        } else {
            selectedPage = pages.first
        }
        let cid = selectedPage?.int("cid") ?? data.int("cid") ?? 0
        guard cid > 0 else { throw EngineError.probeFailed("未找到 cid") }

        let partTitle = selectedPage?.str("part") ?? ""
        let displayTitle = pages.count > 1 && !partTitle.isEmpty ? "\(title) - \(partTitle)" : title

        let play = try await HTTPClient.json(
            url: URL(string: "https://api.bilibili.com/x/player/playurl?\(identifier.query)&cid=\(cid)&qn=127&fnval=4048&fnver=0&fourk=1")!,
            headers: headers
        )
        guard play.int("code") == 0, let playData = play.dict("data") else {
            throw EngineError.probeFailed(play.str("message") ?? "播放地址获取失败")
        }

        var formats: [FormatOption] = []
        var files: [RemoteFile] = []
        var selectedFormat: FormatOption?

        var variants: [String: RemoteFile] = [:]
        if let dash = playData.dict("dash"), let videos = dash.array("video"), !videos.isEmpty {
            let headers = Self.mediaHeaders()
            let renditions = Self.renditions(videos, headers: headers)
            formats = renditions.map(\.format)
            for rendition in renditions { variants[rendition.format.id] = rendition.file }
            let cap = options.formatID.flatMap(Int.init) ?? Quality.targetHeight(options.quality) ?? Int.max
            guard let selected = renditions.first(where: { ($0.format.height ?? 0) <= cap }) ?? renditions.last else {
                throw EngineError.emptyResult
            }
            selectedFormat = selected.format
            files = [selected.file]
            if let audio = (dash.array("audio") ?? []).sorted(by: {
                ($0.int64("bandwidth") ?? 0) > ($1.int64("bandwidth") ?? 0)
            }).first(where: { URL.mediaURL($0.str("baseUrl") ?? $0.str("base_url")) != nil }),
               let audioURL = URL.mediaURL(audio.str("baseUrl") ?? audio.str("base_url")) {
                files.append(RemoteFile(url: audioURL, headers: headers, kind: .audio, fileExtension: "m4a",
                                        alternateURLs: Self.backupURLs(audio)))
            }
        } else if let durl = playData.array("durl"), let first = durl.first {
            if durl.count > 1 {
                // yt-dlp assembles all legacy segments and keeps the selected part.
                return try await YTDLPEngine().probe(url: target, options: options)
            }
            let mediaHeaders = Self.mediaHeaders()
            let videoURL = first.str("url") ?? first.str("base_url") ?? ""
            guard let vURL = URL.mediaURL(videoURL) else { throw EngineError.emptyResult }
            let size = first.int64("size")
            files = [RemoteFile(url: vURL, headers: mediaHeaders, kind: .video,
                                fileExtension: "mp4", totalBytes: size)]
            formats = [FormatOption(id: "source", label: "原始画质", ext: "mp4", filesize: size)]
            selectedFormat = formats.first
        }

        guard !files.isEmpty else { throw EngineError.emptyResult }

        var info = MediaInfo(title: displayTitle,
                         site: "哔哩哔哩",
                         thumbnail: cover,
                         duration: Double(selectedPage?.int("duration") ?? data.int("duration") ?? 0),
                         files: files,
                         formats: formats,
                         selectedFormatID: selectedFormat?.id,
                         suggestedExtension: "mp4",
                         engineID: id,
                         parts: Self.parts(from: pages),
                         extra: ["bvid": identifier.query, "cid": "\(cid)",
                                 "webpage": identifier.webpage, "page": String(pageNumber)])
        info.videoVariants = variants.isEmpty ? nil : variants
        return info
    }

    public func download(_ request: DownloadRequest,
                         onProgress: @escaping @Sendable (Int64, Int64) -> Void) async throws -> URL {
        var info = request.info
        if let pick = request.options.formatID, pick != info.selectedFormatID, info.videoVariants == nil,
           let base = info.extra["webpage"], let part = info.extra["page"].flatMap(Int.init),
           let url = Self.partURL(base: base, page: part) {
            info = try await probe(url: url, options: request.options)
        }
        var files = info.files(for: request.options.formatID)
        let mediaHeaders = Self.mediaHeaders()
        for index in files.indices {
            files[index].headers.merge(mediaHeaders) { current, _ in current }
        }
        return try await DirectPipeline.download(files: files,
                                                 options: request.options,
                                                 destinationDirectory: request.destinationDirectory,
                                                 baseName: request.baseName,
                                                 sourceID: info.extra["cid"],
                                                 onProgress: onProgress)
    }

    // MARK: - Helpers

    static func renditions(_ videos: [[String: Any]], headers: [String: String])
        -> [(format: FormatOption, file: RemoteFile)] {
        var byHeight: [Int: (format: FormatOption, file: RemoteFile, avc: Bool, rate: Int64)] = [:]
        for video in videos {
            guard let height = video.int("height"), height > 0,
                  let url = URL.mediaURL(video.str("baseUrl") ?? video.str("base_url")) else { continue }
            let codec = video.str("codecs") ?? ""
            let avc = codec.hasPrefix("avc")
            let rate = video.int64("bandwidth") ?? 0
            if let old = byHeight[height], old.avc != avc ? old.avc : old.rate >= rate { continue }
            let format = FormatOption(id: String(height), label: "\(height)P", ext: "mp4", height: height, note: codec)
            let file = RemoteFile(url: url, headers: headers, fileExtension: "mp4", alternateURLs: backupURLs(video))
            byHeight[height] = (format, file, avc, rate)
        }
        return byHeight.keys.sorted(by: >).compactMap { byHeight[$0].map { ($0.format, $0.file) } }
    }

    struct Identifier {
        var query: String    // bvid=BV1xx or aid=170001
        var webpage: String  // canonical video URL, without ?p=
    }

    static func parseIdentifier(_ url: URL) throws -> Identifier {
        let parts = url.pathComponents
        if let bvid = parts.first(where: { $0.range(of: "^BV[0-9A-Za-z]{10}$", options: .regularExpression) != nil }) {
            return Identifier(query: "bvid=" + bvid,
                              webpage: "https://www.bilibili.com/video/\(bvid)")
        }
        if let av = parts.first(where: { $0.range(of: "^av[0-9]+$", options: [.regularExpression, .caseInsensitive]) != nil }) {
            let aid = String(av.dropFirst(2))
            return Identifier(query: "aid=\(aid)",
                              webpage: "https://www.bilibili.com/video/av\(aid)")
        }
        throw EngineError.probeFailed("链接里没有 BV/av 号")
    }

    /// Extracts 分 P entries; returns nil for single-part videos.
    static func parts(from pages: [[String: Any]]) -> [MediaPart]? {
        let parts = pages.compactMap { page -> MediaPart? in
            guard let number = page.int("page") else { return nil }
            let duration = page.int("duration").map(Double.init)
            return MediaPart(index: number, title: page.str("part") ?? "", duration: duration)
        }.sorted { $0.index < $1.index }
        return parts.count > 1 ? parts : nil
    }

    /// Builds the URL of one part (分 P) from the canonical video URL.
    public static func partURL(base: String, page: Int) -> URL? {
        guard var components = URLComponents(string: base) else { return nil }
        var items = (components.queryItems ?? []).filter { $0.name != "p" }
        items.append(URLQueryItem(name: "p", value: "\(page)"))
        components.queryItems = items
        return components.url
    }

    static func pageNumber(from url: URL) -> Int {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let value = components.queryItems?.first(where: { $0.name == "p" })?.value,
              let number = Int(value) else { return 1 }
        return number
    }

    /// DASH entries carry 1–3 CDN backups; one of them usually survives a
    /// regional CDN hiccup or an expired signature.
    static func backupURLs(_ entry: [String: Any]) -> [URL]? {
        let raw = (entry["backupUrl"] as? [String]) ?? (entry["backup_url"] as? [String]) ?? []
        let urls = raw.compactMap { URL.mediaURL($0) }
        return urls.isEmpty ? nil : urls
    }

    static func apiHeaders(options: DownloadOptions) -> [String: String] {
        var headers = [
            "Referer": "https://www.bilibili.com/",
            "User-Agent": FetchHeaders.desktopUA,
            "Origin": "https://www.bilibili.com"
        ]
        if let cookie = options.cookieHeader, !cookie.isEmpty { headers["Cookie"] = cookie }
        return headers
    }

    static func mediaHeaders() -> [String: String] {
        [
            "Referer": "https://www.bilibili.com/",
            "User-Agent": FetchHeaders.desktopUA,
            "Accept": "*/*"
        ]
    }
}
