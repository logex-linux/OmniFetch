import Darwin
import Foundation

public enum CommandLineTool {
    public static func isLegacyInvocation(_ arguments: [String]) -> Bool {
        guard let first = arguments.first, first.hasPrefix("-") else { return false }
        return Command(argument: first) != nil
    }

    public static func run(arguments: [String]) -> Int32 {
        let done = DispatchGroup()
        var status: Int32 = 1
        done.enter()
        Task.detached {
            status = await execute(arguments)
            done.leave()
        }
        // The macOS login adapters need the main run loop while the CLI waits.
        if Thread.isMainThread {
            done.notify(queue: .main) { CFRunLoopStop(CFRunLoopGetMain()) }
            while done.wait(timeout: .now()) != .success {
                CFRunLoopRunInMode(.defaultMode, 60, false)
            }
        } else {
            done.wait()
        }
        return status
    }

    private static func execute(_ arguments: [String]) async -> Int32 {
        guard let first = arguments.first else { print(usage); return 0 }
        do {
            guard let command = Command(argument: first) else {
                throw UsageError("未知命令 \(first)")
            }
            let flags = arguments.dropFirst()
            if flags.count == 1, flags.first == "--help" || flags.first == "-h" {
                print(usage)
                return 0
            }
            if command != .probe && command != .download && !flags.isEmpty {
                throw UsageError("\(command.rawValue) 不接受参数")
            }
            switch command {
            case .help:
                print(usage)
            case .version:
                print("omnifetch 1.0.0")
            case .sites:
                for site in SocialPlatform.all { print("\(site.name)\t\(site.domains[0])\t\(site.support)") }
                print("完整上游清单\nhttps://github.com/yt-dlp/yt-dlp/blob/master/supportedsites.md")
                print("https://github.com/mikf/gallery-dl/blob/master/docs/supportedsites.md")
            case .installGallery:
                print(try await GalleryDLInstaller.ensureBinary().path)
            case .selftest:
                return await SelfTest.run()
            case .probe, .download:
                let inputs = try Transfer(command: command, arguments: flags)
                return await runInterruptibly { await transfer(inputs) }
            }
            return 0
        } catch let error as UsageError {
            writeError("error: \(terminalText(error.message))\n运行 omnifetch --help 查看用法。\n")
            return 2
        } catch {
            writeError("error: \(terminalText(error.localizedDescription))\n")
            return 1
        }
    }

    private static func transfer(_ inputs: Transfer) async -> Int32 {
        let registry = EngineRegistry.shared
        var reports: [TransferResult] = []
        var failed = false
        for url in inputs.urls {
            if Task.isCancelled { break }
            let routed = registry.engine(for: url)
            var result = TransferResult(url: url.absoluteString, engine: routed.id)
            do {
                let info = inputs.command == .probe
                    ? try await routed.probe(url: url, options: inputs.options)
                    : try await routed.prepareDownload(url: url, options: inputs.options)
                let engine = registry.engine(id: info.engineID) ?? routed
                result.record(info, engine: engine.id)
                if !inputs.json { printMetadata(info, routed: routed.id, engine: engine.id) }

                if inputs.command == .download {
                    try Task.checkCancellation()
                    result.outputPath = try await download(info, using: engine, inputs: inputs).path
                    if !inputs.json, let path = result.outputPath { print("file:   \(terminalText(path))") }
                }
            } catch {
                let interrupted = Task.isCancelled || error is CancellationError
                let message = interrupted ? "已中断。可重新提交链接，继续可续传的下载。" : error.localizedDescription
                result.error = message
                writeError("error: \(terminalText(message))\n")
                failed = true
            }
            reports.append(result)
        }
        if inputs.json {
            do {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
                var data = try encoder.encode(["results": reports])
                data.append(0x0a)
                try FileHandle.standardOutput.write(contentsOf: data)
            } catch {
                writeError("error: \(terminalText(error.localizedDescription))\n")
                return 1
            }
        }
        return failed ? 1 : 0
    }

    private static func download(_ info: MediaInfo, using engine: DownloadEngine, inputs: Transfer) async throws -> URL {
        let directory = inputs.outputDirectory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var options = inputs.options
        if options.formatID == nil { options.formatID = info.selectedFormatID }
        let request = DownloadRequest(info: info, options: options, destinationDirectory: directory,
                                      baseName: MediaNaming.sanitize(info.title))
        let showProgress = !inputs.json && isatty(STDERR_FILENO) != 0
        let started = ProcessInfo.processInfo.systemUptime
        defer { if showProgress { writeError("\n") } }
        return try await engine.download(request) { done, total in
            guard showProgress else { return }
            let progress: String
            if info.isItemCollection {
                progress = total > 0 ? "\(done)/\(total) 项" : "已保存 \(done) 项"
            } else {
                let elapsed = max(0.001, ProcessInfo.processInfo.systemUptime - started)
                let rate = Int64(exactly: (Double(done) / elapsed).rounded(.down)) ?? Int64.max
                let percent = total > 0 ? String(format: "%.1f%%", Double(done) / Double(total) * 100) : "?"
                let expected = total > 0 ? byteCount(total) : "?"
                progress = "\(percent)  \(byteCount(done)) / \(expected)  \(byteCount(rate))/s"
            }
            writeError("\r\u{001B}[2K" + progress)
        }
    }

    private static func runInterruptibly(_ operation: @escaping @Sendable () async -> Int32) async -> Int32 {
        let work = Task { await operation() }
        let sources = [SIGINT, SIGTERM].map { number in
            // A caught signal gets its default disposition after exec in child processes.
            _ = signal(number) { _ in }
            let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
            source.setEventHandler { work.cancel() }
            source.activate()
            return source
        }
        let status = await work.value
        sources.forEach { $0.cancel() }
        return work.isCancelled ? 130 : status
    }

    private static func printMetadata(_ info: MediaInfo, routed: String, engine: String) {
        print("engine: \(routed)")
        if engine != routed { print("download engine: \(engine)") }
        if info.isItemCollection { print("collection: " + terminalText(info.extra["count"] ?? "按实际媒体数保存")) }
        print("title:  \(terminalText(info.title))")
        print("site:   \(terminalText(info.site ?? "-"))")
        if !info.formats.isEmpty {
            print("formats: " + info.formats.map { terminalText("\($0.id) (\($0.label))") }.joined(separator: ", "))
        }
        if let parts = info.parts, parts.count > 1 {
            print("parts:  \(parts.count)（可用 ?p=N 分别下载）")
        }
        fflush(stdout)
    }

    private static func byteCount(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private static func terminalText(_ text: String) -> String {
        text.components(separatedBy: .controlCharacters).joined(separator: " ")
    }

    private static func writeError(_ text: String) {
        try? FileHandle.standardError.write(contentsOf: Data(text.utf8))
    }

    private static let usage = """
    用法
      omnifetch probe <链接或分享文案>... [选项]
      omnifetch download <链接或分享文案>... [选项]
      omnifetch sites | install-gallery | selftest
      omnifetch --help | --version

    probe 和 download 都接受多个输入。用 - 从标准输入读取链接。

    选项
      --json                      在标准输出写入一个 JSON 结果对象
      --quality <best|1080|4k>      设定画质上限，默认 best
      --format <ID>                选择 probe 显示的格式 ID
      --audio                      提取音频
      --cookies-from-browser <名>  使用指定浏览器的登录会话
      --xhs-app-session            使用 macOS 上的小红书 WebKit 会话

    下载选项
      -o, --out <目录>             指定输出目录，默认 ~/Movies/OmniFetch
      --connections <1–16>         设置直链分片连接数，默认 6
      --limit-kbps <KiB/s>         设置下载限速
    """

    private enum Command: String, Sendable {
        case help, version, sites, selftest, probe, download
        case installGallery = "install-gallery"

        init?(argument: String) {
            if argument == "-h" { self = .help }
            else if argument.hasPrefix("--") { self.init(rawValue: String(argument.dropFirst(2))) }
            else { self.init(rawValue: argument) }
        }
    }

    private struct Transfer: Sendable {
        let command: Command
        let urls: [URL]
        let options: DownloadOptions
        let outputDirectory: URL
        let json: Bool

        init(command: Command, arguments: ArraySlice<String>) throws {
            var remaining = arguments
            var options = DownloadOptions()
            var outputDirectory = AppPaths.defaultDownloadDirectory
            var json = false
            var inputs: [String] = []

            func value(for flag: String) throws -> String {
                guard let value = remaining.popFirst(), !value.isEmpty, !value.hasPrefix("-") else {
                    throw UsageError("\(flag) 缺少参数")
                }
                return value
            }

            while let arg = remaining.popFirst() {
                switch arg {
                case "--":
                    inputs.append(contentsOf: remaining)
                    remaining = []
                case "--json": json = true
                case "--audio": options.audioOnly = true
                case "--xhs-app-session": options.useXHSAppSession = true
                case "--format": options.formatID = try value(for: arg)
                case "--cookies-from-browser": options.cookiesFromBrowser = try value(for: arg)
                case "--quality":
                    let quality = try value(for: arg).lowercased()
                    guard quality == "best" || Quality.targetHeight(quality) != nil else {
                        throw UsageError("--quality 需要 best 或有效分辨率，如 1080、4k")
                    }
                    options.quality = quality
                case "-o", "--out", "--connections", "--limit-kbps":
                    guard command == .download else { throw UsageError("\(arg) 仅适用于 download") }
                    let input = try value(for: arg)
                    if arg == "-o" || arg == "--out" {
                        outputDirectory = URL(fileURLWithPath: (input as NSString).expandingTildeInPath, isDirectory: true)
                    } else if arg == "--connections" {
                        guard let count = Int(input), (1...16).contains(count) else {
                            throw UsageError("--connections 需要 1 至 16 的整数")
                        }
                        options.connections = count
                    } else {
                        guard let rate = Int(input), (1...Int.max / 1024).contains(rate) else {
                            throw UsageError("--limit-kbps 需要有效的正整数")
                        }
                        options.bandwidth = rate * 1024
                    }
                default:
                    guard !arg.hasPrefix("-") || arg == "-" else { throw UsageError("未知选项 \(arg)") }
                    inputs.append(arg)
                }
            }

            guard !inputs.isEmpty else { throw UsageError("请提供链接或用 - 读取标准输入") }
            guard inputs.filter({ $0 == "-" }).count < 2 else { throw UsageError("标准输入只需传入一次 -") }
            var seen = Set<URL>()
            var urls: [URL] = []
            for input in inputs {
                let text = input == "-" ? String(decoding: try FileHandle.standardInput.readToEnd() ?? Data(), as: UTF8.self) : input
                let parsed = ShareLinks.parse(text)
                guard !parsed.isEmpty else { throw UsageError("输入中没有有效的 HTTP(S) 媒体链接") }
                urls.append(contentsOf: parsed.filter { seen.insert($0).inserted })
            }
            if let cookie = ProcessInfo.processInfo.environment["OMNI_COOKIE"], !cookie.isEmpty {
                guard Set(urls.map(Self.origin)).count == 1 else {
                    throw UsageError("设置 OMNI_COOKIE 时，每批链接须来自同一来源")
                }
                options.cookieHeader = cookie
            }

            self.command = command
            self.urls = urls
            self.options = options
            self.outputDirectory = outputDirectory.standardizedFileURL
            self.json = json
        }

        private static func origin(_ url: URL) -> String {
            let scheme = url.scheme?.lowercased() ?? "https"
            return "\(scheme)://\(url.host?.lowercased() ?? ""):\(url.port ?? (scheme == "https" ? 443 : 80))"
        }
    }

    private struct TransferResult: Encodable {
        let url: String
        var engine: String
        var title: String?
        var site: String?
        var duration: Double?
        var formats: [FormatOption]?
        var selectedFormatID: String?
        var parts: [MediaPart]?
        var isCollection: Bool?
        var outputPath: String?
        var error: String?

        mutating func record(_ info: MediaInfo, engine: String) {
            self.engine = engine
            title = info.title
            site = info.site
            duration = info.duration
            formats = info.formats
            selectedFormatID = info.selectedFormatID
            parts = info.parts
            isCollection = info.isItemCollection
        }
    }

    private struct UsageError: Error {
        let message: String
        init(_ message: String) { self.message = message }
    }
}
