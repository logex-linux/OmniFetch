import Foundation

/// Native Xiaohongshu (小红书) support: parse the note page's
/// `window.__INITIAL_STATE__` payload (same source XHS-Downloader uses),
/// then fetch the CDN video with the required Referer.
public struct XiaohongshuEngine: DownloadEngine {
    public let id = "xiaohongshu"
    public var displayName: String { "小红书" }

    public init() {}

    public func canHandle(_ url: URL) -> Bool {
        url.isOn("xiaohongshu.com") || url.isOn("xhslink.com")
    }

    public func probe(url: URL, options: DownloadOptions) async throws -> MediaInfo {
        if options.useXHSAppSession == true {
            let loader = await NoteWebPage()
            var page = url
            if page.scheme?.lowercased() == "http", var components = URLComponents(url: page, resolvingAgainstBaseURL: false) {
                components.scheme = "https"
                page = components.url ?? page
            }
            let (json, canonical) = try await loader.read(page)
            return try Self.mediaInfo(Data(json.utf8), noteID: Self.noteID(from: url) ?? Self.noteID(from: canonical),
                                      page: canonical, options: options)
        }
        do {
            return try await probeNative(url: url, options: options)
        } catch let error as EngineError {
            try Task.checkCancellation()
            if case .unavailable = error { throw error }
            return try await Self.fallbackProbe(url: url, options: options,
                                                reason: error.localizedDescription)
        } catch {
            try Task.checkCancellation()
            return try await Self.fallbackProbe(url: url, options: options,
                                                reason: error.localizedDescription)
        }
    }

    private static func fallbackProbe(url: URL, options: DownloadOptions,
                                      reason: String) async throws -> MediaInfo {
        Log.write("XHS native note data unavailable; trying video extractor")
        do {
            return try await YTDLPEngine().probeVideo(url: url, options: options)
        } catch {
            try Task.checkCancellation()
            // Both paths failed; the usual cause is a login wall, so point at
            // the cookie setting instead of dumping the yt-dlp error alone.
            throw EngineError.unavailable("\(reason)。可使用高级选项中的小红书登录状态重试")
        }
    }

    private func probeNative(url: URL, options: DownloadOptions) async throws -> MediaInfo {
        var target = url
        if url.isOn("xhslink.com"), options.cookieHeader?.isEmpty == false {
            target = await HTTPClient.resolveRedirect(url)
            guard target.isOn("xiaohongshu.com") else { throw EngineError.probeFailed("笔记分享链接未指向小红书") }
        }
        var headers = [
            "User-Agent": FetchHeaders.desktopUA,
            "Referer": "https://www.xiaohongshu.com/",
            "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
            "Accept-Language": "zh-CN,zh;q=0.9"
        ]
        if let cookie = options.cookieHeader, !cookie.isEmpty { headers["Cookie"] = cookie }

        let (data, http) = try await HTTPClient.data(url: target, headers: headers)
        guard http.statusCode < 400, let html = String(data: data, encoding: .utf8) else {
            throw EngineError.probeFailed("页面请求失败 HTTP \(http.statusCode)")
        }

        let page = http.url ?? target
        guard page.isOn("xiaohongshu.com") else { throw EngineError.probeFailed("笔记分享链接无效或已过期") }
        if let error = Self.accessError(page), options.cookiesFromBrowser?.isEmpty != false { throw error }
        // Login redirects may carry an unrelated default note. Retain the requested ID.
        return try Self.parsePage(html, noteID: Self.noteID(from: target) ?? Self.noteID(from: page),
                                  page: target, options: options)
    }

    static func accessError(_ url: URL) -> EngineError? {
        if url.path.hasPrefix("/login") { return .unavailable("这篇笔记需要登录小红书，请在高级选项中登录后重试") }
        if url.path == "/404" { return .unavailable("小红书未提供这篇笔记，请确认原始分享链接仍然有效") }
        return nil
    }

    static func parsePage(_ html: String, noteID: String?, page: URL, options: DownloadOptions) throws -> MediaInfo {
        guard let marker = html.range(of: #"window\.__INITIAL_STATE__\s*=\s*"#, options: .regularExpression),
              let objectText = balancedJSON(in: html[marker.upperBound...]) else {
            throw EngineError.probeFailed("未找到笔记数据，分享链接可能已过期或需要登录")
        }
        let jsonText = Self.replacingUndefined(objectText)
        return try mediaInfo(Data(jsonText.utf8), noteID: noteID, page: page, options: options)
    }

    static func mediaInfo(_ jsonData: Data, noteID: String?, page: URL, options: DownloadOptions) throws -> MediaInfo {
        guard let root = try JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
            throw EngineError.probeFailed("笔记 JSON 解析失败")
        }

        let map = root.dict("note")?.dict("noteDetailMap") ?? [:]
        let matched = noteID.flatMap { (map[$0] as? [String: Any])?.dict("note") }
        let candidates = map.values.compactMap { ($0 as? [String: Any])?.dict("note") }
        guard let note = matched ?? (noteID == nil && candidates.count == 1 ? candidates.first :
            candidates.first { noteID != nil && $0.str("noteId") == noteID }) else {
            throw EngineError.probeFailed("页面未返回这篇笔记，请检查分享链接与登录状态")
        }
        let title = [note.str("title"), note.str("desc")].compactMap { $0?.split(whereSeparator: \.isNewline).first }
            .first.map(String.init) ?? "小红书笔记"
        let headers = ["Referer": "https://www.xiaohongshu.com/", "User-Agent": FetchHeaders.desktopUA]
        let images = note.array("imageList") ?? []
        let cover = images.first.flatMap { imageFiles(from: [$0], headers: headers).first?.url.absoluteString }
        let video = note.dict("video") ?? [:]
        var choices = streamChoices(video.dict("media")?.dict("stream"), headers: headers)
        if choices.isEmpty, let key = video.dict("consumer")?.str("originVideoKey"), !key.isEmpty,
           let url = URL.mediaURL("https://sns-video-bd.xhscdn.com/" + key) {
            choices = [(FormatOption(id: "source", label: "原始画质", ext: "mp4", includesAudio: true),
                        RemoteFile(url: url, headers: headers))]
        }
        var extra = ["webpage": page.absoluteString, "noteID": noteID ?? note.str("noteId") ?? ""]
        if !choices.isEmpty {
            let cap = Quality.targetHeight(options.quality) ?? Int.max
            let selected = choices.first { $0.format.id == options.formatID }
                ?? choices.first { ($0.format.height ?? 0) <= cap } ?? choices[choices.count - 1]
            var info = MediaInfo(title: title, site: "小红书", thumbnail: cover, files: [selected.file],
                                 formats: choices.map(\.format), selectedFormatID: selected.format.id,
                                 engineID: "xiaohongshu", extra: extra)
            info.videoVariants = Dictionary(uniqueKeysWithValues: choices.map { ($0.format.id, $0.file) })
            return info
        }
        // A video note can expose only its poster when the video is unavailable.
        guard note.str("type") != "video", video.isEmpty || note.str("type") == "normal" else {
            throw EngineError.probeFailed("该笔记没有返回可下载的视频")
        }
        let files = imageFiles(from: images, headers: headers)
        guard !files.isEmpty else { throw EngineError.probeFailed("该笔记没有返回可用的图片或视频") }
        extra["kind"] = "images"
        return MediaInfo(title: title, site: "小红书", thumbnail: cover, files: files,
                         formats: [FormatOption(id: "images", label: "图文 \(files.count) 项", ext: "jpg")],
                         selectedFormatID: "images", suggestedExtension: "jpg", engineID: "xiaohongshu", extra: extra)
    }

    private static func streamChoices(_ stream: [String: Any]?, headers: [String: String])
        -> [(format: FormatOption, file: RemoteFile)] {
        var results: [(format: FormatOption, file: RemoteFile)] = []
        var seen = Set<URL>()
        for codec in ["h264", "h265", "av1"] {
            for (index, item) in (stream?.array(codec) ?? []).enumerated() {
                let backups = (item["backupUrls"] as? [String]) ?? []
                let urls = ([item.str("masterUrl") ?? ""] + backups).compactMap { URL.mediaURL($0) }
                guard let url = urls.first, seen.insert(url).inserted else { continue }
                let height = item.int("height")
                let label = height.map { "\($0)p · \(codec)" } ?? codec
                let id = "\(codec)-\(height ?? 0)-\(index)"
                let format = FormatOption(id: id, label: label, ext: "mp4", height: height,
                                          filesize: item.int64("size"), includesAudio: true)
                let file = RemoteFile(url: url, headers: headers, totalBytes: item.int64("size"),
                                      alternateURLs: Array(urls.dropFirst()))
                results.append((format, file))
            }
        }
        return results.sorted { ($0.format.height ?? 0) > ($1.format.height ?? 0) }
    }

    public func download(_ request: DownloadRequest,
                         onProgress: @escaping @Sendable (Int64, Int64) -> Void) async throws -> URL {
        if request.info.extra["kind"] == "images" {
            return try await NativeAlbum.download(request, onProgress: onProgress)
        }
        return try await DirectPipeline.download(files: request.info.files(for: request.options.formatID),
                                                 options: request.options,
                                                 destinationDirectory: request.destinationDirectory,
                                                 baseName: request.baseName,
                                                 onProgress: onProgress)
    }

    static func imageFiles(from imageList: [[String: Any]],
                           headers: [String: String]) -> [RemoteFile] {
        var files: [RemoteFile] = []
        for item in imageList {
            let info = item.array("infoList") ?? []
            let preferred = info.filter { $0.str("imageScene") == "WB_DFT" }
            let candidates = [item.str("urlDefault")] + (preferred + info).map { $0.str("url") }
                + [item.str("url"), item.str("urlPre")]
            let urls = candidates.compactMap { URL.mediaURL($0) }
            if let url = urls.first {
                let rawExt = url.pathExtension.lowercased()
                let ext = ["jpg", "jpeg", "png", "webp", "avif", "gif", "heic"].contains(rawExt) ? rawExt : "jpg"
                files.append(RemoteFile(url: url, headers: headers, kind: .image, fileExtension: ext,
                                        alternateURLs: Array(urls.dropFirst().filter { $0 != url })))
            }
            if let motion = streamChoices(item.dict("stream"), headers: headers).first {
                files.append(motion.file)
            }
        }
        return files
    }

    /// Returns the first complete `{…}` object in `text`, ignoring braces that
    /// appear inside string literals.
    static func balancedJSON(in text: Substring) -> String? {
        guard let start = text.firstIndex(of: "{") else { return nil }
        var depth = 0
        var inString = false
        var escaped = false
        var index = start
        while index < text.endIndex {
            let char = text[index]
            if inString {
                if escaped { escaped = false }
                else if char == "\\" { escaped = true }
                else if char == "\"" { inString = false }
            } else if char == "\"" {
                inString = true
            } else if char == "{" {
                depth += 1
            } else if char == "}" {
                depth -= 1
                if depth == 0 { return String(text[start...index]) }
            }
            index = text.index(after: index)
        }
        return nil
    }

    /// `undefined` is not JSON, but only outside strings — a note title may
    /// legitimately contain the word.
    static func replacingUndefined(_ json: String) -> String {
        let bytes = Array(json.utf8), word = Array("undefined".utf8)
        var output: [UInt8] = []
        output.reserveCapacity(bytes.count)
        var inside = false, escaped = false, i = 0
        while i < bytes.count {
            let byte = bytes[i]
            if inside {
                if escaped { escaped = false }
                else if byte == 92 { escaped = true }
                else if byte == 34 { inside = false }
            } else if byte == 34 { inside = true }
            else if byte == 117, bytes[i...].starts(with: word) {
                output += "null".utf8
                i += word.count
                continue
            }
            output.append(byte)
            i += 1
        }
        return String(decoding: output, as: UTF8.self)
    }

    static func noteID(from url: URL) -> String? {
        let parts = url.path.split(separator: "/").map(String.init)
        if let index = parts.firstIndex(where: { $0 == "explore" || $0 == "item" || $0 == "discovery" }),
           index + 1 < parts.count {
            let candidate = parts[index + 1]
            if candidate.count >= 16 { return candidate }
        }
        return parts.last(where: { $0.count >= 16 })
    }
}
