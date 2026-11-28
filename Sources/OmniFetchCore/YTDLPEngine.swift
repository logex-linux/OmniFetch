import Foundation

/// Video, audio, playlists and streaming manifests supported by yt-dlp.
public struct YTDLPEngine: DownloadEngine {
    public let id = "ytdlp"
    public var displayName: String { "yt-dlp 通用引擎" }

    public init() {}

    private static let sortOrder = "res,fps,vcodec:h264,acodec:aac"

    public func canHandle(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https"
    }

    // MARK: - Probe

    public func probe(url: URL, options: DownloadOptions) async throws -> MediaInfo {
        do {
            return try await probeVideo(url: url, options: options)
        } catch {
            try Task.checkCancellation()
            let reason = error.localizedDescription.lowercased()
            let mismatch = ["unsupported url", "no video formats", "no video could be found", "no video found"]
            guard mismatch.contains(where: reason.contains), !options.audioOnly else { throw error }
            return try await GalleryDLEngine().probeGallery(url: url, options: options)
        }
    }

    func probeVideo(url: URL, options: DownloadOptions) async throws -> MediaInfo {
        let settings = SettingsStore.load()
        let binary = try await YTDLPInstaller.ensureBinary(settings: settings)
        let cookies = try ExternalCookies(options, url: url, settings: settings)
        defer { cookies.removeFile() }

        let best = Self.selector(quality: "best", audioOnly: false)
        let preferred = Self.selector(quality: options.quality, audioOnly: options.audioOnly)
        // Keep the preview available even when the requested height doesn't exist.
        let probeFormat = preferred == best ? best : "(\(preferred))/(\(best))"
        var args = ["--ignore-config", "-J", "--no-warnings", "--no-playlist", "--playlist-items", "1",
                    "-S", Self.sortOrder, "-f", probeFormat,
                    "--socket-timeout", "15", "--extractor-retries", "1"]
        if let referer = options.referer { args += ["--referer", referer] }
        if url.isOn("youtube.com"), url.path == "/playlist" { args.append("--flat-playlist") }
        args += cookies.arguments
        args += ["--", url.absoluteString]
        let result = try await Shell.run(binary.path, args, timeout: 90)
        try Task.checkCancellation()
        guard result.succeeded,
              let json = try? JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any] else {
            throw EngineError.probeFailed(Self.shortError(result.stderr))
        }
        var info = try Self.mediaInfo(json, url: url, options: options)
        if !info.isItemCollection, json["is_live"] as? Bool != true,
           !["is_live", "is_upcoming", "post_live"].contains(json.str("live_status") ?? ""),
           cookies.arguments.isEmpty, result.stdout.utf8.count <= 2 * 1024 * 1024 {
            info.extra["previewID"] = await VideoPreviewCache.shared.insert(Data(result.stdout.utf8))
        }
        return info
    }

    static func mediaInfo(_ json: [String: Any], url: URL, options: DownloadOptions) throws -> MediaInfo {
        let entries = json.array("entries") ?? []
        if ["playlist", "multi_video"].contains(json.str("_type") ?? "") {
            guard let first = entries.first else { throw EngineError.emptyResult }
            var extra = ["webpage": url.absoluteString, "kind": "playlist"]
            if let count = json.int("playlist_count"), count > 0 { extra["count"] = String(count) }
            return MediaInfo(title: json.str("title") ?? first.str("title") ?? "媒体合集",
                             site: SocialPlatform.match(url)?.name ?? json.str("extractor_key"),
                             thumbnail: json.str("thumbnail") ?? first.str("thumbnail"),
                             engineID: "ytdlp", selfDownloading: true, extra: extra)
        }

        let title = json.str("title") ?? json.str("fulltitle") ?? "未命名视频"
        let thumbnail = json.str("thumbnail")
        let duration = json["duration"] as? Double ?? json.int64("duration").map(Double.init)
        let extractor = json.str("extractor_key") ?? json.str("extractor") ?? "yt-dlp"
        let rawFormats = json.array("formats") ?? []
        guard !rawFormats.isEmpty || URL.mediaURL(json.str("url")) != nil else { throw EngineError.emptyResult }

        var formats: [FormatOption] = []
        for raw in rawFormats {
            guard let formatID = raw.str("format_id") else { continue }
            let vcodec = raw.str("vcodec") ?? "none"
            let acodec = raw.str("acodec") ?? "none"
            let height = raw.int("height")
            let ext = raw.str("ext") ?? "mp4"
            let size = raw.int64("filesize") ?? raw.int64("filesize_approx")
            if vcodec != "none" {
                let label = height.map { "\($0)p" } ?? (raw.str("resolution") ?? "视频")
                formats.append(FormatOption(id: formatID,
                                            label: "\(label) · \(ext)",
                                            ext: ext,
                                            height: height,
                                            filesize: size,
                                            includesAudio: acodec != "none",
                                            note: raw.str("format_note")))
            } else if acodec != "none" {
                formats.append(FormatOption(id: formatID,
                                            label: "音频 · \(ext)",
                                            ext: ext,
                                            filesize: size,
                                            isAudioOnly: true,
                                            note: raw.str("format_note")))
            }
        }
        formats.sort { ($0.height ?? 0) > ($1.height ?? 0) }

        let selector: String
        if let chosen = options.formatID, !chosen.isEmpty {
            selector = chosen
        } else {
            selector = Self.selector(quality: options.quality, audioOnly: options.audioOnly)
        }

        return MediaInfo(title: title,
                         site: extractor,
                         thumbnail: thumbnail,
                         duration: duration,
                         files: [],
                         formats: formats,
                         selectedFormatID: options.formatID,
                         suggestedExtension: "mp4",
                         engineID: "ytdlp",
                         selfDownloading: true,
                         extra: ["formatSelector": selector,
                                 "webpage": url.absoluteString])
    }

    // MARK: - Download

    public func download(_ request: DownloadRequest,
                         onProgress: @escaping @Sendable (Int64, Int64) -> Void) async throws -> URL {
        let settings = SettingsStore.load()
        let binary = try await YTDLPInstaller.ensureBinary(settings: settings)
        guard let page = URL.mediaURL(request.info.extra["webpage"]) else { throw EngineError.emptyResult }
        let output = try MediaOutput(request)
        let collection = request.info.isItemCollection
        let cookies = try ExternalCookies(request.options, url: page, settings: settings)
        defer { cookies.removeFile() }
        let staged = try FileManager.default.contentsOfDirectory(atPath: output.staging.path)
        let externalPartial = staged.contains { $0.hasPrefix("media.") }
        var preview = cookies.arguments.isEmpty ? await VideoPreviewCache.shared.get(request.info.extra["previewID"]) : nil
        if preview == nil, cookies.arguments.isEmpty, !externalPartial, !collection, !request.options.audioOnly,
           staged.contains(where: { $0.hasPrefix(".omnifetch-") && $0.hasSuffix(".part") }) {
            let refreshed = try await probeVideo(url: page, options: request.options)
            preview = await VideoPreviewCache.shared.get(refreshed.extra["previewID"])
        }
        if !externalPartial, let preview, let files = Self.parallelHTTPFiles(preview, request: request) {
            var options = request.options
            options.bandwidth = options.bandwidth ?? settings.bandwidthBytesPerSecond
            do {
                let file = try await DirectPipeline.download(files: files, options: options, destinationDirectory: output.staging,
                                                             baseName: "native", onProgress: onProgress)
                try Task.checkCancellation()
                return try output.publish(file: file)
            } catch let error as FetchError {
                try Task.checkCancellation()
                switch error {
                case .rangeUnsupported, .unexpectedContent, .emptyFile: break
                case .badStatus(let code) where code >= 500: break
                default: throw error
                }
                // Keep the extractor's own transport available for incompatible responses.
            }
        }
        let directory = output.staging.path.replacingOccurrences(of: "%", with: "%%")
        let template = collection ? "%(playlist_index)05d-%(id)s.%(ext)s" : "media.%(ext)s"
        var args = [
            "--ignore-config", "-f", Self.selector(for: request),
            collection ? "--yes-playlist" : "--no-playlist",
            "--newline", "--no-mtime", "--continue", "--no-simulate", "--progress",
            "--abort-on-error", "--abort-on-unavailable-fragments",
            "--print", "after_move:OMNI_FILE %(filepath)s",
            "--progress-template",
            "OMNI %(progress.downloaded_bytes)s|%(progress.total_bytes)s|%(progress.total_bytes_estimate)s|%(progress.speed)s|%(progress.eta)s",
            "--concurrent-fragments", "\(request.options.connectionLimit)",
            "-S", Self.sortOrder,
            "--buffer-size", "1M", "--http-chunk-size", "10M", "--retries", "10",
            "--fragment-retries", "10", "--socket-timeout", "20", "-o", directory + "/" + template
        ]
        if let ffmpeg = MediaMerger.ffmpegPath(settings: settings) { args += ["--ffmpeg-location", ffmpeg] }
        if request.options.audioOnly {
            args += ["-x", "--audio-format", "m4a", "--audio-quality", "0"]
        } else {
            args += ["--merge-output-format", "mp4"]
        }
        if let limit = request.options.bandwidth ?? settings.bandwidthBytesPerSecond {
            args += ["--limit-rate", "\(limit)"]
        }
        if let referer = request.options.referer { args += ["--referer", referer] }
        args += cookies.arguments
        if preview != nil { args += ["--load-info-json", "-"] }
        else { args += ["--", page.absoluteString] }

        let process = StreamingProcess(executable: binary.path, arguments: args, input: preview)
        try Task.checkCancellation()
        try process.start()
        var finalFile: URL?
        var members = Set<URL>()
        let count = request.info.extra["count"].flatMap(Int64.init) ?? 0
        var lastError: String?
        await withTaskCancellationHandler {
            for await line in process.lines() {
                if line.hasPrefix("OMNI_FILE "), let file = output.completedFile(at: String(line.dropFirst(10))) {
                    finalFile = file
                    if collection, members.insert(file.resolvingSymlinksInPath()).inserted { onProgress(Int64(members.count), count) }
                } else if !collection && line.hasPrefix("OMNI ") {
                    Self.handleProgress(line, onProgress)
                } else if line.contains("ERROR:") {
                    lastError = Self.shortError(line)
                }
            }
        } onCancel: { process.terminate() }
        let code = await process.waitUntilExit()
        try Task.checkCancellation()
        guard code == 0 else { throw EngineError.probeFailed(lastError ?? "yt-dlp 退出码 \(code)") }
        guard let finalFile else { throw EngineError.emptyResult }
        if collection {
            let folder = try output.publishCollection(members: members)
            onProgress(Int64(members.count), Int64(members.count))
            return folder
        }
        return try output.publish(file: finalFile)
    }

    // MARK: - Helpers

    /// yt-dlp's fragment concurrency applies to manifests. A plain HTTP format
    /// in a fresh preview can use the same verified ranges as a native video.
    static func parallelHTTPFiles(_ preview: Data, request: DownloadRequest) -> [RemoteFile]? {
        let options = request.options
        guard !options.audioOnly, !request.info.isItemCollection, options.referer == nil,
              options.extraHeaders.isEmpty, options.userAgent == nil,
              let info = try? JSONSerialization.jsonObject(with: preview) as? [String: Any],
              ["Youtube", "Generic", "HTML5MediaEmbed"].contains(info.str("extractor_key") ?? ""),
              info["is_live"] as? Bool != true, info.str("live_status").map({ $0 == "not_live" || $0 == "was_live" }) ?? true,
              (info.str("_type") ?? "video") == "video",
              ["section_start", "section_end", "requested_ranges", "__postprocessors"].allSatisfy({ info[$0] == nil || info[$0] is NSNull }),
              info.str("availability").map({ ["public", "unlisted"].contains($0) }) ?? true,
              canTransferDirectly(info) else { return nil }

        let formats: [[String: Any]]
        if let id = options.formatID {
            // Selecting a video-only ID also selects an audio track in yt-dlp.
            guard let format = info.array("formats")?.first(where: { $0.str("format_id") == id }),
                  let audio = format.str("acodec"), audio != "none" else { return nil }
            formats = [format]
        } else {
            guard request.info.extra["formatSelector"] == Self.selector(quality: options.quality, audioOnly: false) else { return nil }
            formats = info.array("requested_formats") ?? [info]
            if let height = Quality.targetHeight(options.quality),
               formats.contains(where: { ($0.int("height") ?? 0) > height }) { return nil }
        }
        guard (1...2).contains(formats.count) else { return nil }

        var files: [RemoteFile] = []
        for format in formats {
            guard ["http", "https"].contains(format.str("protocol") ?? ""),
                  let url = URL.mediaURL(format.str("url")), let size = format.int64("filesize"), size > 0,
                  canTransferDirectly(format) else { return nil }
            let audio = format.str("vcodec") == "none"
            let ext = audio ? "m4a" : "mp4"
            guard format.str("ext") == ext else { return nil }
            let headers = format["http_headers"] as? [String: String] ?? info["http_headers"] as? [String: String] ?? [:]
            let transport = format.dict("downloader_options") ?? [:]
            guard transport.keys.allSatisfy({ $0 == "http_chunk_size" }) else { return nil }
            var file = RemoteFile(url: url, headers: headers.filter { $0.key.lowercased() != "accept-encoding" },
                                  kind: audio ? .audio : .video, fileExtension: ext, totalBytes: size)
            if !transport.isEmpty {
                guard let limit = transport.int64("http_chunk_size"), limit > 0 else { return nil }
                file.maxRangeBytes = limit
            }
            files.append(file)
        }
        guard files.filter({ $0.kind == .video }).count == 1,
              files.contains(where: { FileFetcher.parallelism(for: $0.totalBytes ?? 0, connections: 16) > 1 }) else { return nil }
        return files
    }

    private static func canTransferDirectly(_ format: [String: Any]) -> Bool {
        let special = ["fragments", "manifest_url", "request_data", "impersonate"]
        let drm = format["has_drm"]
        let available = (format["available_at"] as? NSNumber)?.doubleValue ?? 0
        let headers = format["http_headers"] as? [String: String] ?? [:]
        let unsupported = ["cookie", "authorization", "proxy-authorization", "range"]
        return (drm == nil || drm is NSNull || drm as? Bool == false)
            && special.allSatisfy { format[$0] == nil || format[$0] is NSNull }
            && !headers.keys.contains { unsupported.contains($0.lowercased()) }
            && ((format["stretched_ratio"] as? NSNumber)?.doubleValue ?? 1) == 1
            && (format.str("cookies") ?? "").isEmpty && available <= Date().timeIntervalSince1970
    }

    /// Builds the selector from the current download options instead of the
    /// one frozen at probe time, so changing quality/format still applies.
    static func selector(for request: DownloadRequest) -> String {
        let options = request.options
        if !request.info.isItemCollection, let chosen = options.formatID, !chosen.isEmpty {
            if options.audioOnly {
                return request.info.formats.contains { $0.id == chosen && $0.isAudioOnly } ? chosen : "ba/b"
            }
            if request.info.formats.first(where: { $0.id == chosen })?.includesAudio == true {
                return chosen
            }
            return "\(chosen)+ba/\(chosen)"
        }
        return selector(quality: options.quality, audioOnly: options.audioOnly)
    }

    static func selector(quality: String, audioOnly: Bool) -> String {
        if audioOnly { return "ba/b" }
        if let height = Quality.targetHeight(quality) {
            return "bv*[height<=?\(height)]+ba/b[height<=?\(height)]/bv*[height<=?\(height)]/ba"
        }
        return "bv*+ba/b/bv*/ba"
    }

    static func handleProgress(_ line: String, _ onProgress: @Sendable (Int64, Int64) -> Void) {
        let body = line.dropFirst(5)
        let parts = body.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 5 else { return }
        let downloaded = Int64(parts[0]) ?? 0
        let total = Int64(parts[1]) ?? Int64(parts[2]) ?? 0
        onProgress(downloaded, total)
    }

    static func shortError(_ stderr: String) -> String {
        let clean = stderr.replacingOccurrences(of: #"https?://[^\s\])]+"#, with: "[链接]", options: .regularExpression)
        let lines = clean.split(separator: "\n").filter { $0.contains("ERROR") }
        return lines.suffix(2).joined(separator: " ").isEmpty
            ? String(clean.suffix(300))
            : String(lines.suffix(2).joined(separator: " ").prefix(400))
    }
}

/// Fresh anonymous single-video previews can feed yt-dlp directly on stdin.
private actor VideoPreviewCache {
    static let shared = VideoPreviewCache()
    private var entries: [(id: String, expiry: TimeInterval, json: Data)] = []

    func insert(_ json: Data) -> String {
        let now = ProcessInfo.processInfo.systemUptime
        entries.removeAll { $0.expiry <= now }
        if entries.count == 8 { entries.removeFirst() }
        let id = UUID().uuidString
        entries.append((id, now + 90, json))
        return id
    }

    func get(_ id: String?) -> Data? {
        let now = ProcessInfo.processInfo.systemUptime
        entries.removeAll { $0.expiry <= now }
        return entries.first { $0.id == id }?.json
    }
}

// MARK: - Binary management

public enum YTDLPInstaller {
    public static func locate(settings: AppSettings = SettingsStore.load()) -> URL? {
        let fm = FileManager.default
        var candidates: [String] = []
        if !settings.ytdlpPath.isEmpty { candidates.append(settings.ytdlpPath) }
        candidates.append(AppPaths.binDirectory.appendingPathComponent("yt-dlp").path)
        if let which = Shell.which("yt-dlp") { candidates.append(which) }
        candidates.append("/opt/homebrew/bin/yt-dlp")
        candidates.append("/usr/local/bin/yt-dlp")
        for path in candidates where fm.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        return nil
    }

    public static func ensureBinary(settings: AppSettings = SettingsStore.load()) async throws -> URL {
        if let existing = locate(settings: settings) { return existing }
        return try await install()
    }

    public static func install() async throws -> URL {
        // Two tasks can start at once (queue + settings button); keep one install.
        try await InstallGate.shared.run { try await performInstall() }
    }

    private static func performInstall() async throws -> URL {
        AppPaths.ensureDirectories()
        let url = URL(string: "https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp_macos")!
        let destination = AppPaths.binDirectory.appendingPathComponent("yt-dlp")
        Log.write("installing yt-dlp from \(url.absoluteString)")
        let (temp, response) = try await HTTPClient.session.download(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw EngineError.probeFailed("yt-dlp 下载失败")
        }
        let size = (try? FileManager.default.attributesOfItem(atPath: temp.path)[.size] as? NSNumber)??.int64Value ?? 0
        guard size > 1_000_000 else {
            try? FileManager.default.removeItem(at: temp)
            throw EngineError.probeFailed("yt-dlp 下载不完整（\(size) 字节）")
        }
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: temp, to: destination)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: destination.path)
        return destination
    }

    public static func version(binary: URL) async -> String? {
        guard let result = try? await Shell.run(binary.path, ["--version"], timeout: 20),
              result.succeeded else { return nil }
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// The extractor processes need a Netscape cookie file. Isolate each invocation
/// (including concurrent requests for the same host) and unlink it on exit.
struct ExternalCookies {
    var arguments: [String] = []
    private var file: URL?

    init(_ options: DownloadOptions, url: URL, settings: AppSettings) throws {
        if let header = options.cookieHeader, !header.isEmpty, let host = url.host {
            var lines = ["# Netscape HTTP Cookie File"]
            for pair in header.split(separator: ";") {
                let parts = pair.trimmingCharacters(in: .whitespaces).split(separator: "=", maxSplits: 1,
                                                                            omittingEmptySubsequences: false)
                guard parts.count == 2, !parts[0].isEmpty,
                      pair.rangeOfCharacter(from: .controlCharacters) == nil else { continue }
                lines.append(["." + host, "TRUE", "/", "TRUE", "0", String(parts[0]), String(parts[1])].joined(separator: "\t"))
            }
            let target = FileManager.default.temporaryDirectory.appendingPathComponent("omnifetch-\(UUID()).cookies")
            guard FileManager.default.createFile(atPath: target.path, contents: Data(lines.joined(separator: "\n").utf8),
                                                 attributes: [.posixPermissions: 0o600]) else {
                throw CocoaError(.fileWriteNoPermission)
            }
            file = target
            arguments = ["--cookies", target.path]
        }
        let browser = options.cookiesFromBrowser ?? settings.cookiesFromBrowser
        if !browser.isEmpty { arguments += ["--cookies-from-browser", browser] }
    }

    func removeFile() { if let file { try? FileManager.default.removeItem(at: file) } }
}

actor InstallGate {
    static let shared = InstallGate()
    private var inFlight: Task<URL, Error>?

    func run(_ work: @escaping @Sendable () async throws -> URL) async throws -> URL {
        if let inFlight { return try await inFlight.value }
        let task = Task { try await work() }
        inFlight = task
        defer { inFlight = nil }
        return try await task.value
    }
}
