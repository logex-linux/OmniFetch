from __future__ import annotations

import os
import sys
from pathlib import Path

from PySide6.QtCore import Qt
from PySide6.QtGui import QIcon
from PySide6.QtWidgets import QApplication

from .manager import DownloadManager
from .main_window import MainWindow


def _resource_path(relative: str) -> Path:
    base = Path(getattr(sys, "_MEIPASS", Path(__file__).resolve().parent.parent))
    return base / relative


def main() -> int:
    # Ensure crisp Windows Per-Monitor High-DPI rendering
    if os.name == "nt":
        try:
            import ctypes

            ctypes.windll.shell32.SetCurrentProcessExplicitAppUserModelID("com.omnifetch.app")
        except Exception:
            pass

    QApplication.setHighDpiScaleFactorRoundingPolicy(
        Qt.HighDpiScaleFactorRoundingPolicy.PassThrough
    )
    app = QApplication(sys.argv)
    app.setApplicationName("OmniFetch")
    app.setOrganizationName("OmniFetch")

    icon_path = _resource_path("assets/OmniFetch.ico")
    app_icon = QIcon(str(icon_path)) if icon_path.exists() else None
    if app_icon:
        app.setWindowIcon(app_icon)

    manager = DownloadManager()
    window = MainWindow(manager, app_icon=app_icon)
    window.show()
    return app.exec()


if __name__ == "__main__":
    raise SystemExit(main())
