from __future__ import annotations

import os
import re
import time
import uuid
from dataclasses import dataclass, field, asdict
from enum import Enum
from pathlib import Path
from typing import Any, Dict, List, Optional
from urllib.parse import urlparse


class DownloadState(str, Enum):
    QUEUED = "queued"
    PROBING = "probing"
    DOWNLOADING = "downloading"
    PAUSED = "paused"
    MERGING = "merging"
    COMPLETED = "completed"
    FAILED = "failed"
    CANCELLED = "cancelled"

    @property
    def is_active(self) -> bool:
        return self in (DownloadState.PROBING, DownloadState.DOWNLOADING, DownloadState.MERGING)

    @property
    def is_finished(self) -> bool:
        return self in (DownloadState.COMPLETED, DownloadState.FAILED, DownloadState.CANCELLED)


@dataclass
class FormatOption:
    id: str
    label: str
    ext: str = "mp4"
    height: Optional[int] = None
    filesize: Optional[int] = None
    is_audio_only: bool = False
    note: Optional[str] = None


@dataclass
class MediaPart:
    index: int
    title: str
    duration: Optional[float] = None


@dataclass
class MediaInfo:
    title: str
    engine_id: str
    site: Optional[str] = None
    thumbnail: Optional[str] = None
    duration: Optional[float] = None
    formats: List[FormatOption] = field(default_factory=list)
    selected_format_id: Optional[str] = None
    suggested_ext: str = "mp4"
    parts: List[MediaPart] = field(default_factory=list)
    is_collection: bool = False
    extra: Dict[str, Any] = field(default_factory=dict)


@dataclass
class DownloadOptions:
    format_id: Optional[str] = None
    audio_only: bool = False
    quality: str = "best"
    connections: int = 6
    cookie_header: Optional[str] = None
    cookies_from_browser: Optional[str] = None
    bandwidth_bps: Optional[int] = None


@dataclass
class DownloadTask:
    url: str
    title: str = ""
    id: str = field(default_factory=lambda: str(uuid.uuid4()))
    site: Optional[str] = None
    thumbnail: Optional[str] = None
    state: DownloadState = DownloadState.QUEUED
    progress: float = 0.0
    total_bytes: int = 0
    downloaded_bytes: int = 0
    progress_in_items: bool = False
    speed: float = 0.0
    eta: Optional[float] = None
    error_message: Optional[str] = None
    file_path: Optional[str] = None
    engine_id: str = "auto"
    format_label: Optional[str] = None
    duration: Optional[float] = None
    options: DownloadOptions = field(default_factory=DownloadOptions)
    created_at: float = field(default_factory=time.time)
    finished_at: Optional[float] = None

    def __post_init__(self) -> None:
        if not self.title:
            self.title = self.url
        if isinstance(self.state, str):
            self.state = DownloadState(self.state)
        if isinstance(self.options, dict):
            self.options = DownloadOptions(**self.options)

    def to_dict(self) -> Dict[str, Any]:
        d = asdict(self)
        d["state"] = self.state.value
        return d

    @classmethod
    def from_dict(cls, raw: Dict[str, Any]) -> "DownloadTask":
        valid = {k: v for k, v in raw.items() if k in cls.__dataclass_fields__}
        return cls(**valid)


QUALITY_PRESETS = ["best", "4320", "2160", "1440", "1080", "720", "480", "360"]


def default_download_dir() -> str:
    home = Path.home()
    videos = home / "Videos"
    base = videos if videos.exists() else home / "Downloads"
    return str(base / "OmniFetch")


@dataclass
class AppSettings:
    max_concurrent: int = 3
    connections_per_task: int = 6
    bandwidth_limit_kbps: int = 0
    save_directory: str = field(default_factory=default_download_dir)
    clipboard_watch: bool = False
    notify_on_completion: bool = True
    keep_history: bool = True
    cookies_from_browser: str = ""
    cookie_domain: str = ""
    cookie_header: str = ""
    preferred_quality: str = "best"
    theme_mode: str = "system"  # system | light | dark

    @property
    def bandwidth_bps(self) -> Optional[int]:
        return self.bandwidth_limit_kbps * 1024 if self.bandwidth_limit_kbps > 0 else None

    def manual_cookie_for(self, url: str) -> Optional[str]:
        if not self.cookie_header.strip():
            return None
        domain = self.cookie_domain.strip().lower()
        if not domain:
            names = [p.split("=", 1)[0].strip() for p in self.cookie_header.split(";")]
            if "SESSDATA" in names or "bili_jct" in names:
                domain = "bilibili.com"
            elif "web_session" in names:
                domain = "xiaohongshu.com"
        if not domain or "." not in domain:
            return None
        host = (urlparse(url).hostname or "").lower()
        if host == domain or host.endswith("." + domain):
            return self.cookie_header.strip()
        if domain == "bilibili.com" and (host == "b23.tv" or host.endswith(".b23.tv")):
            return self.cookie_header.strip()
        if domain == "xiaohongshu.com" and (host == "xhslink.com" or host.endswith(".xhslink.com")):
            return self.cookie_header.strip()
        return None

    def to_dict(self) -> Dict[str, Any]:
        return asdict(self)

    @classmethod
    def from_dict(cls, raw: Dict[str, Any]) -> "AppSettings":
        valid = {k: v for k, v in raw.items() if k in cls.__dataclass_fields__}
        return cls(**valid)


class AppPaths:
    @staticmethod
    def data_dir() -> Path:
        if os.name == "nt":
            root = Path(os.environ.get("LOCALAPPDATA", str(Path.home() / "AppData" / "Local")))
        else:
            root = Path.home() / ".local" / "share"
        p = root / "OmniFetch"
        p.mkdir(parents=True, exist_ok=True)
        return p

    @classmethod
    def bin_dir(cls) -> Path:
        p = cls.data_dir() / "bin"
        p.mkdir(parents=True, exist_ok=True)
        return p

    @classmethod
    def cache_dir(cls) -> Path:
        p = cls.data_dir() / "cache" / "thumbnails"
        p.mkdir(parents=True, exist_ok=True)
        return p

    @classmethod
    def tasks_file(cls) -> Path:
        return cls.data_dir() / "tasks.json"

    @classmethod
    def settings_file(cls) -> Path:
        return cls.data_dir() / "settings.json"


# MARK: - Social Platform Matching & Share Link Extraction

PLATFORM_DOMAINS: Dict[str, str] = {
    "bilibili.com": "哔哩哔哩",
    "b23.tv": "哔哩哔哩",
    "xiaohongshu.com": "小红书",
    "xhslink.com": "小红书",
    "weixin.qq.com": "微信视频号",
    "finder.video.qq.com": "微信视频号",
    "x.com": "X / Twitter",
    "twitter.com": "X / Twitter",
    "t.co": "X / Twitter",
    "youtube.com": "YouTube",
    "youtu.be": "YouTube",
    "douyin.com": "抖音",
    "iesdouyin.com": "抖音",
    "weibo.com": "微博",
    "weibo.cn": "微博",
    "kuaishou.com": "快手",
    "zhihu.com": "知乎",
    "tiktok.com": "TikTok",
    "instagram.com": "Instagram",
    "reddit.com": "Reddit",
    "redd.it": "Reddit",
    "bsky.app": "Bluesky",
    "pinterest.com": "Pinterest",
    "pixiv.net": "Pixiv",
    "vimeo.com": "Vimeo",
    "twitch.tv": "Twitch",
    "soundcloud.com": "SoundCloud",
    "nicovideo.jp": "Niconico",
}

DIRECT_MEDIA_EXTS = {
    "mp4", "m4v", "mov", "mkv", "webm", "avi", "flv", "ts",
    "mp3", "m4a", "aac", "flac", "wav", "ogg", "opus",
    "jpg", "jpeg", "png", "webp", "gif", "avif",
}

_URL_RE = re.compile(
    r'(?:https?://[^\s<>"“”‘’【】《》，。！？；、（）]+)'
    r'|(?<![A-Za-z0-9_@./:-])(?:BV[A-Za-z0-9]{10}|(?i:av)[0-9]+)(?:\?p=[0-9]+)?(?![A-Za-z0-9_])'
)


def match_platform(url: str) -> Optional[str]:
    host = (urlparse(url).hostname or "").lower()
    while host:
        if host in PLATFORM_DOMAINS:
            return PLATFORM_DOMAINS[host]
        dot = host.find(".")
        if dot < 0:
            break
        host = host[dot + 1 :]
    return None


def looks_like_media_url(url: str) -> bool:
    if match_platform(url) is not None:
        return True
    path = urlparse(url).path.lower()
    ext = path.rsplit(".", 1)[-1] if "." in path else ""
    return ext in DIRECT_MEDIA_EXTS or ext in ("m3u8", "mpd")


def parse_urls(raw: str) -> List[str]:
    if not raw or not raw.strip():
        return []
    seen = set()
    result: List[str] = []
    for match in _URL_RE.finditer(raw):
        token = match.group(0)
        if "?" not in token and "#" not in token:
            token = token.rstrip(".,;!'`")
        while token.endswith(")") and token.count(")") > token.count("("):
            token = token[:-1]
        low = token.lower()
        if not low.startswith("http://") and not low.startswith("https://"):
            token = "https://www.bilibili.com/video/" + token
        parsed = urlparse(token)
        if parsed.scheme in ("http", "https") and parsed.hostname and token not in seen:
            seen.add(token)
            result.append(token)
    return result


def sanitize_filename(raw: str, max_length: int = 110) -> str:
    cleaned = re.sub(r'[\\/:*?"<>|\r\n\t]+', " ", raw)
    cleaned = re.sub(r"\s+", " ", cleaned).strip(" .")
    if not cleaned:
        cleaned = f"media-{int(time.time())}"
    if len(cleaned) > max_length:
        cleaned = cleaned[:max_length].rstrip(" .")
    return cleaned or "media"


def unique_path(directory: Path, base_name: str, ext: str, allow_resume: bool = False) -> Path:
    directory.mkdir(parents=True, exist_ok=True)
    direct = directory / f"{base_name}.{ext}"
    if allow_resume and (Path(str(direct) + ".omni-resume").exists() or not direct.exists()):
        return direct
    if not direct.exists():
        return direct
    idx = 2
    while True:
        cand = directory / f"{base_name} ({idx}).{ext}"
        if not cand.exists():
            return cand
        idx += 1


# MARK: - Formatters

class Formatters:
    @staticmethod
    def bytes(value: int) -> str:
        val = float(max(0, value))
        for unit in ("B", "KB", "MB", "GB", "TB"):
            if val < 1024.0 or unit == "TB":
                return f"{int(val)} {unit}" if unit == "B" else f"{val:.1f} {unit}"
            val /= 1024.0
        return f"{val:.1f} TB"

    @staticmethod
    def speed(value: float) -> str:
        return Formatters.bytes(int(max(0.0, value))) + "/s"

    @staticmethod
    def eta(seconds: Optional[float]) -> str:
        if seconds is None or seconds <= 0 or seconds != seconds:
            return "--:--"
        total = int(seconds)
        h, rem = divmod(total, 3600)
        m, s = divmod(rem, 60)
        return f"{h}:{m:02d}:{s:02d}" if h > 0 else f"{m:02d}:{s:02d}"

    @staticmethod
    def duration(seconds: Optional[float]) -> str:
        if seconds is None or seconds <= 0:
            return ""
        return Formatters.eta(seconds)

    @staticmethod
    def relative_time(ts: Optional[float]) -> str:
        if not ts:
            return ""
        delta = max(0.0, time.time() - ts)
        if delta < 60:
            return "刚刚"
        if delta < 3600:
            return f"{int(delta // 60)} 分钟前"
        if delta < 86400:
            return f"{int(delta // 3600)} 小时前"
        return time.strftime("%m-%d %H:%M", time.localtime(ts))
