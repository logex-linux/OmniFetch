from __future__ import annotations

import json
import os
import subprocess
import threading
import time
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from typing import Dict, List, Optional, Tuple
from urllib.parse import urlparse

from PySide6.QtCore import QObject, QTimer, Signal

from .engines import (
    CancelledError,
    ENGINES,
    GLOBAL_RATE_LIMITER,
    install_ytdlp,
    ytdlp_version,
)
from .models import (
    AppPaths,
    AppSettings,
    DownloadOptions,
    DownloadState,
    DownloadTask,
    MediaInfo,
    match_platform,
    parse_urls,
)


class DownloadManager(QObject):
    tasks_changed = Signal()
    task_updated = Signal(str)
    settings_changed = Signal()
    ytdlp_changed = Signal()
    notification_requested = Signal(str, str, str)  # title, body, file_path

    def __init__(self, parent: Optional[QObject] = None) -> None:
        super().__init__(parent)
        self.settings: AppSettings = self._load_settings()
        GLOBAL_RATE_LIMITER.configure(self.settings.bandwidth_bps)
        self.tasks: List[DownloadTask] = self._load_tasks()
        self.ytdlp_version_str: Optional[str] = None
        self.is_installing_ytdlp: bool = False

        self._cancel_flags: Dict[str, threading.Event] = {}
        self._active_ids: set[str] = set()
        self._info_cache: Dict[str, MediaInfo] = {}
        self._samples: Dict[str, Tuple[int, float, float]] = {}  # id -> (bytes, mono_t, ema_speed)
        self._pending_progress: Dict[str, Tuple[int, int]] = {}
        self._progress_lock = threading.Lock()
        self._pool = ThreadPoolExecutor(max_workers=12, thread_name_prefix="omnifetch-worker")

        # 10 Hz progress coalescer on GUI thread (0% layout churn, zero callback storm)
        self._flush_timer = QTimer(self)
        self._flush_timer.setInterval(100)
        self._flush_timer.timeout.connect(self._flush_progress)
        self._flush_timer.start()

        # Restore previously active tasks as paused
        if not self.settings.keep_history:
            self.tasks = [t for t in self.tasks if not t.state.is_finished]
        for t in self.tasks:
            if t.state.is_active:
                t.state = DownloadState.PAUSED
                t.speed = 0.0

        self.refresh_ytdlp()
        self._pump()

    # MARK: - Queries

    @property
    def active_count(self) -> int:
        return sum(1 for t in self.tasks if t.state.is_active)

    @property
    def paused_count(self) -> int:
        return sum(1 for t in self.tasks if t.state == DownloadState.PAUSED)

    @property
    def clearable_count(self) -> int:
        return sum(1 for t in self.tasks if t.state in (DownloadState.COMPLETED, DownloadState.CANCELLED))

    @property
    def total_speed(self) -> float:
        return sum(t.speed for t in self.tasks if t.state == DownloadState.DOWNLOADING and not t.progress_in_items)

    def get_task(self, task_id: str) -> Optional[DownloadTask]:
        for t in self.tasks:
            if t.id == task_id:
                return t
        return None

    # MARK: - Probe & Enqueue

    def probe_async(self, raw_url: str, options: DownloadOptions, callback) -> None:
        urls = parse_urls(raw_url)
        if not urls:
            callback(None, "链接格式不正确")
            return
        url = urls[0]
        opts = self._resolved_options(options, url)

        def run() -> None:
            try:
                eng = ENGINES.engine_for(url)
                info = eng.probe(url, opts)
                callback(info, None)
            except Exception as e:
                callback(None, str(e))

        self._pool.submit(run)

    def add_url(
        self,
        raw_url: str,
        options: Optional[DownloadOptions] = None,
        info: Optional[MediaInfo] = None,
    ) -> Optional[str]:
        urls = parse_urls(raw_url)
        if not urls:
            return None
        url = urls[0]
        opts = self._resolved_options(options, url)
        task = DownloadTask(
            url=url,
            title=info.title if info else (urlparse(url).hostname or url),
            site=info.site if info else match_platform(url),
            thumbnail=info.thumbnail if info else None,
            duration=info.duration if info else None,
            engine_id=info.engine_id if info else ENGINES.engine_for(url).id,
            options=opts,
        )
        if info:
            self._info_cache[task.id] = info
        self._enqueue([task])
        return task.id

    def add_urls(self, urls: List[str], options: Optional[DownloadOptions] = None) -> int:
        additions: List[DownloadTask] = []
        for url in urls:
            opts = self._resolved_options(options, url)
            additions.append(
                DownloadTask(
                    url=url,
                    title=urlparse(url).hostname or url,
                    site=match_platform(url),
                    engine_id=ENGINES.engine_for(url).id,
                    options=opts,
                )
            )
        if additions:
            self._enqueue(additions)
        return len(additions)

    def _resolved_options(self, options: Optional[DownloadOptions], url: str) -> DownloadOptions:
        opts = DownloadOptions(
            format_id=options.format_id if options else None,
            audio_only=options.audio_only if options else False,
            quality=options.quality if options else self.settings.preferred_quality,
            connections=(options.connections if options and options.connections > 0 else self.settings.connections_per_task),
            cookie_header=(options.cookie_header if options and options.cookie_header else self.settings.manual_cookie_for(url)),
            cookies_from_browser=(
                options.cookies_from_browser
                if options and options.cookies_from_browser
                else (self.settings.cookies_from_browser or None)
            ),
            bandwidth_bps=options.bandwidth_bps if options and options.bandwidth_bps else self.settings.bandwidth_bps,
        )
        return opts

    def _enqueue(self, additions: List[DownloadTask]) -> None:
        for task in reversed(additions):
            self.tasks.insert(0, task)
        self._trim_history()
        self.persist()
        self.tasks_changed.emit()
        self._pump()

    def _trim_history(self, limit: int = 1000) -> None:
        if len(self.tasks) <= limit:
            return
        finished = [t.id for t in self.tasks if t.state.is_finished]
        drop = set(finished[-(len(self.tasks) - limit) :])
        if drop:
            self.tasks = [t for t in self.tasks if t.id not in drop]

    # MARK: - Task Control

    def pause(self, task_id: str) -> None:
        task = self.get_task(task_id)
        if not task:
            return
        if task_id in self._cancel_flags:
            self._cancel_flags[task_id].set()
        self._samples.pop(task_id, None)
        task.state = DownloadState.PAUSED
        task.speed = 0.0
        self.persist()
        self.task_updated.emit(task_id)
        self._pump()

    def resume(self, task_id: str) -> None:
        task = self.get_task(task_id)
        if not task or task.state not in (DownloadState.PAUSED, DownloadState.FAILED, DownloadState.CANCELLED):
            return
        task.state = DownloadState.QUEUED
        task.error_message = None
        self.persist()
        self.task_updated.emit(task_id)
        self._pump()

    def retry(self, task_id: str) -> None:
        task = self.get_task(task_id)
        if not task:
            return
        task.state = DownloadState.QUEUED
        task.progress = 0.0
        task.downloaded_bytes = 0
        task.speed = 0.0
        task.eta = None
        task.error_message = None
        self._info_cache.pop(task_id, None)
        self._samples.pop(task_id, None)
        self.persist()
        self.task_updated.emit(task_id)
        self._pump()

    def cancel(self, task_id: str) -> None:
        task = self.get_task(task_id)
        if not task:
            return
        if task_id in self._cancel_flags:
            self._cancel_flags[task_id].set()
        self._samples.pop(task_id, None)
        task.state = DownloadState.CANCELLED
        task.speed = 0.0
        self.persist()
        self.task_updated.emit(task_id)
        self._pump()

    def remove(self, task_id: str, delete_file: bool = False) -> None:
        task = self.get_task(task_id)
        if task_id in self._cancel_flags:
            self._cancel_flags[task_id].set()
        if task and delete_file and task.file_path:
            Path(task.file_path).unlink(missing_ok=True)
            Path(task.file_path + ".omni-resume").unlink(missing_ok=True)
        self.tasks = [t for t in self.tasks if t.id != task_id]
        self._samples.pop(task_id, None)
        self._info_cache.pop(task_id, None)
        self.persist()
        self.tasks_changed.emit()
        self._pump()

    def clear_completed(self) -> None:
        self.tasks = [t for t in self.tasks if t.state not in (DownloadState.COMPLETED, DownloadState.CANCELLED)]
        self.persist()
        self.tasks_changed.emit()

    def pause_all(self) -> None:
        changed = False
        for t in self.tasks:
            if t.state.is_active or t.state == DownloadState.QUEUED:
                if t.id in self._cancel_flags:
                    self._cancel_flags[t.id].set()
                self._samples.pop(t.id, None)
                t.state = DownloadState.PAUSED
                t.speed = 0.0
                changed = True
        if changed:
            self.persist()
            self.tasks_changed.emit()

    def resume_all(self) -> None:
        changed = False
        for t in self.tasks:
            if t.state == DownloadState.PAUSED:
                t.state = DownloadState.QUEUED
                t.error_message = None
                changed = True
        if changed:
            self.persist()
            self.tasks_changed.emit()
            self._pump()

    # MARK: - OS Integration (Windows Explorer / Default Open)

    def reveal_file(self, task_id: str) -> None:
        task = self.get_task(task_id)
        if not task or not task.file_path:
            return
        path = Path(task.file_path)
        if not path.exists():
            self.open_download_folder()
            return
        if os.name == "nt":
            subprocess.Popen(["explorer", "/select,", str(path)])
        else:
            subprocess.Popen(["open", "-R", str(path)])

    def open_file(self, task_id: str) -> None:
        task = self.get_task(task_id)
        if not task or not task.file_path or not Path(task.file_path).exists():
            return
        if os.name == "nt":
            os.startfile(task.file_path)  # type: ignore[attr-defined]
        else:
            subprocess.Popen(["open", task.file_path])

    def open_download_folder(self) -> None:
        folder = Path(self.settings.save_directory)
        folder.mkdir(parents=True, exist_ok=True)
        if os.name == "nt":
            os.startfile(str(folder))  # type: ignore[attr-defined]
        else:
            subprocess.Popen(["open", str(folder)])

    # MARK: - Settings & Tools

    def update_settings(self, new_settings: AppSettings) -> None:
        self.settings = new_settings
        GLOBAL_RATE_LIMITER.configure(new_settings.bandwidth_bps)
        self._save_settings()
        Path(new_settings.save_directory).mkdir(parents=True, exist_ok=True)
        if not new_settings.keep_history:
            self.tasks = [t for t in self.tasks if not t.state.is_finished]
            self.persist()
            self.tasks_changed.emit()
        self.settings_changed.emit()
        self._pump()

    def refresh_ytdlp(self) -> None:
        def run() -> None:
            ver = ytdlp_version()
            self.ytdlp_version_str = ver
            self.ytdlp_changed.emit()

        self._pool.submit(run)

    def install_ytdlp_async(self) -> None:
        if self.is_installing_ytdlp:
            return
        self.is_installing_ytdlp = True
        self.ytdlp_changed.emit()

        def run() -> None:
            try:
                binary = install_ytdlp()
                self.ytdlp_version_str = ytdlp_version(binary) or "已安装"
            except Exception as e:
                self.ytdlp_version_str = f"安装失败：{e}"
            finally:
                self.is_installing_ytdlp = False
                self.ytdlp_changed.emit()

        self._pool.submit(run)

    # MARK: - Scheduler

    def _pump(self) -> None:
        limit = max(1, self.settings.max_concurrent)
        if len(self._active_ids) >= limit:
            return
        for task in self.tasks:
            if task.state == DownloadState.QUEUED and task.id not in self._active_ids:
                self._launch(task)
                if len(self._active_ids) >= limit:
                    break

    def _launch(self, task: DownloadTask) -> None:
        tid = task.id
        cancel = threading.Event()
        self._cancel_flags[tid] = cancel
        self._active_ids.add(tid)

        def worker() -> None:
            try:
                routed = ENGINES.engine_for(task.url)
                info = self._info_cache.get(tid)
                if info is None:
                    self._set_task_state_threadsafe(tid, DownloadState.PROBING)
                    info = routed.probe(task.url, task.options)
                if cancel.is_set():
                    raise CancelledError()

                engine = ENGINES.engine_by_id(info.engine_id)
                fmt_label = None
                if info.formats:
                    fid = task.options.format_id or info.selected_format_id
                    for f in info.formats:
                        if f.id == fid:
                            fmt_label = f.label
                            break
                if task.options.audio_only:
                    fmt_label = "仅音频"

                self._apply_info_threadsafe(tid, info, fmt_label)

                def on_prog(dl: int, tot: int) -> None:
                    with self._progress_lock:
                        self._pending_progress[tid] = (dl, tot)

                def on_state(st: str) -> None:
                    if st == "merging":
                        self._set_task_state_threadsafe(tid, DownloadState.MERGING)

                dest_dir = Path(self.settings.save_directory)
                output = engine.download(task.url, info, task.options, dest_dir, cancel, on_prog, on_state)
                if cancel.is_set():
                    raise CancelledError()

                size = output.stat().st_size if output.is_file() else 0
                self._finish_success_threadsafe(tid, str(output), size)
            except CancelledError:
                self._finish_cancelled_threadsafe(tid)
            except Exception as e:
                self._finish_error_threadsafe(tid, str(e))
            finally:
                self._active_ids.discard(tid)
                self._cancel_flags.pop(tid, None)
                QTimer.singleShot(0, self._pump)

        self._pool.submit(worker)

    def _set_task_state_threadsafe(self, tid: str, state: DownloadState) -> None:
        def apply() -> None:
            t = self.get_task(tid)
            if t and not t.state.is_finished and t.state != DownloadState.PAUSED:
                t.state = state
                self.task_updated.emit(tid)

        QTimer.singleShot(0, apply)

    def _apply_info_threadsafe(self, tid: str, info: MediaInfo, fmt_label: Optional[str]) -> None:
        def apply() -> None:
            t = self.get_task(tid)
            if not t:
                return
            t.title = info.title
            t.site = info.site or t.site
            t.thumbnail = info.thumbnail or t.thumbnail
            t.duration = info.duration or t.duration
            t.engine_id = info.engine_id
            t.progress_in_items = info.is_collection
            t.format_label = fmt_label or t.format_label
            t.state = DownloadState.DOWNLOADING
            self.task_updated.emit(tid)

        QTimer.singleShot(0, apply)

    def _finish_success_threadsafe(self, tid: str, path: str, size: int) -> None:
        def apply() -> None:
            t = self.get_task(tid)
            if not t:
                return
            t.file_path = path
            t.state = DownloadState.COMPLETED
            t.progress = 1.0
            t.speed = 0.0
            t.eta = 0.0
            t.finished_at = time.time()
            if size > 0:
                t.total_bytes = size
                t.downloaded_bytes = size
            self._samples.pop(tid, None)
            self._info_cache.pop(tid, None)
            self.persist()
            self.task_updated.emit(tid)
            if self.settings.notify_on_completion:
                self.notification_requested.emit("下载完成", t.title, path)

        QTimer.singleShot(0, apply)

    def _finish_cancelled_threadsafe(self, tid: str) -> None:
        def apply() -> None:
            t = self.get_task(tid)
            if t and t.state.is_active:
                t.state = DownloadState.PAUSED
                t.speed = 0.0
                self.persist()
                self.task_updated.emit(tid)

        QTimer.singleShot(0, apply)

    def _finish_error_threadsafe(self, tid: str, error: str) -> None:
        def apply() -> None:
            t = self.get_task(tid)
            if not t:
                return
            t.state = DownloadState.FAILED
            t.error_message = error
            t.speed = 0.0
            t.finished_at = time.time()
            self._samples.pop(tid, None)
            self.persist()
            self.task_updated.emit(tid)

        QTimer.singleShot(0, apply)

    def _flush_progress(self) -> None:
        with self._progress_lock:
            if not self._pending_progress:
                return
            batch = dict(self._pending_progress)
            self._pending_progress.clear()

        now = time.monotonic()
        for tid, (downloaded, total) in batch.items():
            t = self.get_task(tid)
            if not t or t.state != DownloadState.DOWNLOADING:
                continue
            t.downloaded_bytes = downloaded
            if total > 0:
                t.total_bytes = total
                t.progress = min(1.0, downloaded / total)

            prev = self._samples.get(tid)
            if prev:
                prev_bytes, prev_t, prev_speed = prev
                dt = now - prev_t
                if dt >= 0.35:
                    instant = max(0.0, (downloaded - prev_bytes) / dt)
                    smoothed = instant if prev_speed == 0.0 else (prev_speed * 0.7 + instant * 0.3)
                    t.speed = smoothed
                    self._samples[tid] = (downloaded, now, smoothed)
                    t.eta = (max(0, total - downloaded) / smoothed) if (smoothed > 1.0 and total > 0) else None
            else:
                self._samples[tid] = (downloaded, now, 0.0)
            self.task_updated.emit(tid)

    # MARK: - Persistence

    def _load_settings(self) -> AppSettings:
        path = AppPaths.settings_file()
        if path.exists():
            try:
                return AppSettings.from_dict(json.loads(path.read_text(encoding="utf-8")))
            except Exception:
                pass
        return AppSettings()

    def _save_settings(self) -> None:
        try:
            AppPaths.settings_file().write_text(
                json.dumps(self.settings.to_dict(), ensure_ascii=False, indent=2),
                encoding="utf-8",
            )
        except Exception:
            pass

    def _load_tasks(self) -> List[DownloadTask]:
        path = AppPaths.tasks_file()
        if path.exists():
            try:
                raw = json.loads(path.read_text(encoding="utf-8"))
                return [DownloadTask.from_dict(item) for item in raw]
            except Exception:
                pass
        return []

    def persist(self) -> None:
        try:
            data = [t.to_dict() for t in self.tasks]
            tmp = AppPaths.tasks_file().with_suffix(".tmp")
            tmp.write_text(json.dumps(data, ensure_ascii=False, indent=2), encoding="utf-8")
            os.replace(tmp, AppPaths.tasks_file())
        except Exception:
            pass

    def shutdown(self) -> None:
        for ev in list(self._cancel_flags.values()):
            ev.set()
        self.persist()
        self._pool.shutdown(wait=False, cancel_futures=True)
