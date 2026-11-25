import AVFoundation
import Foundation
import Network
import CryptoKit

/// Headless verification used by `omnifetch selftest`.
/// Covers engine routing and the real parallel-range download path against a
/// local HTTP server, so no external network is required.
public enum SelfTest {
    public static func run() async -> Int32 {
        var failures = 0
        func check(_ name: String, _ condition: Bool, _ detail: String = "") {
            print(condition ? "PASS  \(name)" : "FAIL  \(name) \(detail)")
            if !condition { failures += 1 }
        }

        do { try socialChecks(check) } catch { check("social platform fixtures", false, error.localizedDescription) }

        // 1. Engine routing
        let routes: [(String, String)] = [
            ("https://www.bilibili.com/video/BV1xx411c7mD", "bilibili"),
            ("https://b23.tv/abc123", "bilibili"),
            ("https://www.xiaohongshu.com/explore/64f0a1b2c3d4e5f60718293a", "xiaohongshu"),
            ("https://finder.video.qq.com/251/20302/stodownload?encfilekey=x", "wechat"),
            ("https://example.com/clip.mp4", "direct"),
            ("https://www.youtube.com/watch?v=dQw4w9WgXcQ", "ytdlp"),
            ("https://example.com/live/index.m3u8", "ytdlp")
        ]
        for (raw, expected) in routes {
            guard let url = URL(string: raw) else {
                check("route \(raw)", false, "bad url")
                continue
            }
            let engine = EngineRegistry.shared.engine(for: url).id
            check("route \(expected)", engine == expected, "got \(engine)")
        }

        do {
            _ = try await WeChatChannelsEngine().probe(
                url: URL(string: "https://channels.weixin.qq.com/pages/feed?foo=bar")!, options: .init())
            check("wechat share page rejected", false)
        } catch {
            check("wechat share page rejected", error.localizedDescription.contains("视频号链接"))
        }
        do {
            let sample: [String: Any] = ["errCode": 0, "data": ["feedInfo": [
                "description": "测试视频", "h264VideoInfo": ["videoUrl": "https://finder.video.qq.com/v.mp4?x-snsvideoflag=1&keep=ok"]
            ]]]
            let info = try WeChatShare.mediaInfo(sample)
            check("wechat share media parse", info.title == "测试视频" && info.files.first?.url.query == "x-snsvideoflag=1&keep=ok"
                  && info.files.first?.headers["Cookie"] == nil)
        } catch {
            check("wechat share media parse", false, error.localizedDescription)
        }

        // 1d. Bilibili 分 P: canonical URL parsing and per-part URLs.
        if let identifier = try? BilibiliEngine.parseIdentifier(
            URL(string: "https://www.bilibili.com/video/BV1xx411c7mD?p=3")!) {
            check("bilibili canonical url",
                  identifier.webpage == "https://www.bilibili.com/video/BV1xx411c7mD",
                  identifier.webpage)
        } else {
            check("bilibili canonical url", false, "parse failed")
        }
        check("bilibili part url",
              BilibiliEngine.partURL(base: "https://www.bilibili.com/video/BV1xx411c7mD", page: 3)?
                  .absoluteString == "https://www.bilibili.com/video/BV1xx411c7mD?p=3")
        check("bilibili part url replaces p",
              BilibiliEngine.partURL(base: "https://www.bilibili.com/video/BV1xx411c7mD?p=9", page: 2)?
                  .absoluteString == "https://www.bilibili.com/video/BV1xx411c7mD?p=2")
        let samplePages: [[String: Any]] = [
            ["page": 2, "part": "P2", "duration": 65],
            ["page": 1, "part": "P1", "duration": 60]
        ]
        let parsedParts = BilibiliEngine.parts(from: samplePages)
        check("bilibili parts parse",
              parsedParts?.map(\.index) == [1, 2] && parsedParts?.first?.title == "P1",
              "\(parsedParts?.map(\.index) ?? [])")
        check("bilibili single part hidden",
              BilibiliEngine.parts(from: [["page": 1, "part": "only"]]) == nil)

        // 1e. Xiaohongshu image notes: pick the default URL and keep the format.
        let imageList: [[String: Any]] = [
            ["urlDefault": "https://sns-img-bd.xhscdn.com/a.webp", "url": "https://x/a.jpg"],
            ["url": "https://sns-img-bd.xhscdn.com/b"],
            ["urlDefault": ""]
        ]
        let imageFiles = XiaohongshuEngine.imageFiles(from: imageList, headers: [:])
        check("xhs image files",
              imageFiles.count == 2
              && imageFiles[0].fileExtension == "webp"
              && imageFiles[1].fileExtension == "jpg"
              && imageFiles.allSatisfy { $0.kind == .image },
              "\(imageFiles.map(\.url.absoluteString))")

        // 1g. Progress updates from many callbacks collapse into few flushes.
        let recorder = ProgressRecorder()
        let coalescer = ProgressCoalescer(interval: 0.05) { _, downloaded, _ in
            recorder.record(downloaded)
        }
        let coalescedID = UUID()
        for value in 1...50 {
            coalescer.submit(id: coalescedID, downloaded: Int64(value), total: 100)
        }
        try? await Task.sleep(nanoseconds: 200_000_000)
        check("progress coalescing",
              recorder.count <= 2 && recorder.last == 50,
              "calls=\(recorder.count) last=\(recorder.last)")

        // 1f. Settings written before newer fields existed must still decode.
        let legacySettings = """
        {"maxConcurrent":3,"connectionsPerTask":6,"bandwidthLimitKBps":0,\
        "saveDirectory":"/tmp/legacy","clipboardWatch":false,"keepHistory":true,\
        "cookiesFromBrowser":"","cookieHeader":"","preferredQuality":"best",\
        "ytdlpPath":"","ffmpegPath":""}
        """
        if let data = legacySettings.data(using: .utf8),
           let decoded = try? JSONDecoder().decode(AppSettings.self, from: data) {
            check("legacy settings decode",
                  decoded.saveDirectory == "/tmp/legacy" && decoded.notifyOnCompletion == nil,
                  "saveDirectory=\(decoded.saveDirectory)")
        } else {
            check("legacy settings decode", false, "decode failed")
        }

        // 1a. Cancelling a task must stop its child process promptly.
        let shellStart = DispatchTime.now()
        let sleeper = Task { try await Shell.run("/bin/sleep", ["5"]) }
        try? await Task.sleep(nanoseconds: 150_000_000)
        sleeper.cancel()
        let shellResult = try? await sleeper.value
        let shellElapsed = Double(DispatchTime.now().uptimeNanoseconds
                                  - shellStart.uptimeNanoseconds) / 1_000_000_000
        check("cancel kills child process",
              shellElapsed < 1.5 && shellResult?.succeeded == false,
              String(format: "%.2fs, code %d", shellElapsed, shellResult?.code ?? -1))

        // 1b. Resume bookkeeping must keep bytes already on disk.
        check("resume seed",
              ChunkCoordinator(seeded: [1_024, 2_048, 0]).snapshot(count: 3) == [1_024, 2_048, 0])

        // 1c. Bytes written during this session add to the seeded ones; a
        //     finished chunk must not drop the part that was already on disk.
        let seededCoordinator = ChunkCoordinator(seeded: [1_000, 0])
        seededCoordinator.add(index: 0, bytes: 500)
        check("resume accounting",
              seededCoordinator.snapshot(count: 2) == [1_500, 0],
              "\(seededCoordinator.snapshot(count: 2))")

        // 2. Parallel range download against a local server
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("omnifetch-selftest-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let sourceURL = tempDirectory.appendingPathComponent("source.bin")
        let size = 24 * 1024 * 1024
        do {
            try makePatternFile(at: sourceURL, size: size)
        } catch {
            check("create fixture", false, "\(error)")
            return 1
        }

        var server: LocalRangeServer?
        do {
            let localServer = try LocalRangeServer(fileURL: sourceURL)
            server = localServer
            let port = try await localServer.start()
            let remote = URL(string: "http://127.0.0.1:\(port)/source.bin")!
            let output = tempDirectory.appendingPathComponent("output.bin")

            let start = DispatchTime.now()
            let counter = Counter()
            _ = try await FileFetcher.shared.fetch(
                RemoteFile(url: remote, headers: [:], kind: .video, fileExtension: "bin"),
                to: output,
                connections: 6,
                bandwidth: nil,
                onProgress: { _, _ in
                    counter.increment()
                }
            )
            let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000_000

            let attributes = try FileManager.default.attributesOfItem(atPath: output.path)
            let outputSize = (attributes[.size] as? NSNumber)?.int64Value ?? 0
            check("download size", outputSize == Int64(size), "got \(outputSize)")
            check("parallel ranges", localServer.requestCount > 1, "requests=\(localServer.requestCount)")
            check("progress callbacks", counter.value > 0, "calls=\(counter.value)")
            check("content integrity", (try? sha256(of: output)) == (try? sha256(of: sourceURL)))

            localServer.mode = .slow
            let slowRecorder = ProgressRecorder()
            let slowOutput = tempDirectory.appendingPathComponent("slow.bin")
            let slowTask = Task {
                try await FileFetcher.shared.fetch(
                    RemoteFile(url: remote, headers: [:], kind: .video, fileExtension: "bin"),
                    to: slowOutput, connections: 1, bandwidth: nil,
                    onProgress: { done, _ in slowRecorder.record(done) })
            }
            try? await Task.sleep(nanoseconds: 800_000_000)
            check("slow download reports live progress", slowRecorder.last > 0 && slowRecorder.last < Int64(size),
                  "bytes=\(slowRecorder.last)")
            slowTask.cancel()
            _ = try? await slowTask.value
            let streamCheckpoint = try JSONDecoder().decode(ResumeFixture.self,
                from: Data(contentsOf: slowOutput.appendingPathExtension("omni-resume")))
            let saved = streamCheckpoint.chunks.first ?? 0
            check("stream pause saves committed bytes", saved > 0 && saved < Int64(size))
            localServer.mode = .normal
            let beforeResume = localServer.bytesServed
            _ = try await FileFetcher.shared.fetch(RemoteFile(url: remote), to: slowOutput,
                                                   connections: 1, bandwidth: nil, onProgress: { _, _ in })
            check("stream resumes only missing bytes",
                  localServer.bytesServed - beforeResume == Int64(size) - saved + 1 &&
                  (try? sha256(of: slowOutput)) == (try? sha256(of: sourceURL)))
            print(String(format: "INFO  %.1f MB in %.2fs (%.1f MB/s, %d range requests)",
                         Double(size) / 1_048_576, elapsed,
                         Double(size) / 1_048_576 / max(elapsed, 0.001), localServer.requestCount))

            // 3. Resume: keep the first two chunks, re-download the rest.
            let chunk = Int64(size / 4)
            let handle = try FileHandle(forWritingTo: output)
            try handle.truncate(atOffset: UInt64(chunk * 2))
            try handle.close()
            let sidecar = ResumeFixture.make(url: remote.absoluteString, total: Int64(size),
                                             chunks: [chunk, chunk, 0, 0])
            try JSONEncoder().encode(sidecar).write(to: output.appendingPathExtension("omni-resume"))
            let servedBefore = localServer.bytesServed
            _ = try await FileFetcher.shared.fetch(
                RemoteFile(url: remote, headers: [:], kind: .video, fileExtension: "bin"),
                to: output, connections: 4, bandwidth: nil, onProgress: { _, _ in }
            )
            let served = localServer.bytesServed - servedBefore
            check("resume integrity", (try? sha256(of: output)) == (try? sha256(of: sourceURL)))
            check("resume skips finished chunks", served < Int64(size) - chunk,
                  "served \(served) of \(size)")

            // 3b. A sidecar whose bytes are no longer on disk must be ignored,
            //     otherwise the file would be filled with zero holes.
            let staleOutput = tempDirectory.appendingPathComponent("stale.bin")
            FileManager.default.createFile(atPath: staleOutput.path, contents: nil)
            let staleSidecar = ResumeFixture.make(url: remote.absoluteString, total: Int64(size),
                                                  chunks: [chunk, chunk, 0, 0])
            try JSONEncoder().encode(staleSidecar)
                .write(to: staleOutput.appendingPathExtension("omni-resume"))
            _ = try await FileFetcher.shared.fetch(
                RemoteFile(url: remote, headers: [:], kind: .video, fileExtension: "bin"),
                to: staleOutput, connections: 4, bandwidth: nil, onProgress: { _, _ in }
            )
            check("stale sidecar ignored",
                  (try? sha256(of: staleOutput)) == (try? sha256(of: sourceURL)))

            // 4. A server that advertises Range but answers full bodies must
            //    not corrupt the file; the fetch falls back to one stream.
            localServer.mode = .liesAboutRange
            let beforeFallback = localServer.requestCount
            let lyingOutput = tempDirectory.appendingPathComponent("lying.bin")
            _ = try await FileFetcher.shared.fetch(
                RemoteFile(url: remote, headers: [:], kind: .video, fileExtension: "bin"),
                to: lyingOutput, connections: 6, bandwidth: nil, onProgress: { _, _ in }
            )
            check("range-lie fallback integrity",
                  (try? sha256(of: lyingOutput)) == (try? sha256(of: sourceURL)))
            check("range-lie used fallback", localServer.fullBodyResponses > 0,
                  "full responses=\(localServer.fullBodyResponses)")
            check("range-lie avoids repeated requests", localServer.requestCount - beforeFallback <= 6)

            // A resumed single range also needs a full restart when the host
            // answers 200. The odd offset detects writing byte zero mid-file.
            let singleOutput = tempDirectory.appendingPathComponent("single-resume.bin")
            let prefix: Int64 = 65_673
            try FileManager.default.copyItem(at: sourceURL, to: singleOutput)
            let singleHandle = try FileHandle(forWritingTo: singleOutput)
            try singleHandle.truncate(atOffset: UInt64(prefix))
            try singleHandle.close()
            let singleSidecar = ResumeFixture.make(url: remote.absoluteString, total: Int64(size), chunks: [prefix])
            try JSONEncoder().encode(singleSidecar).write(to: singleOutput.appendingPathExtension("omni-resume"))
            _ = try await FileFetcher.shared.fetch(RemoteFile(url: remote), to: singleOutput,
                                                   connections: 1, bandwidth: nil, onProgress: { _, _ in })
            check("resumed range rejects full body", (try? sha256(of: singleOutput)) == (try? sha256(of: sourceURL)))

            localServer.mode = .cappedRange
            let cappedOutput = tempDirectory.appendingPathComponent("capped.bin")
            let beforeCap = localServer.bytesServed
            _ = try await FileFetcher.shared.fetch(RemoteFile(url: remote), to: cappedOutput,
                                                   connections: 4, bandwidth: nil, onProgress: { _, _ in })
            check("capped ranges use each byte once",
                  localServer.bytesServed - beforeCap == Int64(size) + 1 &&
                  (try? sha256(of: cappedOutput)) == (try? sha256(of: sourceURL)))

            // 5. A body shorter than the announced size must fail instead of
            //    being reported as a finished download.
            localServer.mode = .shortBody
            let shortOutput = tempDirectory.appendingPathComponent("short.bin")
            var shortError: Error?
            do {
                _ = try await FileFetcher.shared.fetch(
                    RemoteFile(url: remote, headers: [:], kind: .video, fileExtension: "bin"),
                    to: shortOutput, connections: 4, bandwidth: nil, onProgress: { _, _ in }
                )
            } catch {
                shortError = error
            }
            check("short body rejected",
                  shortError?.localizedDescription.contains("不完整") == true,
                  shortError?.localizedDescription ?? "unexpected success")

            // 5b. The shared bucket must actually hold the configured rate.
            let limiter = RateLimiter(bytesPerSecond: 2 * 1024 * 1024)
            let limitStart = DispatchTime.now()
            for _ in 0..<24 { limiter.consume(256 * 1024) }   // 6 MB at 2 MB/s ≈ 3 s
            let limitElapsed = Double(DispatchTime.now().uptimeNanoseconds
                                      - limitStart.uptimeNanoseconds) / 1_000_000_000
            check("rate limiter", limitElapsed >= 2.4,
                  String(format: "%.2fs for 6MB at 2MB/s", limitElapsed))

            // Parallel chunks must share the same bucket, not each get a copy.
            let sharedLimiter = RateLimiter(bytesPerSecond: 4 * 1024 * 1024)
            let parallelStart = DispatchTime.now()
            DispatchQueue.concurrentPerform(iterations: 4) { _ in
                for _ in 0..<6 { sharedLimiter.consume(256 * 1024) }
            }
            let parallelElapsed = Double(DispatchTime.now().uptimeNanoseconds
                                         - parallelStart.uptimeNanoseconds) / 1_000_000_000
            check("rate limiter concurrency", parallelElapsed >= 1.2,
                  String(format: "%.2fs for 6MB at 4MB/s across 4 consumers", parallelElapsed))
            let lowRate = RateLimiter(bytesPerSecond: 32_768)
            let lowStart = ContinuousClock.now
            lowRate.consume(81_920)
            check("low rate charges the whole buffer", lowStart.duration(to: .now) >= .milliseconds(2180))
            print(String(format: "INFO  limiter: 6MB/2MBps = %.2fs (want 3.00), 6MB/4MBps parallel = %.2fs (want 1.50)",
                         limitElapsed, parallelElapsed))

            // 6. An expired CDN URL (403) must fail over to the backup URL.
            localServer.mode = .normal
            let limitedOutput = tempDirectory.appendingPathComponent("limited-cancel.bin")
            let limitedProgress = ProgressRecorder()
            let limited = Task {
                try await FileFetcher.shared.fetch(RemoteFile(url: remote), to: limitedOutput,
                                                   connections: 1, bandwidth: 16 * 1024,
                                                   onProgress: { done, _ in limitedProgress.record(done) })
            }
            let limitDeadline = ContinuousClock.now + .seconds(2)
            while limitedProgress.last <= 0 && ContinuousClock.now < limitDeadline {
                try await Task.sleep(for: .milliseconds(20))
            }
            check("low rate publishes partial writes", limitedProgress.last > 0 && limitedProgress.last < 64 * 1024)
            let cancelLimited = ContinuousClock.now
            limited.cancel()
            _ = try? await limited.value
            check("cancel wakes throttled writer", cancelLimited.duration(to: .now) < .seconds(1))
            var denied = RemoteFile(url: URL(string: "http://127.0.0.1:\(port)/forbidden.bin")!,
                                    headers: [:], kind: .video, fileExtension: "bin")
            denied.alternateURLs = [remote]
            let backupOutput = tempDirectory.appendingPathComponent("backup.bin")
            _ = try await FileFetcher.shared.fetch(
                denied, to: backupOutput, connections: 4, bandwidth: nil, onProgress: { _, _ in }
            )
            check("backup source failover",
                  (try? sha256(of: backupOutput)) == (try? sha256(of: sourceURL)))

            // 7. Cancelling during the probe must not wait out the 15 s timeout.
            localServer.mode = .stall
            let cancelOutput = tempDirectory.appendingPathComponent("cancel.bin")
            let cancelStart = DispatchTime.now()
            let slow = Task {
                try await FileFetcher.shared.fetch(
                    RemoteFile(url: remote, headers: [:], kind: .video, fileExtension: "bin"),
                    to: cancelOutput, connections: 4, bandwidth: nil, onProgress: { _, _ in }
                )
            }
            try? await Task.sleep(nanoseconds: 150_000_000)
            slow.cancel()
            _ = try? await slow.value
            let cancelElapsed = Double(DispatchTime.now().uptimeNanoseconds
                                       - cancelStart.uptimeNanoseconds) / 1_000_000_000
            check("cancel during probe", cancelElapsed < 1.0,
                  String(format: "%.2fs", cancelElapsed))
            localServer.mode = .normal

            // 8. A changed remote file (new ETag) must not be spliced onto the
            //    bytes of the old version.
            localServer.etag = "\"v1\""
            let etagOutput = tempDirectory.appendingPathComponent("etag.bin")
            try FileManager.default.copyItem(at: sourceURL, to: etagOutput)
            let half = Int64(size / 2)
            let etagHandle = try FileHandle(forWritingTo: etagOutput)
            try etagHandle.truncate(atOffset: UInt64(half))
            try etagHandle.close()
            let oldSidecar = ResumeFixture.make(url: remote.absoluteString, total: Int64(size),
                                                etag: "\"v1\"", chunks: [chunk, chunk, 0, 0])
            try JSONEncoder().encode(oldSidecar)
                .write(to: etagOutput.appendingPathExtension("omni-resume"))

            // Same size, different bytes: only the ETag reveals the change.
            try makePatternFile(at: sourceURL, size: size, offset: 7)
            localServer.etag = "\"v2\""
            _ = try await FileFetcher.shared.fetch(
                RemoteFile(url: remote, headers: [:], kind: .video, fileExtension: "bin"),
                to: etagOutput, connections: 4, bandwidth: nil, onProgress: { _, _ in }
            )
            check("etag change restarts",
                  (try? sha256(of: etagOutput)) == (try? sha256(of: sourceURL)))
            localServer.etag = nil

            // 9. Image notes land in a folder of numbered files.
            let imageSource = tempDirectory.appendingPathComponent("image.bin")
            try makePatternFile(at: imageSource, size: 64 * 1024)
            let imageServer = try LocalRangeServer(fileURL: imageSource)
            defer { imageServer.stop() }
            let imagePort = try await imageServer.start()
            let imageFiles = (1...3).map { index in
                RemoteFile(url: URL(string: "http://127.0.0.1:\(imagePort)/img\(index).jpg")!,
                           headers: [:], kind: .image, fileExtension: "jpg")
            }
            let imageInfo = MediaInfo(title: "图文测试",
                                      files: imageFiles,
                                      formats: [FormatOption(id: "images", label: "图文 3 张", ext: "jpg")],
                                      selectedFormatID: "images",
                                      suggestedExtension: "jpg",
                                      engineID: "xiaohongshu",
                                      extra: ["kind": "images"])
            let imageDirectory = tempDirectory.appendingPathComponent("images", isDirectory: true)
            let imageRequest = DownloadRequest(info: imageInfo, options: DownloadOptions(),
                                               destinationDirectory: imageDirectory,
                                               baseName: "note")
            let imageFolder = try await XiaohongshuEngine().download(imageRequest,
                                                                    onProgress: { _, _ in })
            let imageNames = ((try? FileManager.default.contentsOfDirectory(atPath: imageFolder.path)) ?? []).sorted()
            check("xhs image download", imageNames == ["01.jpg", "02.jpg", "03.jpg"],
                  "\(imageNames)")
            let imageHash = try sha256(of: imageSource)
            let intact = try imageNames.allSatisfy { try sha256(of: imageFolder.appendingPathComponent($0)) == imageHash }
            check("album fetches each image once", intact && imageServer.requestCount == imageFiles.count)
            let duplicate = try await NativeAlbum.download(imageRequest, onProgress: { _, _ in })
            check("repeated albums keep both folders", duplicate != imageFolder && MediaOutput.itemCount(in: duplicate) == 3)
            let loginPage = RemoteFile(url: URL(string: "http://127.0.0.1:\(imagePort)/login.jpg")!, kind: .image, fileExtension: "jpg")
            do {
                _ = try await FileFetcher.shared.fetch(loginPage, to: imageDirectory.appendingPathComponent("login.jpg"),
                                                       connections: 1, bandwidth: nil, onProgress: { _, _ in })
                check("html login response rejected during transfer", false)
            } catch { check("html login response rejected during transfer", error is FetchError) }

            let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jPioAAAAASUVORK5CYII=")!
            try png.write(to: imageSource)
            let mislabeled = try await NativeAlbum.download(imageRequest, onProgress: { _, _ in })
            check("album names CDN images by actual format", (try? Data(contentsOf: mislabeled.appendingPathComponent("01.png"))) == png &&
                  !FileManager.default.fileExists(atPath: mislabeled.appendingPathComponent("01.jpg").path))

            if let ffmpeg = MediaMerger.ffmpegPath() {
                let sample = tempDirectory.appendingPathComponent("channel-sample.mp4")
                let generated = try await Shell.run(ffmpeg, ["-v", "error", "-f", "lavfi", "-i", "color=blue:s=160x90",
                    "-f", "lavfi", "-i", "sine=frequency=440", "-t", "0.4", "-c:v", "libx264", "-c:a", "aac", sample.path])
                guard generated.succeeded else { throw EngineError.probeFailed("无法生成测试视频") }
                let streamServer = try LocalRangeServer(fileURL: sample)
                defer { streamServer.stop() }
                let port = try await streamServer.start()
                var channel = MediaInfo(title: "频道", files: [RemoteFile(url: URL(string: "http://127.0.0.1:\(port)/v.mp4")!)], engineID: "wechat")
                var request = DownloadRequest(info: channel, options: .init(), destinationDirectory: imageDirectory, baseName: "频道")
                let film = try await WeChatChannelsEngine().download(request) { _, _ in }
                check("wechat saves a playable video", (try? sha256(of: film)) == (try? sha256(of: sample)))
                request.options.audioOnly = true
                let sound = try await WeChatChannelsEngine().download(request) { _, _ in }
                let asset = AVURLAsset(url: sound)
                let videoTracks = try await asset.loadTracks(withMediaType: .video)
                let audioTracks = try await asset.loadTracks(withMediaType: .audio)
                check("muxed video saves real audio only", sound.pathExtension == "m4a" && videoTracks.isEmpty && audioTracks.count == 1)
                channel.files = [RemoteFile(url: imageFiles[0].url)]
                request = DownloadRequest(info: channel, options: .init(), destinationDirectory: imageDirectory, baseName: "不可播放")
                do {
                    _ = try await WeChatChannelsEngine().download(request) { _, _ in }
                    check("wechat refuses unplayable payload", false)
                } catch {
                    check("wechat refuses unplayable payload", !FileManager.default.fileExists(atPath: imageDirectory.appendingPathComponent("不可播放.mp4").path))
                }
            }
        } catch {
            check("local range server", false, "\(error)")
        }
        server?.stop()

        print(failures == 0 ? "RESULT  all checks passed" : "RESULT  \(failures) failure(s)")
        return failures == 0 ? 0 : 1
    }

    // MARK: - Fixtures

    private static func makePatternFile(at url: URL, size: Int, offset: Int = 0) throws {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        var block = Data(count: 64 * 1024)
        for index in 0..<block.count {
            block[index] = UInt8((index + offset) % 251)
        }
        var written = 0
        while written < size {
            let chunk = min(block.count, size - written)
            try handle.write(contentsOf: block.prefix(chunk))
            written += chunk
        }
    }

    private static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let data = try handle.read(upToCount: 4 * 1024 * 1024), !data.isEmpty {
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

private final class Counter: @unchecked Sendable {
    private var storage = 0
    private let lock = NSLock()
    func increment() { lock.lock(); storage += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return storage }
}

private struct ResumeFixture: Codable {
    var url: String
    var total: Int64
    var etag: String?
    var chunks: [Int64]

    static func make(url: String, total: Int64, etag: String? = nil,
                     chunks: [Int64]) -> ResumeFixture {
        ResumeFixture(url: url, total: total, etag: etag, chunks: chunks)
    }
}

/// Minimal HTTP/1.1 file server with Range support, bound to loopback.
final class LocalRangeServer: @unchecked Sendable {
    enum Mode {
        case normal
        /// Answers the `bytes=0-0` probe with 206, then ignores Range and
        /// sends the whole file — the exact case that used to corrupt chunks.
        case liesAboutRange
        /// Announces the real size to the probe, then sends only half of it.
        case shortBody
        case cappedRange
        /// Delays every response, so cancellation can be timed.
        case stall
        case slow
    }

    private let listener: NWListener
    private let fileURL: URL
    private let queue = DispatchQueue(label: "omnifetch.selftest.server", attributes: .concurrent)
    private let lock = NSLock()
    private var requests = 0
    private var servedBytes: Int64 = 0
    private var fullBodies = 0
    private var currentMode: Mode = .normal
    private var currentETag: String?

    var requestCount: Int { lock.lock(); defer { lock.unlock() }; return requests }
    var bytesServed: Int64 { lock.lock(); defer { lock.unlock() }; return servedBytes }
    var fullBodyResponses: Int { lock.lock(); defer { lock.unlock() }; return fullBodies }
    var mode: Mode {
        get { lock.lock(); defer { lock.unlock() }; return currentMode }
        set { lock.lock(); currentMode = newValue; lock.unlock() }
    }
    var etag: String? {
        get { lock.lock(); defer { lock.unlock() }; return currentETag }
        set { lock.lock(); currentETag = newValue; lock.unlock() }
    }

    init(fileURL: URL) throws {
        self.fileURL = fileURL
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        listener = try NWListener(using: parameters, on: .any)
    }

    func start() async throws -> UInt16 {
        try await withCheckedThrowingContinuation { continuation in
            let resumed = AtomicFlag()
            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    if resumed.setIfUnset(), let port = self.listener.port?.rawValue {
                        continuation.resume(returning: port)
                    }
                case .failed(let error):
                    if resumed.setIfUnset() { continuation.resume(throwing: error) }
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                self?.handle(connection)
            }
            listener.start(queue: queue)
        }
    }

    func stop() {
        listener.cancel()
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(connection, buffer: Data())
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { connection.cancel(); return }
            var accumulated = buffer
            if let data { accumulated.append(data) }
            if accumulated.range(of: Data("\r\n\r\n".utf8)) != nil {
                self.respond(connection, request: String(decoding: accumulated, as: UTF8.self))
            } else if error != nil || isComplete {
                connection.cancel()
            } else {
                self.receive(connection, buffer: accumulated)
            }
        }
    }

    private func respond(_ connection: NWConnection, request: String) {
        let lines = request.split(separator: "\r\n", omittingEmptySubsequences: false)
        guard let first = lines.first else { connection.cancel(); return }
        let requestParts = first.split(separator: " ")
        let path = requestParts.count > 1 ? String(requestParts[1]) : "/"

        lock.lock()
        requests += 1
        lock.unlock()

        // Lets the failover test simulate an expired CDN signature.
        if path.hasPrefix("/forbidden") {
            let header = "HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
            connection.send(content: Data(header.utf8), completion: .contentProcessed { _ in connection.cancel() })
            return
        }

        lock.lock()
        let stalling = currentMode == .stall
        lock.unlock()
        if stalling { usleep(2_000_000) }

        var rangeStart: Int64 = 0
        var rangeEnd: Int64?
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].lowercased()
            if key == "range" {
                let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                if let eq = value.firstIndex(of: "=") {
                    let parts = value[value.index(after: eq)...].split(separator: "-", omittingEmptySubsequences: false)
                    if let firstPart = parts.first, let start = Int64(firstPart) { rangeStart = start }
                    if parts.count > 1, let end = Int64(parts[1]) { rangeEnd = end }
                }
            }
        }

        lock.lock()
        let isProbe = rangeStart == 0 && rangeEnd == 0
        let lying = currentMode == .liesAboutRange && !isProbe
        let short = currentMode == .shortBody && !isProbe
        lock.unlock()

        let total = (try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? Int64) ?? 0
        var start = rangeStart
        var end = min(rangeEnd ?? (total - 1), total - 1)
        if lying {
            start = 0
            end = total - 1
        } else if short {
            start = 0
            end = max(0, total / 2 - 1)
        } else if mode == .cappedRange && rangeEnd != nil {
            end = min(end, start + 512 * 1024 - 1)
        }
        guard start >= 0, start <= end else {
            let header = "HTTP/1.1 416 Range Not Satisfiable\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
            connection.send(content: Data(header.utf8), completion: .contentProcessed { _ in connection.cancel() })
            return
        }

        let length = end - start + 1
        let body: Data
        do {
            let handle = try FileHandle(forReadingFrom: fileURL)
            defer { try? handle.close() }
            try handle.seek(toOffset: UInt64(start))
            body = try handle.read(upToCount: Int(length)) ?? Data()
        } catch {
            connection.cancel()
            return
        }

        lock.lock()
        servedBytes += Int64(body.count)
        if lying { fullBodies += 1 }
        lock.unlock()

        lock.lock()
        let etagHeader = currentETag
        lock.unlock()

        let isPartial = !lying && !short && rangeEnd != nil
        var header = "HTTP/1.1 \(isPartial ? "206 Partial Content" : "200 OK")\r\n"
        header += path.hasPrefix("/login.jpg") ? "Content-Type: text/html\r\n" : "Content-Type: application/octet-stream\r\n"
        header += "Accept-Ranges: bytes\r\n"
        if let etagHeader { header += "ETag: \(etagHeader)\r\n" }
        header += "Content-Length: \(body.count)\r\n"
        if isPartial {
            header += "Content-Range: bytes \(start)-\(end)/\(total)\r\n"
        }
        header += "Connection: close\r\n\r\n"

        var payload = Data(header.utf8)
        payload.append(body)
        if mode == .slow && !isProbe && body.count > 65_536 {
            let firstEnd = header.utf8.count + 32_768
            let secondEnd = header.utf8.count + 65_536
            connection.send(content: payload.subdata(in: 0..<firstEnd), completion: .contentProcessed { _ in
                self.queue.asyncAfter(deadline: .now() + 0.4) {
                    connection.send(content: payload.subdata(in: firstEnd..<secondEnd), completion: .contentProcessed { _ in
                        self.queue.asyncAfter(deadline: .now() + 0.7) {
                            connection.send(content: payload.subdata(in: secondEnd..<payload.count),
                                            completion: .contentProcessed { _ in connection.cancel() })
                        }
                    })
                }
            })
            return
        }
        connection.send(content: payload, completion: .contentProcessed { _ in connection.cancel() })
    }
}

private final class AtomicFlag: @unchecked Sendable {
    private var flag = false
    private let lock = NSLock()
    func setIfUnset() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if flag { return false }
        flag = true
        return true
    }
}

private final class ProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Int64] = []

    func record(_ value: Int64) {
        lock.lock(); values.append(value); lock.unlock()
    }

    var count: Int { lock.lock(); defer { lock.unlock() }; return values.count }
    var last: Int64 { lock.lock(); defer { lock.unlock() }; return values.last ?? -1 }
}
