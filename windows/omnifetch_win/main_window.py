from __future__ import annotations

from typing import Dict, List, Optional

from PySide6.QtCore import (
    QEasingCurve,
    QPointF,
    QPropertyAnimation,
    QRectF,
    Qt,
    QTimer,
    Signal,
)
from PySide6.QtGui import (
    QColor,
    QDragEnterEvent,
    QDropEvent,
    QFont,
    QKeySequence,
    QPainter,
    QPen,
    QShortcut,
)
from PySide6.QtWidgets import (
    QAbstractButton,
    QApplication,
    QFrame,
    QHBoxLayout,
    QLabel,
    QLineEdit,
    QMainWindow,
    QScrollArea,
    QSystemTrayIcon,
    QVBoxLayout,
    QWidget,
)

from .dialogs import AddDownloadDialog, SettingsDialog
from .manager import DownloadManager
from .models import (
    DownloadState,
    DownloadTask,
    Formatters,
    looks_like_media_url,
    match_platform,
    parse_urls,
)
from .task_row import TaskRowWidget
from .theme import (
    ThemeTokens,
    apply_windows_titlebar_theme,
    build_stylesheet,
    resolve_theme,
    ui_font,
)
from .widgets import (
    OmniMarkWidget,
    TactileButton,
    TactileIconButton,
    ThroughputSparkline,
    draw_glyph,
)


FILTERS = [
    ("all", "全部任务", "stack"),
    ("active", "进行中", "download"),
    ("completed", "已完成", "check"),
    ("failed", "异常", "alert"),
]


def _filter_matches(key: str, task: DownloadTask) -> bool:
    if key == "all":
        return True
    if key == "active":
        return task.state.is_active or task.state in (DownloadState.QUEUED, DownloadState.PAUSED)
    if key == "completed":
        return task.state == DownloadState.COMPLETED
    return task.state in (DownloadState.FAILED, DownloadState.CANCELLED)


# MARK: - Sidebar Row Button

class SidebarFilterButton(QAbstractButton):
    def __init__(self, key: str, title: str, glyph: str, parent=None):
        super().__init__(parent)
        self.key = key
        self._title = title
        self._glyph = glyph
        self._count = 0
        self._selected = False
        self._hovered = False
        self._theme: Optional[ThemeTokens] = None
        self.setFixedHeight(32)
        self.setCursor(Qt.CursorShape.PointingHandCursor)

    def set_theme(self, theme: ThemeTokens) -> None:
        self._theme = theme
        self.update()

    def set_selected(self, selected: bool) -> None:
        if self._selected != selected:
            self._selected = selected
            self.update()

    def set_count(self, count: int) -> None:
        if self._count != count:
            self._count = count
            self.update()

    def enterEvent(self, event) -> None:
        self._hovered = True
        self.update()
        super().enterEvent(event)

    def leaveEvent(self, event) -> None:
        self._hovered = False
        self.update()
        super().leaveEvent(event)

    def paintEvent(self, event) -> None:
        if self._theme is None:
            return
        p = QPainter(self)
        p.setRenderHint(QPainter.RenderHint.Antialiasing, True)
        t = self._theme
        r = QRectF(0.5, 0.5, self.width() - 1.0, self.height() - 1.0)

        if self._selected:
            p.setBrush(QColor(t.canvas))
            border = QColor(t.ink)
            border.setAlphaF(0.11)
            p.setPen(QPen(border, 1.0))
            p.drawRoundedRect(r, 8.0, 8.0)
        elif self._hovered:
            bg = QColor(t.ink)
            bg.setAlphaF(0.05)
            p.setBrush(bg)
            p.setPen(Qt.PenStyle.NoPen)
            p.drawRoundedRect(r, 8.0, 8.0)

        is_alert = (self.key == "failed" and self._count > 0)
        icon_color = QColor(t.accent if self._selected else (t.danger if is_alert else t.ink_muted))
        draw_glyph(p, self._glyph, QRectF(10, 7, 18, 18), icon_color, stroke=1.6)

        p.setFont(ui_font(9.5, QFont.Weight.DemiBold if self._selected else QFont.Weight.Normal))
        p.setPen(QColor(t.ink if self._selected else t.ink_muted))
        p.drawText(QRectF(36, 0, self.width() - 78, self.height()), Qt.AlignmentFlag.AlignVCenter | Qt.AlignmentFlag.AlignLeft, self._title)

        p.setFont(ui_font(8.8, QFont.Weight.Normal, mono=True))
        p.setPen(QColor(t.danger if is_alert else (t.ink if self._selected else t.ink_muted)))
        p.drawText(QRectF(self.width() - 44, 0, 34, self.height()), Qt.AlignmentFlag.AlignVCenter | Qt.AlignmentFlag.AlignRight, str(self._count))
        p.end()


class SidebarUtilityButton(QAbstractButton):
    def __init__(self, title: str, glyph: str, trailing: str = "", parent=None):
        super().__init__(parent)
        self._title = title
        self._glyph = glyph
        self._trailing = trailing
        self._hovered = False
        self._theme: Optional[ThemeTokens] = None
        self.setFixedHeight(30)
        self.setCursor(Qt.CursorShape.PointingHandCursor)

    def set_theme(self, theme: ThemeTokens) -> None:
        self._theme = theme
        self.update()

    def set_trailing(self, text: str) -> None:
        if self._trailing != text:
            self._trailing = text
            self.update()

    def enterEvent(self, event) -> None:
        self._hovered = True
        self.update()
        super().enterEvent(event)

    def leaveEvent(self, event) -> None:
        self._hovered = False
        self.update()
        super().leaveEvent(event)

    def paintEvent(self, event) -> None:
        if self._theme is None:
            return
        p = QPainter(self)
        p.setRenderHint(QPainter.RenderHint.Antialiasing, True)
        t = self._theme
        if self._hovered:
            bg = QColor(t.ink)
            bg.setAlphaF(0.05)
            p.setBrush(bg)
            p.setPen(Qt.PenStyle.NoPen)
            p.drawRoundedRect(QRectF(0, 0, self.width(), self.height()), 7.0, 7.0)

        draw_glyph(p, self._glyph, QRectF(10, 6.5, 17, 17), QColor(t.ink_muted), stroke=1.5)
        p.setFont(ui_font(9.4))
        p.setPen(QColor(t.ink_muted))
        p.drawText(QRectF(35, 0, self.width() - 80, self.height()), Qt.AlignmentFlag.AlignVCenter | Qt.AlignmentFlag.AlignLeft, self._title)
        if self._trailing:
            p.setFont(ui_font(8.4, mono=True))
            tr = QColor(t.ink_muted)
            tr.setAlphaF(0.75)
            p.setPen(tr)
            p.drawText(QRectF(self.width() - 56, 0, 46, self.height()), Qt.AlignmentFlag.AlignVCenter | Qt.AlignmentFlag.AlignRight, self._trailing)
        p.end()


# MARK: - Drag & Drop Overlay

class DropOverlayWidget(QWidget):
    def __init__(self, theme: ThemeTokens, parent=None):
        super().__init__(parent)
        self._theme = theme
        self.setAttribute(Qt.WidgetAttribute.WA_TransparentForMouseEvents)
        layout = QVBoxLayout(self)
        layout.setAlignment(Qt.AlignmentFlag.AlignCenter)

        self.card = QFrame()
        self.card.setObjectName("dropCard")
        cl = QVBoxLayout(self.card)
        cl.setContentsMargins(40, 28, 40, 28)
        cl.setSpacing(10)
        cl.setAlignment(Qt.AlignmentFlag.AlignCenter)

        self.mark = OmniMarkWidget(46, theme)
        cl.addWidget(self.mark, 0, Qt.AlignmentFlag.AlignCenter)
        self.title = QLabel("松开以添加下载")
        self.title.setFont(ui_font(12.5, QFont.Weight.DemiBold))
        self.title.setAlignment(Qt.AlignmentFlag.AlignCenter)
        cl.addWidget(self.title)
        self.sub = QLabel("支持单个链接、多行批量链接或平台分享文案")
        self.sub.setFont(ui_font(9.0))
        self.sub.setAlignment(Qt.AlignmentFlag.AlignCenter)
        cl.addWidget(self.sub)
        layout.addWidget(self.card)
        self.set_theme(theme)
        self.hide()

    def set_theme(self, theme: ThemeTokens) -> None:
        self._theme = theme
        self.mark.set_theme(theme)
        self.title.setStyleSheet(f"color: {theme.ink}; background: transparent;")
        self.sub.setStyleSheet(f"color: {theme.ink_muted}; background: transparent;")
        self.card.setStyleSheet(
            f"QFrame#dropCard {{ background: {theme.surface}; border: 1.5px dashed {theme.accent}; border-radius: 14px; }}"
        )
        self.update()

    def paintEvent(self, event) -> None:
        p = QPainter(self)
        c = QColor(self._theme.canvas)
        c.setAlphaF(0.92)
        p.fillRect(self.rect(), c)
        p.end()


# MARK: - Main Window

class MainWindow(QMainWindow):
    def __init__(self, manager: DownloadManager, app_icon=None):
        super().__init__()
        self._manager = manager
        self._theme: ThemeTokens = resolve_theme(manager.settings.theme_mode)
        self._filter: str = "all"
        self._selected_id: Optional[str] = None
        self._rows: Dict[str, TaskRowWidget] = {}
        self._speed_history: List[float] = [0.0] * 28
        self._last_clipboard: str = ""

        self.setWindowTitle("OmniFetch")
        self.resize(1080, 680)
        self.setMinimumSize(900, 560)
        self.setAcceptDrops(True)
        if app_icon:
            self.setWindowIcon(app_icon)

        # System tray for Windows completion notifications
        self._tray: Optional[QSystemTrayIcon] = None
        if app_icon and QSystemTrayIcon.isSystemTrayAvailable():
            self._tray = QSystemTrayIcon(app_icon, self)
            self._tray.setToolTip("OmniFetch")
            self._tray.show()

        self._build_ui()
        self._setup_shortcuts()
        self._apply_theme(self._theme)

        self._manager.tasks_changed.connect(self._rebuild_queue)
        self._manager.task_updated.connect(self._on_task_updated)
        self._manager.settings_changed.connect(self._on_settings_changed)
        self._manager.notification_requested.connect(self._on_notify)

        # Sparkline 1 Hz ticker (only appends while active; 0% work when idle)
        self._spark_timer = QTimer(self)
        self._spark_timer.setInterval(800)
        self._spark_timer.timeout.connect(self._tick_telemetry)
        self._spark_timer.start()

        # Optional clipboard watcher
        self._clip_timer = QTimer(self)
        self._clip_timer.setInterval(1500)
        self._clip_timer.timeout.connect(self._check_clipboard)
        self._sync_clipboard_watcher()

        self._rebuild_queue()

    # MARK: - UI Construction

    def _build_ui(self) -> None:
        central = QWidget()
        self.setCentralWidget(central)
        shell = QHBoxLayout(central)
        shell.setContentsMargins(0, 0, 0, 0)
        shell.setSpacing(0)

        # Left Sidebar (212px)
        self.sidebar = QWidget()
        self.sidebar.setFixedWidth(212)
        sbl = QVBoxLayout(self.sidebar)
        sbl.setContentsMargins(10, 18, 10, 10)
        sbl.setSpacing(3)

        brand_row = QHBoxLayout()
        brand_row.setContentsMargins(6, 0, 6, 14)
        brand_row.setSpacing(9)
        self.brand_mark = OmniMarkWidget(20, self._theme)
        brand_row.addWidget(self.brand_mark)
        self.brand_label = QLabel("OmniFetch")
        self.brand_label.setFont(ui_font(11.5, QFont.Weight.DemiBold))
        brand_row.addWidget(self.brand_label)
        brand_row.addStretch(1)
        sbl.addLayout(brand_row)

        self._filter_btns: Dict[str, SidebarFilterButton] = {}
        for key, title, glyph in FILTERS:
            btn = SidebarFilterButton(key, title, glyph)
            btn.clicked.connect(lambda _=False, k=key: self._set_filter(k))
            self._filter_btns[key] = btn
            sbl.addWidget(btn)

        sbl.addStretch(1)

        self.sb_div = QFrame()
        self.sb_div.setFixedHeight(1)
        sbl.addWidget(self.sb_div)
        sbl.addSpacing(6)

        self.btn_folder = SidebarUtilityButton("下载目录", "folder")
        self.btn_folder.clicked.connect(self._manager.open_download_folder)
        sbl.addWidget(self.btn_folder)

        self.btn_clear = SidebarUtilityButton("清除已完成", "trash")
        self.btn_clear.clicked.connect(self._manager.clear_completed)
        sbl.addWidget(self.btn_clear)

        self.btn_settings = SidebarUtilityButton("偏好设置", "gear", "Ctrl+,")
        self.btn_settings.clicked.connect(self._open_settings)
        sbl.addWidget(self.btn_settings)

        shell.addWidget(self.sidebar)

        self.v_div = QFrame()
        self.v_div.setFixedWidth(1)
        shell.addWidget(self.v_div)

        # Right Workspace
        self.workspace = QWidget()
        wsl = QVBoxLayout(self.workspace)
        wsl.setContentsMargins(0, 0, 0, 0)
        wsl.setSpacing(0)

        # Command Header
        self.header = QWidget()
        hl = QHBoxLayout(self.header)
        hl.setContentsMargins(16, 12, 16, 12)
        hl.setSpacing(10)

        # Inline Quick-Capture Well
        self.quick_well = QFrame()
        self.quick_well.setObjectName("quickWell")
        self.quick_well.setFixedHeight(36)
        qwl = QHBoxLayout(self.quick_well)
        qwl.setContentsMargins(10, 0, 4, 0)
        qwl.setSpacing(6)

        self.quick_icon = TactileIconButton("link", "快速粘贴链接", size=22, tone="muted")
        self.quick_icon.setAttribute(Qt.WidgetAttribute.WA_TransparentForMouseEvents)
        qwl.addWidget(self.quick_icon)

        self.quick_edit = QLineEdit()
        self.quick_edit.setPlaceholderText("粘贴链接、BV 号或分享文案，回车立即下载…")
        self.quick_edit.setStyleSheet("QLineEdit { background: transparent; border: none; padding: 0; }")
        self.quick_edit.textChanged.connect(self._on_quick_changed)
        self.quick_edit.returnPressed.connect(self._submit_quick)
        qwl.addWidget(self.quick_edit, 1)

        self.quick_pill = QLabel()
        self.quick_pill.setFont(ui_font(8.2, QFont.Weight.Medium))
        self.quick_pill.hide()
        qwl.addWidget(self.quick_pill)

        self.quick_paste_btn = TactileIconButton("clipboard", "粘贴剪贴板链接", size=24, tone="muted")
        self.quick_paste_btn.clicked.connect(self._paste_into_quick)
        qwl.addWidget(self.quick_paste_btn)

        self.quick_opts_btn = TactileIconButton("sliders", "解析画质与高级选项 (Ctrl+N)", size=24, tone="muted")
        self.quick_opts_btn.clicked.connect(lambda: self._open_add_dialog(self.quick_edit.text()))
        qwl.addWidget(self.quick_opts_btn)

        self.quick_submit_btn = TactileButton("新建", variant="primary", compact=True)
        self.quick_submit_btn.clicked.connect(self._on_quick_button)
        qwl.addWidget(self.quick_submit_btn)

        hl.addWidget(self.quick_well, 1)

        # Expandable Search
        self.search_edit = QLineEdit()
        self.search_edit.setPlaceholderText("筛选标题或站点…")
        self.search_edit.setFixedSize(172, 32)
        self.search_edit.textChanged.connect(lambda _: self._rebuild_queue())
        self.search_edit.hide()
        hl.addWidget(self.search_edit)

        self.btn_search = TactileIconButton("search", "搜索任务 (Ctrl+F)", size=30, tone="muted")
        self.btn_search.clicked.connect(self._toggle_search)
        hl.addWidget(self.btn_search)

        self.btn_pause_all = TactileIconButton("pause", "全部暂停 (Ctrl+Alt+P)", size=30, tone="ink")
        self.btn_pause_all.clicked.connect(self._manager.pause_all)
        hl.addWidget(self.btn_pause_all)

        self.btn_resume_all = TactileIconButton("play", "继续全部已暂停任务", size=30, tone="ink")
        self.btn_resume_all.clicked.connect(self._manager.resume_all)
        hl.addWidget(self.btn_resume_all)

        wsl.addWidget(self.header)

        self.top_div = QFrame()
        self.top_div.setFixedHeight(1)
        wsl.addWidget(self.top_div)

        # Queue Scroll Area
        self.scroll = QScrollArea()
        self.scroll.setWidgetResizable(True)
        self.queue_host = QWidget()
        self.queue_layout = QVBoxLayout(self.queue_host)
        self.queue_layout.setContentsMargins(12, 8, 12, 12)
        self.queue_layout.setSpacing(0)
        self.queue_layout.addStretch(1)
        self.scroll.setWidget(self.queue_host)
        wsl.addWidget(self.scroll, 1)

        # Empty State
        self.empty_widget = QWidget()
        el = QVBoxLayout(self.empty_widget)
        el.setAlignment(Qt.AlignmentFlag.AlignCenter)
        el.setSpacing(14)
        self.empty_mark = OmniMarkWidget(46, self._theme, line_scale=0.88)
        el.addWidget(self.empty_mark, 0, Qt.AlignmentFlag.AlignCenter)
        self.empty_title = QLabel("粘贴或拖入链接即可开始")
        self.empty_title.setFont(ui_font(12.5, QFont.Weight.DemiBold))
        self.empty_title.setAlignment(Qt.AlignmentFlag.AlignCenter)
        el.addWidget(self.empty_title)
        self.empty_sub = QLabel("支持 B 站分 P、小红书视频与图集、X、YouTube 及媒体直链。")
        self.empty_sub.setFont(ui_font(9.5))
        self.empty_sub.setAlignment(Qt.AlignmentFlag.AlignCenter)
        el.addWidget(self.empty_sub)

        eb_row = QHBoxLayout()
        eb_row.setSpacing(10)
        self.empty_primary_btn = TactileButton("从剪贴板解析", variant="secondary")
        self.empty_primary_btn.clicked.connect(self._on_empty_primary)
        self.empty_secondary_btn = TactileButton("新建下载…", variant="subtle")
        self.empty_secondary_btn.clicked.connect(lambda: self._open_add_dialog(""))
        eb_row.addWidget(self.empty_primary_btn)
        eb_row.addWidget(self.empty_secondary_btn)
        el.addLayout(eb_row)
        self.empty_widget.hide()
        wsl.addWidget(self.empty_widget, 1)

        self.bot_div = QFrame()
        self.bot_div.setFixedHeight(1)
        wsl.addWidget(self.bot_div)

        # Bottom Telemetry Bar (34px)
        self.status_bar = QWidget()
        self.status_bar.setFixedHeight(34)
        stl = QHBoxLayout(self.status_bar)
        stl.setContentsMargins(16, 0, 16, 0)
        stl.setSpacing(10)

        self.status_dot = QFrame()
        self.status_dot.setFixedSize(7, 7)
        stl.addWidget(self.status_dot)

        self.status_text = QLabel("就绪")
        self.status_text.setFont(ui_font(8.8, QFont.Weight.Medium))
        stl.addWidget(self.status_text)

        self.spark_div = QFrame()
        self.spark_div.setFixedSize(1, 11)
        stl.addWidget(self.spark_div)

        self.sparkline = ThroughputSparkline()
        stl.addWidget(self.sparkline)

        self.total_speed_label = QLabel()
        self.total_speed_label.setFont(ui_font(9.0, QFont.Weight.Medium, mono=True))
        stl.addWidget(self.total_speed_label)

        self.notice_label = QLabel()
        self.notice_label.setFont(ui_font(8.8))
        self.notice_label.hide()
        stl.addWidget(self.notice_label)

        stl.addStretch(1)

        self.specs_label = QLabel()
        self.specs_label.setFont(ui_font(8.6, mono=True))
        stl.addWidget(self.specs_label)
        wsl.addWidget(self.status_bar)

        shell.addWidget(self.workspace, 1)

        self.drop_overlay = DropOverlayWidget(self._theme, central)

    def _setup_shortcuts(self) -> None:
        QShortcut(QKeySequence("Ctrl+N"), self, activated=lambda: self._open_add_dialog(""))
        QShortcut(QKeySequence("Ctrl+Shift+V"), self, activated=self._paste_and_open_dialog)
        QShortcut(QKeySequence("Ctrl+L"), self, activated=self.quick_edit.setFocus)
        QShortcut(QKeySequence("Ctrl+F"), self, activated=self._focus_search)
        QShortcut(QKeySequence("Ctrl+,"), self, activated=self._open_settings)
        QShortcut(QKeySequence("Ctrl+1"), self, activated=lambda: self._set_filter("all"))
        QShortcut(QKeySequence("Ctrl+2"), self, activated=lambda: self._set_filter("active"))
        QShortcut(QKeySequence("Ctrl+3"), self, activated=lambda: self._set_filter("completed"))
        QShortcut(QKeySequence("Ctrl+4"), self, activated=lambda: self._set_filter("failed"))
        QShortcut(QKeySequence("Ctrl+Alt+P"), self, activated=self._toggle_pause_all)
        QShortcut(QKeySequence("Ctrl+K"), self, activated=self._manager.clear_completed)
        QShortcut(QKeySequence(Qt.Key.Key_Escape), self, activated=self._handle_escape)

    # MARK: - Theme Application

    def _apply_theme(self, t: ThemeTokens) -> None:
        self._theme = t
        app = QApplication.instance()
        if app is not None:
            app.setStyleSheet(build_stylesheet(t))

        apply_windows_titlebar_theme(self, t)
        self.sidebar.setStyleSheet(f"background: {t.surface};")
        self.workspace.setStyleSheet(f"background: {t.canvas};")
        self.header.setStyleSheet(f"background: {t.canvas};")
        self.status_bar.setStyleSheet(f"background: {t.surface};")
        self.queue_host.setStyleSheet("background: transparent;")
        self.empty_widget.setStyleSheet("background: transparent;")

        for div in (self.sb_div, self.v_div, self.top_div, self.bot_div, self.spark_div):
            div.setStyleSheet(f"background: {t.line}; border: none;")

        self.brand_mark.set_theme(t)
        self.brand_label.setStyleSheet(f"color: {t.ink};")
        for btn in self._filter_btns.values():
            btn.set_theme(t)
        for ub in (self.btn_folder, self.btn_clear, self.btn_settings):
            ub.set_theme(t)

        self.quick_well.setStyleSheet(
            f"QFrame#quickWell {{ background: {t.surface}; border: 1px solid {t.line}; border-radius: 10px; }}"
        )
        self.quick_pill.setStyleSheet(
            f"color: {t.accent}; background: {t.active_fill}; border-radius: 9px; padding: 2px 7px;"
        )
        for ib in (self.quick_icon, self.quick_paste_btn, self.quick_opts_btn, self.btn_search, self.btn_pause_all, self.btn_resume_all):
            ib.set_theme(t)
        for tb in (self.quick_submit_btn, self.empty_primary_btn, self.empty_secondary_btn):
            tb.set_theme(t)

        self.empty_mark.set_theme(t)
        self.empty_title.setStyleSheet(f"color: {t.ink};")
        self.empty_sub.setStyleSheet(f"color: {t.ink_muted};")
        self.sparkline.set_theme(t)
        self.total_speed_label.setStyleSheet(f"color: {t.accent};")
        self.notice_label.setStyleSheet(f"color: {t.accent};")
        self.specs_label.setStyleSheet(f"color: {t.ink_muted};")
        self.drop_overlay.set_theme(t)

        for row in self._rows.values():
            row.set_theme(t)
        self._refresh_chrome_state()

    # MARK: - Queue Rendering & In-Place Diff Updates

    def _visible_tasks(self) -> List[DownloadTask]:
        q = self.search_edit.text().strip().lower()
        out = []
        for task in self._manager.tasks:
            if not _filter_matches(self._filter, task):
                continue
            if q and q not in task.title.lower() and q not in (task.site or "").lower() and q not in task.url.lower():
                continue
            out.append(task)
        return out

    def _rebuild_queue(self) -> None:
        shown = self._visible_tasks()
        shown_ids = [t.id for t in shown]

        # Clear layout items without destroying reusable rows
        while self.queue_layout.count() > 0:
            item = self.queue_layout.takeAt(0)
            w = item.widget()
            if w is not None:
                w.setParent(None)

        # Prune deleted rows
        alive = {t.id for t in self._manager.tasks}
        for old_id in list(self._rows.keys()):
            if old_id not in alive:
                self._rows.pop(old_id).deleteLater()

        for idx, task in enumerate(shown):
            row = self._rows.get(task.id)
            if row is None:
                row = TaskRowWidget(task, self._manager, self._theme)
                row.selected.connect(self._select_task)
                self._rows[task.id] = row
            else:
                row.update_task(task)
            row.set_selected(task.id == self._selected_id)
            row.set_show_divider(idx < len(shown) - 1)
            self.queue_layout.addWidget(row)
        self.queue_layout.addStretch(1)

        is_empty = len(shown_ids) == 0
        self.scroll.setVisible(not is_empty)
        self.empty_widget.setVisible(is_empty)
        if is_empty:
            self._update_empty_copy()
        self._refresh_chrome_state()

    def _on_task_updated(self, task_id: str) -> None:
        task = self._manager.get_task(task_id)
        if task is None:
            self._rebuild_queue()
            return
        row = self._rows.get(task_id)
        in_view = _filter_matches(self._filter, task)
        if row is not None and in_view:
            row.update_task(task)
            self._refresh_chrome_state()
        else:
            self._rebuild_queue()

    def _select_task(self, task_id: str) -> None:
        if self._selected_id == task_id:
            return
        if self._selected_id and self._selected_id in self._rows:
            self._rows[self._selected_id].set_selected(False)
        self._selected_id = task_id
        if task_id in self._rows:
            self._rows[task_id].set_selected(True)

    def _set_filter(self, key: str) -> None:
        if self._filter != key:
            self._filter = key
            self._rebuild_queue()

    def _update_empty_copy(self) -> None:
        has_any = len(self._manager.tasks) > 0
        searching = bool(self.search_edit.text().strip())
        if searching:
            self.empty_title.setText("未找到匹配的任务")
            self.empty_sub.setText("尝试更换关键词，或切换左侧任务分类。")
            self.empty_primary_btn.setText("清除搜索条件")
            self.empty_secondary_btn.hide()
        elif has_any:
            title = dict((k, t) for k, t, _ in FILTERS).get(self._filter, "")
            self.empty_title.setText(f"「{title}」下暂无记录")
            self.empty_sub.setText("当前筛选分类下没有任务。")
            self.empty_primary_btn.setText("查看全部任务")
            self.empty_secondary_btn.hide()
        else:
            self.empty_title.setText("粘贴或拖入链接即可开始")
            self.empty_sub.setText("支持 B 站分 P、小红书视频与图集、X、YouTube 及媒体直链。")
            self.empty_primary_btn.setText("从剪贴板解析")
            self.empty_secondary_btn.show()

    def _on_empty_primary(self) -> None:
        if self._manager.tasks:
            self.search_edit.clear()
            self.search_edit.hide()
            self._set_filter("all")
        else:
            self._paste_and_open_dialog()

    def _refresh_chrome_state(self) -> None:
        counts = {"all": 0, "active": 0, "completed": 0, "failed": 0}
        for t in self._manager.tasks:
            counts["all"] += 1
            if t.state == DownloadState.COMPLETED:
                counts["completed"] += 1
            elif t.state in (DownloadState.FAILED, DownloadState.CANCELLED):
                counts["failed"] += 1
            else:
                counts["active"] += 1

        for key, btn in self._filter_btns.items():
            btn.set_selected(key == self._filter)
            btn.set_count(counts[key])

        clearable = self._manager.clearable_count
        self.btn_clear.setVisible(clearable > 0)
        self.btn_clear.set_trailing(str(clearable) if clearable > 0 else "")

        active = self._manager.active_count
        paused = self._manager.paused_count
        self.btn_pause_all.setEnabled(active > 0)
        self.btn_resume_all.setEnabled(paused > 0)

        dot_c = self._theme.accent if active > 0 else self._theme.ink_muted
        self.status_dot.setStyleSheet(f"background: {dot_c}; border-radius: 3.5px;")
        self.status_text.setText(f"{active} 个任务进行中" if active > 0 else "就绪")
        self.status_text.setStyleSheet(f"color: {self._theme.ink if active > 0 else self._theme.ink_muted};")

        spd = self._manager.total_speed
        has_spd = spd > 0 or any(v > 0 for v in self._speed_history)
        self.spark_div.setVisible(has_spd)
        self.sparkline.setVisible(has_spd)
        self.total_speed_label.setVisible(has_spd)
        if has_spd:
            self.total_speed_label.setText(Formatters.speed(spd))

        s = self._manager.settings
        specs = f"并发 {s.max_concurrent}  |  {s.connections_per_task} 线程/任务"
        if s.bandwidth_limit_kbps > 0:
            specs += f"  |  限速 {s.bandwidth_limit_kbps} KB/s"
        self.specs_label.setText(specs)

    def _tick_telemetry(self) -> None:
        spd = self._manager.total_speed
        if spd == 0 and not any(v > 0 for v in self._speed_history):
            return
        self._speed_history = self._speed_history[1:] + [spd]
        self.sparkline.set_samples(self._speed_history)
        self.total_speed_label.setText(Formatters.speed(spd))
        if not any(v > 0 for v in self._speed_history):
            self._refresh_chrome_state()

    # MARK: - Quick Capture & Dialogs

    def _on_quick_changed(self, text: str) -> None:
        urls = parse_urls(text)
        if len(urls) > 1:
            self.quick_pill.setText(f"批量 {len(urls)} 条")
            self.quick_pill.show()
            self.quick_submit_btn.setText("批量下载")
            self.quick_icon.set_glyph("download", "批量链接", "accent")
            self.quick_paste_btn.set_glyph("close", "清空输入", "muted")
        elif len(urls) == 1:
            self.quick_pill.setText(match_platform(urls[0]) or "链接")
            self.quick_pill.show()
            self.quick_submit_btn.setText("下载")
            self.quick_icon.set_glyph("download", "就绪", "accent")
            self.quick_paste_btn.set_glyph("close", "清空输入", "muted")
        else:
            self.quick_pill.hide()
            self.quick_submit_btn.setText("新建")
            self.quick_icon.set_glyph("link", "粘贴链接", "muted")
            self.quick_paste_btn.set_glyph("close" if text else "clipboard", "清空输入" if text else "粘贴剪贴板链接", "muted")

    def _paste_into_quick(self) -> None:
        if self.quick_edit.text():
            self.quick_edit.clear()
            return
        clip = (QApplication.clipboard().text() or "").strip()
        if clip:
            self.quick_edit.setText(clip)
            self.quick_edit.setFocus()

    def _on_quick_button(self) -> None:
        if parse_urls(self.quick_edit.text()):
            self._submit_quick()
        else:
            self._open_add_dialog("")

    def _submit_quick(self) -> None:
        raw = self.quick_edit.text().strip()
        urls = parse_urls(raw)
        if not urls:
            if raw:
                self._open_add_dialog(raw)
            return
        if len(urls) > 1:
            self._manager.add_urls(urls)
            self._flash_notice(f"已加入 {len(urls)} 条下载任务")
        else:
            self._manager.add_url(urls[0])
            self._flash_notice("已开始下载")
        self.quick_edit.clear()
        if self._filter in ("completed", "failed"):
            self._set_filter("all")

    def _open_add_dialog(self, prefilled: str = "") -> None:
        dlg = AddDownloadDialog(self._manager, self._theme, prefilled=prefilled, parent=self)
        dlg.exec()

    def _paste_and_open_dialog(self) -> None:
        clip = (QApplication.clipboard().text() or "").strip()
        self._open_add_dialog(clip)

    def _open_settings(self) -> None:
        dlg = SettingsDialog(self._manager, self._theme, parent=self)
        dlg.exec()

    def _toggle_search(self) -> None:
        if self.search_edit.isVisible():
            self.search_edit.clear()
            self.search_edit.hide()
        else:
            self._focus_search()

    def _focus_search(self) -> None:
        self.search_edit.show()
        self.search_edit.setFocus()

    def _toggle_pause_all(self) -> None:
        if self._manager.active_count > 0:
            self._manager.pause_all()
        elif self._manager.paused_count > 0:
            self._manager.resume_all()

    def _handle_escape(self) -> None:
        if self.search_edit.isVisible():
            self.search_edit.clear()
            self.search_edit.hide()
        else:
            self.setFocus()

    def _flash_notice(self, text: str) -> None:
        self.notice_label.setText(text)
        self.notice_label.show()
        QTimer.singleShot(2200, lambda: self.notice_label.hide() if self.notice_label.text() == text else None)

    # MARK: - Settings / Clipboard / Notifications / Drag & Drop

    def _on_settings_changed(self) -> None:
        new_theme = resolve_theme(self._manager.settings.theme_mode)
        if new_theme != self._theme:
            self._apply_theme(new_theme)
        else:
            self._refresh_chrome_state()
        self._sync_clipboard_watcher()

    def _sync_clipboard_watcher(self) -> None:
        if self._manager.settings.clipboard_watch:
            self._last_clipboard = QApplication.clipboard().text() or ""
            if not self._clip_timer.isActive():
                self._clip_timer.start()
        else:
            self._clip_timer.stop()

    def _check_clipboard(self) -> None:
        text = (QApplication.clipboard().text() or "").strip()
        if not text or text == self._last_clipboard:
            return
        self._last_clipboard = text
        urls = parse_urls(text)
        if urls and looks_like_media_url(urls[0]):
            self.raise_()
            self.activateWindow()
            self._open_add_dialog(urls[0])

    def _on_notify(self, title: str, body: str, path: str) -> None:
        if self._tray is not None:
            self._tray.showMessage(title, body, QSystemTrayIcon.MessageIcon.Information, 3500)

    def dragEnterEvent(self, event: QDragEnterEvent) -> None:
        if event.mimeData().hasUrls() or event.mimeData().hasText():
            event.acceptProposedAction()
            self.drop_overlay.setGeometry(self.centralWidget().rect())
            self.drop_overlay.show()
            self.drop_overlay.raise_()

    def dragLeaveEvent(self, event) -> None:
        self.drop_overlay.hide()

    def dropEvent(self, event: QDropEvent) -> None:
        self.drop_overlay.hide()
        md = event.mimeData()
        raw_parts = []
        if md.hasUrls():
            raw_parts += [u.toString() for u in md.urls() if u.scheme() in ("http", "https")]
        if md.hasText():
            raw_parts.append(md.text())
        urls = parse_urls("\n".join(raw_parts))
        if len(urls) > 1:
            self._manager.add_urls(urls)
            self._flash_notice(f"已通过拖放加入 {len(urls)} 条链接")
        elif len(urls) == 1:
            self._open_add_dialog(urls[0])

    def resizeEvent(self, event) -> None:
        super().resizeEvent(event)
        if self.drop_overlay.isVisible() and self.centralWidget():
            self.drop_overlay.setGeometry(self.centralWidget().rect())

    def closeEvent(self, event) -> None:
        if self._tray is not None:
            self._tray.hide()
        self._manager.shutdown()
        super().closeEvent(event)
