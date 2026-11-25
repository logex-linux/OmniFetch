import SwiftUI
import AppKit
import OmniFetchCore

enum SettingsTab: String, CaseIterable, Identifiable {
    case general = "通用与传输"
    case accounts = "账号与 Cookie"
    case engines = "引擎与环境"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .general: return "slider.horizontal.3"
        case .accounts: return "key"
        case .engines: return "cpu"
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject private var manager: DownloadManager
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var selectedTab: SettingsTab
    @State private var draft = SettingsStore.load()
    @State private var savedFlash = false
    @Namespace private var tabNamespace

    init(initialTab: SettingsTab = .general) {
        _selectedTab = State(initialValue: initialTab)
    }

    var body: some View {
        VStack(spacing: 0) {
            tabBar
            Rectangle().fill(OmniColor.line).frame(height: 1)

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    switch selectedTab {
                    case .general:
                        generalTab
                    case .accounts:
                        accountsTab
                    case .engines:
                        enginesTab
                    }
                }
                .padding(20)
            }

            Rectangle().fill(OmniColor.line).frame(height: 1)
            footerBar
        }
        .frame(width: 560, height: 556)
        .background(OmniColor.canvas)
        .onChange(of: draft.maxConcurrent) { _, _ in save() }
        .onChange(of: draft.connectionsPerTask) { _, _ in save() }
        .onChange(of: draft.bandwidthLimitKBps) { _, _ in save() }
        .onChange(of: draft.clipboardWatch) { _, _ in save() }
        .onChange(of: draft.keepHistory) { _, _ in save() }
        .onChange(of: draft.preferredQuality) { _, _ in save() }
        .onChange(of: draft.cookiesFromBrowser) { _, _ in save() }
    }

    // MARK: - Segmented Tab Header

    private var tabBar: some View {
        HStack(spacing: 4) {
            ForEach(SettingsTab.allCases) { tab in
                let active = selectedTab == tab
                Button {
                    withAnimation(OmniMotion.snappy(reduceMotion: reduceMotion)) {
                        selectedTab = tab
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: tab.icon)
                            .font(.system(size: 12, weight: active ? .semibold : .regular))
                            .foregroundStyle(active ? OmniColor.accent : OmniColor.inkMuted)
                        Text(tab.rawValue)
                            .font(active ? OmniFont.bodyMedium : OmniFont.body)
                            .foregroundStyle(active ? OmniColor.ink : OmniColor.inkMuted)
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 30)
                    .background {
                        if active {
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(OmniColor.canvas)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                                        .strokeBorder(OmniColor.line, lineWidth: 1)
                                )
                                .matchedGeometryEffect(id: "settingsTab", in: tabNamespace)
                        }
                    }
                    .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .background(OmniColor.surface, in: RoundedRectangle(cornerRadius: OmniRadius.md, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: OmniRadius.md, style: .continuous)
                .strokeBorder(OmniColor.line, lineWidth: 1)
        )
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(OmniColor.surface)
    }

    // MARK: - Tab 1: General & Transfer

    private var generalTab: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingsCard(title: "存储与传输") {
                settingsRow(label: "保存目录") {
                    HStack(spacing: 8) {
                        Text(draft.saveDirectory)
                            .font(OmniFont.meta)
                            .foregroundStyle(OmniColor.inkMuted)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: 260, alignment: .trailing)
                        Button("选择…") { chooseDirectory() }
                            .buttonStyle(OmniButtonStyle(variant: .secondary, compact: true))
                    }
                }

                rowDivider

                settingsRow(label: "同时下载任务") {
                    Stepper(value: $draft.maxConcurrent, in: 1...10) {
                        Text("\(draft.maxConcurrent) 个")
                            .font(OmniFont.telemetry)
                            .foregroundStyle(OmniColor.ink)
                            .frame(width: 48, alignment: .trailing)
                    }
                }

                rowDivider

                settingsRow(label: "每任务分片连接", caption: "单文件并发越高越快；同时下载过多任务会争抢带宽与磁盘 IO。") {
                    Stepper(value: $draft.connectionsPerTask, in: 1...16) {
                        Text("\(draft.connectionsPerTask) 线程")
                            .font(OmniFont.telemetry)
                            .foregroundStyle(OmniColor.ink)
                            .frame(width: 56, alignment: .trailing)
                    }
                }

                rowDivider

                settingsRow(label: "全局限速", caption: "0 表示不限速，对原生分片与 yt-dlp 同时生效。") {
                    HStack(spacing: 6) {
                        TextField("0", value: $draft.bandwidthLimitKBps, format: .number)
                            .textFieldStyle(.plain)
                            .font(OmniFont.telemetry)
                            .multilineTextAlignment(.trailing)
                            .padding(.horizontal, 8)
                            .frame(width: 82, height: 28)
                            .background(OmniColor.canvas, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .strokeBorder(OmniColor.line, lineWidth: 1)
                            )
                        Text("KB/s")
                            .font(OmniFont.meta)
                            .foregroundStyle(OmniColor.inkMuted)
                    }
                }
            }

            SettingsCard(title: "默认行为") {
                settingsRow(label: "默认首选画质") {
                    Picker("", selection: $draft.preferredQuality) {
                        ForEach(Quality.presets, id: \.self) { preset in
                            Text(preset == "best" ? "最佳" : preset + "p").tag(preset)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 120)
                }

                rowDivider

                settingsRow(label: "监听剪贴板媒体链接") {
                    Toggle("", isOn: $draft.clipboardWatch)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .tint(OmniColor.accent)
                }

                rowDivider

                settingsRow(label: "下载完成发送系统通知") {
                    Toggle("", isOn: Binding(
                        get: { draft.notifyOnCompletion ?? true },
                        set: { draft.notifyOnCompletion = $0; save() }
                    ))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .tint(OmniColor.accent)
                }

                rowDivider

                settingsRow(label: "保留下载历史记录") {
                    Toggle("", isOn: $draft.keepHistory)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .tint(OmniColor.accent)
                }
            }
        }
    }

    // MARK: - Tab 2: Accounts & Cookies

    private var accountsTab: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingsCard(title: "浏览器会话") {
                settingsRow(label: "读取浏览器 Cookie", caption: "用于需要登录才能获取高码率（如 B 站 4K）或受限内容的站点。") {
                    Picker("", selection: $draft.cookiesFromBrowser) {
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

            SettingsCard(title: "手动绑定 Cookie") {
                VStack(alignment: .leading, spacing: 6) {
                    Text("所属域名")
                        .font(OmniFont.metaMedium)
                        .foregroundStyle(OmniColor.inkMuted)
                    TextField("例如 bilibili.com 或 xiaohongshu.com", text: Binding(
                        get: { draft.cookieDomain ?? "" },
                        set: { draft.cookieDomain = $0 }
                    ))
                    .textFieldStyle(.plain)
                    .font(OmniFont.body)
                    .padding(.horizontal, 10)
                    .frame(height: 32)
                    .background(OmniColor.canvas, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .strokeBorder(OmniColor.line, lineWidth: 1)
                    )
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)

                rowDivider

                VStack(alignment: .leading, spacing: 6) {
                    Text("Cookie 请求头（可选）")
                        .font(OmniFont.metaMedium)
                        .foregroundStyle(OmniColor.inkMuted)
                    TextField("SESSDATA=…; bili_jct=…", text: $draft.cookieHeader, axis: .vertical)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12, design: .monospaced))
                        .lineLimit(2...4)
                        .padding(10)
                        .background(OmniColor.canvas, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .strokeBorder(OmniColor.line, lineWidth: 1)
                        )
                    Text("仅发送给上述绑定域名。修改文本后点击右下角「保存设置」生效。")
                        .font(OmniFont.meta)
                        .foregroundStyle(OmniColor.inkMuted)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            }
        }
    }

    // MARK: - Tab 3: Engines

    private var enginesTab: some View {
        let galleryInstalled = GalleryDLInstaller.locate() != nil
        let ffmpegPath = MediaMerger.ffmpegPath(settings: draft)

        return VStack(alignment: .leading, spacing: 16) {
            SettingsCard(title: "本地运行组件") {
                settingsRow(label: "yt-dlp", caption: "负责 YouTube 及通用视频站点解析与流媒体拉取。") {
                    HStack(spacing: 8) {
                        Text(manager.ytdlpVersion ?? "未安装")
                            .font(OmniFont.telemetrySmall)
                            .foregroundStyle(manager.ytdlpVersion == nil ? OmniColor.inkMuted : OmniColor.ink)
                        Button(manager.isInstallingYTDLP ? "安装中…" : "安装 / 更新") {
                            manager.installYTDLP()
                        }
                        .buttonStyle(OmniButtonStyle(variant: .secondary, compact: true))
                        .disabled(manager.isInstallingYTDLP)

                        OmniIconButton(systemName: "arrow.clockwise", help: "重新检测版本", tint: OmniColor.inkMuted, size: 28) {
                            manager.refreshYTDLP()
                        }
                    }
                }

                rowDivider

                settingsRow(label: "gallery-dl", caption: "负责 X、Pixiv、Instagram 等图集与混合媒体帖子。") {
                    Text(galleryInstalled ? "已安装" : "首次下载图集时自动安装")
                        .font(OmniFont.metaMedium)
                        .foregroundStyle(galleryInstalled ? OmniColor.accent : OmniColor.inkMuted)
                }

                rowDivider

                settingsRow(label: "ffmpeg", caption: "合并 DASH 双轨与提取音频，可用 brew install ffmpeg 安装。") {
                    Text(ffmpegPath ?? "未找到")
                        .font(OmniFont.telemetrySmall)
                        .foregroundStyle(ffmpegPath == nil ? OmniColor.danger : OmniColor.inkMuted)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: 200, alignment: .trailing)
                }
            }

            SettingsCard(title: "支持站点清单") {
                HStack(spacing: 16) {
                    Link(destination: URL(string: "https://github.com/yt-dlp/yt-dlp/blob/master/supportedsites.md")!) {
                        Label("yt-dlp 视频站点清单", systemImage: "arrow.up.right.square")
                            .font(OmniFont.bodyMedium)
                            .foregroundStyle(OmniColor.accent)
                    }
                    Link(destination: URL(string: "https://github.com/mikf/gallery-dl/blob/master/docs/supportedsites.md")!) {
                        Label("gallery-dl 图集站点清单", systemImage: "arrow.up.right.square")
                            .font(OmniFont.bodyMedium)
                            .foregroundStyle(OmniColor.accent)
                    }
                    Spacer()
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
            }
        }
    }

    // MARK: - Footer

    private var footerBar: some View {
        HStack {
            if savedFlash {
                HStack(spacing: 5) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 12, weight: .semibold))
                    Text("设置已保存")
                        .font(OmniFont.metaMedium)
                }
                .foregroundStyle(OmniColor.accent)
                .transition(.opacity)
            } else {
                Text("开关与数值调整会自动即时生效")
                    .font(OmniFont.meta)
                    .foregroundStyle(OmniColor.inkMuted)
            }

            Spacer()

            Button("保存设置") { save() }
                .buttonStyle(OmniButtonStyle(variant: .primary))
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 11)
        .background(OmniColor.surface)
        .animation(OmniMotion.hover, value: savedFlash)
    }

    // MARK: - Helpers

    private var rowDivider: some View {
        Rectangle()
            .fill(OmniColor.line)
            .frame(height: 1)
            .padding(.leading, 14)
    }

    private func settingsRow<Control: View>(
        label: String,
        caption: String? = nil,
        @ViewBuilder control: () -> Control
    ) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(OmniFont.body)
                    .foregroundStyle(OmniColor.ink)
                if let caption {
                    Text(caption)
                        .font(OmniFont.meta)
                        .foregroundStyle(OmniColor.inkMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            control()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }

    private func save() {
        manager.updateSettings(draft)
        ClipboardWatcher.shared.start()
        savedFlash = true
        Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            await MainActor.run { savedFlash = false }
        }
    }

    private func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: draft.saveDirectory)
        if panel.runModal() == .OK, let path = panel.url?.path {
            draft.saveDirectory = path
            save()
        }
    }
}

private struct SettingsCard<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(OmniFont.metaMedium)
                .foregroundStyle(OmniColor.inkMuted)
                .padding(.leading, 2)

            VStack(alignment: .leading, spacing: 0) {
                content
            }
            .background(OmniColor.surface, in: RoundedRectangle(cornerRadius: OmniRadius.md, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: OmniRadius.md, style: .continuous)
                    .strokeBorder(OmniColor.line, lineWidth: 1)
            )
        }
    }
}
