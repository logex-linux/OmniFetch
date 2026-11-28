from __future__ import annotations

import hashlib
import math
import urllib.request
from typing import Dict, List, Optional

from PySide6.QtCore import (
    QBuffer,
    QEasingCurve,
    QObject,
    QPointF,
    QRectF,
    QRunnable,
    QSize,
    Qt,
    QThreadPool,
    QTimer,
    QVariantAnimation,
    Signal,
)
from PySide6.QtGui import (
    QColor,
    QFont,
    QImage,
    QImageReader,
    QPainter,
    QPainterPath,
    QPen,
    QPixmap,
)
from PySide6.QtWidgets import QAbstractButton, QPushButton, QSizePolicy, QWidget

from .models import AppPaths
from .theme import ThemeTokens, ui_font


# MARK: - Vector Brand Mark (1:1 Optical Aperture Collimator)

class OmniMarkWidget(QWidget):
    def __init__(self, size: int = 20, theme: Optional[ThemeTokens] = None, line_scale: float = 1.0, parent=None):
        super().__init__(parent)
        self._size = size
        self._theme = theme
        self._line_scale = line_scale
        self.setFixedSize(size, size)
        self.setAttribute(Qt.WidgetAttribute.WA_TransparentForMouseEvents)

    def set_theme(self, theme: ThemeTokens) -> None:
        self._theme = theme
        self.update()

    def paintEvent(self, event) -> None:
        if self._theme is None:
            return
        p = QPainter(self)
        p.setRenderHint(QPainter.RenderHint.Antialiasing, True)

        s = float(min(self.width(), self.height()))
        cx, cy = self.width() / 2.0, self.height() / 2.0
        radius = s * 0.40
        arc_w = max(1.6, s * 0.112 * self._line_scale)
        arrow_w = max(1.5, s * 0.106 * self._line_scale)

        arc_pen = QPen(QColor(self._theme.accent), arc_w, Qt.PenStyle.SolidLine, Qt.PenCapStyle.RoundCap, Qt.PenJoinStyle.RoundJoin)
        p.setPen(arc_pen)
        rect = QRectF(cx - radius, cy - radius, radius * 2.0, radius * 2.0)
        # Qt drawArc uses 1/16th degrees, 0 = 3 o'clock, positive = CCW
        p.drawArc(rect, int((180 - 52) * 16), int(104 * 16))
        p.drawArc(rect, int((-52) * 16), int(104 * 16))

        arrow_pen = QPen(QColor(self._theme.ink), arrow_w, Qt.PenStyle.SolidLine, Qt.PenCapStyle.RoundCap, Qt.PenJoinStyle.RoundJoin)
        p.setPen(arrow_pen)
        top_y = cy - s * 0.36
        apex_y = cy + s * 0.32
        wing_dx = s * 0.185
        p.drawLine(QPointF(cx, top_y), QPointF(cx, apex_y - s * 0.02))
        p.drawLine(QPointF(cx - wing_dx, apex_y - wing_dx), QPointF(cx, apex_y))
        p.drawLine(QPointF(cx + wing_dx, apex_y - wing_dx), QPointF(cx, apex_y))
        p.end()


# MARK: - Crisp Vector Glyph Drawing (Zero Emoji / Zero Font-Missing Boxes)

def draw_glyph(p: QPainter, name: str, rect: QRectF, color: QColor, stroke: float = 1.6) -> None:
    p.save()
    p.setRenderHint(QPainter.RenderHint.Antialiasing, True)
    pen = QPen(color, stroke, Qt.PenStyle.SolidLine, Qt.PenCapStyle.RoundCap, Qt.PenJoinStyle.RoundJoin)
    p.setPen(pen)
    p.setBrush(Qt.BrushStyle.NoBrush)

    cx, cy = rect.center().x(), rect.center().y()
    w, h = rect.width(), rect.height()
    r = min(w, h) * 0.36

    if name == "pause":
        bw = max(2.2, w * 0.14)
        bh = h * 0.56
        gap = w * 0.12
        p.setPen(Qt.PenStyle.NoPen)
        p.setBrush(color)
        p.drawRoundedRect(QRectF(cx - gap - bw, cy - bh / 2, bw, bh), 1.0, 1.0)
        p.drawRoundedRect(QRectF(cx + gap, cy - bh / 2, bw, bh), 1.0, 1.0)
    elif name == "play":
        p.setPen(Qt.PenStyle.NoPen)
        p.setBrush(color)
        path = QPainterPath()
        dx = w * 0.06
        path.moveTo(cx - r * 0.72 + dx, cy - r * 0.92)
        path.lineTo(cx + r * 0.98 + dx, cy)
        path.lineTo(cx - r * 0.72 + dx, cy + r * 0.92)
        path.closeSubpath()
        p.drawPath(path)
    elif name == "close":
        d = r * 0.82
        p.drawLine(QPointF(cx - d, cy - d), QPointF(cx + d, cy + d))
        p.drawLine(QPointF(cx + d, cy - d), QPointF(cx - d, cy + d))
    elif name == "folder":
        fw, fh = w * 0.72, h * 0.54
        x0, y0 = cx - fw / 2, cy - fh / 2 + 1
        path = QPainterPath()
        path.moveTo(x0, y0 + 2)
        path.lineTo(x0 + fw * 0.36, y0 + 2)
        path.lineTo(x0 + fw * 0.46, y0 - 2.2)
        path.lineTo(x0 + fw, y0 - 2.2)
        path.lineTo(x0 + fw, y0 + fh)
        path.lineTo(x0, y0 + fh)
        path.closeSubpath()
        p.drawPath(path)
    elif name == "retry":
        arc_r = QRectF(cx - r, cy - r, r * 2, r * 2)
        p.drawArc(arc_r, 45 * 16, 285 * 16)
        ax, ay = cx + r * 0.72, cy - r * 0.72
        p.drawLine(QPointF(ax, ay), QPointF(ax + 0.5, ay - 3.6))
        p.drawLine(QPointF(ax, ay), QPointF(ax - 3.6, ay - 0.5))
    elif name == "trash":
        tw, th = w * 0.56, h * 0.62
        x0, y0 = cx - tw / 2, cy - th / 2 + 1
        p.drawLine(QPointF(x0 - 2, y0), QPointF(x0 + tw + 2, y0))
        p.drawLine(QPointF(cx - tw * 0.22, y0 - 2.5), QPointF(cx + tw * 0.22, y0 - 2.5))
        p.drawRoundedRect(QRectF(x0 + 1, y0, tw - 2, th), 1.5, 1.5)
    elif name == "open":
        box = QRectF(cx - r, cy - r * 0.6, r * 1.6, r * 1.6)
        p.drawRoundedRect(box, 2.0, 2.0)
        p.drawLine(QPointF(cx, cy), QPointF(cx + r, cy - r))
        p.drawLine(QPointF(cx + r * 0.35, cy - r), QPointF(cx + r, cy - r))
        p.drawLine(QPointF(cx + r, cy - r * 0.35), QPointF(cx + r, cy - r))
    elif name == "search":
        cr = r * 0.78
        c = QPointF(cx - r * 0.16, cy - r * 0.16)
        p.drawEllipse(c, cr, cr)
        p.drawLine(QPointF(c.x() + cr * 0.72, c.y() + cr * 0.72), QPointF(cx + r, cy + r))
    elif name == "sliders":
        for dy, knob in ((-r * 0.65, -r * 0.25), (0.0, r * 0.35), (r * 0.65, -r * 0.1)):
            p.drawLine(QPointF(cx - r, cy + dy), QPointF(cx + r, cy + dy))
            p.setBrush(color)
            p.drawEllipse(QPointF(cx + knob, cy + dy), 1.8, 1.8)
            p.setBrush(Qt.BrushStyle.NoBrush)
    elif name == "clipboard":
        bw, bh = w * 0.56, h * 0.66
        p.drawRoundedRect(QRectF(cx - bw / 2, cy - bh / 2 + 1.5, bw, bh - 1.5), 2.0, 2.0)
        p.drawRoundedRect(QRectF(cx - bw * 0.28, cy - bh / 2 - 0.5, bw * 0.56, 3.2), 1.2, 1.2)
    elif name == "link":
        p.drawRoundedRect(QRectF(cx - r * 1.05, cy - r * 0.42, r * 1.15, r * 0.84), r * 0.42, r * 0.42)
        p.drawRoundedRect(QRectF(cx - r * 0.10, cy - r * 0.42, r * 1.15, r * 0.84), r * 0.42, r * 0.42)
    elif name == "check":
        p.drawEllipse(QPointF(cx, cy), r, r)
        p.drawLine(QPointF(cx - r * 0.42, cy + r * 0.04), QPointF(cx - r * 0.10, cy + r * 0.38))
        p.drawLine(QPointF(cx - r * 0.10, cy + r * 0.38), QPointF(cx + r * 0.48, cy - r * 0.32))
    elif name == "alert":
        path = QPainterPath()
        path.moveTo(cx, cy - r)
        path.lineTo(cx + r, cy + r * 0.85)
        path.lineTo(cx - r, cy + r * 0.85)
        path.closeSubpath()
        p.drawPath(path)
        p.drawLine(QPointF(cx, cy - r * 0.32), QPointF(cx, cy + r * 0.25))
        p.drawPoint(QPointF(cx, cy + r * 0.55))
    elif name == "stack":
        for dy in (-r * 0.48, 0.0, r * 0.48):
            p.drawLine(QPointF(cx - r * 0.9, cy + dy), QPointF(cx + r * 0.9, cy + dy))
    elif name == "download":
        p.drawEllipse(QPointF(cx, cy), r, r)
        p.drawLine(QPointF(cx, cy - r * 0.45), QPointF(cx, cy + r * 0.42))
        p.drawLine(QPointF(cx - r * 0.36, cy + r * 0.08), QPointF(cx, cy + r * 0.45))
        p.drawLine(QPointF(cx + r * 0.36, cy + r * 0.08), QPointF(cx, cy + r * 0.45))
    elif name == "gear":
        p.drawEllipse(QPointF(cx, cy), r * 0.45, r * 0.45)
        for i in range(8):
            ang = i * math.pi / 4.0
            p.drawLine(
                QPointF(cx + math.cos(ang) * r * 0.68, cy + math.sin(ang) * r * 0.68),
                QPointF(cx + math.cos(ang) * r * 1.0, cy + math.sin(ang) * r * 1.0),
            )
    elif name == "film":
        p.drawRoundedRect(QRectF(cx - r * 1.15, cy - r * 0.8, r * 2.3, r * 1.6), 2.5, 2.5)
        p.drawLine(QPointF(cx - r * 0.55, cy - r * 0.8), QPointF(cx - r * 0.55, cy + r * 0.8))
        p.drawLine(QPointF(cx + r * 0.55, cy - r * 0.8), QPointF(cx + r * 0.55, cy + r * 0.8))
    elif name == "gallery":
        p.drawRoundedRect(QRectF(cx - r * 1.05, cy - r * 0.78, r * 2.1, r * 1.56), 2.5, 2.5)
        p.drawLine(QPointF(cx - r * 0.85, cy + r * 0.52), QPointF(cx - r * 0.2, cy - r * 0.1))
        p.drawLine(QPointF(cx - r * 0.2, cy - r * 0.1), QPointF(cx + r * 0.3, cy + r * 0.32))
        p.drawLine(QPointF(cx + r * 0.3, cy + r * 0.32), QPointF(cx + r * 0.75, cy - r * 0.22))
    elif name == "audio":
        for dx, hh in ((-r * 0.6, 0.45), (-r * 0.2, 0.9), (r * 0.2, 0.65), (r * 0.6, 0.35)):
            p.drawLine(QPointF(cx + dx, cy - r * hh), QPointF(cx + dx, cy + r * hh))
    p.restore()


# MARK: - Tactile Buttons (Zero-Latency Press Feedback)

class TactileButton(QPushButton):
    def __init__(self, text: str, variant: str = "secondary", compact: bool = False, parent=None):
        super().__init__(text, parent)
        self._variant = variant
        self._compact = compact
        self._theme: Optional[ThemeTokens] = None
        self.setCursor(Qt.CursorShape.PointingHandCursor)
        self.setFixedHeight(28 if compact else 32)
        self.setSizePolicy(QSizePolicy.Policy.Fixed, QSizePolicy.Policy.Fixed)

    def set_theme(self, theme: ThemeTokens) -> None:
        self._theme = theme
        pad = "0 11px" if self._compact else "0 14px"
        radius = "6px" if self._compact else "8px"
        fsize = "12px" if self._compact else "13px"
        if self._variant == "primary":
            self.setStyleSheet(
                f"QPushButton {{ background: {theme.accent}; color: {theme.accent_ink}; border: none; "
                f"border-radius: {radius}; padding: {pad}; font-size: {fsize}; font-weight: 600; }}"
                f"QPushButton:hover {{ background: {theme.accent}; opacity: 0.92; }}"
                f"QPushButton:pressed {{ padding-top: 1px; }}"
                f"QPushButton:disabled {{ opacity: 0.42; }}"
            )
        elif self._variant == "subtle":
            self.setStyleSheet(
                f"QPushButton {{ background: transparent; color: {theme.ink}; border: none; "
                f"border-radius: {radius}; padding: {pad}; font-size: {fsize}; font-weight: 500; }}"
                f"QPushButton:hover {{ background: {theme.hover_fill}; }}"
                f"QPushButton:disabled {{ opacity: 0.42; }}"
            )
        else:
            self.setStyleSheet(
                f"QPushButton {{ background: {theme.surface}; color: {theme.ink}; border: 1px solid {theme.line}; "
                f"border-radius: {radius}; padding: {pad}; font-size: {fsize}; font-weight: 500; }}"
                f"QPushButton:hover {{ background: {theme.hover_fill}; border-color: {theme.line_strong}; }}"
                f"QPushButton:disabled {{ opacity: 0.42; }}"
            )


class TactileIconButton(QAbstractButton):
    def __init__(self, glyph: str, tooltip: str, size: int = 28, tone: str = "ink", parent=None):
        super().__init__(parent)
        self._glyph = glyph
        self._tone = tone  # ink | muted | accent | danger
        self._theme: Optional[ThemeTokens] = None
        self._hovered = False
        self.setFixedSize(size, size)
        self.setToolTip(tooltip)
        self.setCursor(Qt.CursorShape.PointingHandCursor)

    def set_glyph(self, glyph: str, tooltip: str, tone: str = "ink") -> None:
        if self._glyph == glyph and self._tone == tone and self.toolTip() == tooltip:
            return
        self._glyph = glyph
        self._tone = tone
        self.setToolTip(tooltip)
        self.update()

    def set_theme(self, theme: ThemeTokens) -> None:
        self._theme = theme
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
        if not self.isEnabled():
            p.setOpacity(0.36)
        elif self.isDown():
            p.translate(self.width() / 2.0, self.height() / 2.0)
            p.scale(0.93, 0.93)
            p.translate(-self.width() / 2.0, -self.height() / 2.0)

        rect = QRectF(0.5, 0.5, self.width() - 1.0, self.height() - 1.0)
        if self._hovered or self.isDown():
            bg = QColor(self._theme.ink)
            bg.setAlphaF(0.08 if self.isDown() else 0.05)
            border = QColor(self._theme.ink)
            border.setAlphaF(0.12)
            p.setBrush(bg)
            p.setPen(QPen(border, 1.0))
            p.drawRoundedRect(rect, 7.0, 7.0)

        if self._tone == "accent":
            fg = QColor(self._theme.accent)
        elif self._tone == "muted":
            fg = QColor(self._theme.ink_muted)
        elif self._tone == "danger":
            fg = QColor(self._theme.danger)
        else:
            fg = QColor(self._theme.ink)

        icon_rect = QRectF(self.width() * 0.22, self.height() * 0.22, self.width() * 0.56, self.height() * 0.56)
        draw_glyph(p, self._glyph, icon_rect, fg, stroke=1.65)
        p.end()


# MARK: - Smooth Pill Switch (Windows Settings)

class SwitchToggle(QAbstractButton):
    def __init__(self, checked: bool = False, parent=None):
        super().__init__(parent)
        self.setCheckable(True)
        self.setChecked(checked)
        self.setFixedSize(36, 20)
        self.setCursor(Qt.CursorShape.PointingHandCursor)
        self._theme: Optional[ThemeTokens] = None
        self._pos: float = 1.0 if checked else 0.0
        self._anim = QVariantAnimation(self)
        self._anim.setDuration(140)
        self._anim.setEasingCurve(QEasingCurve.Type.OutCubic)
        self._anim.valueChanged.connect(self._on_anim)
        self.toggled.connect(self._start_anim)

    def set_theme(self, theme: ThemeTokens) -> None:
        self._theme = theme
        self.update()

    def _start_anim(self, checked: bool) -> None:
        self._anim.stop()
        self._anim.setStartValue(self._pos)
        self._anim.setEndValue(1.0 if checked else 0.0)
        self._anim.start()

    def _on_anim(self, val) -> None:
        self._pos = float(val)
        self.update()

    def paintEvent(self, event) -> None:
        if self._theme is None:
            return
        p = QPainter(self)
        p.setRenderHint(QPainter.RenderHint.Antialiasing, True)
        r = QRectF(0.5, 0.5, self.width() - 1.0, self.height() - 1.0)
        off_c = QColor(self._theme.ink)
        off_c.setAlphaF(0.18)
        on_c = QColor(self._theme.accent)
        t = self._pos
        track = QColor(
            int(off_c.red() + (on_c.red() - off_c.red()) * t),
            int(off_c.green() + (on_c.green() - off_c.green()) * t),
            int(off_c.blue() + (on_c.blue() - off_c.blue()) * t),
            int(off_c.alpha() + (on_c.alpha() - off_c.alpha()) * t),
        )
        p.setPen(Qt.PenStyle.NoPen)
        p.setBrush(track)
        p.drawRoundedRect(r, 10.0, 10.0)

        knob_d = 14.0
        kx = 3.0 + (self.width() - knob_d - 6.0) * t
        knob_c = QColor(self._theme.accent_ink if self.isChecked() else self._theme.canvas)
        p.setBrush(knob_c)
        p.drawEllipse(QRectF(kx, 3.0, knob_d, knob_d))
        p.end()


# MARK: - GPU-Smooth Custom Painted Throughput Track (Zero CPU When Idle)

class ThroughputTrack(QWidget):
    def __init__(self, parent=None):
        super().__init__(parent)
        self.setFixedHeight(4)
        self._theme: Optional[ThemeTokens] = None
        self._display_progress: float = 0.0
        self._target_progress: float = 0.0
        self._indeterminate: bool = False
        self._paused: bool = False
        self._phase: float = 0.0

        self._anim = QVariantAnimation(self)
        self._anim.setDuration(150)
        self._anim.setEasingCurve(QEasingCurve.Type.OutCubic)
        self._anim.valueChanged.connect(self._on_anim)

        self._sweep_timer = QTimer(self)
        self._sweep_timer.setInterval(16)
        self._sweep_timer.timeout.connect(self._tick_sweep)

    def set_theme(self, theme: ThemeTokens) -> None:
        self._theme = theme
        self.update()

    def set_state(self, progress: float, indeterminate: bool, paused: bool) -> None:
        clamped = max(0.0, min(1.0, float(progress)))
        self._paused = paused
        if indeterminate != self._indeterminate:
            self._indeterminate = indeterminate
            if indeterminate:
                self._sweep_timer.start()
            else:
                self._sweep_timer.stop()
            self.update()

        if abs(clamped - self._target_progress) > 0.002:
            self._target_progress = clamped
            if not indeterminate:
                self._anim.stop()
                self._anim.setStartValue(self._display_progress)
                self._anim.setEndValue(clamped)
                self._anim.start()
        else:
            self.update()

    def _on_anim(self, val) -> None:
        self._display_progress = float(val)
        self.update()

    def _tick_sweep(self) -> None:
        self._phase = (self._phase + 0.016 / 1.25) % 1.0
        self.update()

    def paintEvent(self, event) -> None:
        if self._theme is None:
            return
        p = QPainter(self)
        p.setRenderHint(QPainter.RenderHint.Antialiasing, True)
        w, h = float(self.width()), float(self.height())
        rad = h / 2.0

        rail = QColor(self._theme.ink)
        rail.setAlphaF(0.11)
        p.setPen(Qt.PenStyle.NoPen)
        p.setBrush(rail)
        p.drawRoundedRect(QRectF(0, 0, w, h), rad, rad)

        if self._indeterminate:
            bar_w = max(36.0, w * 0.28)
            x = -bar_w + self._phase * (w + bar_w)
            clip = QPainterPath()
            clip.addRoundedRect(QRectF(0, 0, w, h), rad, rad)
            p.setClipPath(clip)
            p.setBrush(QColor(self._theme.accent))
            p.drawRoundedRect(QRectF(x, 0, bar_w, h), rad, rad)
        else:
            fill_w = max(h, w * max(0.015, self._display_progress))
            if self._paused:
                fill_c = QColor(self._theme.ink_muted)
                fill_c.setAlphaF(0.55)
            else:
                fill_c = QColor(self._theme.accent)
            p.setBrush(fill_c)
            p.drawRoundedRect(QRectF(0, 0, fill_w, h), rad, rad)
        p.end()


# MARK: - Live Throughput Sparkline

class ThroughputSparkline(QWidget):
    def __init__(self, parent=None):
        super().__init__(parent)
        self.setFixedSize(70, 16)
        self._theme: Optional[ThemeTokens] = None
        self._samples: List[float] = [0.0] * 28

    def set_theme(self, theme: ThemeTokens) -> None:
        self._theme = theme
        self.update()

    def set_samples(self, samples: List[float]) -> None:
        self._samples = samples
        self.update()

    def paintEvent(self, event) -> None:
        if self._theme is None or len(self._samples) < 2:
            return
        peak = max(max(self._samples), 1024.0)
        p = QPainter(self)
        p.setRenderHint(QPainter.RenderHint.Antialiasing, True)
        w, h = float(self.width()), float(self.height())
        step = w / float(len(self._samples) - 1)

        line = QPainterPath()
        for i, val in enumerate(self._samples):
            x = i * step
            y = h - 1.0 - max(0.0, min(1.0, val / peak)) * (h - 2.0)
            if i == 0:
                line.moveTo(x, y)
            else:
                line.lineTo(x, y)

        area = QPainterPath(line)
        area.lineTo(w, h)
        area.lineTo(0, h)
        area.closeSubpath()

        fill = QColor(self._theme.accent)
        fill.setAlphaF(0.14)
        p.fillPath(area, fill)
        p.setPen(QPen(QColor(self._theme.accent), 1.4, Qt.PenStyle.SolidLine, Qt.PenCapStyle.RoundCap, Qt.PenJoinStyle.RoundJoin))
        p.drawPath(line)
        p.end()


# MARK: - Background ImageIO-Style Scaled Thumbnail Cache

class _ThumbSignals(QObject):
    loaded = Signal(str, QImage)


class _ThumbFetchJob(QRunnable):
    def __init__(self, url: str, target_size: QSize, signals: _ThumbSignals):
        super().__init__()
        self.url = url
        self.target_size = target_size
        self.signals = signals

    def run(self) -> None:
        key = hashlib.sha256(self.url.encode("utf-8")).hexdigest()[:24]
        disk_path = AppPaths.cache_dir() / f"{key}.img"
        data = b""
        if disk_path.exists():
            try:
                data = disk_path.read_bytes()
            except Exception:
                data = b""
        if not data:
            try:
                req = urllib.request.Request(self.url, headers={"User-Agent": "Mozilla/5.0"})
                with urllib.request.urlopen(req, timeout=10) as resp:
                    data = resp.read()
                if data:
                    disk_path.write_bytes(data)
            except Exception:
                return
        if not data:
            return
        buf = QBuffer()
        buf.setData(data)
        buf.open(QBuffer.OpenModeFlag.ReadOnly)
        reader = QImageReader(buf)
        reader.setAutoTransform(True)
        orig = reader.size()
        if orig.isValid() and (orig.width() > self.target_size.width() or orig.height() > self.target_size.height()):
            scaled = orig.scaled(self.target_size, Qt.AspectRatioMode.KeepAspectRatioByExpanding)
            reader.setScaledSize(scaled)
        img = reader.read()
        if not img.isNull():
            self.signals.loaded.emit(self.url, img)


class ThumbnailCache(QObject):
    image_ready = Signal(str)

    def __init__(self) -> None:
        super().__init__()
        self._mem: Dict[str, QPixmap] = {}
        self._inflight: set[str] = set()
        self._signals = _ThumbSignals()
        self._signals.loaded.connect(self._on_loaded)

    def get(self, url: Optional[str]) -> Optional[QPixmap]:
        if not url:
            return None
        return self._mem.get(url)

    def request(self, url: Optional[str], width: int = 240, height: int = 135) -> None:
        if not url or url in self._mem or url in self._inflight:
            return
        self._inflight.add(url)
        QThreadPool.globalInstance().start(_ThumbFetchJob(url, QSize(width, height), self._signals))

    def _on_loaded(self, url: str, img: QImage) -> None:
        self._inflight.discard(url)
        if len(self._mem) > 240:
            self._mem.pop(next(iter(self._mem)))
        self._mem[url] = QPixmap.fromImage(img)
        self.image_ready.emit(url)


THUMB_CACHE = ThumbnailCache()


class ThumbnailWidget(QWidget):
    def __init__(self, width: int = 96, height: int = 54, radius: float = 6.0, parent=None):
        super().__init__(parent)
        self.setFixedSize(width, height)
        self._radius = radius
        self._theme: Optional[ThemeTokens] = None
        self._url: Optional[str] = None
        self._duration: str = ""
        self._kind: str = "film"  # film | gallery | audio
        THUMB_CACHE.image_ready.connect(self._on_cache_ready)

    def set_theme(self, theme: ThemeTokens) -> None:
        self._theme = theme
        self.update()

    def configure(self, url: Optional[str], duration: str = "", is_collection: bool = False, is_audio: bool = False) -> None:
        new_kind = "audio" if is_audio else ("gallery" if is_collection else "film")
        changed = (url != self._url) or (duration != self._duration) or (new_kind != self._kind)
        self._url = url
        self._duration = duration
        self._kind = new_kind
        if url:
            THUMB_CACHE.request(url, self.width() * 2, self.height() * 2)
        if changed:
            self.update()

    def _on_cache_ready(self, url: str) -> None:
        if url == self._url:
            self.update()

    def paintEvent(self, event) -> None:
        if self._theme is None:
            return
        p = QPainter(self)
        p.setRenderHint(QPainter.RenderHint.Antialiasing, True)
        p.setRenderHint(QPainter.RenderHint.SmoothPixmapTransform, True)

        rect = QRectF(0.5, 0.5, self.width() - 1.0, self.height() - 1.0)
        clip = QPainterPath()
        clip.addRoundedRect(rect, self._radius, self._radius)
        p.setClipPath(clip)

        p.fillRect(rect, QColor(self._theme.surface))

        pix = THUMB_CACHE.get(self._url)
        if pix and not pix.isNull():
            scaled = pix.scaled(self.size() * self.devicePixelRatioF(), Qt.AspectRatioMode.KeepAspectRatioByExpanding, Qt.TransformationMode.SmoothTransformation)
            scaled.setDevicePixelRatio(self.devicePixelRatioF())
            sx = (scaled.width() / self.devicePixelRatioF() - self.width()) / 2.0
            sy = (scaled.height() / self.devicePixelRatioF() - self.height()) / 2.0
            p.drawPixmap(QPointF(-sx, -sy), scaled)
        else:
            fg = QColor(self._theme.ink_muted)
            fg.setAlphaF(0.65)
            ir = QRectF(self.width() * 0.34, self.height() * 0.28, self.width() * 0.32, self.height() * 0.44)
            draw_glyph(p, self._kind, ir, fg, stroke=1.5)

        if self._duration:
            f = ui_font(7.8, QFont.Weight.Medium, mono=True)
            p.setFont(f)
            fm = p.fontMetrics()
            tw = fm.horizontalAdvance(self._duration)
            th = fm.height()
            bw, bh = tw + 10, th + 2
            br = QRectF(self.width() - bw - 4, self.height() - bh - 4, bw, bh)
            p.setPen(Qt.PenStyle.NoPen)
            p.setBrush(QColor(18, 23, 27, 214))
            p.drawRoundedRect(br, 4.0, 4.0)
            p.setPen(QColor(242, 247, 250))
            p.drawText(br, Qt.AlignmentFlag.AlignCenter, self._duration)

        p.setClipping(False)
        border = QColor(self._theme.ink)
        border.setAlphaF(0.11)
        p.setPen(QPen(border, 1.0))
        p.setBrush(Qt.BrushStyle.NoBrush)
        p.drawRoundedRect(rect, self._radius, self._radius)
        p.end()
