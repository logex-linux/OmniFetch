import SwiftUI
import AppKit
import UniformTypeIdentifiers
import OmniFetchCore

enum TaskFilter: String, CaseIterable, Identifiable {
    case all, active, completed, failed

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: return "全部任务"
        case .active: return "进行中"
        case .completed: return "已完成"
        case .failed: return "异常"
        }
    }

    var icon: String {
        switch self {
        case .all: return "square.stack.3d.up"
        case .active: return "arrow.down.circle"
        case .completed: return "checkmark.circle"
        case .failed: return "exclamationmark.triangle"
        }
    }

    var shortcutDigit: String {
        switch self {
        case .all: return "1"
        case .active: return "2"
        case .completed: return "3"
        case .failed: return "4"
        }
    }

    func matches(_ task: DownloadTask) -> Bool {
        switch self {
        case .all: return true
        case .active: return task.state.isActive || task.state == .queued || task.state == .paused
        case .completed: return task.state == .completed
        case .failed: return task.state == .failed || task.state == .cancelled
        }
    }
}

struct ContentView: View {
    @EnvironmentObject private var manager: DownloadManager
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Optional static task list injected only by design previews / offscreen visual checks.
    var previewTasks: [DownloadTask]? = nil
    var previewSpeedHistory: [Double]? = nil

    @State private var filter: TaskFilter = .all
    @State private var showAdd = false
    @State private var prefilledURL: String?
    @State private var quickInput = ""
    @State private var search = ""
    @State private var showSearch = false
    @State private var selection: UUID?
    @State private var isDropTargeted = false
    @State private var speedHistory: [Double] = Array(repeating: 0, count: 28)
    @State private var feedbackNotice: String?

    @FocusState private var focusedField: Field?
    @Namespace private var sidebarNamespace

    private enum Field: Hashable {
        case quickInput
        case search
    }

    private var allTasks: [DownloadTask] {
        previewTasks ?? manager.tasks
    }

    private var visibleTasks: [DownloadTask] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return allTasks.filter { task in
            guard filter.matches(task) else { return false }
            guard !query.isEmpty else { return true }
            return task.title.localizedCaseInsensitiveContains(query)
                || (task.site ?? "").localizedCaseInsensitiveContains(query)
                || task.url.localizedCaseInsensitiveContains(query)
        }
    }

    private var parsedQuickURLs: [URL] {
        DownloadManager.parseURLList(quickInput)
    }

    private var quickDetectionLabel: String? {
        let urls = parsedQuickURLs
        guard !urls.isEmpty else { return nil }
        if urls.count > 1 { return "批量 \(urls.count) 条" }
        if let site = SocialPlatform.match(urls[0])?.name { return site }
        return urls[0].host ?? "链接"
    }

    private var activeTaskCount: Int {
        allTasks.filter { $0.state.isActive }.count
    }

    private var pausedTaskCount: Int {
        allTasks.filter { $0.state == .paused }.count
    }

    private var finishedClearableCount: Int {
        allTasks.filter { $0.state == .completed || $0.state == .cancelled }.count
    }

    private var totalSpeed: Double {
        allTasks
            .filter { $0.state == .downloading && $0.progressInItems != true }
            .reduce(0) { $0 + $1.speed }
    }

    private var activeSparklineSamples: [Double] {
        previewSpeedHistory ?? speedHistory
    }

    var body: some View {
        let shown = visibleTasks
        let counts = taskCounts

        shellContent(shown: shown, counts: counts)
            .modifier(ContentNotificationsModifier(
                filter: $filter,
                showAdd: $showAdd,
                prefilledURL: $prefilledURL,
                showSearch: $showSearch,
                focusQuickInput: { focusedField = .quickInput },
                focusSearch: { focusedField = .search },
                activeTaskCount: activeTaskCount,
                pausedTaskCount: pausedTaskCount,
                finishedClearableCount: finishedClearableCount,
                reduceMotion: reduceMotion
            ))
            .onChange(of: totalSpeed) { _, newValue in
                guard previewSpeedHistory == nil else { return }
                var next = speedHistory
                if next.count >= 28 { next.removeFirst() }
                next.append(newValue)
                speedHistory = next
            }
            .onKeyPress(.upArrow) { moveSelection(delta: -1, in: shown) }
            .onKeyPress(.downArrow) { moveSelection(delta: 1, in: shown) }
            .onKeyPress(.space) { togglePauseSelected() }
            .onKeyPress(.return) { openSelectedIfCompleted() }
            .onKeyPress(.escape) { handleEscape() }
    }

    private func shellContent(shown: [DownloadTask], counts: [TaskFilter: Int]) -> some View {
        ZStack {
            HStack(spacing: 0) {
                sidebar(counts: counts)

                Rectangle()
                    .fill(OmniColor.line)
                    .frame(width: 1)

                workspace(shown: shown)
            }
            .background(OmniColor.canvas)

            if isDropTargeted {
                dropOverlay
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
            }
        }
        .animation(OmniMotion.snappy(reduceMotion: reduceMotion), value: isDropTargeted)
        .onDrop(of: [UTType.url, UTType.plainText], isTargeted: $isDropTargeted) { providers in
            handleDrop(providers: providers)
        }
        .sheet(isPresented: $showAdd, onDismiss: { prefilledURL = nil }) {
            AddDownloadView(prefilledURL: prefilledURL)
                .environmentObject(manager)
        }
    }

    private func togglePauseSelected() -> KeyPress.Result {
        guard focusedField == nil, let id = selection, let task = allTasks.first(where: { $0.id == id }) else {
            return .ignored
        }
        if task.state.isActive {
            manager.pause(id)
        } else if task.state == .paused || task.state == .failed || task.state == .cancelled {
            manager.resume(id)
        }
        return .handled
    }

    private func openSelectedIfCompleted() -> KeyPress.Result {
        guard focusedField == nil, let id = selection, let task = allTasks.first(where: { $0.id == id }) else {
            return .ignored
        }
        if task.state == .completed {
            manager.open(id)
            return .handled
        }
        return .ignored
    }

    private func handleEscape() -> KeyPress.Result {
        if showSearch {
            search = ""
            showSearch = false
            focusedField = nil
            return .handled
        }
        if focusedField != nil {
            focusedField = nil
            return .handled
        }
        return .ignored
    }

    // MARK: - Sidebar

    private func sidebar(counts: [TaskFilter: Int]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // Safe top inset clears native macOS traffic lights under hiddenTitleBar
            HStack(spacing: 9) {
                OmniMarkView(size: 19, arcColor: OmniColor.accent, arrowColor: OmniColor.ink)
                Text("OmniFetch")
                    .font(OmniFont.windowTitle)
                    .foregroundStyle(OmniColor.ink)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.top, 38)
            .padding(.bottom, 18)

            VStack(spacing: 3) {
                ForEach(TaskFilter.allCases) { item in
                    sidebarRow(item: item, count: counts[item] ?? 0)
                }
            }
            .padding(.horizontal, 10)

            Spacer(minLength: 16)

            Rectangle()
                .fill(OmniColor.line)
                .frame(height: 1)
                .padding(.horizontal, 12)

            VStack(spacing: 2) {
                SidebarUtilityButton(title: "下载目录", systemName: "folder") {
                    manager.openDownloadFolder()
                }
                if finishedClearableCount > 0 {
                    SidebarUtilityButton(title: "清除已完成", systemName: "trash", trailingText: "\(finishedClearableCount)") {
                        withAnimation(OmniMotion.snappy(reduceMotion: reduceMotion)) {
                            manager.clearCompleted()
                        }
                    }
                }
                SettingsLink {
                    SidebarUtilityRowLabel(title: "偏好设置", systemName: "gearshape", trailingText: "⌘,")
                }
                .buttonStyle(SidebarUtilityLinkStyle())
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 10)
        }
        .frame(width: 212)
        .frame(maxHeight: .infinity)
        .background(OmniColor.surface)
    }

    private func sidebarRow(item: TaskFilter, count: Int) -> some View {
        let selected = filter == item
        let isAlertCount = (item == .failed && count > 0)

        return Button {
            withAnimation(OmniMotion.snappy(reduceMotion: reduceMotion)) {
                filter = item
            }
        } label: {
            HStack(spacing: 9) {
                Image(systemName: item.icon)
                    .font(.system(size: 13, weight: selected ? .semibold : .regular))
                    .foregroundStyle(selected ? OmniColor.accent : (isAlertCount ? OmniColor.danger : OmniColor.inkMuted))
                    .frame(width: 18, alignment: .center)

                Text(item.title)
                    .font(selected ? OmniFont.bodyMedium : OmniFont.body)
                    .foregroundStyle(selected ? OmniColor.ink : OmniColor.inkMuted)

                Spacer()

                Text("\(count)")
                    .font(OmniFont.telemetrySmall)
                    .foregroundStyle(isAlertCount ? OmniColor.danger : (selected ? OmniColor.ink : OmniColor.inkMuted))
                    .contentTransition(.numericText())
            }
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background {
                if selected {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(OmniColor.canvas)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(OmniColor.line, lineWidth: 1)
                        )
                        .matchedGeometryEffect(id: "sidebarActivePill", in: sidebarNamespace)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(TactilePressStyle(reduceMotion: reduceMotion))
    }

    // MARK: - Main Workspace

    private func workspace(shown: [DownloadTask]) -> some View {
        VStack(spacing: 0) {
            commandHeader
            Rectangle().fill(OmniColor.line).frame(height: 1)

            if shown.isEmpty {
                EmptyStateView(
                    hasAny: !allTasks.isEmpty,
                    isSearching: !search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                    filterTitle: filter.title,
                    onPasteAndAdd: pasteFromClipboardIntoSheet,
                    onOpenAdd: { showAdd = true },
                    onClearFilter: {
                        search = ""
                        showSearch = false
                        filter = .all
                    }
                )
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(shown.enumerated()), id: \.element.id) { idx, task in
                            TaskRowView(
                                task: task,
                                isSelected: selection == task.id,
                                showDivider: idx < shown.count - 1,
                                onSelect: { selection = task.id }
                            )
                            .equatable()
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                }
            }

            Rectangle().fill(OmniColor.line).frame(height: 1)
            StatusBarView(
                activeCount: activeTaskCount,
                totalSpeed: totalSpeed,
                speedSamples: activeSparklineSamples,
                feedbackNotice: feedbackNotice
            )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Top Command Bar (Single-Step Quick Capture + Transport Controls)

    private var commandHeader: some View {
        let isQuickFocused = focusedField == .quickInput
        let hasURLs = !parsedQuickURLs.isEmpty

        return HStack(spacing: 10) {
            // Inline Quick-Capture input well
            HStack(spacing: 8) {
                Image(systemName: hasURLs ? "arrow.down.circle.fill" : "link")
                    .font(.system(size: 13.5, weight: .medium))
                    .foregroundStyle(hasURLs ? OmniColor.accent : OmniColor.inkMuted)

                TextField("粘贴链接、BV 号或分享文案，回车立即下载…", text: $quickInput)
                    .textFieldStyle(.plain)
                    .font(OmniFont.body)
                    .foregroundStyle(OmniColor.ink)
                    .focused($focusedField, equals: .quickInput)
                    .onSubmit { submitQuickCapture() }

                if let detected = quickDetectionLabel {
                    Text(detected)
                        .font(OmniFont.badge)
                        .foregroundStyle(OmniColor.accent)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(OmniColor.activeFill, in: Capsule(style: .continuous))
                        .transition(.opacity.combined(with: .scale(scale: 0.94)))
                }

                if quickInput.isEmpty {
                    OmniIconButton(systemName: "doc.on.clipboard", help: "粘贴剪贴板链接", tint: OmniColor.inkMuted, size: 24) {
                        if let clip = NSPasteboard.general.string(forType: .string) {
                            quickInput = clip.trimmingCharacters(in: .whitespacesAndNewlines)
                            focusedField = .quickInput
                        }
                    }
                } else {
                    OmniIconButton(systemName: "xmark.circle.fill", help: "清空输入", tint: OmniColor.inkMuted, size: 24) {
                        quickInput = ""
                    }
                }

                OmniIconButton(systemName: "slider.horizontal.3", help: "解析画质与高级选项 (⌘N)", tint: OmniColor.inkMuted, size: 24) {
                    prefilledURL = quickInput.isEmpty ? nil : quickInput
                    showAdd = true
                }

                Button(hasURLs ? (parsedQuickURLs.count > 1 ? "批量下载" : "下载") : "新建") {
                    if hasURLs {
                        submitQuickCapture()
                    } else {
                        showAdd = true
                    }
                }
                .buttonStyle(OmniButtonStyle(variant: .primary, compact: true))
                .help(hasURLs ? "使用默认配置立即入队 (↩)" : "打开新建下载面板 (⌘N)")
            }
            .padding(.leading, 11)
            .padding(.trailing, 5)
            .frame(height: 36)
            .background(
                RoundedRectangle(cornerRadius: OmniRadius.md, style: .continuous)
                    .fill(OmniColor.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: OmniRadius.md, style: .continuous)
                    .strokeBorder(isQuickFocused ? OmniColor.accent : OmniColor.line, lineWidth: isQuickFocused ? 1.5 : 1)
            )
            .animation(OmniMotion.hover, value: isQuickFocused)
            .animation(OmniMotion.snappy(reduceMotion: reduceMotion), value: quickDetectionLabel)

            // Search input (expandable or compact)
            if showSearch || !search.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(OmniColor.inkMuted)
                    TextField("筛选标题或站点", text: $search)
                        .textFieldStyle(.plain)
                        .font(OmniFont.body)
                        .focused($focusedField, equals: .search)
                    Button {
                        search = ""
                        showSearch = false
                        focusedField = nil
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(OmniColor.inkMuted)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 9)
                .frame(width: 176, height: 32)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(OmniColor.surface)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(focusedField == .search ? OmniColor.accent : OmniColor.line, lineWidth: 1)
                )
                .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .trailing)))
            }

            HStack(spacing: 4) {
                if !showSearch && search.isEmpty {
                    OmniIconButton(systemName: "magnifyingglass", help: "搜索任务 (⌘F)", tint: OmniColor.inkMuted, size: 30) {
                        withAnimation(OmniMotion.snappy(reduceMotion: reduceMotion)) {
                            showSearch = true
                        }
                        focusedField = .search
                    }
                }
                OmniIconButton(
                    systemName: "pause.fill",
                    help: "全部暂停 (⌥⌘P)",
                    tint: OmniColor.ink,
                    size: 30,
                    disabled: activeTaskCount == 0
                ) {
                    manager.pauseAll()
                }
                OmniIconButton(
                    systemName: "play.fill",
                    help: "继续全部已暂停任务",
                    tint: OmniColor.ink,
                    size: 30,
                    disabled: pausedTaskCount == 0
                ) {
                    manager.resumeAll()
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 12)
        .animation(OmniMotion.snappy(reduceMotion: reduceMotion), value: showSearch)
    }

    // MARK: - Drag & Drop Overlay

    private var dropOverlay: some View {
        ZStack {
            OmniColor.canvas.opacity(0.92)
            VStack(spacing: 12) {
                OmniMarkView(size: 46, arcColor: OmniColor.accent, arrowColor: OmniColor.ink)
                Text("松开以添加下载")
                    .font(OmniFont.sheetTitle)
                    .foregroundStyle(OmniColor.ink)
                Text("支持单个链接、多行批量链接或平台分享文案")
                    .font(OmniFont.meta)
                    .foregroundStyle(OmniColor.inkMuted)
            }
            .padding(.horizontal, 36)
            .padding(.vertical, 28)
            .background(
                RoundedRectangle(cornerRadius: OmniRadius.lg, style: .continuous)
                    .fill(OmniColor.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: OmniRadius.lg, style: .continuous)
                    .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6, 5]))
                    .foregroundStyle(OmniColor.accent)
            )
        }
        .ignoresSafeArea()
    }

    // MARK: - Actions

    private func submitQuickCapture() {
        let urls = parsedQuickURLs
        guard !urls.isEmpty else {
            if !quickInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                prefilledURL = quickInput
                showAdd = true
            }
            return
        }
        if urls.count > 1 {
            manager.add(urls: urls)
            flashNotice("已加入 \(urls.count) 条下载任务")
        } else {
            manager.add(url: urls[0].absoluteString)
            flashNotice("已开始下载")
        }
        quickInput = ""
        if filter == .completed || filter == .failed {
            filter = .all
        }
    }

    private func pasteFromClipboardIntoSheet() {
        if let text = NSPasteboard.general.string(forType: .string) {
            prefilledURL = text
        }
        showAdd = true
    }

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        var accepted = false
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
                accepted = true
                provider.loadItem(forTypeIdentifier: UTType.url.identifier, options: nil) { item, _ in
                    let extracted: String?
                    if let data = item as? Data {
                        extracted = URL(dataRepresentation: data, relativeTo: nil)?.absoluteString
                            ?? String(data: data, encoding: .utf8)
                    } else if let url = item as? URL {
                        extracted = url.absoluteString
                    } else if let str = item as? String {
                        extracted = str
                    } else {
                        extracted = nil
                    }
                    guard let text = extracted, !text.isEmpty else { return }
                    Task { @MainActor in
                        self.enqueueOrPrefillDropped(text)
                    }
                }
            } else if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
                accepted = true
                provider.loadObject(ofClass: NSString.self) { item, _ in
                    guard let text = item as? String, !text.isEmpty else { return }
                    Task { @MainActor in
                        self.enqueueOrPrefillDropped(text)
                    }
                }
            }
        }
        return accepted
    }

    private func enqueueOrPrefillDropped(_ raw: String) {
        let urls = DownloadManager.parseURLList(raw)
        if urls.count > 1 {
            manager.add(urls: urls)
            flashNotice("已通过拖放加入 \(urls.count) 条链接")
        } else if let first = urls.first {
            prefilledURL = first.absoluteString
            showAdd = true
        }
    }

    private func flashNotice(_ message: String) {
        feedbackNotice = message
        Task {
            try? await Task.sleep(nanoseconds: 2_200_000_000)
            await MainActor.run {
                if feedbackNotice == message {
                    feedbackNotice = nil
                }
            }
        }
    }

    private func moveSelection(delta: Int, in shown: [DownloadTask]) -> KeyPress.Result {
        guard focusedField == nil, !shown.isEmpty else { return .ignored }
        if let current = selection, let idx = shown.firstIndex(where: { $0.id == current }) {
            let next = max(0, min(shown.count - 1, idx + delta))
            selection = shown[next].id
        } else {
            selection = delta > 0 ? shown.first?.id : shown.last?.id
        }
        return .handled
    }

    /// Single pass over tasks for sidebar badges.
    private var taskCounts: [TaskFilter: Int] {
        var result: [TaskFilter: Int] = [:]
        for task in allTasks {
            result[.all, default: 0] += 1
            switch task.state {
            case .completed:
                result[.completed, default: 0] += 1
            case .failed, .cancelled:
                result[.failed, default: 0] += 1
            default:
                result[.active, default: 0] += 1
            }
        }
        return result
    }
}

// MARK: - Notification Router Modifier

private struct ContentNotificationsModifier: ViewModifier {
    @EnvironmentObject private var manager: DownloadManager

    @Binding var filter: TaskFilter
    @Binding var showAdd: Bool
    @Binding var prefilledURL: String?
    @Binding var showSearch: Bool
    let focusQuickInput: () -> Void
    let focusSearch: () -> Void
    let activeTaskCount: Int
    let pausedTaskCount: Int
    let finishedClearableCount: Int
    let reduceMotion: Bool

    func body(content: Content) -> some View {
        content
            .onReceive(NotificationCenter.default.publisher(for: .omniShowAdd)) { note in
                if let url = note.object as? String { prefilledURL = url }
                showAdd = true
            }
            .onReceive(NotificationCenter.default.publisher(for: .omniAddFromClipboard)) { _ in
                if let text = NSPasteboard.general.string(forType: .string) {
                    prefilledURL = text
                }
                showAdd = true
            }
            .onReceive(NotificationCenter.default.publisher(for: .omniFocusQuickInput)) { _ in
                focusQuickInput()
            }
            .onReceive(NotificationCenter.default.publisher(for: .omniFocusSearch)) { _ in
                showSearch = true
                focusSearch()
            }
            .onReceive(NotificationCenter.default.publisher(for: .omniSelectFilter)) { note in
                if let target = note.object as? TaskFilter {
                    filter = target
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .omniTogglePauseAll)) { _ in
                if activeTaskCount > 0 {
                    manager.pauseAll()
                } else if pausedTaskCount > 0 {
                    manager.resumeAll()
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .omniClearCompleted)) { _ in
                if finishedClearableCount > 0 {
                    withAnimation(OmniMotion.snappy(reduceMotion: reduceMotion)) {
                        manager.clearCompleted()
                    }
                }
            }
    }
}

// MARK: - Sidebar Utility Controls

private struct SidebarUtilityRowLabel: View {
    let title: String
    let systemName: String
    var trailingText: String? = nil

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: systemName)
                .font(.system(size: 12.5, weight: .regular))
                .foregroundStyle(OmniColor.inkMuted)
                .frame(width: 18, alignment: .center)
            Text(title)
                .font(OmniFont.body)
                .foregroundStyle(OmniColor.inkMuted)
            Spacer()
            if let trailingText {
                Text(trailingText)
                    .font(OmniFont.telemetrySmall)
                    .foregroundStyle(OmniColor.inkMuted.opacity(0.75))
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
        .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
    }
}

private struct SidebarUtilityButton: View {
    let title: String
    let systemName: String
    var trailingText: String? = nil
    let action: () -> Void

    @State private var isHovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            SidebarUtilityRowLabel(title: title, systemName: systemName, trailingText: trailingText)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(isHovered ? OmniColor.hoverFill : .clear)
                )
        }
        .buttonStyle(TactilePressStyle(reduceMotion: reduceMotion))
        .onHover { isHovered = $0 }
        .animation(OmniMotion.hover, value: isHovered)
    }
}

private struct SidebarUtilityLinkStyle: ButtonStyle {
    @State private var isHovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(isHovered ? OmniColor.hoverFill : .clear)
            )
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1.0)
            .animation(OmniMotion.press, value: configuration.isPressed)
            .animation(OmniMotion.hover, value: isHovered)
            .onHover { isHovered = $0 }
    }
}

// MARK: - Empty State

struct EmptyStateView: View {
    let hasAny: Bool
    let isSearching: Bool
    let filterTitle: String
    let onPasteAndAdd: () -> Void
    let onOpenAdd: () -> Void
    let onClearFilter: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            OmniMarkView(
                size: 46,
                arcColor: OmniColor.accent.opacity(0.85),
                arrowColor: OmniColor.ink.opacity(0.78),
                lineScale: 0.88
            )

            VStack(spacing: 6) {
                Text(headline)
                    .font(OmniFont.sheetTitle)
                    .foregroundStyle(OmniColor.ink)
                Text(subtitle)
                    .font(OmniFont.body)
                    .foregroundStyle(OmniColor.inkMuted)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 460)
            }

            if hasAny {
                Button(isSearching ? "清除搜索条件" : "查看全部任务", action: onClearFilter)
                    .buttonStyle(OmniButtonStyle(variant: .secondary))
            } else {
                HStack(spacing: 10) {
                    Button("从剪贴板解析", action: onPasteAndAdd)
                        .buttonStyle(OmniButtonStyle(variant: .secondary))
                    Button("新建下载…", action: onOpenAdd)
                        .buttonStyle(OmniButtonStyle(variant: .subtle))
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(32)
    }

    private var headline: String {
        if isSearching { return "未找到匹配的任务" }
        if hasAny { return "「\(filterTitle)」下暂无记录" }
        return "粘贴或拖入链接即可开始"
    }

    private var subtitle: String {
        if isSearching { return "尝试更换关键词，或切换左侧任务分类。" }
        if hasAny { return "当前筛选分类下没有任务。" }
        return "支持 B 站分 P、小红书视频与图集、微信视频号、X、YouTube 及媒体直链。"
    }
}

// MARK: - Bottom Telemetry Bar

struct StatusBarView: View {
    @EnvironmentObject private var manager: DownloadManager

    let activeCount: Int
    let totalSpeed: Double
    let speedSamples: [Double]
    let feedbackNotice: String?

    private var hasThroughputActivity: Bool {
        totalSpeed > 0 || speedSamples.contains { $0 > 0 }
    }

    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 7) {
                Circle()
                    .fill(activeCount > 0 ? OmniColor.accent : OmniColor.inkMuted.opacity(0.45))
                    .frame(width: 6.5, height: 6.5)

                Text(statusText)
                    .font(OmniFont.metaMedium)
                    .foregroundStyle(activeCount > 0 ? OmniColor.ink : OmniColor.inkMuted)
            }

            if hasThroughputActivity {
                Rectangle()
                    .fill(OmniColor.line)
                    .frame(width: 1, height: 12)

                HStack(spacing: 8) {
                    ThroughputSparklineView(samples: speedSamples)
                    Text(Formatters.speed(totalSpeed))
                        .font(OmniFont.telemetry)
                        .foregroundStyle(OmniColor.accent)
                        .contentTransition(.numericText())
                }
            }

            if let feedbackNotice {
                Rectangle()
                    .fill(OmniColor.line)
                    .frame(width: 1, height: 12)
                Text(feedbackNotice)
                    .font(OmniFont.meta)
                    .foregroundStyle(OmniColor.accent)
                    .transition(.opacity)
            }

            Spacer()

            HStack(spacing: 10) {
                Text("并发 \(manager.settings.maxConcurrent)")
                Rectangle().fill(OmniColor.line).frame(width: 1, height: 10)
                Text("\(manager.settings.connectionsPerTask) 线程/任务")
                if manager.settings.bandwidthLimitKBps > 0 {
                    Rectangle().fill(OmniColor.line).frame(width: 1, height: 10)
                    Text("限速 \(manager.settings.bandwidthLimitKBps) KB/s")
                        .foregroundStyle(OmniColor.ink)
                }
            }
            .font(OmniFont.telemetrySmall)
            .foregroundStyle(OmniColor.inkMuted)
        }
        .padding(.horizontal, 16)
        .frame(height: 34)
        .background(OmniColor.surface)
    }

    private var statusText: String {
        activeCount > 0 ? "\(activeCount) 个任务进行中" : "就绪"
    }
}

// MARK: - Formatters

enum Formatters {
    static func bytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }

    static func speed(_ value: Double) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(max(0, value)), countStyle: .file) + "/s"
    }

    static func eta(_ seconds: Double?) -> String {
        guard let seconds, seconds.isFinite, seconds > 0 else { return "--:--" }
        let total = Int(seconds)
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%02d:%02d", m, s)
    }

    static func duration(_ seconds: Double?) -> String {
        guard let seconds, seconds > 0 else { return "" }
        return eta(seconds)
    }

    static func relativeTime(_ date: Date) -> String {
        let delta = max(0, Date().timeIntervalSince(date))
        if delta < 60 { return "刚刚" }
        if delta < 3600 { return "\(Int(delta / 60)) 分钟前" }
        if delta < 86400 { return "\(Int(delta / 3600)) 小时前" }
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm"
        return formatter.string(from: date)
    }
}
