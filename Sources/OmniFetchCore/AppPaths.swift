import Foundation

public enum AppPaths {
    public static let appName = "OmniFetch"

    public static let supportDirectory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent(appName, isDirectory: true)
    }()

    public static let cacheDirectory: URL = {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Caches")
        return base.appendingPathComponent(appName, isDirectory: true)
    }()

    public static let binDirectory = supportDirectory.appendingPathComponent("bin", isDirectory: true)
    public static let tasksFile = supportDirectory.appendingPathComponent("tasks.json")
    public static let settingsFile = supportDirectory.appendingPathComponent("settings.json")

    public static var defaultDownloadDirectory: URL {
        let movies = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory())
        return movies.appendingPathComponent("OmniFetch", isDirectory: true)
    }

    @discardableResult
    public static func ensureDirectories() -> Bool {
        let fm = FileManager.default
        for dir in [supportDirectory, binDirectory, cacheDirectory] {
            if !fm.fileExists(atPath: dir.path) {
                try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            }
        }
        return true
    }
}

public enum Log {
    private static let queue = DispatchQueue(label: "omnifetch.log")
    /// Keeps the log bounded; downloaders run for hours and log per retry.
    private static let maxBytes: UInt64 = 2 * 1024 * 1024
    private static var written: UInt64 = 0
    private static let handle: FileHandle? = {
        AppPaths.ensureDirectories()
        let url = AppPaths.supportDirectory.appendingPathComponent("omnifetch.log")
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        let h = try? FileHandle(forWritingTo: url)
        written = h?.seekToEndOfFile() ?? 0
        return h
    }()

    public static func write(_ message: String) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        let line = "[\(stamp)] \(message)\n"
        queue.async {
            if let data = line.data(using: .utf8), let handle {
                if written + UInt64(data.count) > maxBytes {
                    try? handle.truncate(atOffset: 0)
                    written = 0
                }
                handle.write(data)
                written += UInt64(data.count)
            }
            #if DEBUG
            FileHandle.standardError.write(line.data(using: .utf8) ?? Data())
            #endif
        }
    }
}
