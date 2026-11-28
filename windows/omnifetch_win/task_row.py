from __future__ import annotations

from typing import Optional

from PySide6.QtCore import Qt, Signal
from PySide6.QtGui import QAction, QColor, QFont, QPainter, QPen
from PySide6.QtWidgets import (
    QApplication,
    QHBoxLayout,
    QLabel,
    QMenu,
    QVBoxLayout,
    QWidget,
)

from .manager import DownloadManager
from .models import DownloadState, DownloadTask, Formatters
from .theme import ThemeTokens, ui_font
from .widgets import TactileIconButton, ThroughputTrack, ThumbnailWidget


class TaskRowWidget(QWidget):
    selected = Signal(str)

    def __init__(self, task: DownloadTask, manager: DownloadManager, theme: ThemeTokens, parent=None):
        super().__init__(parent)
        self.task_id = task.id
        self._task = task
        self._manager = manager
        self._theme = theme
        self._is_selected = False
        self._is_hovered = False
        self._show_divider = True

        self.setMouseTracking(True)
        self.setContextMenuPolicy(Qt.ContextMenuPolicy.CustomContextMenu)
        self.customContextMenuRequested.connect(self._show_context_menu)

        outer = QHBoxLayout(self)
        outer.setContentsMargins(12, 10, 12, 11)
        outer.setSpacing(14)

        self.thumb = ThumbnailWidget(96, 54, radius=6.0)
        outer.addWidget(self.thumb, 0, Qt.AlignmentFlag.AlignVCenter)

        # Center stack
        center = QVBoxLayout()
        center.setContentsMargins(0, 0, 0, 0)
        center.setSpacing(4)

        # Row 1: Title + Telemetry anchor
        top_row = QHBoxLayout()
        top_row.setContentsMargins(0, 0, 0, 0)
        top_row.setSpacing(10)

        self.title_label = QLabel()
        self.title_label.setFont(ui_font(10.0, QFont.Weight.Medium))
        self.title_label.setMinimumWidth(80)
        top_row.addWidget(self.title_label, 1)

        self.speed_label = QLabel()
        self.speed_label.setFont(ui_font(9.2, QFont.Weight.Medium, mono=True))
        top_row.addWidget(self.speed_label, 0)

        self.status_label = QLabel()
        self.status_label.setFont(ui_font(9.2, QFont.Weight.Medium, mono=True))
        top_row.addWidget(self.status_label, 0)
        center.addLayout(top_row)

        # Row 2: Site badge + Format + Counter/ETA
        meta_row = QHBoxLayout()
        meta_row.setContentsMargins(0, 0, 0, 0)
        meta_row.setSpacing(7)

        self.site_badge = QLabel()
        self.site_badge.setFont(ui_font(8.2, QFont.Weight.Medium))
        meta_row.addWidget(self.site_badge, 0)

        self.format_label = QLabel()
        self.format_label.setFont(ui_font(8.5, QFont.Weight.Normal))
        meta_row.addWidget(self.format_label, 0)

        meta_row.addStretch(1)

        self.counter_label = QLabel()
        self.counter_label.setFont(ui_font(8.6, QFont.Weight.Normal, mono=True))
        meta_row.addWidget(self.counter_label, 0)
        center.addLayout(meta_row)

        # Row 3: ThroughputTrack or Error text
        self.track = ThroughputTrack()
        center.addWidget(self.track)

        self.error_label = QLabel()
        self.error_label.setFont(ui_font(8.6, QFont.Weight.Normal))
        center.addWidget(self.error_label)

        outer.addLayout(center, 1)

        # Right: 64px flush-right tactile controls (secondary on left, primary pinned flush-right)
        actions_box = QHBoxLayout()
        actions_box.setContentsMargins(0, 0, 0, 0)
        actions_box.setSpacing(4)
        actions_box.addStretch(1)

        self.secondary_btn = TactileIconButton("close", "取消", size=28, tone="muted")
        self.secondary_btn.clicked.connect(self._on_secondary_clicked)
        actions_box.addWidget(self.secondary_btn)

        self.primary_btn = TactileIconButton("pause", "暂停", size=28, tone="ink")
        self.primary_btn.clicked.connect(self._on_primary_clicked)
        actions_box.addWidget(self.primary_btn)

        actions_wrap = QWidget()
        actions_wrap.setFixedWidth(64)
        actions_wrap.setLayout(actions_box)
        outer.addWidget(actions_wrap, 0, Qt.AlignmentFlag.AlignVCenter)

        self.set_theme(theme)
        self.update_task(task)

    def set_theme(self, theme: ThemeTokens) -> None:
        self._theme = theme
        self.thumb.set_theme(theme)
        self.track.set_theme(theme)
        self.primary_btn.set_theme(theme)
        self.secondary_btn.set_theme(theme)
        self.title_label.setStyleSheet(f"color: {theme.ink}; background: transparent;")
        self.format_label.setStyleSheet(f"color: {theme.ink_muted}; background: transparent;")
        self.counter_label.setStyleSheet(f"color: {theme.ink_muted}; background: transparent;")
        self.error_label.setStyleSheet(f"color: {theme.danger}; background: transparent;")
        self.site_badge.setStyleSheet(
            f"color: {theme.ink_muted}; background: {theme.surface}; "
            f"border: 1px solid {theme.line}; border-radius: 4px; padding: 1px 6px;"
        )
        self._sync_telemetry_colors()
        self.update()

    def set_selected(self, selected: bool) -> None:
        if self._is_selected != selected:
            self._is_selected = selected
            self._sync_action_visibility()
            self.update()

    def set_show_divider(self, show: bool) -> None:
        if self._show_divider != show:
            self._show_divider = show
            self.update()

    def update_task(self, task: DownloadTask) -> None:
        self._task = task
        self.thumb.configure(
            task.thumbnail,
            duration=Formatters.duration(task.duration),
            is_collection=task.progress_in_items,
            is_audio=task.options.audio_only,
        )

        # Elide single-line title smoothly
        fm = self.title_label.fontMetrics()
        max_w = max(240, self.width() - 260)
        self.title_label.setText(fm.elidedText(task.title, Qt.TextElideMode.ElideRight, max_w))
        self.title_label.setToolTip(task.title)

        if task.site:
            self.site_badge.setText(task.site)
            self.site_badge.show()
        else:
            self.site_badge.hide()

        fmt_text = task.format_label or ("仅音频" if task.options.audio_only else "")
        self.format_label.setText(fmt_text)
        self.format_label.setVisible(bool(fmt_text))

        # Telemetry & progress state
        st = task.state
        if st == DownloadState.DOWNLOADING:
            if not task.progress_in_items and task.speed > 0:
                self.speed_label.setText(Formatters.speed(task.speed))
                self.speed_label.show()
            else:
                self.speed_label.hide()
            self.status_label.setText(f"{int(task.progress * 100)}%" if task.total_bytes > 0 else "下载中")
        elif st == DownloadState.PROBING:
            self.speed_label.hide()
            self.status_label.setText("解析中")
        elif st == DownloadState.MERGING:
            self.speed_label.hide()
            self.status_label.setText("合并音视频")
        elif st == DownloadState.QUEUED:
            self.speed_label.hide()
            self.status_label.setText("排队中")
        elif st == DownloadState.PAUSED:
            self.speed_label.hide()
            self.status_label.setText(f"已暂停 {int(task.progress * 100)}%" if task.total_bytes > 0 else "已暂停")
        elif st == DownloadState.COMPLETED:
            self.speed_label.hide()
            size_txt = f"{task.downloaded_bytes} 项" if task.progress_in_items else Formatters.bytes(task.total_bytes)
            self.status_label.setText(f"✓  {size_txt}")
        elif st == DownloadState.FAILED:
            self.speed_label.hide()
            self.status_label.setText("✕  失败")
        else:
            self.speed_label.hide()
            self.status_label.setText("已取消")

        # Secondary counter / ETA / relative time
        if st in (DownloadState.DOWNLOADING, DownloadState.PAUSED, DownloadState.QUEUED):
            if task.progress_in_items:
                cnt = f"{task.downloaded_bytes} / {task.total_bytes} 项" if task.total_bytes > 0 else f"已保存 {task.downloaded_bytes} 项"
            else:
                done = Formatters.bytes(task.downloaded_bytes)
                cnt = f"{done} / {Formatters.bytes(task.total_bytes)}" if task.total_bytes > 0 else done
            if st == DownloadState.DOWNLOADING and task.eta and task.eta > 0:
                cnt += "   剩余 " + Formatters.eta(task.eta)
            self.counter_label.setText(cnt)
            self.counter_label.show()
        elif st == DownloadState.COMPLETED and task.finished_at:
            self.counter_label.setText(Formatters.relative_time(task.finished_at))
            self.counter_label.show()
        else:
            self.counter_label.hide()

        # Track vs Error
        shows_track = st in (
            DownloadState.DOWNLOADING,
            DownloadState.PROBING,
            DownloadState.MERGING,
            DownloadState.PAUSED,
            DownloadState.QUEUED,
        )
        self.track.setVisible(shows_track)
        if shows_track:
            indet = st in (DownloadState.PROBING, DownloadState.MERGING) or (
                st == DownloadState.DOWNLOADING and task.total_bytes == 0 and task.progress <= 0.001
            )
            self.track.set_state(task.progress, indet, st in (DownloadState.PAUSED, DownloadState.QUEUED))

        if st == DownloadState.FAILED and task.error_message:
            self.error_label.setText(task.error_message)
            self.error_label.setToolTip(task.error_message)
            self.error_label.show()
        else:
            self.error_label.hide()

        # Action glyphs
        if st in (DownloadState.DOWNLOADING, DownloadState.PROBING, DownloadState.MERGING):
            self.primary_btn.set_glyph("pause", "暂停", "ink")
            self.secondary_btn.set_glyph("close", "取消", "muted")
        elif st == DownloadState.PAUSED:
            self.primary_btn.set_glyph("play", "继续下载", "accent")
            self.secondary_btn.set_glyph("close", "取消", "muted")
        elif st in (DownloadState.FAILED, DownloadState.CANCELLED):
            self.primary_btn.set_glyph("retry", "重新解析并下载", "accent")
            self.secondary_btn.set_glyph("trash", "移除记录", "muted")
        elif st == DownloadState.COMPLETED:
            self.primary_btn.set_glyph("folder", "在资源管理器中显示", "ink")
            self.secondary_btn.set_glyph("open", "打开文件", "muted")
        else:  # QUEUED
            self.primary_btn.set_glyph("close", "取消排队", "muted")
            self.secondary_btn.set_glyph("close", "", "muted")

        self._sync_telemetry_colors()
        self._sync_action_visibility()

    def _sync_telemetry_colors(self) -> None:
        t = self._theme
        st = self._task.state
        self.speed_label.setStyleSheet(f"color: {t.accent}; background: transparent;")
        if st == DownloadState.FAILED:
            c = t.danger
        elif st in (DownloadState.PROBING, DownloadState.MERGING):
            c = t.accent
        elif st == DownloadState.DOWNLOADING:
            c = t.ink if self._task.total_bytes > 0 else t.accent
        else:
            c = t.ink_muted
        self.status_label.setStyleSheet(f"color: {c}; background: transparent;")

    def _sync_action_visibility(self) -> None:
        has_secondary = self._task.state != DownloadState.QUEUED
        self.secondary_btn.setVisible(has_secondary and (self._is_hovered or self._is_selected))

    def _on_primary_clicked(self) -> None:
        st = self._task.state
        if st in (DownloadState.DOWNLOADING, DownloadState.PROBING, DownloadState.MERGING):
            self._manager.pause(self.task_id)
        elif st == DownloadState.PAUSED:
            self._manager.resume(self.task_id)
        elif st in (DownloadState.FAILED, DownloadState.CANCELLED):
            self._manager.retry(self.task_id)
        elif st == DownloadState.COMPLETED:
            self._manager.reveal_file(self.task_id)
        elif st == DownloadState.QUEUED:
            self._manager.cancel(self.task_id)

    def _on_secondary_clicked(self) -> None:
        st = self._task.state
        if st in (DownloadState.DOWNLOADING, DownloadState.PROBING, DownloadState.MERGING, DownloadState.PAUSED):
            self._manager.cancel(self.task_id)
        elif st in (DownloadState.FAILED, DownloadState.CANCELLED):
            self._manager.remove(self.task_id)
        elif st == DownloadState.COMPLETED:
            self._manager.open_file(self.task_id)

    def enterEvent(self, event) -> None:
        self._is_hovered = True
        self._sync_action_visibility()
        self.update()
        super().enterEvent(event)

    def leaveEvent(self, event) -> None:
        self._is_hovered = False
        self._sync_action_visibility()
        self.update()
        super().leaveEvent(event)

    def mousePressEvent(self, event) -> None:
        if event.button() == Qt.MouseButton.LeftButton:
            self.selected.emit(self.task_id)
        super().mousePressEvent(event)

    def mouseDoubleClickEvent(self, event) -> None:
        if event.button() == Qt.MouseButton.LeftButton and self._task.state == DownloadState.COMPLETED:
            self._manager.open_file(self.task_id)
        super().mouseDoubleClickEvent(event)

    def resizeEvent(self, event) -> None:
        super().resizeEvent(event)
        fm = self.title_label.fontMetrics()
        max_w = max(240, self.width() - 260)
        self.title_label.setText(fm.elidedText(self._task.title, Qt.TextElideMode.ElideRight, max_w))

    def paintEvent(self, event) -> None:
        p = QPainter(self)
        p.setRenderHint(QPainter.RenderHint.Antialiasing, True)
        rect = self.rect().adjusted(1, 1, -1, -2)

        if self._is_selected:
            fill = QColor(self._theme.accent)
            fill.setAlphaF(0.13 if self._theme.is_dark else 0.10)
            border = QColor(self._theme.accent)
            border.setAlphaF(0.38)
            p.setBrush(fill)
            p.setPen(QPen(border, 1.0))
            p.drawRoundedRect(rect, 10.0, 10.0)
        elif self._is_hovered:
            fill = QColor(self._theme.ink)
            fill.setAlphaF(0.055 if self._theme.is_dark else 0.045)
            p.setBrush(fill)
            p.setPen(Qt.PenStyle.NoPen)
            p.drawRoundedRect(rect, 10.0, 10.0)
        elif self._show_divider:
            line = QColor(self._theme.ink)
            line.setAlphaF(0.10)
            p.setPen(QPen(line, 1.0))
            p.drawLine(122, self.height() - 1, self.width() - 12, self.height() - 1)
        p.end()

    def _show_context_menu(self, pos) -> None:
        self.selected.emit(self.task_id)
        menu = QMenu(self)
        st = self._task.state
        if st == DownloadState.COMPLETED:
            a_open = QAction("打开文件", menu)
            a_open.triggered.connect(lambda: self._manager.open_file(self.task_id))
            menu.addAction(a_open)
            a_rev = QAction("在资源管理器中显示", menu)
            a_rev.triggered.connect(lambda: self._manager.reveal_file(self.task_id))
            menu.addAction(a_rev)
        if st.is_active:
            a_pause = QAction("暂停", menu)
            a_pause.triggered.connect(lambda: self._manager.pause(self.task_id))
            menu.addAction(a_pause)
            a_cancel = QAction("取消", menu)
            a_cancel.triggered.connect(lambda: self._manager.cancel(self.task_id))
            menu.addAction(a_cancel)
        if st == DownloadState.PAUSED:
            a_res = QAction("继续下载", menu)
            a_res.triggered.connect(lambda: self._manager.resume(self.task_id))
            menu.addAction(a_res)
        if st in (DownloadState.FAILED, DownloadState.CANCELLED, DownloadState.PAUSED):
            a_ret = QAction("重新解析并下载", menu)
            a_ret.triggered.connect(lambda: self._manager.retry(self.task_id))
            menu.addAction(a_ret)

        a_copy = QAction("复制链接", menu)
        a_copy.triggered.connect(lambda: QApplication.clipboard().setText(self._task.url))
        menu.addAction(a_copy)
        menu.addSeparator()

        a_rm = QAction("移除任务", menu)
        a_rm.triggered.connect(lambda: self._manager.remove(self.task_id, delete_file=False))
        menu.addAction(a_rm)
        if self._task.file_path:
            a_rm_file = QAction("移除并删除本地文件", menu)
            a_rm_file.triggered.connect(lambda: self._manager.remove(self.task_id, delete_file=True))
            menu.addAction(a_rm_file)

        menu.exec(self.mapToGlobal(pos))
