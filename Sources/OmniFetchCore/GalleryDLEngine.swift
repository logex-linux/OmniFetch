import Foundation

/// Image posts and mixed-media galleries, including sites with no video extractor.
public struct GalleryDLEngine: DownloadEngine {
    public let id = "gallerydl"
    public var displayName: String { "gallery-dl 图集引擎" }

    public init() {}

    public func canHandle(_ url: URL) -> Bool {
        if url.isOn("bilibili.com") {
            return url.isOn("t.bilibili.com") || url.path.hasPrefix("/opus/") || url.path.hasPrefix("/read/") ||
                (url.isOn("space.bilibili.com") && ["article", "opus", "dynamic"].contains(url.lastPathComponent))
        }
        if (url.isOn("x.com") || url.isOn("twitter.com")) && url.path.contains("/video/") { return false }
        return SocialPlatform.match(url)?.preferGallery == true
    }

    public func probe(url: URL, options: DownloadOptions) async throws -> MediaInfo {
        if url.isOn("t.co") || (url.isOn("bilibili.com") && url.path.hasPrefix("/read/")) {
            let expanded = await HTTPClient.resolveRedirect(url)
            try Task.checkCancellation()
            if expanded != url, !expanded.isOn("t.co"),
               !(expanded.isOn("bilibili.com") && expanded.path.hasPrefix("/read/")),
               URL.mediaURL(expanded.absoluteString) != nil {
                var next = options
                let sameSite = url.isOn("t.co") ? expanded.isOn("x.com") || expanded.isOn("twitter.com") : expanded.isOn("bilibili.com")
                if !sameSite { next.cookieHeader = nil }
                return try await EngineRegistry.shared.engine(for: expanded).probe(url: expanded, options: next)
            }
        }
        let wantsVideo = options.audioOnly || options.formatID != nil
        if wantsVideo {
            do { return try await YTDLPEngine().probeVideo(url: url, options: options) }
            catch { try Task.checkCancellation(); if options.audioOnly { throw error } }
        }
        do {
            return try await probeGallery(url: url, options: options)
        } catch {
            try Task.checkCancellation()
            guard !wantsVideo else { throw error }
            let galleryError = error
            do {
                var info = try await YTDLPEngine().probeVideo(url: url, options: options)
                if url.isOn("x.com") || url.isOn("twitter.com") { info.extra["videoAttachmentsOnly"] = "true" }
                return info
            } catch {
                try Task.checkCancellation()
                throw EngineError.probeFailed([galleryError.localizedDescription, error.localizedDescription].joined(separator: "\n"))
            }
        }
    }

    private static let baseArguments = ["--config-ignore", "--no-input", "--http-timeout", "15", "-R", "1"]

    func probeGallery(url: URL, options: DownloadOptions) async throws -> MediaInfo {
        let binary = try await GalleryDLInstaller.ensureBinary()
        try Task.checkCancellation()
        let cookies = try ExternalCookies(options, url: url, settings: SettingsStore.load())
        defer { cookies.removeFile() }
        let args = Self.baseArguments + cookies.arguments + ["--range", "1", "--child-range", "1", "-j", "--", url.absoluteString]
        let result = try await Shell.run(binary.path, args, timeout: 55)
        try Task.checkCancellation()
        guard result.succeeded else {
            throw EngineError.probeFailed("gallery-dl " + YTDLPEngine.shortError(result.stderr))
        }
        return try Self.mediaInfo(Data(result.stdout.utf8), url: url)
    }

    static func mediaInfo(_ json: Data, url: URL) throws -> MediaInfo {
        guard let messages = try JSONSerialization.jsonObject(with: json) as? [[Any]] else { throw EngineError.emptyResult }
        for message in messages {
            // 2 introduces a directory, 3 is a file, and 6 delegates a URL to a child extractor.
            guard message.count >= 3, let type = message[0] as? Int, [3, 6].contains(type),
                  let media = message[1] as? String, !media.isEmpty, let fields = message[2] as? [String: Any] else { continue }
            let site = SocialPlatform.match(url)?.name ?? fields.str("category") ?? url.host ?? "图集"
            let title = [fields.str("title"), fields.str("content"), fields.str("description"),
                         fields.dict("status")?.str("text_raw"), fields.dict("caption")?.str("text"), fields.str("filename")]
                .compactMap { $0?.split(whereSeparator: \.isNewline).first.map(String.init) }
                .first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            return MediaInfo(title: title.map { String($0.prefix(160)) } ?? "\(site) · \(url.lastPathComponent)",
                             site: site, thumbnail: URL.mediaURL(fields.str("thumbnail"))?.absoluteString,
                             engineID: "gallerydl", selfDownloading: true,
                             extra: ["webpage": url.absoluteString, "kind": "gallery"])
        }
        throw EngineError.emptyResult
    }

    public func download(_ request: DownloadRequest,
                         onProgress: @escaping @Sendable (Int64, Int64) -> Void) async throws -> URL {
        guard let page = URL.mediaURL(request.info.extra["webpage"]) else { throw EngineError.emptyResult }
        guard !request.options.audioOnly else { throw EngineError.unsupported("图集仅支持保存原始媒体") }
        let binary = try await GalleryDLInstaller.ensureBinary()
        let output = try MediaOutput(request)
        let settings = SettingsStore.load()
        let cookies = try ExternalCookies(request.options, url: page, settings: settings)
        defer { cookies.removeFile() }
        var args = Self.baseArguments + cookies.arguments
        // The extractor's subdirectories preserve filenames across albums/profiles.
        args += ["-d", output.staging.path, "--Print", "after:OMNI_FILE {_path}", "--Print", "skip:OMNI_FILE {_path}"]
        if let limit = request.options.bandwidth ?? settings.bandwidthBytesPerSecond {
            args += ["--limit-rate", String(limit)]
        }
        args += ["--", page.absoluteString]
        let process = StreamingProcess(executable: binary.path, arguments: args)
        try Task.checkCancellation()
        try process.start()
        var saved = Set<URL>()
        var errorLine: String?
        await withTaskCancellationHandler {
            for await line in process.lines() {
                if line.hasPrefix("OMNI_FILE "), let file = output.completedFile(at: String(line.dropFirst(10))),
                   saved.insert(file.resolvingSymlinksInPath()).inserted {
                    onProgress(Int64(saved.count), 0)
                } else if line.lowercased().contains("error") {
                    errorLine = YTDLPEngine.shortError(line)
                }
            }
        } onCancel: { process.terminate() }
        let code = await process.waitUntilExit()
        try Task.checkCancellation()
        guard code == 0 else { throw EngineError.probeFailed(errorLine ?? "gallery-dl 退出码 \(code)") }
        guard !saved.isEmpty else { throw EngineError.emptyResult }
        let folder = try output.publishCollection(members: saved)
        let count = Int64(saved.count)
        onProgress(count, count)
        return folder
    }
}

public enum GalleryDLInstaller {
    private static let gate = InstallGate()

    public static func locate() -> URL? {
        let local = AppPaths.binDirectory.appendingPathComponent("gallery-dl")
        if FileManager.default.isExecutableFile(atPath: local.path) { return local }
        return Shell.which("gallery-dl").map { URL(fileURLWithPath: $0) }
    }

    public static func ensureBinary() async throws -> URL {
        if let existing = locate() { return existing }
        return try await gate.run {
            if let existing = locate() { return existing }
            guard let python = Shell.which("python3") else {
                throw EngineError.missingTool("gallery-dl（安装 Python 3 或 brew install gallery-dl）")
            }
            AppPaths.ensureDirectories()
            let runtime = AppPaths.binDirectory.appendingPathComponent("gallery-runtime-\(UUID())")
            let executable = runtime.appendingPathComponent("bin/gallery-dl")
            let link = AppPaths.binDirectory.appendingPathComponent("gallery-dl")
            let fm = FileManager.default
            do {
                let venv = try await Shell.run(python, ["-I", "-m", "venv", runtime.path], timeout: 90)
                guard venv.succeeded else { throw EngineError.missingTool("Python 3 venv 或 gallery-dl（brew install gallery-dl）") }
                let install = try await Shell.run(runtime.appendingPathComponent("bin/python").path,
                    ["-I", "-m", "pip", "--isolated", "--disable-pip-version-check", "install", "--no-input",
                     "--index-url", "https://pypi.org/simple", "gallery-dl[video]"], timeout: 180)
                guard install.succeeded, fm.isExecutableFile(atPath: executable.path) else {
                    throw EngineError.probeFailed("无法从 PyPI 安装 gallery-dl，请检查网络，或使用 brew install gallery-dl")
                }
                try fm.createSymbolicLink(at: link, withDestinationURL: executable)
                return link
            } catch {
                try? fm.removeItem(at: runtime)
                if let winner = locate() { return winner }
                throw error
            }
        }
    }
}
