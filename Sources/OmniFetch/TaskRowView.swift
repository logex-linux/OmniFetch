import SwiftUI
import AppKit
import OmniFetchCore

struct TaskRowView: View, Equatable {
    let task: DownloadTask
    let isSelected: Bool
    let showDivider: Bool
    let onSelect: () -> Void

    @EnvironmentObject private var manager: DownloadManager
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false

    /// Value-level diffing so 10 Hz progress ticks only re-render rows whose task changed.
    static func == (lhs: TaskRowView, rhs: TaskRowView) -> Bool {
        lhs.task == rhs.task
            && lhs.isSelected == rhs.isSelected
            && lhs.showDivider == rhs.showDivider
    }

    private var countBased: Bool {
        task.progressInItems ?? (task.engineID == "xiaohongshu" && task.formatLabel?.contains("图文") == true)
    }

    private var showsProgressTrack: Bool {
        switch task.state {
        case .downloading, .probing, .merging, .paused, .queued:
            return true
        case .completed, .failed, .cancelled:
            return false
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 14) {
                CachedThumbnailView(
                    urlString: task.thumbnail,
                    width: 96,
                    height: 54,
                    cornerRadius: OmniRadius.sm,
                    isCollection: countBased,
                    isAudioOnly: task.options.audioOnly,
                    durationText: Formatters.duration(task.duration)
                )

                VStack(alignment: .leading, spacing: 5) {
                    // Row 1: Title + Right-aligned telemetry anchor
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(task.title)
                            .font(OmniFont.rowTitle)
                            .foregroundStyle(OmniColor.ink)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .help(task.title)

                        Spacer(minLength: 8)

                        telemetrySummary
                    }

                    // Row 2: Metadata (site + format) + Progress counters / ETA
                    HStack(alignment: .center, spacing: 8) {
                        metadataStrip

                        Spacer(minLength: 8)

                        secondaryReadout
                    }

                    // Row 3: Live throughput bar OR error line
                    if showsProgressTrack {
                        ThroughputTrackView(
                            progress: task.progress,
                            isActive: task.state.isActive,
                            isIndeterminate: task.state == .probing || task.state == .merging || (task.state == .downloading && task.totalBytes == 0 && task.progress <= 0.001),
                            isPaused: task.state == .paused || task.state == .queued
                        )
                        .padding(.top, 2)
                    } else if task.state == .failed, let error = task.errorMessage, !error.isEmpty {
                        Text(error)
                            .font(OmniFont.meta)
                            .foregroundStyle(OmniColor.danger)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .help(error)
                    }
                }
                .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)

                actionCluster
                    .frame(width: 64, alignment: .trailing)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: OmniRadius.md, style: .continuous)
                    .fill(rowBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: OmniRadius.md, style: .continuous)
                    .strokeBorder(isSelected ? OmniColor.accentLine : .clear, lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: OmniRadius.md, style: .continuous))
            .onTapGesture(count: 2) {
                onSelect()
                if task.state == .completed {
                    manager.open(task.id)
                }
            }
            .onTapGesture(count: 1) {
                onSelect()
            }
            .onHover { hovering in
                withAnimation(OmniMotion.hover) {
                    isHovered = hovering
                }
            }
            .contextMenu { contextMenu }

            if showDivider && !isSelected && !isHovered {
                Rectangle()
                    .fill(OmniColor.line)
                    .frame(height: 1)
                    .padding(.leading, 122)
                    .padding(.trailing, 12)
            }
        }
    }

    private var rowBackground: Color {
        if isSelected { return OmniColor.activeFill }
        if isHovered { return OmniColor.hoverFill }
        return .clear
    }

    // MARK: - Telemetry Anchor (Icon + Label + Tone Triple-Coded)

    @ViewBuilder
    private var telemetrySummary: some View {
        switch task.state {
        case .downloading:
            HStack(spacing: 8) {
                if !countBased && task.speed > 0 {
                    Text(Formatters.speed(task.speed))
                        .font(OmniFont.telemetry)
                        .foregroundStyle(OmniColor.accent)
                        .contentTransition(.numericText())
                }
                if task.totalBytes > 0 {
                    Text("\(Int(task.progress * 100))%")
                        .font(OmniFont.telemetry)
                        .foregroundStyle(OmniColor.ink)
                        .contentTransition(.numericText())
                } else {
                    Text("下载中")
                        .font(OmniFont.metaMedium)
                        .foregroundStyle(OmniColor.accent)
                }
            }

        case .probing:
            HStack(spacing: 5) {
                Image(systemName: "sparkle.magnifyingglass")
                    .font(.system(size: 10.5, weight: .semibold))
                Text("解析中")
                    .font(OmniFont.metaMedium)
            }
            .foregroundStyle(OmniColor.accent)

        case .merging:
            HStack(spacing: 5) {
                Image(systemName: "arrow.triangle.merge")
                    .font(.system(size: 10.5, weight: .semibold))
                Text("合并音视频")
                    .font(OmniFont.metaMedium)
            }
            .foregroundStyle(OmniColor.accent)

        case .queued:
            HStack(spacing: 5) {
                Image(systemName: "clock")
                    .font(.system(size: 10.5, weight: .medium))
                Text("排队中")
                    .font(OmniFont.metaMedium)
            }
            .foregroundStyle(OmniColor.inkMuted)

        case .paused:
            HStack(spacing: 5) {
                Image(systemName: "pause.circle")
                    .font(.system(size: 10.5, weight: .medium))
                Text(task.totalBytes > 0 ? "已暂停 \(Int(task.progress * 100))%" : "已暂停")
                    .font(OmniFont.telemetrySmall)
            }
            .foregroundStyle(OmniColor.inkMuted)

        case .completed:
            HStack(spacing: 5) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(OmniColor.inkMuted)
                Text(countBased ? "\(task.downloadedBytes) 项" : Formatters.bytes(task.totalBytes))
                    .font(OmniFont.telemetrySmall)
                    .foregroundStyle(OmniColor.inkMuted)
            }

        case .failed:
            HStack(spacing: 5) {
                Image(systemName: "exclamationmark.circle.fill")
                    .font(.system(size: 11, weight: .medium))
                Text("失败")
                    .font(OmniFont.metaMedium)
            }
            .foregroundStyle(OmniColor.danger)

        case .cancelled:
            HStack(spacing: 5) {
                Image(systemName: "minus.circle")
                    .font(.system(size: 10.5, weight: .medium))
                Text("已取消")
                    .font(OmniFont.metaMedium)
            }
            .foregroundStyle(OmniColor.inkMuted)
        }
    }

    // MARK: - Metadata Strip

    private var metadataStrip: some View {
        HStack(spacing: 6) {
            if let site = task.site, !site.isEmpty {
                Text(site)
                    .font(OmniFont.badge)
                    .foregroundStyle(OmniColor.inkMuted)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1.5)
                    .background(OmniColor.surface, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .strokeBorder(OmniColor.line, lineWidth: 0.75)
                    )
            }

            if let label = task.formatLabel, !label.isEmpty {
                Text(label)
                    .font(OmniFont.meta)
                    .foregroundStyle(OmniColor.inkMuted)
            } else if task.options.audioOnly {
                Text("仅音频")
                    .font(OmniFont.meta)
                    .foregroundStyle(OmniColor.inkMuted)
            }
        }
    }

    @ViewBuilder
    private var secondaryReadout: some View {
        switch task.state {
        case .downloading, .paused, .queued:
            HStack(spacing: 8) {
                Text(progressCounterText)
                if task.state == .downloading, let eta = task.eta, eta.isFinite, eta > 0 {
                    Text("剩余 " + Formatters.eta(eta))
                }
            }
            .font(OmniFont.telemetrySmall)
            .foregroundStyle(OmniColor.inkMuted)

        case .completed:
            if let finished = task.finishedAt {
                Text(Formatters.relativeTime(finished))
                    .font(OmniFont.meta)
                    .foregroundStyle(OmniColor.inkMuted.opacity(0.8))
            }

        default:
            EmptyView()
        }
    }

    private var progressCounterText: String {
        if countBased {
            if task.totalBytes == 0 { return "已保存 \(task.downloadedBytes) 项" }
            return "\(task.downloadedBytes) / \(task.totalBytes) 项"
        }
        let done = Formatters.bytes(task.downloadedBytes)
        if task.totalBytes > 0 {
            return "\(done) / \(Formatters.bytes(task.totalBytes))"
        }
        return done
    }

    // MARK: - Tactile Row Controls (Primary action pinned flush-right; secondary reveals cleanly to its left)

    private var actionCluster: some View {
        let revealSecondary = isHovered || isSelected
        return HStack(spacing: 4) {
            switch task.state {
            case .downloading, .probing, .merging:
                OmniIconButton(systemName: "xmark", help: "取消", tint: OmniColor.inkMuted) {
                    manager.cancel(task.id)
                }
                .opacity(revealSecondary ? 1 : 0)
                .allowsHitTesting(revealSecondary)

                OmniIconButton(systemName: "pause.fill", help: "暂停", tint: OmniColor.ink) {
                    manager.pause(task.id)
                }

            case .paused:
                OmniIconButton(systemName: "xmark", help: "取消", tint: OmniColor.inkMuted) {
                    manager.cancel(task.id)
                }
                .opacity(revealSecondary ? 1 : 0)
                .allowsHitTesting(revealSecondary)

                OmniIconButton(systemName: "play.fill", help: "继续下载", tint: OmniColor.accent) {
                    manager.resume(task.id)
                }

            case .failed, .cancelled:
                OmniIconButton(systemName: "trash", help: "移除记录", tint: OmniColor.inkMuted) {
                    manager.remove(task.id)
                }
                .opacity(revealSecondary ? 1 : 0)
                .allowsHitTesting(revealSecondary)

                OmniIconButton(systemName: "arrow.clockwise", help: "重试", tint: OmniColor.accent) {
                    manager.retry(task.id)
                }

            case .completed:
                OmniIconButton(systemName: "arrow.up.forward.square", help: "打开文件", tint: OmniColor.inkMuted) {
                    manager.open(task.id)
                }
                .opacity(revealSecondary ? 1 : 0)
                .allowsHitTesting(revealSecondary)

                OmniIconButton(systemName: "folder", help: "在 Finder 中显示", tint: OmniColor.ink) {
                    manager.reveal(task.id)
                }

            case .queued:
                OmniIconButton(systemName: "xmark", help: "取消排队", tint: OmniColor.inkMuted) {
                    manager.cancel(task.id)
                }
            }
        }
        .animation(reduceMotion ? nil : OmniMotion.hover, value: revealSecondary)
    }

    @ViewBuilder
    private var contextMenu: some View {
        if task.state == .completed {
            Button("打开文件") { manager.open(task.id) }
            Button("在 Finder 中显示") { manager.reveal(task.id) }
        }
        if task.state == .downloading || task.state == .probing || task.state == .merging {
            Button("暂停") { manager.pause(task.id) }
            Button("取消") { manager.cancel(task.id) }
        }
        if task.state == .paused {
            Button("继续下载") { manager.resume(task.id) }
        }
        if task.state == .failed || task.state == .cancelled || task.state == .paused {
            Button("重新解析并下载") { manager.retry(task.id) }
        }
        Button("复制链接") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(task.url, forType: .string)
        }
        Divider()
        Button("移除任务", role: .destructive) { manager.remove(task.id) }
        if task.filePath != nil {
            Button("移除并删除本地文件", role: .destructive) { manager.remove(task.id, deleteFile: true) }
        }
    }
}
