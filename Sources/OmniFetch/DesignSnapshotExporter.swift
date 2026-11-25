import SwiftUI
import AppKit
import OmniFetchCore

/// Renders deterministic Retina (2x) Light & Dark PNG snapshots of OmniFetch views
/// for visual audit without touching persisted user queues.
@MainActor
enum DesignSnapshotExporter {
    static func run(outputDir: String) -> Int32 {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)

        let outURL = URL(fileURLWithPath: outputDir, isDirectory: true)
        try? FileManager.default.createDirectory(at: outURL, withIntermediateDirectories: true)

        let manager = DownloadManager.shared
        let tasks = sampleTasks()
        let sparkline: [Double] = [
            0, 2.4e6, 5.1e6, 9.8e6, 12.6e6, 14.2e6, 15.8e6, 16.4e6,
            15.9e6, 17.8e6, 19.2e6, 18.6e6, 17.4e6, 18.9e6, 20.3e6,
            21.1e6, 19.7e6, 18.5e6, 19.4e6, 21.8e6, 22.4e6, 20.9e6,
            19.6e6, 20.8e6, 21.5e6, 22.1e6, 21.3e6, 21.9e6
        ]

        let mainQueue = ContentView(previewTasks: tasks, previewSpeedHistory: sparkline)
            .environmentObject(manager)
        let mainEmpty = ContentView(previewTasks: [], previewSpeedHistory: [])
            .environmentObject(manager)
        let addSheet = AddDownloadView(
            prefilledURL: "https://www.bilibili.com/video/BV1C8xn6YEDA",
            previewInfo: sampleProbedInfo()
        ).environmentObject(manager)
        let settingsGeneral = SettingsView(initialTab: .general)
            .environmentObject(manager)
        let settingsEngines = SettingsView(initialTab: .engines)
            .environmentObject(manager)

        var ok = true
        ok = ok && render(mainQueue, size: CGSize(width: 1080, height: 680), dark: false, to: outURL.appendingPathComponent("queue_light.png"))
        ok = ok && render(mainQueue, size: CGSize(width: 1080, height: 680), dark: true, to: outURL.appendingPathComponent("queue_dark.png"))
        ok = ok && render(mainEmpty, size: CGSize(width: 1080, height: 680), dark: false, to: outURL.appendingPathComponent("empty_light.png"))
        ok = ok && render(mainEmpty, size: CGSize(width: 1080, height: 680), dark: true, to: outURL.appendingPathComponent("empty_dark.png"))
        ok = ok && render(addSheet, size: CGSize(width: 600, height: 540), dark: false, to: outURL.appendingPathComponent("add_light.png"))
        ok = ok && render(addSheet, size: CGSize(width: 600, height: 540), dark: true, to: outURL.appendingPathComponent("add_dark.png"))
        ok = ok && render(settingsGeneral, size: CGSize(width: 560, height: 556), dark: false, to: outURL.appendingPathComponent("settings_general_light.png"))
        ok = ok && render(settingsEngines, size: CGSize(width: 560, height: 556), dark: true, to: outURL.appendingPathComponent("settings_engines_dark.png"))

        print(ok ? "snapshots exported to \(outputDir)" : "snapshot export failed")
        return ok ? 0 : 1
    }

    private static func render<V: View>(_ view: V, size: CGSize, dark: Bool, to url: URL) -> Bool {
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)!
        let framed = view
            .frame(width: size.width, height: size.height)
            .environment(\.colorScheme, dark ? .dark : .light)

        let host = NSHostingView(rootView: framed)
        host.appearance = appearance
        host.frame = CGRect(origin: .zero, size: size)
        host.wantsLayer = true

        let window = NSWindow(
            contentRect: CGRect(origin: .zero, size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.appearance = appearance
        window.contentView = host
        window.isReleasedWhenClosed = false
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))

        let scale: CGFloat = 2.0
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(size.width * scale),
            pixelsHigh: Int(size.height * scale),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return false }
        rep.size = size

        appearance.performAsCurrentDrawingAppearance {
            NSGraphicsContext.saveGraphicsState()
            if let ctx = NSGraphicsContext(bitmapImageRep: rep) {
                NSGraphicsContext.current = ctx
                host.displayIgnoringOpacity(host.bounds, in: ctx)
            }
            NSGraphicsContext.restoreGraphicsState()
        }

        guard let data = rep.representation(using: .png, properties: [:]) else { return false }
        do {
            try data.write(to: url)
            return true
        } catch {
            return false
        }
    }

    private static func sampleTasks() -> [DownloadTask] {
        var t1 = DownloadTask(url: "https://www.bilibili.com/video/BV1C8xn6YEDA", title: "从 0 到 1 理解 Apple Silicon 统一内存架构与 GPU 带宽瓶颈分析（4K 60fps 精校版）")
        t1.site = "哔哩哔哩"
        t1.formatLabel = "4K · AVC1 + M4A"
        t1.duration = 1482
        t1.state = .downloading
        t1.progress = 0.64
        t1.downloadedBytes = 412_876_800
        t1.totalBytes = 645_120_000
        t1.speed = 16_800_000
        t1.eta = 14
        t1.engineID = "bilibili"

        var t2 = DownloadTask(url: "https://www.xiaohongshu.com/explore/671a0b2c", title: "京都鸭川秋日光影与 Leica Q3 28mm 胶片直出色彩实拍合集")
        t2.site = "小红书"
        t2.formatLabel = "有序图集"
        t2.progressInItems = true
        t2.state = .downloading
        t2.progress = 0.66
        t2.downloadedBytes = 6
        t2.totalBytes = 9
        t2.speed = 5_100_000
        t2.engineID = "xiaohongshu"

        var t3 = DownloadTask(url: "https://www.youtube.com/watch?v=dQw4w9WgXcQ", title: "Designing Fluid Interfaces — WWDC Architecture & Spring Physics Breakdown")
        t3.site = "YouTube"
        t3.formatLabel = "1080P"
        t3.duration = 3815
        t3.state = .merging
        t3.progress = 0.98
        t3.downloadedBytes = 284_000_000
        t3.totalBytes = 284_000_000
        t3.engineID = "ytdlp"

        var t4 = DownloadTask(url: "https://x.com/studio/status/18472910482", title: "Motion reel breakdown: optical collimator rig and frame pacing benchmark")
        t4.site = "X / Twitter"
        t4.formatLabel = "1080P"
        t4.duration = 114
        t4.state = .paused
        t4.progress = 0.42
        t4.downloadedBytes = 38_400_000
        t4.totalBytes = 91_428_000
        t4.engineID = "xmedia"

        var t5 = DownloadTask(url: "https://www.bilibili.com/video/BV1xx411c7mD", title: "现代排版与瑞士网格：数字界面中的字阶、留白与信息密度")
        t5.site = "哔哩哔哩"
        t5.formatLabel = "1080P"
        t5.duration = 942
        t5.state = .completed
        t5.progress = 1.0
        t5.downloadedBytes = 158_400_000
        t5.totalBytes = 158_400_000
        t5.finishedAt = Date().addingTimeInterval(-420)
        t5.filePath = "/tmp/sample.mp4"
        t5.engineID = "bilibili"

        var t6 = DownloadTask(url: "https://finder.video.qq.com/sph/expired-token", title: "微信视频号分享片段 · 建筑光影记录")
        t6.site = "微信视频号"
        t6.formatLabel = "1080P"
        t6.state = .failed
        t6.errorMessage = "签名链接已过期，请在高级选项中重新登录腾讯元宝后重试"
        t6.engineID = "wechat"

        return [t1, t2, t3, t4, t5, t6]
    }

    private static func sampleProbedInfo() -> MediaInfo {
        MediaInfo(
            title: "从 0 到 1 理解 Apple Silicon 统一内存架构与 GPU 带宽瓶颈分析",
            site: "哔哩哔哩",
            thumbnail: nil,
            duration: 1482,
            files: [],
            formats: [
                FormatOption(id: "120", label: "4K 超清", ext: "mp4", height: 2160, note: "AVC1 · DASH"),
                FormatOption(id: "80", label: "1080P 高清", ext: "mp4", height: 1080, note: "AVC1 · DASH"),
                FormatOption(id: "64", label: "720P 高清", ext: "mp4", height: 720, note: "AVC1")
            ],
            selectedFormatID: "120",
            suggestedExtension: "mp4",
            engineID: "bilibili",
            selfDownloading: false,
            parts: [
                MediaPart(index: 1, title: "统一内存总线与 SLC 缓存", duration: 680),
                MediaPart(index: 2, title: "GPU 带宽实测与 Metal 调度", duration: 802)
            ],
            extra: ["webpage": "https://www.bilibili.com/video/BV1C8xn6YEDA"]
        )
    }
}
