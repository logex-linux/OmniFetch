import Foundation

// MARK: - Task state

public enum DownloadState: String, Codable, Sendable {
    case queued, probing, downloading, paused, merging, completed, failed, cancelled

    public var isActive: Bool {
        switch self {
        case .probing, .downloading, .merging: return true
        default: return false
        }
    }

    public var isFinished: Bool {
        switch self {
        case .completed, .failed, .cancelled: return true
        default: return false
        }
    }
}

public enum FileKind: String, Codable, Sendable {
    case video, audio, subtitle, image, unknown
}

// MARK: - Remote media description

public struct RemoteFile: Codable, Hashable, Sendable {
    public var url: URL
    /// CDN backups (Bilibili `backupUrl`) tried when `url` fails.
    public var alternateURLs: [URL]?
    public var headers: [String: String]
    public var kind: FileKind
    public var fileExtension: String
    public var totalBytes: Int64?

    public init(url: URL, headers: [String: String] = [:], kind: FileKind = .video,
                fileExtension: String = "mp4", totalBytes: Int64? = nil,
                alternateURLs: [URL]? = nil) {
        self.url = url
        self.headers = headers
        self.kind = kind
        self.fileExtension = fileExtension
        self.totalBytes = totalBytes
        self.alternateURLs = alternateURLs
    }
}

public struct FormatOption: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var label: String
    public var ext: String
    public var height: Int?
    public var filesize: Int64?
    public var isAudioOnly: Bool
    /// True when the format already carries an audio track (muxed); false/nil
    /// means a separate audio download is required.
    public var includesAudio: Bool?
    public var note: String?

    public init(id: String, label: String, ext: String, height: Int? = nil,
                filesize: Int64? = nil, isAudioOnly: Bool = false,
                includesAudio: Bool? = nil, note: String? = nil) {
        self.id = id
        self.label = label
        self.ext = ext
        self.height = height
        self.filesize = filesize
        self.isAudioOnly = isAudioOnly
        self.includesAudio = includesAudio
        self.note = note
    }
}

/// One part of a multi-part video (Bilibili 分 P).
public struct MediaPart: Codable, Hashable, Sendable, Identifiable {
    public var index: Int
    public var title: String
    public var duration: Double?

    public var id: Int { index }

    public init(index: Int, title: String, duration: Double? = nil) {
        self.index = index
        self.title = title
        self.duration = duration
    }
}

public struct MediaInfo: Codable, Hashable, Sendable {
    public var title: String
    public var site: String?
    public var thumbnail: String?
    public var duration: Double?
    public var files: [RemoteFile]
    /// Native video renditions keyed by the ID displayed in the format picker.
    public var videoVariants: [String: RemoteFile]?
    public var formats: [FormatOption]
    public var selectedFormatID: String?
    public var suggestedExtension: String
    public var engineID: String
    /// Some engines (yt-dlp) download by themselves; others hand raw files to FileFetcher.
    public var selfDownloading: Bool
    /// Present only when the page contains more than one part.
    public var parts: [MediaPart]?
    public var extra: [String: String]

    public var isItemCollection: Bool {
        ["gallery", "playlist", "images", "attachments"].contains(extra["kind"] ?? "")
    }

    func files(for format: String?) -> [RemoteFile] {
        guard let format, let video = videoVariants?[format] else { return files }
        return [video] + files.filter { $0.kind != .video }
    }

    public init(title: String, site: String? = nil, thumbnail: String? = nil, duration: Double? = nil,
                files: [RemoteFile] = [], formats: [FormatOption] = [], selectedFormatID: String? = nil,
                suggestedExtension: String = "mp4", engineID: String, selfDownloading: Bool = false,
                parts: [MediaPart]? = nil, extra: [String: String] = [:]) {
        self.title = title
        self.site = site
        self.thumbnail = thumbnail
        self.duration = duration
        self.files = files
        self.formats = formats
        self.selectedFormatID = selectedFormatID
        self.suggestedExtension = suggestedExtension
        self.engineID = engineID
        self.selfDownloading = selfDownloading
        self.parts = parts
        self.extra = extra
    }
}

// MARK: - Options

public struct DownloadOptions: Codable, Hashable, Sendable {
    public var formatID: String?
    public var useXHSAppSession: Bool?
    public var audioOnly: Bool
    public var quality: String          // best / 2160 / 1080 / 720 / 480
    public var connections: Int         // parallel HTTP ranges
    public var cookieHeader: String?
    public var cookiesFromBrowser: String?
    public var referer: String?
    public var userAgent: String?
    public var bandwidth: Int?          // bytes per second, nil = unlimited
    public var extraHeaders: [String: String]

    public init(formatID: String? = nil, audioOnly: Bool = false, quality: String = "best",
                connections: Int = 6, cookieHeader: String? = nil, cookiesFromBrowser: String? = nil,
                referer: String? = nil, userAgent: String? = nil, bandwidth: Int? = nil,
                extraHeaders: [String: String] = [:]) {
        self.formatID = formatID
        self.audioOnly = audioOnly
        self.quality = quality
        self.connections = connections
        self.cookieHeader = cookieHeader
        self.cookiesFromBrowser = cookiesFromBrowser
        self.referer = referer
        self.userAgent = userAgent
        self.bandwidth = bandwidth
        self.extraHeaders = extraHeaders
    }
}

// MARK: - Task

public struct DownloadTask: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var url: String
    public var title: String
    public var site: String?
    public var thumbnail: String?
    public var state: DownloadState
    public var progress: Double          // 0...1
    public var totalBytes: Int64
    public var progressInItems: Bool?
    public var downloadedBytes: Int64
    public var speed: Double             // bytes per second
    public var eta: Double?
    public var errorMessage: String?
    public var filePath: String?
    public var engineID: String
    public var formatLabel: String?
    public var duration: Double?
    public var options: DownloadOptions
    /// Probe result captured when the user added the task, so starting the
    /// download does not have to probe the site a second time.
    public var cachedInfo: MediaInfo?
    public var createdAt: Date
    public var finishedAt: Date?

    public init(url: String, title: String = "", options: DownloadOptions = .init(),
                cachedInfo: MediaInfo? = nil) {
        self.id = UUID()
        self.url = url
        self.title = title.isEmpty ? url : title
        self.state = .queued
        self.progress = 0
        self.totalBytes = 0
        self.downloadedBytes = 0
        self.speed = 0
        self.options = options
        self.cachedInfo = cachedInfo
        self.engineID = "auto"
        self.createdAt = Date()
    }

    public var fileURL: URL? {
        filePath.map { URL(fileURLWithPath: $0) }
    }
}

// MARK: - Settings

public struct AppSettings: Codable, Sendable {
    public var maxConcurrent: Int = 3
    public var connectionsPerTask: Int = 6
    public var bandwidthLimitKBps: Int = 0        // 0 = unlimited
    public var saveDirectory: String = AppPaths.defaultDownloadDirectory.path
    public var clipboardWatch: Bool = false
    public var keepHistory: Bool = true
    public var cookiesFromBrowser: String = ""
    public var cookieHeader: String = ""
    public var cookieDomain: String?
    public var preferredQuality: String = "best"
    public var ytdlpPath: String = ""
    public var ffmpegPath: String = ""
    /// Optional so settings written by older builds still decode; nil means on.
    public var notifyOnCompletion: Bool?

    public init() {}

    func manualCookie(for url: URL) -> String? {
        guard !cookieHeader.isEmpty else { return nil }
        var domain = (cookieDomain ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if domain.isEmpty {
            // Recognize the two native services supported by older settings.
            let names = cookieHeader.split(separator: ";").map { $0.split(separator: "=", maxSplits: 1).first?
                .trimmingCharacters(in: .whitespaces) ?? "" }
            if names.contains("SESSDATA") || names.contains("bili_jct") { domain = "bilibili.com" }
            else if names.contains("web_session") { domain = "xiaohongshu.com" }
        }
        guard !domain.isEmpty && domain.contains(".") else { return nil }
        if url.isOn(domain) { return cookieHeader }
        if domain == "bilibili.com" && url.isOn("b23.tv") { return cookieHeader }
        if domain == "xiaohongshu.com" && url.isOn("xhslink.com") { return cookieHeader }
        return nil
    }

    public var bandwidthBytesPerSecond: Int? {
        bandwidthLimitKBps > 0 ? bandwidthLimitKBps * 1024 : nil
    }
}
