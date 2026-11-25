import SwiftUI
import AppKit
import OmniFetchCore

struct AddDownloadView: View {
    @EnvironmentObject private var manager: DownloadManager
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let prefilledURL: String?

    @State private var urlText = ""
    @State private var options: DownloadOptions
    @State private var info: MediaInfo?
    @State private var selectedFormatID: String?
    @State private var quality = "best"
    @State private var audioOnly = false
    @State private var isProbing = false
    @State private var errorText: String?
    @State private var showAdvanced = false
    @State private var saveDirectory: String
    @State private var probeTask: Task<Void, Never>?
    @State private var downloadAllParts = false
    @State private var showYuanbaoLogin = false
    @State private var showXHSLogin = false
    @FocusState private var isURLFocused: Bool

    private var batchURLs: [URL] { DownloadManager.parseURLList(urlText) }
    private var isBatch: Bool { batchURLs.count > 1 }

    private var detectedSiteLabel: String? {
        guard let first = batchURLs.first else { return nil }
        if isBatch { return "批量 \(batchURLs.count) 条" }
        return SocialPlatform.match(first)?.name ?? first.host
    }

    init(prefilledURL: String?, previewInfo: MediaInfo? = nil) {
        self.prefilledURL = prefilledURL
        let settings = SettingsStore.load()
        _options = State(initialValue: DownloadOptions(
            quality: settings.preferredQuality,
            connections: settings.connectionsPerTask
        ))
        _saveDirectory = State(initialValue: settings.saveDirectory)
        _quality = State(initialValue: settings.preferredQuality)
        if let prefilledURL, previewInfo != nil {
            _urlText = State(initialValue: prefilledURL)
        }
        if let previewInfo {
            _info = State(initialValue: previewInfo)
            _selectedFormatID = State(initialValue: previewInfo.selectedFormatID)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Rectangle().fill(OmniColor.line).frame(height: 1)

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    urlSection

                    if isBatch {
                        batchNotice
                            .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .top)))
                    } else {
                        if isProbing {
                            probingRow
                                .transition(.opacity)
                        }
                        if let errorText {
                            errorBanner(errorText)
                                .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .top)))
                        }
                        if let info {
                            infoSection(info)
                                .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .top)))
                        }
                    }

                    advancedSection
                }
                .padding(20)
                .animation(OmniMotion.panel(reduceMotion: reduceMotion), value: info != nil)
                .animation(OmniMotion.panel(reduceMotion: reduceMotion), value: isProbing)
                .animation(OmniMotion.panel(reduceMotion: reduceMotion), value: errorText != nil)
                .animation(OmniMotion.panel(reduceMotion: reduceMotion), value: showAdvanced)
            }

            Rectangle().fill(OmniColor.line).frame(height: 1)
            footer
        }
        .frame(width: 600, height: 540)
        .background(OmniColor.canvas)
        .onAppear {
            guard info == nil else { return }
            if urlText.isEmpty {
                urlText = prefilledURL ?? NSPasteboard.general.string(forType: .string) ?? ""
            }
            if prefilledURL != nil {
                probe()
            } else {
                isURLFocused = true
            }
        }
        .onDisappear { probeTask?.cancel() }
        .sheet(isPresented: $showYuanbaoLogin) {
            PlatformLoginView(
                title: "登录腾讯元宝",
                message: "登录后点击完成，再解析视频号分享链接。",
                url: URL(string: "https://yuanbao.tencent.com/")!
            )
        }
        .sheet(isPresented: $showXHSLogin) {
            PlatformLoginView(
                title: "登录小红书",
                message: "登录后点击完成，再解析笔记。登录状态保存在本机的 OmniFetch 中。",
                url: URL(string: "https://www.xiaohongshu.com/")!
            )
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            OmniMarkView(size: 20, arcColor: OmniColor.accent, arrowColor: OmniColor.ink)
            Text("新建下载")
                .font(OmniFont.sheetTitle)
                .foregroundStyle(OmniColor.ink)

            if let label = detectedSiteLabel {
                Text(label)
                    .font(OmniFont.badge)
                    .foregroundStyle(OmniColor.accent)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(OmniColor.activeFill, in: Capsule(style: .continuous))
            }

            Spacer()

            OmniIconButton(systemName: "xmark", help: "关闭 (Esc)", tint: OmniColor.inkMuted, size: 26) {
                dismiss()
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(OmniColor.surface)
    }

    // MARK: - URL Input

    private var urlSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("媒体链接")
                .font(OmniFont.metaMedium)
                .foregroundStyle(OmniColor.inkMuted)

            HStack(spacing: 8) {
                HStack(spacing: 8) {
                    TextField("https://www.bilibili.com/video/BV…", text: Binding(
                        get: { urlText }, set: { updateURL($0) }
                    ))
                    .textFieldStyle(.plain)
                    .font(OmniFont.body)
                    .foregroundStyle(OmniColor.ink)
                    .focused($isURLFocused)
                    .onSubmit { probe() }

                    OmniIconButton(systemName: "doc.on.clipboard", help: "从剪贴板粘贴并解析", tint: OmniColor.inkMuted, size: 24) {
                        if let text = NSPasteboard.general.string(forType: .string) {
                            updateURL(text)
                            probe()
                        }
                    }
                }
                .padding(.leading, 10)
                .padding(.trailing, 4)
                .frame(height: 34)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(OmniColor.surface)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(isURLFocused ? OmniColor.accent : OmniColor.line, lineWidth: isURLFocused ? 1.5 : 1)
                )

                Button(isProbing ? "解析中…" : "解析") {
                    probe()
                }
                .buttonStyle(OmniButtonStyle(variant: .secondary))
                .disabled(urlText.isEmpty || isProbing || isBatch)
            }

            Text("可直接粘贴带文字的分享消息、BV / av 号，或多条链接进行批量排队。")
                .font(OmniFont.meta)
                .foregroundStyle(OmniColor.inkMuted)
        }
    }

    // MARK: - States (Batch / Probing / Error)

    private var batchNotice: some View {
        HStack(spacing: 10) {
            Image(systemName: "square.stack.3d.up")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(OmniColor.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text("已识别 \(batchURLs.count) 条链接，将批量入队")
                    .font(OmniFont.bodyMedium)
                    .foregroundStyle(OmniColor.ink)
                Text("批量任务使用当前默认画质（\(quality == "best" ? "最佳" : quality + "p")）和分片配置。")
                    .font(OmniFont.meta)
                    .foregroundStyle(OmniColor.inkMuted)
            }
            Spacer()
        }
        .padding(12)
        .background(OmniColor.activeFill, in: RoundedRectangle(cornerRadius: OmniRadius.md, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: OmniRadius.md, style: .continuous)
                .strokeBorder(OmniColor.accentLine, lineWidth: 1)
        )
    }

    private var probingRow: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "sparkle.magnifyingglass")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(OmniColor.accent)
                Text("正在解析媒体元数据与可用轨道…")
                    .font(OmniFont.body)
                    .foregroundStyle(OmniColor.ink)
                Spacer()
            }
            ThroughputTrackView(progress: 0, isActive: true, isIndeterminate: true, isPaused: false)
        }
        .padding(14)
        .background(OmniColor.surface, in: RoundedRectangle(cornerRadius: OmniRadius.md, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: OmniRadius.md, style: .continuous)
                .strokeBorder(OmniColor.line, lineWidth: 1)
        )
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: "exclamationmark.circle.fill")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(OmniColor.danger)
                .padding(.top, 1)
            Text(message)
                .font(OmniFont.body)
                .foregroundStyle(OmniColor.danger)
                .textSelection(.enabled)
            Spacer()
        }
        .padding(12)
        .background(OmniColor.dangerFill, in: RoundedRectangle(cornerRadius: OmniRadius.md, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: OmniRadius.md, style: .continuous)
                .strokeBorder(OmniColor.danger.opacity(0.30), lineWidth: 1)
        )
    }

    // MARK: - Probed Media Preview & Options

    @ViewBuilder
    private func infoSection(_ info: MediaInfo) -> some View {
        let isImageNote = info.extra["kind"] == "gallery"
            || info.extra["kind"] == "images"
            || info.extra["kind"] == "attachments"
            || (!info.files.isEmpty && info.files.allSatisfy { $0.kind == .image })

        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 14) {
                CachedThumbnailView(
                    urlString: info.thumbnail,
                    width: 136,
                    height: 76,
                    cornerRadius: OmniRadius.sm,
                    isCollection: info.isItemCollection || isImageNote,
                    isAudioOnly: audioOnly,
                    durationText: Formatters.duration(info.duration)
                )

                VStack(alignment: .leading, spacing: 6) {
                    Text(info.title)
                        .font(OmniFont.rowTitle)
                        .foregroundStyle(OmniColor.ink)
                        .lineLimit(2)

                    HStack(spacing: 8) {
                        if let site = info.site, !site.isEmpty {
                            Text(site)
                                .font(OmniFont.badge)
                                .foregroundStyle(OmniColor.inkMuted)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1.5)
                                .background(OmniColor.canvas, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                                        .strokeBorder(OmniColor.line, lineWidth: 0.75)
                                )
                        }
                        if let duration = info.duration, duration > 0 {
                            Text(Formatters.duration(duration))
                                .font(OmniFont.telemetrySmall)
                                .foregroundStyle(OmniColor.inkMuted)
                        }
                        if info.isItemCollection {
                            let count = info.extra["count"].flatMap(Int.init) ?? (info.files.isEmpty ? nil : info.files.count)
                            Text(count.map { "\($0) 项合集" } ?? "媒体合集")
                                .font(OmniFont.meta)
                                .foregroundStyle(OmniColor.inkMuted)
                        }
                    }
                }
                Spacer(minLength: 0)
            }

            Rectangle().fill(OmniColor.line).frame(height: 1)

            VStack(alignment: .leading, spacing: 10) {
                if !info.formats.isEmpty && !info.isItemCollection && !audioOnly {
                    HStack {
                        Text("清晰度与格式")
                            .font(OmniFont.body)
                            .foregroundStyle(OmniColor.ink)
                        Spacer()
                        Picker("", selection: $selectedFormatID) {
                            if info.selfDownloading { Text("按画质上限自动选择").tag(String?.none) }
                            ForEach(info.formats.filter { !$0.isAudioOnly }) { format in
                                Text(format.label + (format.note.map { " (\($0))" } ?? ""))
                                    .tag(Optional(format.id))
                            }
                        }
                        .labelsHidden()
                        .frame(maxWidth: 260)
                    }
                }

                if let parts = info.parts, parts.count > 1 {
                    Toggle("下载全部 \(parts.count) 个分 P（排队逐个保存）", isOn: $downloadAllParts)
                        .font(OmniFont.body)
                        .foregroundStyle(OmniColor.ink)
                        .tint(OmniColor.accent)
                }

                if info.extra["videoAttachmentsOnly"] == "true" {
                    Text("当前来源提供了视频附件，图片附件的可用性未知。")
                        .font(OmniFont.meta)
                        .foregroundStyle(OmniColor.inkMuted)
                }

                if info.isItemCollection {
                    let count = info.extra["count"].flatMap(Int.init) ?? (info.files.isEmpty ? nil : info.files.count)
                    Text(count.map { "将保存 \($0) 项到同一个子文件夹。" } ?? "将保存帖子或合集中的媒体到同一个子文件夹。")
                        .font(OmniFont.meta)
                        .foregroundStyle(OmniColor.inkMuted)
                }

                HStack(spacing: 16) {
                    if !isImageNote {
                        Toggle("仅提取音频", isOn: $audioOnly)
                            .font(OmniFont.body)
                            .foregroundStyle(OmniColor.ink)
                            .tint(OmniColor.accent)
                    }
                    Spacer()
                    if info.engineID == "ytdlp" && selectedFormatID == nil && !audioOnly {
                        HStack(spacing: 8) {
                            Text("画质上限")
                                .font(OmniFont.meta)
                                .foregroundStyle(OmniColor.inkMuted)
                            Picker("", selection: $quality) {
                                ForEach(Quality.presets, id: \.self) { preset in
                                    Text(preset == "best" ? "最佳" : preset + "p").tag(preset)
                                }
                            }
                            .labelsHidden()
                            .frame(width: 110)
                        }
                    }
                }
            }
        }
        .padding(14)
        .background(OmniColor.surface, in: RoundedRectangle(cornerRadius: OmniRadius.md, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: OmniRadius.md, style: .continuous)
                .strokeBorder(OmniColor.line, lineWidth: 1)
        )
    }

    // MARK: - Advanced Options

    private var advancedSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(OmniMotion.panel(reduceMotion: reduceMotion)) {
                    showAdvanced.toggle()
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(OmniColor.inkMuted)
                        .rotationEffect(.degrees(showAdvanced ? 90 : 0))
                    Text("高级选项")
                        .font(OmniFont.bodyMedium)
                        .foregroundStyle(OmniColor.ink)
                    Spacer()
                    Text("保存路径、并发线程与平台会话")
                        .font(OmniFont.meta)
                        .foregroundStyle(OmniColor.inkMuted)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 11)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if showAdvanced {
                Rectangle().fill(OmniColor.line).frame(height: 1)

                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Toggle("使用应用内小红书登录状态", isOn: Binding(
                            get: { options.useXHSAppSession == true },
                            set: { options.useXHSAppSession = $0 }
                        ))
                        .tint(OmniColor.accent)
                        Spacer()
                        Button("登录小红书…") {
                            options.useXHSAppSession = true
                            showXHSLogin = true
                        }
                        .buttonStyle(OmniButtonStyle(variant: .secondary, compact: true))
                    }

                    HStack {
                        Text("微信视频号分享解析")
                            .font(OmniFont.body)
                            .foregroundStyle(OmniColor.ink)
                        Spacer()
                        Button("登录腾讯元宝…") { showYuanbaoLogin = true }
                            .buttonStyle(OmniButtonStyle(variant: .secondary, compact: true))
                    }

                    Rectangle().fill(OmniColor.line).frame(height: 1)

                    HStack(spacing: 10) {
                        Text("保存位置")
                            .font(OmniFont.body)
                            .foregroundStyle(OmniColor.ink)
                        Text(saveDirectory)
                            .font(OmniFont.meta)
                            .foregroundStyle(OmniColor.inkMuted)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Button("选择…") { chooseDirectory() }
                            .buttonStyle(OmniButtonStyle(variant: .secondary, compact: true))
                    }

                    HStack {
                        Text("单任务分片连接")
                            .font(OmniFont.body)
                            .foregroundStyle(OmniColor.ink)
                        Spacer()
                        Stepper(value: $options.connections, in: 1...16) {
                            Text("\(options.connections) 线程")
                                .font(OmniFont.telemetry)
                                .foregroundStyle(OmniColor.ink)
                                .frame(width: 56, alignment: .trailing)
                        }
                    }

                    HStack {
                        Text("读取浏览器 Cookie")
                            .font(OmniFont.body)
                            .foregroundStyle(OmniColor.ink)
                        Spacer()
                        Picker("", selection: Binding(
                            get: { options.cookiesFromBrowser ?? "" },
                            set: { options.cookiesFromBrowser = $0.isEmpty ? nil : $0 }
                        )) {
                            Text("不使用").tag("")
                            Text("Chrome").tag("chrome")
                            Text("Safari").tag("safari")
                            Text("Edge").tag("edge")
                            Text("Firefox").tag("firefox")
                        }
                        .labelsHidden()
                        .frame(width: 140)
                    }
                }
                .font(OmniFont.body)
                .padding(14)
            }
        }
        .background(OmniColor.surface, in: RoundedRectangle(cornerRadius: OmniRadius.md, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: OmniRadius.md, style: .continuous)
                .strokeBorder(OmniColor.line, lineWidth: 1)
        )
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 10) {
            Text(footerHint)
                .font(OmniFont.meta)
                .foregroundStyle(OmniColor.inkMuted)
            Spacer()
            Button("取消") { dismiss() }
                .buttonStyle(OmniButtonStyle(variant: .secondary))
                .keyboardShortcut(.cancelAction)
            Button(isBatch ? "批量加入队列" : "开始下载") { startDownload() }
                .buttonStyle(OmniButtonStyle(variant: .primary))
                .keyboardShortcut(.defaultAction)
                .disabled(urlText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(OmniColor.surface)
    }

    private var footerHint: String {
        if isBatch { return "将依次路由至对应平台引擎" }
        if info != nil { return "将使用 \(engineName) 引擎" }
        return "可先解析预览画质，或直接开始下载"
    }

    private var engineName: String {
        guard let info else { return "" }
        return EngineRegistry.shared.allEngines.first { $0.id == info.engineID }?.displayName ?? info.engineID
    }

    // MARK: - Logic

    private func updateURL(_ text: String) {
        guard text != urlText else { return }
        probeTask?.cancel()
        isProbing = false
        info = nil
        selectedFormatID = nil
        errorText = nil
        urlText = text
    }

    private func probe() {
        guard !urlText.isEmpty && !isBatch else { return }
        probeTask?.cancel()
        isProbing = true
        info = nil
        selectedFormatID = nil
        errorText = nil
        let raw = urlText
        probeTask = Task {
            do {
                let result = try await manager.probe(url: raw, options: options)
                guard !Task.isCancelled else { return }
                info = result
                downloadAllParts = false
                selectedFormatID = result.selectedFormatID
                if let format = result.formats.first(where: { $0.id == selectedFormatID }), let height = format.height {
                    quality = height >= 2160 ? "2160" : height >= 1080 ? "1080" : height >= 720 ? "720" : "best"
                }
                isProbing = false
            } catch {
                guard !Task.isCancelled else { return }
                errorText = error.localizedDescription
                isProbing = false
            }
        }
    }

    private func startDownload() {
        var finalOptions = options
        let images = info.map {
            $0.extra["kind"] == "images"
                || $0.extra["kind"] == "gallery"
                || $0.extra["kind"] == "attachments"
                || (!$0.files.isEmpty && $0.files.allSatisfy { $0.kind == .image })
        } ?? false
        finalOptions.audioOnly = audioOnly && !images
        finalOptions.quality = quality
        finalOptions.formatID = finalOptions.audioOnly || info?.isItemCollection == true ? nil : selectedFormatID
        if finalOptions.connections <= 0 {
            finalOptions.connections = manager.settings.connectionsPerTask
        }
        if isBatch {
            manager.add(urls: batchURLs, options: finalOptions)
        } else if downloadAllParts,
                  let info,
                  let parts = info.parts, parts.count > 1,
                  let base = info.extra["webpage"] {
            let urls = parts.compactMap { BilibiliEngine.partURL(base: base, page: $0.index) }
            manager.add(urls: urls, options: finalOptions)
        } else {
            manager.add(url: urlText, options: finalOptions, info: info)
        }
        dismiss()
    }

    private func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: saveDirectory)
        if panel.runModal() == .OK, let path = panel.url?.path {
            saveDirectory = path
            var settings = manager.settings
            settings.saveDirectory = path
            manager.updateSettings(settings)
        }
    }
}
