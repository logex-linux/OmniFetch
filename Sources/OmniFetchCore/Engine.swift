import Foundation

public struct DownloadRequest: Sendable {
    public var info: MediaInfo
    public var options: DownloadOptions
    public var destinationDirectory: URL
    public var baseName: String

    public init(info: MediaInfo, options: DownloadOptions, destinationDirectory: URL, baseName: String) {
        self.info = info
        self.options = options
        self.destinationDirectory = destinationDirectory
        self.baseName = baseName
    }
}

public protocol DownloadEngine: Sendable {
    var id: String { get }
    var displayName: String { get }
    func canHandle(_ url: URL) -> Bool
    func probe(url: URL, options: DownloadOptions) async throws -> MediaInfo
    func prepareDownload(url: URL, options: DownloadOptions) async throws -> MediaInfo
    func download(_ request: DownloadRequest,
                  onProgress: @escaping @Sendable (Int64, Int64) -> Void) async throws -> URL
}

public extension DownloadEngine {
    var displayName: String { id }

    func prepareDownload(url: URL, options: DownloadOptions) async throws -> MediaInfo {
        try await probe(url: url, options: options)
    }
}

public enum EngineError: LocalizedError {
    case unavailable(String)
    case unsupported(String)
    case probeFailed(String)
    case missingTool(String)
    case emptyResult

    public var errorDescription: String? {
        switch self {
        case .unavailable(let reason): return reason
        case .unsupported(let host): return "暂不支持该站点：\(host)"
        case .probeFailed(let reason): return "解析失败：\(reason)"
        case .missingTool(let name): return "缺少依赖：\(name)"
        case .emptyResult: return "没有解析到可下载的媒体"
        }
    }
}

public final class EngineRegistry: @unchecked Sendable {
    public static let shared = EngineRegistry()

    private let engines: [DownloadEngine]

    private init() {
        engines = [
            BilibiliEngine(),
            XiaohongshuEngine(),
            WeChatChannelsEngine(),
            DirectMediaEngine(),
            XMediaEngine(),
            GalleryDLEngine(),
            YTDLPEngine()
        ]
    }

    public func engine(for url: URL) -> DownloadEngine {
        engines.first { $0.canHandle(url) } ?? engines[engines.count - 1]
    }

    /// Resolves the engine that produced a probe result. Native engines fall
    /// back to yt-dlp, so the downloader can differ from the routed engine.
    public func engine(id: String) -> DownloadEngine? {
        engines.first { $0.id == id }
    }

    public var allEngines: [DownloadEngine] { engines }
}

// MARK: - Shared helpers

public enum MediaNaming {
    public static func sanitize(_ raw: String, maxLength: Int = 120) -> String {
        let banned = CharacterSet(charactersIn: "/\\:*?\"<>|\n\r\t")
        var name = raw.components(separatedBy: banned).joined(separator: " ")
        name = name.replacingOccurrences(of: " +", with: " ", options: .regularExpression)
        name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        // A leading dot would create a hidden file next to the media.
        name = name.trimmingCharacters(in: CharacterSet(charactersIn: "."))
        if name.isEmpty { name = "video-\(Int(Date().timeIntervalSince1970))" }
        // macOS file-name limits are in UTF-8 bytes, including collision suffixes and extensions.
        if name.count > maxLength { name = String(name.prefix(maxLength)) }
        while name.utf8.count > 208 { name.removeLast() }
        name = name.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
        return name.isEmpty ? "media" : name
    }

    /// Reuses an interrupted download's path so the `.omni-resume` sidecar can
    /// continue where it stopped; completed files still get a fresh name.
    public static func destinationURL(directory: URL, baseName: String, ext: String) -> URL {
        let fm = FileManager.default
        let direct = directory.appendingPathComponent("\(baseName).\(ext)")
        if fm.fileExists(atPath: direct.path + ".omni-resume") || !fm.fileExists(atPath: direct.path) {
            return direct
        }
        return uniqueURL(directory: directory, baseName: baseName, ext: ext)
    }

    public static func uniqueURL(directory: URL, baseName: String, ext: String) -> URL {
        let fm = FileManager.default
        var candidate = directory.appendingPathComponent("\(baseName).\(ext)")
        var index = 2
        while fm.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent("\(baseName) \(index).\(ext)")
            index += 1
        }
        return candidate
    }
}

public enum Quality {
    public static let presets = ["best", "4320", "2160", "1440", "1080", "720", "480", "360", "240"]

    public static func targetHeight(_ preference: String) -> Int? {
        let raw = preference.lowercased()
        switch raw {
        case "8k": return 4320
        case "4k": return 2160
        case "2k": return 1440
        default:
            let value = raw.hasSuffix("p") ? String(raw.dropLast()) : raw
            guard let height = Int(value), (1...16384).contains(height) else { return nil }
            return height
        }
    }

    public static func pickBest<T>(_ items: [T], height: (T) -> Int, score: (T) -> Int64, preferred: String) -> T? {
        guard !items.isEmpty else { return nil }
        if let target = targetHeight(preferred) {
            let eligible = items.filter { height($0) <= target }
            if let best = eligible.max(by: { score($0) < score($1) }) { return best }
        }
        return items.max(by: { score($0) < score($1) })
    }
}
