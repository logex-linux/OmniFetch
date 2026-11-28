import Foundation

public enum MediaMerger {
    public static func ffmpegPath(settings: AppSettings = SettingsStore.load()) -> String? {
        if !settings.ffmpegPath.isEmpty,
           FileManager.default.isExecutableFile(atPath: settings.ffmpegPath) {
            return settings.ffmpegPath
        }
        let bundled = AppPaths.binDirectory.appendingPathComponent("ffmpeg").path
        if FileManager.default.isExecutableFile(atPath: bundled) { return bundled }
        return Shell.which("ffmpeg")
    }

    /// Remuxes separate video/audio tracks without re-encoding.
    public static func merge(video: URL, audio: URL, output: URL) async throws {
        guard let ffmpeg = ffmpegPath() else { throw EngineError.missingTool("ffmpeg") }
        let args = [
            "-hide_banner", "-loglevel", "error", "-nostdin", "-y",
            "-i", video.path,
            "-i", audio.path,
            "-c", "copy",
            "-movflags", "+faststart",
            "-map", "0:v:0", "-map", "1:a:0",
            // Explicit format: the caller may merge into a `.part` temp name.
            "-f", "mp4",
            output.path
        ]
        let result = try await Shell.run(ffmpeg, args, timeout: 3600)
        guard result.succeeded, FileManager.default.fileExists(atPath: output.path) else {
            throw EngineError.probeFailed("音视频合并失败：\(result.stderr.suffix(400))")
        }
    }

    /// Converts an audio-only download to m4a/mp3 when the container needs it.
    public static func extractAudio(input: URL, output: URL) async throws {
        guard let ffmpeg = ffmpegPath() else { throw EngineError.missingTool("ffmpeg") }
        let common = ["-hide_banner", "-loglevel", "error", "-nostdin", "-y", "-i", input.path, "-map", "0:a:0", "-vn"]
        let copied = try await Shell.run(ffmpeg, common + ["-c:a", "copy", "-f", "ipod", output.path], timeout: 1800)
        try Task.checkCancellation()
        if copied.succeeded { return }
        let converted = try await Shell.run(ffmpeg, common + ["-c:a", "aac", "-q:a", "2", "-f", "ipod", output.path], timeout: 1800)
        try Task.checkCancellation()
        guard converted.succeeded else { throw EngineError.probeFailed("音频提取失败，源文件可能没有音轨") }
    }

    public static func remuxToMP4(input: URL, output: URL) async throws {
        guard let ffmpeg = ffmpegPath() else { throw EngineError.missingTool("ffmpeg") }
        let args = ["-hide_banner", "-loglevel", "error", "-nostdin", "-y", "-i", input.path,
                    "-c", "copy", "-movflags", "+faststart", output.path]
        let result = try await Shell.run(ffmpeg, args, timeout: 3600)
        guard result.succeeded else {
            throw EngineError.probeFailed("封装失败：\(result.stderr.suffix(400))")
        }
    }
}

/// Shared download pipeline for engines that resolve direct media URLs.
public enum DirectPipeline {
    public static func download(files: [RemoteFile],
                                options: DownloadOptions,
                                destinationDirectory: URL,
                                baseName: String,
                                sourceID: String? = nil,
                                onProgress: @escaping @Sendable (Int64, Int64) -> Void) async throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)

        let video = files.first { $0.kind == .video }
        let audio = files.first { $0.kind == .audio }

        guard let primary = options.audioOnly ? (audio ?? video) : (video ?? audio) else {
            throw EngineError.emptyResult
        }

        let bandwidth = options.bandwidth
            ?? options.extraHeaders["x-omnifetch-bandwidth"].flatMap(Int.init)
        let connections = options.connectionLimit

        if options.audioOnly && audio == nil {
            guard MediaMerger.ffmpegPath() != nil else { throw EngineError.missingTool("ffmpeg") }
            let info = MediaInfo(title: baseName, files: [primary], engineID: "native-audio")
            let output = try MediaOutput(DownloadRequest(info: info, options: options,
                                                        destinationDirectory: destinationDirectory, baseName: baseName))
            let source = output.staging.appendingPathComponent("source.part")
            let audioFile = output.staging.appendingPathComponent("audio.m4a")
            _ = try await FileFetcher.shared.fetch(primary, to: source, connections: connections,
                                                   bandwidth: bandwidth, onProgress: onProgress)
            try await MediaMerger.extractAudio(input: source, output: audioFile)
            try Task.checkCancellation()
            return try output.publish(file: audioFile)
        }

        guard !options.audioOnly, let audio, let video, video.url != audio.url else {
            return try await fetchSingle(primary, directory: destinationDirectory, baseName: baseName,
                                         connections: connections, bandwidth: bandwidth, onProgress: onProgress)
        }

        // Fail before transferring gigabytes if the merge step cannot run.
        guard MediaMerger.ffmpegPath() != nil else { throw EngineError.missingTool("ffmpeg") }

        let identity = sourceID.map { [$0, video.url.path, audio.url.path].joined(separator: "\n") }
            ?? [video.url.absoluteString, audio.url.absoluteString].joined(separator: "\n")
        let info = MediaInfo(title: baseName, files: [video, audio], engineID: "native-dash", extra: ["webpage": identity])
        let output = try MediaOutput(DownloadRequest(info: info, options: options,
                                                    destinationDirectory: destinationDirectory, baseName: baseName))
        let counter = TrackCounter()
        let session = TransferSession.make()
        defer { session.invalidateAndCancel() }
        @Sendable func track(_ file: RemoteFile, stem: String, connections: Int) async throws -> URL {
            let completed = output.staging.appendingPathComponent(stem + ".m4s")
            let partial = output.staging.appendingPathComponent(stem + ".part")
            let report: @Sendable (Int64, Int64) -> Void = { got, total in
                let progress = counter.update(file.kind, received: got, total: total)
                onProgress(progress.received, progress.total)
            }
            if MediaOutput.isCompleteFile(completed) {
                let size = Int64((try completed.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? 0)
                report(size, size)
                return completed
            }
            let old = destinationDirectory.appendingPathComponent(".\(baseName).\(stem).part")
            FileFetcher.adoptPartial(old, at: partial, for: file)
            _ = try await FileFetcher.shared.fetch(file, to: partial, connections: connections,
                                                   bandwidth: bandwidth, session: session, onProgress: report)
            try FileManager.default.moveItem(at: partial, to: completed)
            return completed
        }
        let tracks: (URL, URL)
        if connections == 1 {
            let videoTrack = try await track(video, stem: "video", connections: 1)
            try Task.checkCancellation()
            tracks = (videoTrack, try await track(audio, stem: "audio", connections: 1))
        } else {
            let audioBudget = max(1, connections / 4)
            let audioConnections = audio.totalBytes.map { FileFetcher.parallelism(for: $0, connections: audioBudget) } ?? audioBudget
            async let videoTrack = track(video, stem: "video", connections: connections - audioConnections)
            async let audioTrack = track(audio, stem: "audio", connections: audioConnections)
            tracks = try await (videoTrack, audioTrack)
        }
        let muxed = output.staging.appendingPathComponent("merged.mp4")
        try await MediaMerger.merge(video: tracks.0, audio: tracks.1, output: muxed)
        try Task.checkCancellation()
        return try output.publish(file: muxed)
    }

    static func fetchSingle(_ file: RemoteFile, directory: URL, baseName: String, connections: Int,
                            bandwidth: Int?, onProgress: @escaping @Sendable (Int64, Int64) -> Void) async throws -> URL {
        let ext = file.fileExtension.isEmpty ? "mp4" : file.fileExtension
        let info = MediaInfo(title: baseName, files: [file], engineID: "native-file")
        let output = try MediaOutput(DownloadRequest(info: info, options: .init(),
                                                     destinationDirectory: directory, baseName: baseName))
        let partial = output.staging.appendingPathComponent("media.\(ext)")
        let legacy = MediaNaming.destinationURL(directory: directory, baseName: baseName, ext: ext)
        FileFetcher.adoptPartial(legacy, at: partial, for: file)
        _ = try await FileFetcher.shared.fetch(file, to: partial, connections: connections,
                                               bandwidth: bandwidth, onProgress: onProgress)
        try Task.checkCancellation()
        return try output.publish(file: partial)
    }
}

private final class TrackCounter: @unchecked Sendable {
    private var video: Int64 = 0
    private var audio: Int64 = 0
    private var videoTotal: Int64 = 0
    private var audioTotal: Int64 = 0
    private let lock = NSLock()

    func update(_ kind: FileKind, received: Int64, total: Int64) -> (received: Int64, total: Int64) {
        lock.lock(); defer { lock.unlock() }
        if kind == .audio {
            audio = received
            audioTotal = total
        } else {
            video = received
            videoTotal = total
        }
        return (video + audio, videoTotal + audioTotal)
    }
}

enum NativeAlbum {
    static func download(_ request: DownloadRequest,
                         onProgress: @escaping @Sendable (Int64, Int64) -> Void) async throws -> URL {
        let files = request.info.files
        guard !files.isEmpty else { throw EngineError.emptyResult }
        let output = try MediaOutput(request)
        let destinations = files.enumerated().map { index, file in
            let ext = file.fileExtension.isEmpty ? "jpg" : file.fileExtension
            return output.staging.appendingPathComponent(String(format: "%02d", index + 1) + "." + ext)
        }

        let session = TransferSession.make()
        defer { session.invalidateAndCancel() }
        let budget = request.options.connectionLimit
        let simultaneous = min(files.count, budget)
        var connections = Array(repeating: 1, count: files.count)
        if simultaneous < budget {
            let clips = files.indices.filter { files[$0].kind != .image }
            let spare = budget - simultaneous
            for (rank, index) in clips.enumerated() {
                connections[index] += spare / clips.count + (rank < spare % clips.count ? 1 : 0)
            }
        }
        var members = Set<URL>()
        try await withThrowingTaskGroup(of: URL.self) { group in
            func enqueue(_ position: Int) {
                let file = files[position]
                let destination = destinations[position]
                let limit = connections[position]
                group.addTask {
                    _ = try await FileFetcher.shared.fetch(file, to: destination, connections: limit,
                                                           bandwidth: request.options.bandwidth, session: session,
                                                           onProgress: { _, _ in })
                    guard file.kind == .image, let ext = try imageExtension(of: destination),
                          ext != destination.pathExtension.lowercased() else { return destination }
                    let corrected = destination.deletingPathExtension().appendingPathExtension(ext)
                    // Both names are inside this job's locked staging directory.
                    guard rename(destination.path, corrected.path) == 0 else {
                        throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
                    }
                    return corrected
                }
            }
            var next = simultaneous
            for position in 0..<next { enqueue(position) }
            while let saved = try await group.next() {
                try Task.checkCancellation()
                members.insert(saved)
                onProgress(Int64(members.count), Int64(files.count))
                if next < files.count {
                    enqueue(next)
                    next += 1
                }
            }
        }
        try Task.checkCancellation()
        return try output.publishCollection(members: members)
    }

    /// Some photo CDNs return WebP/AVIF from an extensionless or .jpg URL.
    /// Inspect the container header without decoding the image or issuing a new request.
    private static func imageExtension(of file: URL) throws -> String? {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        guard let header = try handle.read(upToCount: 16), header.count >= 12 else { return nil }
        if header.starts(with: [0xff, 0xd8, 0xff]) { return "jpg" }
        if header.starts(with: [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]) { return "png" }
        if header.starts(with: "GIF87a".utf8) || header.starts(with: "GIF89a".utf8) { return "gif" }
        let brand = header[8..<12]
        if header.starts(with: "RIFF".utf8), brand.elementsEqual("WEBP".utf8) { return "webp" }
        if header[4..<8].elementsEqual("ftyp".utf8) {
            switch String(decoding: brand, as: UTF8.self) {
            case "avif", "avis": return "avif"
            case "heic", "heix", "hevc", "hevx": return "heic"
            default: break
            }
        }
        return nil
    }
}
