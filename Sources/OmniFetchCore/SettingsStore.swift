import Foundation

public enum SettingsStore {
    private static let lock = NSLock()
    private static var cached: AppSettings?

    public static func load() -> AppSettings {
        lock.lock()
        defer { lock.unlock() }
        if let cached { return cached }
        AppPaths.ensureDirectories()
        var settings = AppSettings()
        if let data = try? Data(contentsOf: AppPaths.settingsFile),
           let decoded = try? JSONDecoder().decode(AppSettings.self, from: data) {
            settings = decoded
        }
        cached = settings
        return settings
    }

    public static func save(_ settings: AppSettings) {
        lock.lock()
        cached = settings
        lock.unlock()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(settings) {
            try? data.write(to: AppPaths.settingsFile, options: .atomic)
            // The file can hold a raw Cookie header.
            try? FileManager.default.setAttributes([.posixPermissions: 0o600],
                                                   ofItemAtPath: AppPaths.settingsFile.path)
        }
    }

    public static func update(_ mutate: (inout AppSettings) -> Void) {
        var settings = load()
        mutate(&settings)
        save(settings)
    }
}
