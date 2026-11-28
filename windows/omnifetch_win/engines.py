from __future__ import annotations

import json
import os
import re
import shutil
import subprocess
import threading
import time
import urllib.error
import urllib.request
from concurrent.futures import ThreadPoolExecutor, as_completed
from pathlib import Path
from typing import Callable, Dict, List, Optional, Tuple
from urllib.parse import urlparse

from .models import (
    AppPaths,
    DIRECT_MEDIA_EXTS,
    DownloadOptions,
    FormatOption,
    MediaInfo,
    MediaPart,
    match_platform,
    sanitize_filename,
    unique_path,
)

DESKTOP_UA = (
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) "
    "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"
)

CREATE_NO_WINDOW = 0x08000000 if os.name == "nt" else 0

ProgressCallback = Callable[[int, int], None]


class CancelledError(Exception):
    pass


# MARK: - Global Token Bucket Rate Limiter

class TokenBucket:
    def __init__(self) -> None:
        self._lock = threading.Lock()
        self._rate: Optional[int] = None
        self._tokens: float = 0.0
        self._last = time.monotonic()

    def configure(self, bps: Optional[int]) -> None:
        with self._lock:
            self._rate = bps if bps and bps > 0 else None
            self._last = time.monotonic()
            self._tokens = float(self._rate) * 0.25 if self._rate else 0.0

    def consume(self, nbytes: int, cancel: threading.Event) -> None:
        while not cancel.is_set():
            with self._lock:
                rate = self._rate
                if not rate:
                    return
                now = time.monotonic()
                dt = max(0.0, now - self._last)
                self._last = now
                burst = rate * 0.25
                self._tokens = min(burst, self._tokens + dt * rate)
                if self._tokens >= nbytes:
                    self._tokens -= nbytes
                    return
                deficit = nbytes - self._tokens
                wait = min(0.25, deficit / rate)
            cancel.wait(wait)
        raise CancelledError()


GLOBAL_RATE_LIMITER = TokenBucket()


# MARK: - Binary Locators (yt-dlp / gallery-dl / ffmpeg)

def locate_ytdlp() -> Optional[Path]:
    exe = "yt-dlp.exe" if os.name == "nt" else "yt-dlp"
    local = AppPaths.bin_dir() / exe
    if local.exists():
        return local
    found = shutil.which("yt-dlp")
    return Path(found) if found else None


def locate_ffmpeg() -> Optional[Path]:
    exe = "ffmpeg.exe" if os.name == "nt" else "ffmpeg"
    local = AppPaths.bin_dir() / exe
    if local.exists():
        return local
    found = shutil.which("ffmpeg")
    return Path(found) if found else None


def locate_gallery_dl() -> Optional[Path]:
    exe = "gallery-dl.exe" if os.name == "nt" else "gallery-dl"
    local = AppPaths.bin_dir() / exe
    if local.exists():
        return local
    found = shutil.which("gallery-dl")
    return Path(found) if found else None


def ytdlp_version(binary: Optional[Path] = None) -> Optional[str]:
    path = binary or locate_ytdlp()
    if not path:
        return None
    try:
        out = subprocess.check_output(
            [str(path), "--version"],
            stdin=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            creationflags=CREATE_NO_WINDOW,
            timeout=6,
            text=True,
        )
        return out.strip()
    except Exception:
        return None


def install_ytdlp() -> Path:
    url = (
        "https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp.exe"
        if os.name == "nt"
        else "https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp"
    )
    exe = "yt-dlp.exe" if os.name == "nt" else "yt-dlp"
    target = AppPaths.bin_dir() / exe
    tmp = target.with_suffix(".tmp")
    req = urllib.request.Request(url, headers={"User-Agent": DESKTOP_UA})
    with urllib.request.urlopen(req, timeout=60) as resp, open(tmp, "wb") as f:
        shutil.copyfileobj(resp, f, length=256 * 1024)
    os.replace(tmp, target)
    if os.name != "nt":
        os.chmod(target, 0o755)
    return target


# MARK: - Parallel HTTP Range Downloader with .omni-resume Sidecar

def _http_head(url: str, headers: Dict[str, str]) -> Tuple[str, int, bool, str]:
    req = urllib.request.Request(url, headers=headers, method="HEAD")
    try:
        with urllib.request.urlopen(req, timeout=20) as resp:
            final_url = resp.geturl()
            length = int(resp.headers.get("Content-Length") or 0)
            accept_ranges = "bytes" in (resp.headers.get("Accept-Ranges") or "").lower()
            etag = resp.headers.get("ETag") or ""
            return final_url, length, accept_ranges, etag
    except Exception:
        return url, 0, False, ""


def fetch_file_parallel(
    url: str,
    dest: Path,
    headers: Dict[str, str],
    connections: int,
    cancel: threading.Event,
    on_progress: ProgressCallback,
) -> Path:
    req_headers = {"User-Agent": DESKTOP_UA, **headers}
    final_url, total, accept_ranges, etag = _http_head(url, req_headers)
    if cancel.is_set():
        raise CancelledError()

    # Adaptive concurrency for small files
    conns = max(1, min(16, connections))
    if total < 8 * 1024 * 1024 or not accept_ranges:
        conns = 1
    elif total < 32 * 1024 * 1024:
        conns = min(conns, 4)

    if conns == 1 or total <= 0:
        return _fetch_single_stream(final_url, dest, req_headers, total, cancel, on_progress)

    sidecar = Path(str(dest) + ".omni-resume")
    part_path = Path(str(dest) + ".part")
    chunk_size = (total + conns - 1) // conns
    ranges: List[List[int]] = []
    for i in range(conns):
        start = i * chunk_size
        end = min(total - 1, start + chunk_size - 1)
        if start <= end:
            ranges.append([start, start, end])  # [origin, cursor, end]

    # Resume existing valid sidecar
    if sidecar.exists() and part_path.exists() and part_path.stat().st_size == total:
        try:
            saved = json.loads(sidecar.read_text(encoding="utf-8"))
            if saved.get("total") == total and saved.get("etag", "") == etag and saved.get("ranges"):
                ranges = saved["ranges"]
        except Exception:
            pass

    if not part_path.exists() or part_path.stat().st_size != total:
        with open(part_path, "wb") as f:
            f.truncate(total)

    lock = threading.Lock()
    downloaded = sum(max(0, r[1] - r[0]) for r in ranges)
    on_progress(downloaded, total)
    last_save = time.monotonic()

    def save_sidecar(force: bool = False) -> None:
        nonlocal last_save
        now = time.monotonic()
        if not force and now - last_save < 2.0:
            return
        last_save = now
        try:
            sidecar.write_text(
                json.dumps({"total": total, "etag": etag, "ranges": ranges}),
                encoding="utf-8",
            )
        except Exception:
            pass

    def worker(idx: int) -> None:
        nonlocal downloaded
        origin, cursor, end = ranges[idx]
        if cursor > end:
            return
        for attempt in range(5):
            if cancel.is_set():
                raise CancelledError()
            h = {**req_headers, "Range": f"bytes={cursor}-{end}"}
            req = urllib.request.Request(final_url, headers=h)
            try:
                with urllib.request.urlopen(req, timeout=25) as resp:
                    if resp.status == 200 and cursor == origin:
                        # Server ignored Range header; fall back cleanly
                        raise RuntimeError("RANGE_UNSUPPORTED")
                    with open(part_path, "r+b") as fh:
                        fh.seek(cursor)
                        while cursor <= end:
                            if cancel.is_set():
                                raise CancelledError()
                            chunk = resp.read(min(256 * 1024, end - cursor + 1))
                            if not chunk:
                                break
                            GLOBAL_RATE_LIMITER.consume(len(chunk), cancel)
                            fh.write(chunk)
                            cursor += len(chunk)
                            with lock:
                                ranges[idx][1] = cursor
                                downloaded += len(chunk)
                                on_progress(downloaded, total)
                                save_sidecar()
                    if cursor > end:
                        return
            except CancelledError:
                save_sidecar(force=True)
                raise
            except RuntimeError as e:
                if str(e) == "RANGE_UNSUPPORTED":
                    raise
                if attempt == 4:
                    raise
                cancel.wait(0.4 * (2 ** attempt))
            except Exception:
                save_sidecar(force=True)
                if attempt == 4:
                    raise
                cancel.wait(0.4 * (2 ** attempt))
        if cursor <= end:
            raise IOError("分片下载未完整结束")

    try:
        with ThreadPoolExecutor(max_workers=len(ranges)) as pool:
            futs = [pool.submit(worker, i) for i in range(len(ranges))]
            for fut in as_completed(futs):
                fut.result()
    except RuntimeError as e:
        if str(e) == "RANGE_UNSUPPORTED":
            return _fetch_single_stream(final_url, dest, req_headers, total, cancel, on_progress)
        save_sidecar(force=True)
        raise
    except Exception:
        save_sidecar(force=True)
        raise

    os.replace(part_path, dest)
    if sidecar.exists():
        sidecar.unlink(missing_ok=True)
    on_progress(total, total)
    return dest


def _fetch_single_stream(
    url: str,
    dest: Path,
    headers: Dict[str, str],
    expected_total: int,
    cancel: threading.Event,
    on_progress: ProgressCallback,
) -> Path:
    part_path = Path(str(dest) + ".part")
    req = urllib.request.Request(url, headers=headers)
    downloaded = 0
    with urllib.request.urlopen(req, timeout=30) as resp, open(part_path, "wb") as fh:
        total = int(resp.headers.get("Content-Length") or expected_total or 0)
        while True:
            if cancel.is_set():
                raise CancelledError()
            chunk = resp.read(256 * 1024)
            if not chunk:
                break
            GLOBAL_RATE_LIMITER.consume(len(chunk), cancel)
            fh.write(chunk)
            downloaded += len(chunk)
            on_progress(downloaded, total)
    if expected_total > 0 and downloaded < expected_total:
        raise IOError(f"下载不完整（收到 {downloaded} / {expected_total} 字节）")
    os.replace(part_path, dest)
    on_progress(downloaded, downloaded)
    return dest


# MARK: - Bilibili Native Engine (API + DASH + ffmpeg merge)

_BILI_BV_RE = re.compile(r"(BV[A-Za-z0-9]{10})")
_BILI_QN_LABELS = {
    127: "8K 超高清",
    126: "杜比视界",
    120: "4K 超清",
    116: "1080P 60帧",
    112: "1080P+ 高码率",
    80: "1080P 高清",
    64: "720P 高清",
    32: "480P 清晰",
    16: "360P 流畅",
}
_BILI_QN_HEIGHTS = {127: 4320, 126: 2160, 120: 2160, 116: 1080, 112: 1080, 80: 1080, 64: 720, 32: 480, 16: 360}


class BilibiliEngine:
    id = "bilibili"
    display_name = "哔哩哔哩"

    def can_handle(self, url: str) -> bool:
        host = (urlparse(url).hostname or "").lower()
        return host.endswith("bilibili.com") or host == "b23.tv"

    def _headers(self, options: DownloadOptions) -> Dict[str, str]:
        h = {"User-Agent": DESKTOP_UA, "Referer": "https://www.bilibili.com/"}
        if options.cookie_header:
            h["Cookie"] = options.cookie_header
        return h

    def _resolve_bvid(self, url: str, headers: Dict[str, str]) -> Tuple[str, int, str]:
        target = url
        if "b23.tv" in (urlparse(url).hostname or "").lower():
            req = urllib.request.Request(url, headers=headers)
            with urllib.request.urlopen(req, timeout=15) as resp:
                target = resp.geturl()
        m = _BILI_BV_RE.search(target)
        if not m:
            raise ValueError("未能从链接提取 B 站 BV 号")
        bvid = m.group(1)
        pm = re.search(r"[?&]p=(\d+)", target)
        page = int(pm.group(1)) if pm else 1
        return bvid, page, f"https://www.bilibili.com/video/{bvid}"

    def probe(self, url: str, options: DownloadOptions) -> MediaInfo:
        headers = self._headers(options)
        bvid, page, webpage = self._resolve_bvid(url, headers)
        view_url = f"https://api.bilibili.com/x/web-interface/view?bvid={bvid}"
        req = urllib.request.Request(view_url, headers=headers)
        with urllib.request.urlopen(req, timeout=15) as resp:
            payload = json.loads(resp.read().decode("utf-8"))
        if payload.get("code") != 0:
            raise RuntimeError(payload.get("message") or "B 站接口返回错误")

        data = payload["data"]
        pages = data.get("pages") or []
        chosen = pages[page - 1] if 1 <= page <= len(pages) else (pages[0] if pages else {})
        cid = chosen.get("cid") or data.get("cid")
        title = data.get("title") or bvid
        if len(pages) > 1 and chosen.get("part"):
            title = f"{title} - P{page} {chosen['part']}"
        parts = [
            MediaPart(index=p.get("page", i + 1), title=p.get("part", f"P{i+1}"), duration=p.get("duration"))
            for i, p in enumerate(pages)
        ] if len(pages) > 1 else []

        play_url = (
            f"https://api.bilibili.com/x/player/playurl?bvid={bvid}&cid={cid}"
            f"&fnval=4048&fourk=1&qn=120"
        )
        req2 = urllib.request.Request(play_url, headers=headers)
        with urllib.request.urlopen(req2, timeout=15) as resp2:
            play_data = json.loads(resp2.read().decode("utf-8")).get("data") or {}

        dash = play_data.get("dash") or {}
        videos = dash.get("video") or []
        audios = dash.get("audio") or []
        formats: List[FormatOption] = []
        seen_qn = set()
        for v in sorted(videos, key=lambda x: (x.get("id", 0), 1 if "avc" in (x.get("codecs") or "") else 0), reverse=True):
            qn = int(v.get("id", 0))
            if qn in seen_qn:
                continue
            seen_qn.add(qn)
            codec = (v.get("codecs") or "").split(".")[0].upper()
            formats.append(
                FormatOption(
                    id=str(qn),
                    label=_BILI_QN_LABELS.get(qn, f"{v.get('height', qn)}P"),
                    ext="mp4",
                    height=_BILI_QN_HEIGHTS.get(qn, v.get("height")),
                    note=f"{codec} · DASH" if codec else "DASH",
                )
            )

        selected = formats[0].id if formats else None
        return MediaInfo(
            title=title,
            engine_id=self.id,
            site="哔哩哔哩",
            thumbnail=data.get("pic"),
            duration=float(chosen.get("duration") or data.get("duration") or 0),
            formats=formats,
            selected_format_id=selected,
            parts=parts,
            extra={
                "bvid": bvid,
                "cid": cid,
                "webpage": webpage,
                "dash": dash,
                "durl": play_data.get("durl") or [],
            },
        )

    def download(
        self,
        url: str,
        info: MediaInfo,
        options: DownloadOptions,
        dest_dir: Path,
        cancel: threading.Event,
        on_progress: ProgressCallback,
        on_state: Callable[[str], None],
    ) -> Path:
        headers = self._headers(options)
        dash = info.extra.get("dash") or {}
        videos = dash.get("video") or []
        audios = dash.get("audio") or []
        base = sanitize_filename(info.title)
        ffmpeg = locate_ffmpeg()

        if options.audio_only and audios:
            best_audio = max(audios, key=lambda a: a.get("bandwidth", 0))
            dest = unique_path(dest_dir, base, "m4a", allow_resume=True)
            return fetch_file_parallel(best_audio["baseUrl"], dest, headers, 2, cancel, on_progress)

        if videos and audios and ffmpeg:
            target_id = int(options.format_id) if options.format_id and options.format_id.isdigit() else None
            candidates = [v for v in videos if v.get("id") == target_id] if target_id else videos
            if not candidates:
                candidates = videos
            # Prefer AVC1 for universal Windows Media Player / Explorer compatibility
            best_v = max(candidates, key=lambda v: (v.get("id", 0), 1 if "avc" in (v.get("codecs") or "") else 0, v.get("bandwidth", 0)))
            best_a = max(audios, key=lambda a: a.get("bandwidth", 0))

            v_tmp = dest_dir / f".{base}.video.m4s"
            a_tmp = dest_dir / f".{base}.audio.m4s"
            out = unique_path(dest_dir, base, "mp4")
            merge_tmp = dest_dir / f".{base}.merge.mp4"

            v_done, v_tot, a_done, a_tot = 0, 0, 0, 0

            def report_v(d: int, t: int) -> None:
                nonlocal v_done, v_tot
                v_done, v_tot = d, t
                on_progress(v_done + a_done, v_tot + a_tot)

            def report_a(d: int, t: int) -> None:
                nonlocal a_done, a_tot
                a_done, a_tot = d, t
                on_progress(v_done + a_done, v_tot + a_tot)

            fetch_file_parallel(best_v["baseUrl"], v_tmp, headers, options.connections, cancel, report_v)
            fetch_file_parallel(best_a["baseUrl"], a_tmp, headers, 1, cancel, report_a)

            on_state("merging")
            proc = subprocess.Popen(
                [str(ffmpeg), "-y", "-nostdin", "-i", str(v_tmp), "-i", str(a_tmp), "-c", "copy", str(merge_tmp)],
                stdin=subprocess.DEVNULL,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                creationflags=CREATE_NO_WINDOW,
            )
            while proc.poll() is None:
                if cancel.is_set():
                    proc.terminate()
                    raise CancelledError()
                time.sleep(0.1)
            if proc.returncode != 0:
                raise RuntimeError("ffmpeg 合并音视频失败")
            os.replace(merge_tmp, out)
            v_tmp.unlink(missing_ok=True)
            a_tmp.unlink(missing_ok=True)
            return out

        # Fallback to yt-dlp when ffmpeg missing or non-DASH
        return YTDLPEngine().download(url, info, options, dest_dir, cancel, on_progress, on_state)


# MARK: - Direct Media Engine

class DirectMediaEngine:
    id = "direct"
    display_name = "直链引擎"

    def can_handle(self, url: str) -> bool:
        path = urlparse(url).path.lower()
        ext = path.rsplit(".", 1)[-1] if "." in path else ""
        return ext in DIRECT_MEDIA_EXTS

    def probe(self, url: str, options: DownloadOptions) -> MediaInfo:
        parsed = urlparse(url)
        name = Path(parsed.path).stem or parsed.hostname or "media"
        ext = (Path(parsed.path).suffix.lstrip(".") or "mp4").lower()
        return MediaInfo(
            title=name,
            engine_id=self.id,
            site=parsed.hostname,
            suggested_ext=ext,
            formats=[FormatOption(id="direct", label=ext.upper(), ext=ext)],
            selected_format_id="direct",
        )

    def download(
        self,
        url: str,
        info: MediaInfo,
        options: DownloadOptions,
        dest_dir: Path,
        cancel: threading.Event,
        on_progress: ProgressCallback,
        on_state: Callable[[str], None],
    ) -> Path:
        headers = {"Cookie": options.cookie_header} if options.cookie_header else {}
        dest = unique_path(dest_dir, sanitize_filename(info.title), info.suggested_ext, allow_resume=True)
        return fetch_file_parallel(url, dest, headers, options.connections, cancel, on_progress)


# MARK: - yt-dlp Universal Engine (Auto-installs yt-dlp.exe on Windows)

class YTDLPEngine:
    id = "ytdlp"
    display_name = "yt-dlp"

    def can_handle(self, url: str) -> bool:
        return True

    def _ensure_binary(self) -> Path:
        binary = locate_ytdlp()
        if binary:
            return binary
        return install_ytdlp()

    def _common_args(self, options: DownloadOptions) -> List[str]:
        args: List[str] = ["--no-warnings", "--retries", "8", "--fragment-retries", "8"]
        if options.cookies_from_browser:
            args += ["--cookies-from-browser", options.cookies_from_browser]
        if options.cookie_header:
            args += ["--add-header", f"Cookie:{options.cookie_header}"]
        ffmpeg = locate_ffmpeg()
        if ffmpeg:
            args += ["--ffmpeg-location", str(ffmpeg.parent)]
        return args

    def probe(self, url: str, options: DownloadOptions) -> MediaInfo:
        binary = self._ensure_binary()
        cmd = [str(binary), "-J", "--no-playlist", *self._common_args(options), url]
        proc = subprocess.run(
            cmd,
            stdin=subprocess.DEVNULL,
            capture_output=True,
            text=True,
            creationflags=CREATE_NO_WINDOW,
            timeout=45,
        )
        if proc.returncode != 0:
            err = (proc.stderr or proc.stdout or "yt-dlp 解析失败").strip().splitlines()[-1]
            raise RuntimeError(err)

        data = json.loads(proc.stdout)
        formats: List[FormatOption] = []
        seen = set()
        for f in reversed(data.get("formats") or []):
            h = f.get("height")
            vcodec = f.get("vcodec") or "none"
            if not h or vcodec == "none":
                continue
            label = f"{h}P"
            if label in seen:
                continue
            seen.add(label)
            formats.append(
                FormatOption(
                    id=str(f.get("format_id")),
                    label=label,
                    ext=f.get("ext") or "mp4",
                    height=int(h),
                    filesize=f.get("filesize") or f.get("filesize_approx"),
                    note=f.get("ext", "").upper(),
                )
            )
        formats.sort(key=lambda x: x.height or 0, reverse=True)
        return MediaInfo(
            title=data.get("title") or url,
            engine_id=self.id,
            site=match_platform(url) or data.get("extractor_key") or urlparse(url).hostname,
            thumbnail=data.get("thumbnail"),
            duration=float(data.get("duration") or 0) or None,
            formats=formats,
            selected_format_id=None,
            is_collection=data.get("_type") == "playlist",
        )

    def download(
        self,
        url: str,
        info: MediaInfo,
        options: DownloadOptions,
        dest_dir: Path,
        cancel: threading.Event,
        on_progress: ProgressCallback,
        on_state: Callable[[str], None],
    ) -> Path:
        binary = self._ensure_binary()
        dest_dir.mkdir(parents=True, exist_ok=True)
        base = sanitize_filename(info.title)
        template = str(dest_dir / f"{base}.%(ext)s")

        cmd = [
            str(binary),
            "--newline",
            "--no-playlist",
            "--concurrent-fragments", str(max(1, min(8, options.connections))),
            "--progress-template", "download:OMNI|%(progress.downloaded_bytes)s|%(progress.total_bytes)s|%(progress.total_bytes_estimate)s",
            "--print", "after_move:OMNI_OUT|%(filepath)s",
            "-o", template,
            *self._common_args(options),
        ]

        if options.bandwidth_bps:
            cmd += ["--limit-rate", str(options.bandwidth_bps)]

        if options.audio_only:
            cmd += ["-x", "--audio-format", "m4a"]
        elif options.format_id:
            cmd += ["-f", f"{options.format_id}+bestaudio/best", "--merge-output-format", "mp4"]
        elif options.quality and options.quality != "best" and options.quality.isdigit():
            q = options.quality
            cmd += [
                "-f",
                f"bestvideo[height<={q}][vcodec^=avc1]+bestaudio[ext=m4a]/bestvideo[height<={q}]+bestaudio/best[height<={q}]/best",
                "--merge-output-format", "mp4",
            ]
        else:
            cmd += [
                "-f",
                "bestvideo[vcodec^=avc1]+bestaudio[ext=m4a]/bestvideo+bestaudio/best",
                "--merge-output-format", "mp4",
            ]

        cmd.append(url)
        proc = subprocess.Popen(
            cmd,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            encoding="utf-8",
            errors="replace",
            creationflags=CREATE_NO_WINDOW,
        )

        final_path: Optional[Path] = None
        last_line = ""
        assert proc.stdout is not None
        for line in proc.stdout:
            if cancel.is_set():
                proc.terminate()
                try:
                    proc.wait(timeout=3)
                except Exception:
                    proc.kill()
                raise CancelledError()
            s = line.strip()
            if not s:
                continue
            if s.startswith("OMNI|"):
                parts = s.split("|")
                if len(parts) >= 4:
                    dl = int(float(parts[1])) if parts[1].replace(".", "", 1).isdigit() else 0
                    tot_raw = parts[2] if parts[2].replace(".", "", 1).isdigit() else parts[3]
                    tot = int(float(tot_raw)) if tot_raw.replace(".", "", 1).isdigit() else 0
                    on_progress(dl, tot)
            elif s.startswith("OMNI_OUT|"):
                final_path = Path(s.split("|", 1)[1].strip())
            elif "[Merger]" in s or "[ExtractAudio]" in s:
                on_state("merging")
            else:
                last_line = s

        code = proc.wait()
        if cancel.is_set():
            raise CancelledError()
        if code != 0:
            raise RuntimeError(last_line or f"yt-dlp 退出码 {code}")

        if final_path and final_path.exists():
            return final_path
        # Fallback locate matching file in dest_dir
        matches = sorted(dest_dir.glob(f"{base}.*"), key=lambda p: p.stat().st_mtime, reverse=True)
        if matches:
            return matches[0]
        return dest_dir


class EngineRegistry:
    def __init__(self) -> None:
        self._engines = [
            BilibiliEngine(),
            DirectMediaEngine(),
            YTDLPEngine(),
        ]

    def engine_for(self, url: str):
        for eng in self._engines:
            if eng.can_handle(url):
                return eng
        return self._engines[-1]

    def engine_by_id(self, engine_id: str):
        for eng in self._engines:
            if eng.id == engine_id:
                return eng
        return self._engines[-1]


ENGINES = EngineRegistry()
