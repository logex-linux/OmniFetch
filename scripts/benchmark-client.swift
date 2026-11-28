import Foundation
import OmniFetchCore

// Compiling against an older checkout uses its original per-link entry point.
// A package with a concrete batch method takes precedence over this extension.
private protocol QueueBenchmark {}
extension DownloadManager: QueueBenchmark {}
private extension QueueBenchmark where Self: DownloadManager {
    @MainActor func add(urls: [URL], options: DownloadOptions?, start: Bool) {
        for url in urls { _ = add(url: url.absoluteString, options: options, start: start) }
    }
}

@main
struct BenchmarkClient {
    @MainActor static func main() async throws {
        let args = CommandLine.arguments
        let root = URL(string: args[2])!
        if args[1] == "queue" {
            let home = ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"]!
            let supportHome = AppPaths.supportDirectory.deletingLastPathComponent()
                .deletingLastPathComponent().deletingLastPathComponent()
            precondition(supportHome.resolvingSymlinksInPath().path ==
                         URL(fileURLWithPath: home).resolvingSymlinksInPath().path)
            let manager = DownloadManager()
            precondition(manager.tasks.isEmpty)
            let urls = (0..<500).map { root.appendingPathComponent("job-\($0).mp4") }
            let start = ContinuousClock.now
            manager.add(urls: urls, options: DownloadOptions(), start: false)
            let elapsed = start.duration(to: .now).components
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let saved = try decoder.decode([DownloadTask].self, from: Data(contentsOf: AppPaths.tasksFile))
            precondition(saved.map(\.url) == urls.reversed().map(\.absoluteString))
            precondition(saved.map(\.id) == manager.tasks.map(\.id))
            print(Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18)
        } else {
            let files = (1...24).map { index in
                RemoteFile(url: root.appendingPathComponent("image-\(index).jpg"), kind: .image, fileExtension: "jpg")
            }
            let info = MediaInfo(title: "album", files: files, engineID: "xiaohongshu", extra: ["kind": "images"])
            let options = DownloadOptions(connections: args.count > 4 ? Int(args[4])! : 6)
            let request = DownloadRequest(info: info, options: options,
                                          destinationDirectory: URL(fileURLWithPath: args[3]), baseName: "album")
            _ = try await XiaohongshuEngine().download(request) { _, _ in }
        }
    }
}
