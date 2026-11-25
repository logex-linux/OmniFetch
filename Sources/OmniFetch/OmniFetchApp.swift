import SwiftUI
import AppKit
import UserNotifications
import OmniFetchCore

@main
enum OmniFetchMain {
    @MainActor static func main() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if CommandLineTool.isLegacyInvocation(arguments) {
            exit(CommandLineTool.run(arguments: arguments))
        }
        if let idx = CommandLine.arguments.firstIndex(of: "--render-ui-snapshots"),
           CommandLine.arguments.count > idx + 1 {
            exit(DesignSnapshotExporter.run(outputDir: CommandLine.arguments[idx + 1]))
        }
        OmniFetchApp.main()
    }
}

struct OmniFetchApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var manager = DownloadManager.shared

    init() {
        AppPaths.ensureDirectories()
        Self.configureImageCache()
    }

    /// Thumbnails are re-decoded on every scroll and relaunch with the default
    /// 512 KB cache; give them a real disk cache instead.
    private static func configureImageCache() {
        let directory = AppPaths.cacheDirectory.appendingPathComponent("http", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        URLCache.shared = URLCache(memoryCapacity: 32 * 1024 * 1024,
                                   diskCapacity: 256 * 1024 * 1024,
                                   directory: directory)
    }

    var body: some Scene {
        WindowGroup("OmniFetch") {
            ContentView()
                .environmentObject(manager)
                .frame(minWidth: 920, minHeight: 580)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1080, height: 680)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("新建下载…") {
                    NotificationCenter.default.post(name: .omniShowAdd, object: nil)
                }
                .keyboardShortcut("n", modifiers: .command)

                Button("从剪贴板解析") {
                    NotificationCenter.default.post(name: .omniAddFromClipboard, object: nil)
                }
                .keyboardShortcut("v", modifiers: [.command, .shift])

                Divider()

                Button("聚焦快速输入框") {
                    NotificationCenter.default.post(name: .omniFocusQuickInput, object: nil)
                }
                .keyboardShortcut("l", modifiers: .command)

                Button("搜索任务") {
                    NotificationCenter.default.post(name: .omniFocusSearch, object: nil)
                }
                .keyboardShortcut("f", modifiers: .command)
            }

            CommandMenu("队列") {
                Button("全部任务") {
                    NotificationCenter.default.post(name: .omniSelectFilter, object: TaskFilter.all)
                }
                .keyboardShortcut("1", modifiers: .command)

                Button("进行中") {
                    NotificationCenter.default.post(name: .omniSelectFilter, object: TaskFilter.active)
                }
                .keyboardShortcut("2", modifiers: .command)

                Button("已完成") {
                    NotificationCenter.default.post(name: .omniSelectFilter, object: TaskFilter.completed)
                }
                .keyboardShortcut("3", modifiers: .command)

                Button("异常") {
                    NotificationCenter.default.post(name: .omniSelectFilter, object: TaskFilter.failed)
                }
                .keyboardShortcut("4", modifiers: .command)

                Divider()

                Button("暂停 / 继续全部") {
                    NotificationCenter.default.post(name: .omniTogglePauseAll, object: nil)
                }
                .keyboardShortcut("p", modifiers: [.command, .option])

                Button("清除已完成记录") {
                    NotificationCenter.default.post(name: .omniClearCompleted, object: nil)
                }
                .keyboardShortcut("k", modifiers: .command)
            }
        }

        Settings {
            SettingsView()
                .environmentObject(manager)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        if CompletionNotifier.isAvailable {
            UNUserNotificationCenter.current().delegate = self
        }
        ClipboardWatcher.shared.start()
    }

    /// Show the banner even when the app is in the foreground.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    /// Clicking the notification reveals the finished file.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        if let path = response.notification.request.content.userInfo["path"] as? String {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
        }
        completionHandler()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationWillTerminate(_ notification: Notification) {
        DownloadManager.shared.persist()
    }
}

extension Notification.Name {
    static let omniShowAdd = Notification.Name("omni.showAdd")
    static let omniAddFromClipboard = Notification.Name("omni.addFromClipboard")
    static let omniFocusQuickInput = Notification.Name("omni.focusQuickInput")
    static let omniFocusSearch = Notification.Name("omni.focusSearch")
    static let omniSelectFilter = Notification.Name("omni.selectFilter")
    static let omniTogglePauseAll = Notification.Name("omni.togglePauseAll")
    static let omniClearCompleted = Notification.Name("omni.clearCompleted")
}

/// Optional clipboard watcher: detects a copied video link and surfaces it.
final class ClipboardWatcher {
    static let shared = ClipboardWatcher()
    private var timer: Timer?
    private var lastChangeCount = NSPasteboard.general.changeCount
    private(set) var pendingURL: String?

    /// Starts or stops the poll timer according to the setting, so a disabled
    /// watcher costs nothing.
    func start() {
        let enabled = SettingsStore.load().clipboardWatch
        if enabled, timer != nil { return }
        timer?.invalidate()
        timer = nil
        guard enabled else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            self?.tick()
        }
    }

    private func tick() {
        guard SettingsStore.load().clipboardWatch else {
            timer?.invalidate()
            timer = nil
            return
        }
        let pasteboard = NSPasteboard.general
        guard pasteboard.changeCount != lastChangeCount else { return }
        lastChangeCount = pasteboard.changeCount
        guard let text = pasteboard.string(forType: .string),
              let url = DownloadManager.parseURL(text),
              Self.looksLikeMedia(url) else { return }
        pendingURL = url.absoluteString
        NotificationCenter.default.post(name: .omniShowAdd, object: url.absoluteString)
    }

    static func looksLikeMedia(_ url: URL) -> Bool {
        DirectMediaEngine().canHandle(url) || ["m3u8", "mpd"].contains(url.pathExtension.lowercased())
            || SocialPlatform.match(url) != nil
    }
}
