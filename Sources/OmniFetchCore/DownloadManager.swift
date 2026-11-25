import Foundation
import Combine
import AppKit

@MainActor
public final class DownloadManager: ObservableObject {
    public static let shared = DownloadManager()

    @Published public private(set) var tasks: [DownloadTask] = []
    @Published public private(set) var settings: AppSettings
    @Published public private(set) var ytdlpVersion: String?
    @Published public private(set) var isInstallingYTDLP = false

    private var runners: [UUID: Task<Void, Never>] = [:]
    private var samples: [UUID: (bytes: Int64, time: DispatchTime, speed: Double)] = [:]
    /// One 10 Hz flush for every task instead of one wake-up per callback.
    private lazy var progressCoalescer = ProgressCoalescer { [weak self] id, downloaded, total in
        Task { @MainActor [weak self] in
            self?.applyProgress(id: id, downloaded: downloaded, total: total)
        }
    }
    private let registry = EngineRegistry.shared

    public init() {
        AppPaths.ensureDirectories()
        settings = SettingsStore.load()
        tasks = Self.loadTasks()
        if !settings.keepHistory {
            tasks.removeAll { $0.state.isFinished }
        }
        for index in tasks.indices where tasks[index].state.isActive {
            tasks[index].state = .paused
            tasks[index].speed = 0
        }
        refreshYTDLP()
        pump()
    }

    // MARK: - Public API

    public var activeCount: Int {
        tasks.filter { $0.state.isActive }.count
    }

    public func task(_ id: UUID) -> DownloadTask? {
        tasks.first { $0.id == id }
    }

    public func probe(url: String, options: DownloadOptions) async throws -> MediaInfo {
        guard let parsed = Self.parseURL(url) else { throw EngineError.probeFailed("链接格式不正确") }
        return try await registry.engine(for: parsed).probe(url: parsed, options: taskOptions(options, for: parsed))
    }

    /// `info` is the probe result already shown to the user; passing it avoids
    /// probing the site a second time when the download starts.
    @discardableResult
    public func add(url: String, options: DownloadOptions? = nil,
                    info: MediaInfo? = nil, start: Bool = true) -> UUID? {
        guard let parsed = Self.parseURL(url) else { return nil }
        let task = makeTask(url: parsed, options: taskOptions(options, for: parsed), info: info)
        enqueue([task], start: start)
        return task.id
    }

    public func add(urls: [URL], options: DownloadOptions? = nil, start: Bool = true) {
        let defaults = taskOptions(options)
        let needsCookie = defaults.cookieHeader == nil && !settings.cookieHeader.isEmpty
        let additions = urls.compactMap { url -> DownloadTask? in
            guard let parsed = url.isRemoteMediaURL ? url : Self.parseURL(url.absoluteString) else { return nil }
            var resolved = defaults
            if needsCookie { resolved.cookieHeader = settings.manualCookie(for: parsed) }
            return makeTask(url: parsed, options: resolved, info: nil)
        }
        enqueue(additions, start: start)
    }

    private func taskOptions(_ options: DownloadOptions?, for url: URL? = nil) -> DownloadOptions {
        var opts = options ?? DownloadOptions(quality: settings.preferredQuality,
                                              connections: settings.connectionsPerTask)
        if opts.connections <= 0 { opts.connections = settings.connectionsPerTask }
        if opts.bandwidth == nil { opts.bandwidth = settings.bandwidthBytesPerSecond }
        if opts.cookieHeader == nil, let url { opts.cookieHeader = settings.manualCookie(for: url) }
        if opts.cookiesFromBrowser == nil, !settings.cookiesFromBrowser.isEmpty {
            opts.cookiesFromBrowser = settings.cookiesFromBrowser
        }

        return opts
    }

    private func makeTask(url: URL, options: DownloadOptions, info: MediaInfo?) -> DownloadTask {
        var task = DownloadTask(url: url.absoluteString, options: options, cachedInfo: info)
        task.engineID = info?.engineID ?? registry.engine(for: url).id
        task.title = info?.title ?? url.host ?? url.absoluteString
        return task
    }

    private func enqueue(_ additions: [DownloadTask], start: Bool) {
        guard !additions.isEmpty else { return }
        tasks.insert(contentsOf: additions.reversed(), at: 0)
        trimHistory()
        persist()
        if start {
            let freeSlots = max(0, max(1, settings.maxConcurrent) - runners.count)
            for task in additions.prefix(freeSlots) { launch(task) }
            pump()
        }
    }

    /// Keeps the persisted list (and the SwiftUI list) from growing forever;
    /// only finished rows are dropped, oldest first.
    private func trimHistory(limit: Int = 1000) {
        guard tasks.count > limit else { return }
        let finished = tasks.filter { $0.state.isFinished }.suffix(tasks.count - limit)
        let drop = Set(finished.map(\.id))
        guard !drop.isEmpty else { return }
        tasks.removeAll { drop.contains($0.id) }
        for id in drop { samples[id] = nil }
    }

    public func pause(_ id: UUID) {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return }
        runners[id]?.cancel()
        samples[id] = nil
        tasks[index].state = .paused
        tasks[index].speed = 0
        persist()
        pump()
    }

    public func resume(_ id: UUID) {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return }
        guard tasks[index].state == .paused || tasks[index].state == .failed || tasks[index].state == .cancelled else { return }
        tasks[index].state = .queued
        tasks[index].errorMessage = nil
        persist()
        pump()
    }

    public func cancel(_ id: UUID) {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return }
        runners[id]?.cancel()
        samples[id] = nil
        tasks[index].state = .cancelled
        tasks[index].speed = 0
        persist()
        pump()
    }

    public func retry(_ id: UUID) {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return }
        tasks[index].state = .queued
        tasks[index].progress = 0
        tasks[index].downloadedBytes = 0
        tasks[index].speed = 0
        tasks[index].eta = nil
        tasks[index].errorMessage = nil
        // Cached media URLs are usually signed and may have expired; probe again.
        tasks[index].cachedInfo = nil
        samples[id] = nil
        persist()
        pump()
    }

    public func remove(_ id: UUID, deleteFile: Bool = false) {
        runners[id]?.cancel()
        if let task = task(id), deleteFile, let path = task.filePath {
            try? FileManager.default.removeItem(atPath: path)
            try? FileManager.default.removeItem(atPath: path + ".omni-resume")
        }
        tasks.removeAll { $0.id == id }
        samples[id] = nil
        persist()
        pump()
    }

    public func clearCompleted() {
        let removed = tasks.filter { $0.state == .completed || $0.state == .cancelled }.map(\.id)
        tasks.removeAll { $0.state == .completed || $0.state == .cancelled }
        for id in removed { samples[id] = nil }
        persist()
    }

    public func pauseAll() {
        var rows = tasks
        var changed = false
        for index in rows.indices where rows[index].state.isActive || rows[index].state == .queued {
            let id = rows[index].id
            runners[id]?.cancel()
            samples[id] = nil
            rows[index].state = .paused
            rows[index].speed = 0
            changed = true
        }
        if changed {
            tasks = rows
            persist()
        }
    }

    public func resumeAll() {
        var rows = tasks
        var changed = false
        for index in rows.indices where rows[index].state == .paused {
            rows[index].state = .queued
            rows[index].errorMessage = nil
            changed = true
        }
        if changed {
            tasks = rows
            persist()
            pump()
        }
    }

    public func reveal(_ id: UUID) {
        guard let path = task(id)?.filePath else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    public func open(_ id: UUID) {
        guard let path = task(id)?.filePath else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    public func openDownloadFolder() {
        let dir = URL(fileURLWithPath: settings.saveDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        NSWorkspace.shared.open(dir)
    }

    public func updateSettings(_ newSettings: AppSettings) {
        settings = newSettings
        SettingsStore.save(newSettings)
        if !newSettings.keepHistory {
            let removed = tasks.filter { $0.state.isFinished }.map(\.id)
            tasks.removeAll { $0.state.isFinished }
            for id in removed { samples[id] = nil }
            persist()
        }
        try? FileManager.default.createDirectory(atPath: newSettings.saveDirectory,
                                                 withIntermediateDirectories: true)
        pump()
    }

    public func refreshYTDLP() {
        Task { [weak self] in
            guard let binary = YTDLPInstaller.locate() else { return }
            let version = await YTDLPInstaller.version(binary: binary)
            await MainActor.run { self?.ytdlpVersion = version }
        }
    }

    public func installYTDLP() {
        guard !isInstallingYTDLP else { return }
        isInstallingYTDLP = true
        Task { [weak self] in
            do {
                let binary = try await YTDLPInstaller.install()
                let version = await YTDLPInstaller.version(binary: binary)
                await MainActor.run {
                    self?.ytdlpVersion = version
                    self?.isInstallingYTDLP = false
                }
            } catch {
                await MainActor.run {
                    self?.ytdlpVersion = "安装失败：\(error.localizedDescription)"
                    self?.isInstallingYTDLP = false
                }
            }
        }
    }

    // MARK: - Scheduling

    private func pump() {
        let limit = max(1, settings.maxConcurrent)
        guard runners.count < limit else { return }
        for task in tasks where task.state == .queued && runners[task.id] == nil {
            launch(task)
            if runners.count >= limit { break }
        }
    }

    private func launch(_ snapshot: DownloadTask) {
        let runner = Task { [weak self] in
            guard let self else { return }
            await self.execute(snapshot)
        }
        runners[snapshot.id] = runner
    }

    private func execute(_ snapshot: DownloadTask) async {
        let id = snapshot.id
        // A rapid pause/resume must wait for the old writer and its checkpoint.
        defer {
            runners[id] = nil
            pump()
        }
        guard !Task.isCancelled else { return }
        guard let url = URL(string: snapshot.url) else {
            finish(id: id, error: "链接无效")
            return
        }
        let routed = registry.engine(for: url)
        var options = snapshot.options
        if options.connections <= 0 { options.connections = settings.connectionsPerTask }
        if options.bandwidth == nil { options.bandwidth = settings.bandwidthBytesPerSecond }

        do {
            let info: MediaInfo
            if let cached = snapshot.cachedInfo {
                info = cached
            } else {
                setState(id, .probing)
                info = try await routed.prepareDownload(url: url, options: options)
            }
            try Task.checkCancellation()
            // Native engines fall back to yt-dlp during probe; the download
            // must follow the engine that actually produced the media URLs.
            let engine = registry.engine(id: info.engineID) ?? routed

            update(id) { task in
                task.title = info.title
                task.site = info.site
                task.thumbnail = info.thumbnail
                task.duration = info.duration
                task.engineID = info.engineID
                task.progressInItems = info.isItemCollection
                task.formatLabel = info.formats.first(where: { $0.id == (options.formatID ?? info.selectedFormatID) })?.label
                task.state = .downloading
                // Native media URLs are signed and expire, so a resume must
                // probe again. yt-dlp only needs the page URL, so keeping its
                // probe result makes pause → resume skip a slow `-J` run.
                task.cachedInfo = info.selfDownloading ? info : nil
            }

            let directory = URL(fileURLWithPath: settings.saveDirectory)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let baseName = MediaNaming.sanitize(info.title)
            let request = DownloadRequest(info: info, options: options,
                                          destinationDirectory: directory, baseName: baseName)

            let coalescer = progressCoalescer
            let output = try await engine.download(request, onProgress: { downloaded, total in
                coalescer.submit(id: id, downloaded: downloaded, total: total)
            })
            try Task.checkCancellation()

            let finalSize: Int64 = info.isItemCollection
                ? MediaOutput.itemCount(in: output)
                : ((try? FileManager.default.attributesOfItem(atPath: output.path)[.size] as? NSNumber)?.int64Value ?? 0)

            update(id) { task in
                task.filePath = output.path
                task.state = .completed
                task.progress = 1
                task.speed = 0
                task.eta = 0
                task.finishedAt = Date()
                if finalSize > 0 { task.totalBytes = finalSize }
                if task.totalBytes > 0 { task.downloadedBytes = task.totalBytes }
                // Only needed while a task can be resumed; keeps tasks.json small.
                task.cachedInfo = nil
            }
            samples[id] = nil
            CompletionNotifier.notifyDownloadFinished(title: info.title, location: output.path)
            persist()
        } catch {
            // A cancelled child process can surface an engine error during merge.
            switch error {
            case _ where Task.isCancelled, is CancellationError, FetchError.cancelled:
                if task(id)?.state.isActive == true {
                    update(id) { $0.state = .paused; $0.speed = 0 }
                    persist()
                }
            default:
                finish(id: id, error: error.localizedDescription)
            }
        }
    }

    private func finish(id: UUID, error: String) {
        update(id) { task in
            task.state = .failed
            task.errorMessage = error
            task.speed = 0
            task.finishedAt = Date()
        }
        Log.write("task \(id) failed: \(error)")
        persist()
    }

    private func setState(_ id: UUID, _ state: DownloadState) {
        update(id) { $0.state = state }
    }

    private func update(_ id: UUID, _ mutate: (inout DownloadTask) -> Void) {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return }
        mutate(&tasks[index])
    }

    private func applyProgress(id: UUID, downloaded: Int64, total: Int64) {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return }
        var row = tasks[index]
        guard row.state == .downloading else { return }
        row.downloadedBytes = downloaded
        if total > 0 {
            row.totalBytes = total
            row.progress = min(1, Double(downloaded) / Double(total))
        }

        let now = DispatchTime.now()
        if let sample = samples[id] {
            let elapsed = Double(now.uptimeNanoseconds - sample.time.uptimeNanoseconds) / 1_000_000_000
            if elapsed >= 0.35 {
                let delta = Double(downloaded - sample.bytes)
                let instant = delta / elapsed
                let smoothed = sample.speed == 0 ? instant : sample.speed * 0.7 + instant * 0.3
                row.speed = max(0, smoothed)
                samples[id] = (downloaded, now, smoothed)
                row.eta = smoothed > 1 && total > 0
                    ? Double(max(0, total - downloaded)) / smoothed : nil
            }
        } else {
            samples[id] = (downloaded, now, 0)
        }
        tasks[index] = row
        // Progress is deliberately not persisted: encoding the whole task list
        // on every tick writes megabytes per minute during long downloads.
        // State transitions persist instead, and the sidecar holds real resume
        // progress.
    }

    // MARK: - Persistence

    private static func loadTasks() -> [DownloadTask] {
        guard let data = try? Data(contentsOf: AppPaths.tasksFile) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([DownloadTask].self, from: data)) ?? []
    }

    public func persist() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(tasks) {
            try? data.write(to: AppPaths.tasksFile, options: .atomic)
        }
    }

    // MARK: - Helpers

    /// Splits pasted text into links (one per line or space separated),
    /// dropping duplicates and anything that does not look like a URL.
    public nonisolated static func parseURLList(_ raw: String) -> [URL] { ShareLinks.parse(raw) }

    public nonisolated static func parseURL(_ raw: String) -> URL? { ShareLinks.parse(raw).first }
}
