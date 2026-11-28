from __future__ import annotations

import ctypes
import os
from dataclasses import dataclass

from PySide6.QtCore import Qt
from PySide6.QtGui import QColor, QFont
from PySide6.QtWidgets import QApplication, QWidget


@dataclass(frozen=True)
class ThemeTokens:
    """SSOT synced 1:1 with .design/visual-dna.json (strictly <= 6 distinct colors)."""

    is_dark: bool
    canvas: str
    surface: str
    ink: str
    ink_muted: str
    accent: str
    accent_ink: str
    danger: str
    line: str
    line_strong: str
    hover_fill: str
    active_fill: str
    accent_line: str
    danger_fill: str
    track_rail: str


LIGHT_THEME = ThemeTokens(
    is_dark=False,
    canvas="#F6F8F9",
    surface="#EBF0F2",
    ink="#162026",
    ink_muted="#4F606A",
    accent="#0B6E77",
    accent_ink="#F6F8F9",
    danger="#B93827",
    line="rgba(22, 32, 38, 0.11)",
    line_strong="rgba(22, 32, 38, 0.20)",
    hover_fill="rgba(22, 32, 38, 0.048)",
    active_fill="rgba(11, 110, 119, 0.10)",
    accent_line="rgba(11, 110, 119, 0.36)",
    danger_fill="rgba(185, 56, 39, 0.10)",
    track_rail="rgba(22, 32, 38, 0.10)",
)

DARK_THEME = ThemeTokens(
    is_dark=True,
    canvas="#12171A",
    surface="#1B2227",
    ink="#E8EEF2",
    ink_muted="#8E9FA9",
    accent="#3BBCC7",
    accent_ink="#12171A",
    danger="#EE7262",
    line="rgba(232, 238, 242, 0.10)",
    line_strong="rgba(232, 238, 242, 0.19)",
    hover_fill="rgba(232, 238, 242, 0.055)",
    active_fill="rgba(59, 188, 199, 0.13)",
    accent_line="rgba(59, 188, 199, 0.38)",
    danger_fill="rgba(238, 114, 98, 0.14)",
    track_rail="rgba(232, 238, 242, 0.11)",
)


def detect_system_dark() -> bool:
    app = QApplication.instance()
    if app is not None:
        try:
            scheme = app.styleHints().colorScheme()
            if scheme == Qt.ColorScheme.Dark:
                return True
            if scheme == Qt.ColorScheme.Light:
                return False
        except Exception:
            pass
    if os.name == "nt":
        try:
            import winreg

            with winreg.OpenKey(
                winreg.HKEY_CURRENT_USER,
                r"Software\Microsoft\Windows\CurrentVersion\Themes\Personalize",
            ) as key:
                val, _ = winreg.QueryValueEx(key, "AppsUseLightTheme")
                return int(val) == 0
        except Exception:
            pass
    return False


def resolve_theme(mode: str) -> ThemeTokens:
    if mode == "dark":
        return DARK_THEME
    if mode == "light":
        return LIGHT_THEME
    return DARK_THEME if detect_system_dark() else LIGHT_THEME


def apply_windows_titlebar_theme(widget: QWidget, theme: ThemeTokens) -> None:
    """Syncs native Windows 11 titlebar dark/light caption with OmniFetch Visual DNA."""
    if os.name != "nt":
        return
    try:
        hwnd = int(widget.winId())
        dwmapi = ctypes.windll.dwmapi
        use_dark = ctypes.c_int(1 if theme.is_dark else 0)
        # DWMWA_USE_IMMERSIVE_DARK_MODE (20 on Win10 2004+ / Win11)
        dwmapi.DwmSetWindowAttribute(hwnd, 20, ctypes.byref(use_dark), ctypes.sizeof(use_dark))
        # DWMWA_CAPTION_COLOR (35 on Win11): COLORREF is 0x00BBGGRR
        c = QColor(theme.surface)
        colorref = ctypes.c_int((c.blue() << 16) | (c.green() << 8) | c.red())
        dwmapi.DwmSetWindowAttribute(hwnd, 35, ctypes.byref(colorref), ctypes.sizeof(colorref))
    except Exception:
        pass


def ui_font(size_pt: float = 10.0, weight: QFont.Weight = QFont.Weight.Normal, mono: bool = False) -> QFont:
    f = QFont()
    if mono:
        f.setFamilies(["Cascadia Mono", "Consolas", "Menlo", "monospace"])
    else:
        f.setFamilies(["Segoe UI Variable Text", "Segoe UI", "Microsoft YaHei UI", "PingFang SC", "sans-serif"])
    f.setPointSizeF(size_pt)
    f.setWeight(weight)
    return f


def build_stylesheet(t: ThemeTokens) -> str:
    return f"""
    QWidget {{
        color: {t.ink};
        font-family: "Segoe UI Variable Text", "Segoe UI", "Microsoft YaHei UI", sans-serif;
        font-size: 13px;
    }}
    QMainWindow, QDialog {{
        background-color: {t.canvas};
    }}
    QScrollArea {{
        background: transparent;
        border: none;
    }}
    QScrollBar:vertical {{
        background: transparent;
        width: 8px;
        margin: 4px 2px 4px 0px;
    }}
    QScrollBar::handle:vertical {{
        background: {t.line_strong};
        border-radius: 4px;
        min-height: 28px;
    }}
    QScrollBar::handle:vertical:hover {{
        background: {t.ink_muted};
    }}
    QScrollBar::add-line:vertical, QScrollBar::sub-line:vertical,
    QScrollBar::add-page:vertical, QScrollBar::sub-page:vertical {{
        background: none;
        height: 0px;
    }}
    QLineEdit, QPlainTextEdit {{
        background-color: {t.canvas};
        color: {t.ink};
        border: 1px solid {t.line};
        border-radius: 7px;
        padding: 5px 10px;
        selection-background-color: {t.accent};
        selection-color: {t.accent_ink};
    }}
    QLineEdit:focus, QPlainTextEdit:focus {{
        border: 1.5px solid {t.accent};
    }}
    QComboBox, QSpinBox {{
        background-color: {t.canvas};
        color: {t.ink};
        border: 1px solid {t.line};
        border-radius: 7px;
        padding: 4px 10px;
        min-height: 22px;
    }}
    QComboBox:hover, QSpinBox:hover {{
        border: 1px solid {t.line_strong};
    }}
    QComboBox:focus, QSpinBox:focus {{
        border: 1.5px solid {t.accent};
    }}
    QComboBox::drop-down {{
        border: none;
        width: 22px;
    }}
    QComboBox QAbstractItemView {{
        background-color: {t.surface};
        color: {t.ink};
        border: 1px solid {t.line_strong};
        border-radius: 7px;
        selection-background-color: {t.active_fill};
        selection-color: {t.ink};
        outline: 0;
        padding: 4px;
    }}
    QCheckBox {{
        spacing: 8px;
        color: {t.ink};
    }}
    QCheckBox::indicator {{
        width: 16px;
        height: 16px;
        border-radius: 4px;
        border: 1px solid {t.line_strong};
        background-color: {t.canvas};
    }}
    QCheckBox::indicator:checked {{
        background-color: {t.accent};
        border-color: {t.accent};
    }}
    QMenu {{
        background-color: {t.surface};
        color: {t.ink};
        border: 1px solid {t.line_strong};
        border-radius: 8px;
        padding: 4px;
    }}
    QMenu::item {{
        padding: 6px 24px 6px 12px;
        border-radius: 5px;
    }}
    QMenu::item:selected {{
        background-color: {t.hover_fill};
    }}
    QMenu::separator {{
        height: 1px;
        background: {t.line};
        margin: 4px 8px;
    }}
    QToolTip {{
        background-color: {t.surface};
        color: {t.ink};
        border: 1px solid {t.line_strong};
        border-radius: 6px;
        padding: 4px 8px;
        font-size: 11.5px;
    }}
    """
