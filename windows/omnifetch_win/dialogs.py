from __future__ import annotations

import webbrowser
from typing import Optional

from PySide6.QtCore import Qt, QTimer, Signal
from PySide6.QtGui import QFont
from PySide6.QtWidgets import (
    QApplication,
    QCheckBox,
    QComboBox,
    QDialog,
    QFileDialog,
    QFrame,
    QHBoxLayout,
    QLabel,
    QLineEdit,
    QPlainTextEdit,
    QScrollArea,
    QSpinBox,
    QStackedWidget,
    QVBoxLayout,
    QWidget,
)

from .engines import locate_ffmpeg, locate_gallery_dl
from .manager import DownloadManager
from .models import (
    AppSettings,
    DownloadOptions,
    Formatters,
    MediaInfo,
    QUALITY_PRESETS,
    match_platform,
    parse_urls,
)
from .theme import ThemeTokens, apply_windows_titlebar_theme, ui_font
from .widgets import (
    OmniMarkWidget,
    SwitchToggle,
    TactileButton,
    TactileIconButton,
    ThroughputTrack,
    ThumbnailWidget,
)


def _hline(theme: ThemeTokens) -> QFrame:
    f = QFrame()
    f.setFixedHeight(1)
    f.setStyleSheet(f"background: {theme.line}; border: none;")
    return f


# MARK: - Add Download Dialog

class AddDownloadDialog(QDialog):
    _probe_done = Signal(object, object)  # info, error

    def __init__(self, manager: DownloadManager, theme: ThemeTokens, prefilled: str = "", parent=None):
        super().__init__(parent)
        self._manager = manager
        self._theme = theme
        self._info: Optional[MediaInfo] = None
        self._is_probing = False

        self.setWindowTitle("新建下载 · OmniFetch")
        self.setFixedSize(600, 540)
        self.setModal(True)
        self.setStyleSheet(f"QDialog {{ background: {theme.canvas}; }}")

        self._probe_done.connect(self._on_probe_done)

        root = QVBoxLayout(self)
        root.setContentsMargins(0, 0, 0, 0)
        root.setSpacing(0)

        # Header
        header = QWidget()
        header.setStyleSheet(f"background: {theme.surface};")
        hl = QHBoxLayout(header)
        hl.setContentsMargins(20, 14, 16, 14)
        hl.setSpacing(10)

        mark = OmniMarkWidget(20, theme)
        hl.addWidget(mark)

        title = QLabel("新建下载")
        title.setFont(ui_font(12.0, QFont.Weight.DemiBold))
        hl.addWidget(title)

        self.site_pill = QLabel()
        self.site_pill.setFont(ui_font(8.5, QFont.Weight.Medium))
        self.site_pill.setStyleSheet(
            f"color: {theme.accent}; background: {theme.active_fill}; border-radius: 9px; padding: 2px 8px;"
        )
        self.site_pill.hide()
        hl.addWidget(self.site_pill)
        hl.addStretch(1)

        close_btn = TactileIconButton("close", "关闭 (Esc)", size=26, tone="muted")
        close_btn.set_theme(theme)
        close_btn.clicked.connect(self.reject)
        hl.addWidget(close_btn)
        root.addWidget(header)
        root.addWidget(_hline(theme))

        # Scrollable body
        scroll = QScrollArea()
        scroll.setWidgetResizable(True)
        body_wrap = QWidget()
        body_wrap.setStyleSheet("background: transparent;")
        bl = QVBoxLayout(body_wrap)
        bl.setContentsMargins(20, 18, 20, 18)
        bl.setSpacing(16)

        # URL section
        url_lbl = QLabel("媒体链接")
        url_lbl.setFont(ui_font(8.8, QFont.Weight.Medium))
        url_lbl.setStyleSheet(f"color: {theme.ink_muted};")
        bl.addWidget(url_lbl)

        url_row = QHBoxLayout()
        url_row.setSpacing(8)
        self.url_edit = QLineEdit()
        self.url_edit.setPlaceholderText("https://www.bilibili.com/video/BV…")
        self.url_edit.setFixedHeight(34)
        self.url_edit.textChanged.connect(self._on_url_changed)
        self.url_edit.returnPressed.connect(self._start_probe)
        url_row.addWidget(self.url_edit, 1)

        paste_btn = TactileIconButton("clipboard", "从剪贴板粘贴并解析", size=34, tone="muted")
        paste_btn.set_theme(theme)
        paste_btn.clicked.connect(self._paste_and_probe)
        url_row.addWidget(paste_btn)

        self.probe_btn = TactileButton("解析", variant="secondary")
        self.probe_btn.set_theme(theme)
        self.probe_btn.setFixedHeight(34)
        self.probe_btn.clicked.connect(self._start_probe)
        url_row.addWidget(self.probe_btn)
        bl.addLayout(url_row)

        hint = QLabel("可直接粘贴带文字的分享消息、BV / av 号，或多条链接批量排队。")
        hint.setFont(ui_font(8.6))
        hint.setStyleSheet(f"color: {theme.ink_muted};")
        bl.addWidget(hint)

        # Batch banner
        self.batch_banner = QFrame()
        self.batch_banner.setStyleSheet(
            f"background: {theme.active_fill}; border: 1px solid {theme.accent_line}; border-radius: 10px;"
        )
        bbl = QVBoxLayout(self.batch_banner)
        bbl.setContentsMargins(14, 10, 14, 10)
        self.batch_title = QLabel()
        self.batch_title.setFont(ui_font(9.5, QFont.Weight.Medium))
        self.batch_sub = QLabel("批量任务使用当前默认画质与并发分片配置。")
        self.batch_sub.setFont(ui_font(8.6))
        self.batch_sub.setStyleSheet(f"color: {theme.ink_muted}; border: none; background: transparent;")
        self.batch_title.setStyleSheet(f"color: {theme.ink}; border: none; background: transparent;")
        bbl.addWidget(self.batch_title)
        bbl.addWidget(self.batch_sub)
        self.batch_banner.hide()
        bl.addWidget(self.batch_banner)

        # Probing indicator
        self.probe_card = QFrame()
        self.probe_card.setStyleSheet(
            f"background: {theme.surface}; border: 1px solid {theme.line}; border-radius: 10px;"
        )
        pcl = QVBoxLayout(self.probe_card)
        pcl.setContentsMargins(14, 12, 14, 12)
        pcl.setSpacing(8)
        p_lbl = QLabel("正在解析媒体元数据与可用轨道…")
        p_lbl.setStyleSheet(f"color: {theme.ink}; border: none; background: transparent;")
        self.probe_track = ThroughputTrack()
        self.probe_track.set_theme(theme)
        pcl.addWidget(p_lbl)
        pcl.addWidget(self.probe_track)
        self.probe_card.hide()
        bl.addWidget(self.probe_card)

        # Error banner
        self.error_label = QLabel()
        self.error_label.setWordWrap(True)
        self.error_label.setStyleSheet(
            f"color: {theme.danger}; background: {theme.danger_fill}; "
            f"border: 1px solid {theme.danger}; border-radius: 10px; padding: 10px 12px;"
        )
        self.error_label.hide()
        bl.addWidget(self.error_label)

        # Probed media info card
        self.info_card = QFrame()
        self.info_card.setStyleSheet(
            f"QFrame#infoCard {{ background: {theme.surface}; border: 1px solid {theme.line}; border-radius: 10px; }}"
        )
        self.info_card.setObjectName("infoCard")
        icl = QVBoxLayout(self.info_card)
        icl.setContentsMargins(14, 14, 14, 14)
        icl.setSpacing(12)

        top_info = QHBoxLayout()
        top_info.setSpacing(14)
        self.preview_thumb = ThumbnailWidget(136, 76, radius=6.0)
        self.preview_thumb.set_theme(theme)
        top_info.addWidget(self.preview_thumb)

        info_text = QVBoxLayout()
        info_text.setSpacing(6)
        self.preview_title = QLabel()
        self.preview_title.setWordWrap(True)
        self.preview_title.setFont(ui_font(10.0, QFont.Weight.DemiBold))
        self.preview_meta = QLabel()
        self.preview_meta.setFont(ui_font(8.8))
        self.preview_meta.setStyleSheet(f"color: {theme.ink_muted};")
        info_text.addWidget(self.preview_title)
        info_text.addWidget(self.preview_meta)
        info_text.addStretch(1)
        top_info.addLayout(info_text, 1)
        icl.addLayout(top_info)
        icl.addWidget(_hline(theme))

        fmt_row = QHBoxLayout()
        fmt_row.addWidget(QLabel("清晰度与格式"))
        fmt_row.addStretch(1)
        self.format_combo = QComboBox()
        self.format_combo.setMinimumWidth(230)
        fmt_row.addWidget(self.format_combo)
        icl.addLayout(fmt_row)

        self.parts_check = QCheckBox()
        self.parts_check.hide()
        icl.addWidget(self.parts_check)

        opts_row = QHBoxLayout()
        self.audio_check = QCheckBox("仅提取音频")
        self.audio_check.toggled.connect(lambda on: self.format_combo.setEnabled(not on))
        opts_row.addWidget(self.audio_check)
        opts_row.addStretch(1)
        opts_row.addWidget(QLabel("画质上限"))
        self.quality_combo = QComboBox()
        for q in QUALITY_PRESETS:
            self.quality_combo.addItem("最佳" if q == "best" else f"{q}p", q)
        idx = QUALITY_PRESETS.index(manager.settings.preferred_quality) if manager.settings.preferred_quality in QUALITY_PRESETS else 0
        self.quality_combo.setCurrentIndex(idx)
        opts_row.addWidget(self.quality_combo)
        icl.addLayout(opts_row)

        self.info_card.hide()
        bl.addWidget(self.info_card)

        # Advanced options card
        adv_card = QFrame()
        adv_card.setObjectName("advCard")
        adv_card.setStyleSheet(
            f"QFrame#advCard {{ background: {theme.surface}; border: 1px solid {theme.line}; border-radius: 10px; }}"
        )
        acl = QVBoxLayout(adv_card)
        acl.setContentsMargins(14, 10, 14, 10)
        acl.setSpacing(10)

        adv_head = QHBoxLayout()
        adv_lbl = QLabel("高级选项")
        adv_lbl.setFont(ui_font(9.5, QFont.Weight.Medium))
        adv_head.addWidget(adv_lbl)
        adv_head.addStretch(1)
        self.adv_toggle = TactileButton("展开", variant="subtle", compact=True)
        self.adv_toggle.set_theme(theme)
        self.adv_toggle.clicked.connect(self._toggle_advanced)
        adv_head.addWidget(self.adv_toggle)
        acl.addLayout(adv_head)

        self.adv_body = QWidget()
        abl = QVBoxLayout(self.adv_body)
        abl.setContentsMargins(0, 6, 0, 2)
        abl.setSpacing(10)

        dir_row = QHBoxLayout()
        dir_row.addWidget(QLabel("保存位置"))
        self.dir_label = QLabel(manager.settings.save_directory)
        self.dir_label.setStyleSheet(f"color: {theme.ink_muted};")
        dir_row.addWidget(self.dir_label, 1)
        choose_btn = TactileButton("选择…", variant="secondary", compact=True)
        choose_btn.set_theme(theme)
        choose_btn.clicked.connect(self._choose_dir)
        dir_row.addWidget(choose_btn)
        abl.addLayout(dir_row)

        conn_row = QHBoxLayout()
        conn_row.addWidget(QLabel("单任务分片连接"))
        conn_row.addStretch(1)
        self.conn_spin = QSpinBox()
        self.conn_spin.setRange(1, 16)
        self.conn_spin.setValue(manager.settings.connections_per_task)
        self.conn_spin.setSuffix(" 线程")
        conn_row.addWidget(self.conn_spin)
        abl.addLayout(conn_row)

        ck_row = QHBoxLayout()
        ck_row.addWidget(QLabel("读取浏览器 Cookie"))
        ck_row.addStretch(1)
        self.browser_combo = QComboBox()
        for label, val in [("不使用", ""), ("Chrome", "chrome"), ("Edge", "edge"), ("Firefox", "firefox")]:
            self.browser_combo.addItem(label, val)
        b_idx = self.browser_combo.findData(manager.settings.cookies_from_browser)
        if b_idx >= 0:
            self.browser_combo.setCurrentIndex(b_idx)
        ck_row.addWidget(self.browser_combo)
        abl.addLayout(ck_row)

        self.adv_body.hide()
        acl.addWidget(self.adv_body)
        bl.addWidget(adv_card)
        bl.addStretch(1)

        scroll.setWidget(body_wrap)
        root.addWidget(scroll, 1)
        root.addWidget(_hline(theme))

        # Footer
        footer = QWidget()
        footer.setStyleSheet(f"background: {theme.surface};")
        fl = QHBoxLayout(footer)
        fl.setContentsMargins(20, 12, 20, 12)
        fl.setSpacing(10)

        self.footer_hint = QLabel("可先解析预览画质，或直接开始下载")
        self.footer_hint.setFont(ui_font(8.8))
        self.footer_hint.setStyleSheet(f"color: {theme.ink_muted};")
        fl.addWidget(self.footer_hint)
        fl.addStretch(1)

        cancel_btn = TactileButton("取消", variant="secondary")
        cancel_btn.set_theme(theme)
        cancel_btn.clicked.connect(self.reject)
        fl.addWidget(cancel_btn)

        self.start_btn = TactileButton("开始下载", variant="primary")
        self.start_btn.set_theme(theme)
        self.start_btn.clicked.connect(self._submit)
        fl.addWidget(self.start_btn)
        root.addWidget(footer)

        if prefilled.strip():
            self.url_edit.setText(prefilled.strip())
            QTimer.singleShot(80, self._start_probe)
        else:
            clip = (QApplication.clipboard().text() or "").strip()
            if parse_urls(clip):
                self.url_edit.setText(clip)
            self.url_edit.setFocus()

        apply_windows_titlebar_theme(self, theme)

    def _on_url_changed(self, text: str) -> None:
        self._info = None
        self.info_card.hide()
        self.error_label.hide()
        urls = parse_urls(text)
        if len(urls) > 1:
            self.site_pill.setText(f"批量 {len(urls)} 条")
            self.site_pill.show()
            self.batch_title.setText(f"已识别 {len(urls)} 条链接，将批量加入队列")
            self.batch_banner.show()
            self.probe_btn.setEnabled(False)
            self.start_btn.setText("批量加入队列")
            self.footer_hint.setText("将依次路由至对应平台引擎")
        elif len(urls) == 1:
            site = match_platform(urls[0]) or "链接"
            self.site_pill.setText(site)
            self.site_pill.show()
            self.batch_banner.hide()
            self.probe_btn.setEnabled(not self._is_probing)
            self.start_btn.setText("开始下载")
            self.footer_hint.setText("可先解析预览画质，或直接开始下载")
        else:
            self.site_pill.hide()
            self.batch_banner.hide()
            self.probe_btn.setEnabled(False)
            self.start_btn.setText("开始下载")
        self.start_btn.setEnabled(bool(text.strip()))

    def _paste_and_probe(self) -> None:
        clip = (QApplication.clipboard().text() or "").strip()
        if clip:
            self.url_edit.setText(clip)
            self._start_probe()

    def _start_probe(self) -> None:
        urls = parse_urls(self.url_edit.text())
        if len(urls) != 1 or self._is_probing:
            return
        self._is_probing = True
        self.probe_btn.setEnabled(False)
        self.probe_btn.setText("解析中…")
        self.error_label.hide()
        self.info_card.hide()
        self.probe_card.show()
        self.probe_track.set_state(0.0, indeterminate=True, paused=False)

        opts = DownloadOptions(
            quality=self.quality_combo.currentData(),
            connections=self.conn_spin.value(),
            cookies_from_browser=self.browser_combo.currentData() or None,
        )
        self._manager.probe_async(urls[0], opts, lambda info, err: self._probe_done.emit(info, err))

    def _on_probe_done(self, info: Optional[MediaInfo], err: Optional[str]) -> None:
        self._is_probing = False
        self.probe_card.hide()
        self.probe_track.set_state(0.0, indeterminate=False, paused=False)
        self.probe_btn.setText("解析")
        self.probe_btn.setEnabled(len(parse_urls(self.url_edit.text())) == 1)

        if err or info is None:
            self.error_label.setText(err or "解析失败")
            self.error_label.show()
            return

        self._info = info
        self.preview_thumb.configure(info.thumbnail, duration=Formatters.duration(info.duration), is_collection=info.is_collection)
        self.preview_title.setText(info.title)
        meta_parts = [p for p in [info.site, Formatters.duration(info.duration)] if p]
        self.preview_meta.setText("  ·  ".join(meta_parts))

        self.format_combo.clear()
        if info.engine_id == "ytdlp":
            self.format_combo.addItem("按画质上限自动选择", None)
        for fmt in info.formats:
            if not fmt.is_audio_only:
                label = f"{fmt.label} ({fmt.note})" if fmt.note else fmt.label
                self.format_combo.addItem(label, fmt.id)
        if info.selected_format_id:
            idx = self.format_combo.findData(info.selected_format_id)
            if idx >= 0:
                self.format_combo.setCurrentIndex(idx)

        if len(info.parts) > 1:
            self.parts_check.setText(f"下载全部 {len(info.parts)} 个分 P（排队逐个保存）")
            self.parts_check.setChecked(False)
            self.parts_check.show()
        else:
            self.parts_check.hide()

        self.footer_hint.setText(f"将使用 {info.engine_id} 引擎")
        self.info_card.show()

    def _toggle_advanced(self) -> None:
        vis = not self.adv_body.isVisible()
        self.adv_body.setVisible(vis)
        self.adv_toggle.setText("收起" if vis else "展开")

    def _choose_dir(self) -> None:
        chosen = QFileDialog.getExistingDirectory(self, "选择下载目录", self._manager.settings.save_directory)
        if chosen:
            self.dir_label.setText(chosen)
            s = AppSettings.from_dict(self._manager.settings.to_dict())
            s.save_directory = chosen
            self._manager.update_settings(s)

    def _submit(self) -> None:
        urls = parse_urls(self.url_edit.text())
        if not urls:
            return
        opts = DownloadOptions(
            format_id=None if self.audio_check.isChecked() else self.format_combo.currentData(),
            audio_only=self.audio_check.isChecked(),
            quality=self.quality_combo.currentData(),
            connections=self.conn_spin.value(),
            cookies_from_browser=self.browser_combo.currentData() or None,
        )
        if len(urls) > 1:
            self._manager.add_urls(urls, opts)
        elif self._info and self.parts_check.isVisible() and self.parts_check.isChecked():
            base = self._info.extra.get("webpage") or urls[0]
            part_urls = [f"{base}?p={p.index}" for p in self._info.parts]
            self._manager.add_urls(part_urls, opts)
        else:
            self._manager.add_url(urls[0], opts, info=self._info)
        self.accept()


# MARK: - Settings Dialog (3-Tab Precision Preferences)

class SettingsDialog(QDialog):
    def __init__(self, manager: DownloadManager, theme: ThemeTokens, parent=None):
        super().__init__(parent)
        self._manager = manager
        self._theme = theme
        self._draft = AppSettings.from_dict(manager.settings.to_dict())

        self.setWindowTitle("偏好设置 · OmniFetch")
        self.setFixedSize(560, 560)
        self.setModal(True)
        self.setStyleSheet(f"QDialog {{ background: {theme.canvas}; }}")

        root = QVBoxLayout(self)
        root.setContentsMargins(0, 0, 0, 0)
        root.setSpacing(0)

        # Segmented tab bar
        tab_bar = QWidget()
        tab_bar.setStyleSheet(f"background: {theme.surface};")
        tbl = QHBoxLayout(tab_bar)
        tbl.setContentsMargins(20, 12, 20, 12)
        tbl.setSpacing(4)

        self._tab_buttons = []
        for idx, label in enumerate(["通用与传输", "账号与 Cookie", "引擎与环境"]):
            btn = TactileButton(label, variant="subtle", compact=True)
            btn.set_theme(theme)
            btn.setSizePolicy(btn.sizePolicy().Policy.Expanding, btn.sizePolicy().Policy.Fixed)
            btn.clicked.connect(lambda _=False, i=idx: self._select_tab(i))
            self._tab_buttons.append(btn)
            tbl.addWidget(btn)
        root.addWidget(tab_bar)
        root.addWidget(_hline(theme))

        self.stack = QStackedWidget()
        self.stack.addWidget(self._build_general_tab())
        self.stack.addWidget(self._build_accounts_tab())
        self.stack.addWidget(self._build_engines_tab())
        root.addWidget(self.stack, 1)
        root.addWidget(_hline(theme))

        # Footer
        footer = QWidget()
        footer.setStyleSheet(f"background: {theme.surface};")
        fl = QHBoxLayout(footer)
        fl.setContentsMargins(20, 11, 20, 11)
        self.saved_label = QLabel("开关与数值调整会自动即时生效")
        self.saved_label.setFont(ui_font(8.8))
        self.saved_label.setStyleSheet(f"color: {theme.ink_muted};")
        fl.addWidget(self.saved_label)
        fl.addStretch(1)

        save_btn = TactileButton("保存设置", variant="primary")
        save_btn.set_theme(theme)
        save_btn.clicked.connect(self._save_all)
        fl.addWidget(save_btn)
        root.addWidget(footer)

        self._manager.ytdlp_changed.connect(self._refresh_engine_labels)
        self._select_tab(0)
        apply_windows_titlebar_theme(self, theme)

    def _select_tab(self, idx: int) -> None:
        self.stack.setCurrentIndex(idx)
        t = self._theme
        for i, btn in enumerate(self._tab_buttons):
            if i == idx:
                btn.setStyleSheet(
                    f"QPushButton {{ background: {t.canvas}; color: {t.ink}; border: 1px solid {t.line}; "
                    f"border-radius: 7px; font-weight: 600; font-size: 12.5px; }}"
                )
            else:
                btn.setStyleSheet(
                    f"QPushButton {{ background: transparent; color: {t.ink_muted}; border: none; "
                    f"border-radius: 7px; font-weight: 500; font-size: 12.5px; }}"
                    f"QPushButton:hover {{ background: {t.hover_fill}; }}"
                )

    def _card(self, title: str):
        wrap = QWidget()
        wl = QVBoxLayout(wrap)
        wl.setContentsMargins(0, 0, 0, 0)
        wl.setSpacing(6)
        lbl = QLabel(title)
        lbl.setFont(ui_font(8.8, QFont.Weight.Medium))
        lbl.setStyleSheet(f"color: {self._theme.ink_muted}; padding-left: 2px;")
        wl.addWidget(lbl)

        frame = QFrame()
        frame.setObjectName("settingsCard")
        frame.setStyleSheet(
            f"QFrame#settingsCard {{ background: {self._theme.surface}; border: 1px solid {self._theme.line}; border-radius: 10px; }}"
        )
        fl = QVBoxLayout(frame)
        fl.setContentsMargins(0, 0, 0, 0)
        fl.setSpacing(0)
        wl.addWidget(frame)
        return wrap, fl

    def _row(self, label: str, control: QWidget, caption: str = "") -> QWidget:
        w = QWidget()
        w.setStyleSheet("background: transparent;")
        hl = QHBoxLayout(w)
        hl.setContentsMargins(14, 9, 14, 9)
        hl.setSpacing(12)
        left = QVBoxLayout()
        left.setSpacing(2)
        t_lbl = QLabel(label)
        t_lbl.setFont(ui_font(9.5))
        left.addWidget(t_lbl)
        if caption:
            c_lbl = QLabel(caption)
            c_lbl.setWordWrap(True)
            c_lbl.setFont(ui_font(8.4))
            c_lbl.setStyleSheet(f"color: {self._theme.ink_muted};")
            left.addWidget(c_lbl)
        hl.addLayout(left, 1)
        hl.addWidget(control, 0, Qt.AlignmentFlag.AlignVCenter)
        return w

    def _build_general_tab(self) -> QWidget:
        page = QWidget()
        pl = QVBoxLayout(page)
        pl.setContentsMargins(20, 16, 20, 16)
        pl.setSpacing(14)

        c1, l1 = self._card("存储与传输")
        dir_ctrl = QWidget()
        dl = QHBoxLayout(dir_ctrl)
        dl.setContentsMargins(0, 0, 0, 0)
        dl.setSpacing(8)
        self.dir_text = QLabel(self._draft.save_directory)
        self.dir_text.setStyleSheet(f"color: {self._theme.ink_muted};")
        self.dir_text.setMaximumWidth(230)
        dl.addWidget(self.dir_text)
        dir_btn = TactileButton("选择…", variant="secondary", compact=True)
        dir_btn.set_theme(self._theme)
        dir_btn.clicked.connect(self._choose_dir)
        dl.addWidget(dir_btn)
        l1.addWidget(self._row("保存目录", dir_ctrl))
        l1.addWidget(_hline(self._theme))

        self.conc_spin = QSpinBox()
        self.conc_spin.setRange(1, 10)
        self.conc_spin.setValue(self._draft.max_concurrent)
        self.conc_spin.setSuffix(" 个")
        self.conc_spin.valueChanged.connect(lambda v: self._mutate(max_concurrent=v))
        l1.addWidget(self._row("同时下载任务", self.conc_spin))
        l1.addWidget(_hline(self._theme))

        self.conn_spin = QSpinBox()
        self.conn_spin.setRange(1, 16)
        self.conn_spin.setValue(self._draft.connections_per_task)
        self.conn_spin.setSuffix(" 线程")
        self.conn_spin.valueChanged.connect(lambda v: self._mutate(connections_per_task=v))
        l1.addWidget(self._row("每任务分片连接", self.conn_spin, "单文件并发越高越快；并发过多会争抢带宽与磁盘 IO。"))
        l1.addWidget(_hline(self._theme))

        self.limit_spin = QSpinBox()
        self.limit_spin.setRange(0, 1_000_000)
        self.limit_spin.setSingleStep(512)
        self.limit_spin.setValue(self._draft.bandwidth_limit_kbps)
        self.limit_spin.setSuffix(" KB/s")
        self.limit_spin.valueChanged.connect(lambda v: self._mutate(bandwidth_limit_kbps=v))
        l1.addWidget(self._row("全局限速", self.limit_spin, "0 表示不限速，对原生分片与 yt-dlp 同时生效。"))
        pl.addWidget(c1)

        c2, l2 = self._card("外观与默认行为")
        self.theme_combo = QComboBox()
        for label, val in [("跟随系统", "system"), ("浅色模式", "light"), ("深色模式", "dark")]:
            self.theme_combo.addItem(label, val)
        t_idx = self.theme_combo.findData(self._draft.theme_mode)
        if t_idx >= 0:
            self.theme_combo.setCurrentIndex(t_idx)
        self.theme_combo.currentIndexChanged.connect(lambda _: self._mutate(theme_mode=self.theme_combo.currentData()))
        l2.addWidget(self._row("界面主题", self.theme_combo))
        l2.addWidget(_hline(self._theme))

        self.qual_combo = QComboBox()
        for q in QUALITY_PRESETS:
            self.qual_combo.addItem("最佳" if q == "best" else f"{q}p", q)
        q_idx = self.qual_combo.findData(self._draft.preferred_quality)
        if q_idx >= 0:
            self.qual_combo.setCurrentIndex(q_idx)
        self.qual_combo.currentIndexChanged.connect(lambda _: self._mutate(preferred_quality=self.qual_combo.currentData()))
        l2.addWidget(self._row("默认首选画质", self.qual_combo))
        l2.addWidget(_hline(self._theme))

        self.clip_sw = SwitchToggle(self._draft.clipboard_watch)
        self.clip_sw.set_theme(self._theme)
        self.clip_sw.toggled.connect(lambda v: self._mutate(clipboard_watch=v))
        l2.addWidget(self._row("监听剪贴板媒体链接", self.clip_sw))
        l2.addWidget(_hline(self._theme))

        self.notify_sw = SwitchToggle(self._draft.notify_on_completion)
        self.notify_sw.set_theme(self._theme)
        self.notify_sw.toggled.connect(lambda v: self._mutate(notify_on_completion=v))
        l2.addWidget(self._row("下载完成发送系统通知", self.notify_sw))
        l2.addWidget(_hline(self._theme))

        self.hist_sw = SwitchToggle(self._draft.keep_history)
        self.hist_sw.set_theme(self._theme)
        self.hist_sw.toggled.connect(lambda v: self._mutate(keep_history=v))
        l2.addWidget(self._row("保留下载历史记录", self.hist_sw))
        pl.addWidget(c2)
        pl.addStretch(1)
        return page

    def _build_accounts_tab(self) -> QWidget:
        page = QWidget()
        pl = QVBoxLayout(page)
        pl.setContentsMargins(20, 16, 20, 16)
        pl.setSpacing(14)

        c1, l1 = self._card("浏览器会话")
        self.browser_combo = QComboBox()
        for label, val in [("不使用", ""), ("Chrome", "chrome"), ("Edge", "edge"), ("Firefox", "firefox")]:
            self.browser_combo.addItem(label, val)
        b_idx = self.browser_combo.findData(self._draft.cookies_from_browser)
        if b_idx >= 0:
            self.browser_combo.setCurrentIndex(b_idx)
        self.browser_combo.currentIndexChanged.connect(lambda _: self._mutate(cookies_from_browser=self.browser_combo.currentData()))
        l1.addWidget(self._row("读取浏览器 Cookie", self.browser_combo, "用于 B 站 4K 或需登录才可访问的媒体资源。"))
        pl.addWidget(c1)

        c2, l2 = self._card("手动绑定 Cookie")
        box = QWidget()
        bl = QVBoxLayout(box)
        bl.setContentsMargins(14, 10, 14, 12)
        bl.setSpacing(8)
        bl.addWidget(QLabel("所属域名"))
        self.domain_edit = QLineEdit(self._draft.cookie_domain)
        self.domain_edit.setPlaceholderText("例如 bilibili.com 或 xiaohongshu.com")
        bl.addWidget(self.domain_edit)
        bl.addWidget(QLabel("Cookie 请求头（可选）"))
        self.cookie_edit = QPlainTextEdit(self._draft.cookie_header)
        self.cookie_edit.setPlaceholderText("SESSDATA=…; bili_jct=…")
        self.cookie_edit.setFixedHeight(78)
        self.cookie_edit.setFont(ui_font(9.0, mono=True))
        bl.addWidget(self.cookie_edit)
        note = QLabel("仅发送给上述绑定域名。修改文本后点击右下角「保存设置」生效。")
        note.setFont(ui_font(8.4))
        note.setStyleSheet(f"color: {self._theme.ink_muted};")
        bl.addWidget(note)
        l2.addWidget(box)
        pl.addWidget(c2)
        pl.addStretch(1)
        return page

    def _build_engines_tab(self) -> QWidget:
        page = QWidget()
        pl = QVBoxLayout(page)
        pl.setContentsMargins(20, 16, 20, 16)
        pl.setSpacing(14)

        c1, l1 = self._card("本地运行组件")
        yt_ctrl = QWidget()
        yl = QHBoxLayout(yt_ctrl)
        yl.setContentsMargins(0, 0, 0, 0)
        yl.setSpacing(8)
        self.yt_ver_label = QLabel()
        self.yt_ver_label.setFont(ui_font(8.8, mono=True))
        yl.addWidget(self.yt_ver_label)
        self.yt_install_btn = TactileButton("安装 / 更新", variant="secondary", compact=True)
        self.yt_install_btn.set_theme(self._theme)
        self.yt_install_btn.clicked.connect(self._manager.install_ytdlp_async)
        yl.addWidget(self.yt_install_btn)
        yt_ref = TactileIconButton("retry", "重新检测版本", size=28, tone="muted")
        yt_ref.set_theme(self._theme)
        yt_ref.clicked.connect(self._manager.refresh_ytdlp)
        yl.addWidget(yt_ref)
        l1.addWidget(self._row("yt-dlp", yt_ctrl, "负责 YouTube 及通用视频站点解析与流媒体拉取。"))
        l1.addWidget(_hline(self._theme))

        g_installed = locate_gallery_dl() is not None
        g_lbl = QLabel("已安装" if g_installed else "未检测到（可选 pip install gallery-dl）")
        g_lbl.setStyleSheet(f"color: {self._theme.accent if g_installed else self._theme.ink_muted};")
        l1.addWidget(self._row("gallery-dl", g_lbl, "负责 X、Pixiv、Instagram 等图集帖子。"))
        l1.addWidget(_hline(self._theme))

        ff = locate_ffmpeg()
        ff_lbl = QLabel(str(ff) if ff else "未找到（winget install Gyan.FFmpeg）")
        ff_lbl.setFont(ui_font(8.5, mono=True))
        ff_lbl.setStyleSheet(f"color: {self._theme.ink_muted if ff else self._theme.danger};")
        ff_lbl.setMaximumWidth(230)
        l1.addWidget(self._row("ffmpeg", ff_lbl, "合并 DASH 双轨与提取音频。"))
        pl.addWidget(c1)

        c2, l2 = self._card("支持站点清单")
        links = QWidget()
        ll = QHBoxLayout(links)
        ll.setContentsMargins(14, 10, 14, 10)
        ll.setSpacing(12)
        b1 = TactileButton("yt-dlp 视频站点清单 ↗", variant="subtle", compact=True)
        b1.set_theme(self._theme)
        b1.clicked.connect(lambda: webbrowser.open("https://github.com/yt-dlp/yt-dlp/blob/master/supportedsites.md"))
        b2 = TactileButton("gallery-dl 图集站点清单 ↗", variant="subtle", compact=True)
        b2.set_theme(self._theme)
        b2.clicked.connect(lambda: webbrowser.open("https://github.com/mikf/gallery-dl/blob/master/docs/supportedsites.md"))
        ll.addWidget(b1)
        ll.addWidget(b2)
        ll.addStretch(1)
        l2.addWidget(links)
        pl.addWidget(c2)
        pl.addStretch(1)

        self._refresh_engine_labels()
        return page

    def _refresh_engine_labels(self) -> None:
        ver = self._manager.ytdlp_version_str
        self.yt_ver_label.setText(ver or "未安装")
        self.yt_ver_label.setStyleSheet(f"color: {self._theme.ink if ver else self._theme.ink_muted};")
        self.yt_install_btn.setText("安装中…" if self._manager.is_installing_ytdlp else "安装 / 更新")
        self.yt_install_btn.setEnabled(not self._manager.is_installing_ytdlp)

    def _choose_dir(self) -> None:
        chosen = QFileDialog.getExistingDirectory(self, "选择下载目录", self._draft.save_directory)
        if chosen:
            self.dir_text.setText(chosen)
            self._mutate(save_directory=chosen)

    def _mutate(self, **kwargs) -> None:
        for k, v in kwargs.items():
            setattr(self._draft, k, v)
        self._save_all()

    def _save_all(self) -> None:
        self._draft.cookie_domain = self.domain_edit.text().strip()
        self._draft.cookie_header = self.cookie_edit.toPlainText().strip()
        self._manager.update_settings(AppSettings.from_dict(self._draft.to_dict()))
        self.saved_label.setText("✓  设置已保存")
        self.saved_label.setStyleSheet(f"color: {self._theme.accent}; font-weight: 500;")
        QTimer.singleShot(1600, self._reset_saved_hint)

    def _reset_saved_hint(self) -> None:
        self.saved_label.setText("开关与数值调整会自动即时生效")
        self.saved_label.setStyleSheet(f"color: {self._theme.ink_muted};")
