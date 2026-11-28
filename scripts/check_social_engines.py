#!/usr/bin/env python3
"""Check the CLI and real yt-dlp against a local video page."""
import argparse
import collections
import contextlib
import http.server
import json
import os
from pathlib import Path
import shutil
import statistics
import subprocess
import sys
import tempfile
import threading
import time
from benchmark import FixtureServer, MIB


def run_app(binary, url, destination, env, success=True, legacy=False, flags=()):
    command = ["--download"] if legacy else ["download", "--json"]
    result = subprocess.run([binary, *command, url, "--out", destination, *flags], env=env,
                            capture_output=True, text=True, timeout=60)
    if (result.returncode == 0) != success:
        raise AssertionError(result.stdout[-1300:] + result.stderr[-300:])
    if not legacy:
        record, = json.loads(result.stdout)["results"]
        if not success:
            assert record["error"] and "outputPath" not in record
            return None
        return Path(record["outputPath"])
    lines = [line.removeprefix("file:").strip() for line in result.stdout.splitlines() if line.startswith("file:")]
    if not success:
        assert not lines, "failed extractor reported a finished file"
        return None
    assert len(lines) == 1
    return Path(lines[0])


@contextlib.contextmanager
def local_post(media):
    counts = collections.Counter()

    class Handler(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            counts[self.path] += 1
            if self.path == "/post":
                time.sleep(0.12)
                body = b'<html><head><title>Social test</title></head><body><video controls src="/clip.mp4"></video></body></html>'
                kind = "text/html"
            elif self.path == "/clip.mp4":
                body = media
                kind = "video/mp4"
            else:
                self.send_error(404)
                return
            self.send_response(200)
            self.send_header("Content-Type", kind)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            try:
                self.wfile.write(body)
            except (BrokenPipeError, ConnectionResetError):
                pass

        def log_message(self, *args):
            pass

    with http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler) as server:
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            yield f"http://127.0.0.1:{server.server_port}/post", counts
        finally:
            server.shutdown()
            thread.join()


def check_preview_reuse(binary, baseline, rounds, work, env):
    fixture = work / "source.mp4"
    subprocess.run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-f", "lavfi", "-i", "color=blue:s=160x90",
                    "-f", "lavfi", "-i", "sine=frequency=440", "-t", "0.4", "-c:v", "libx264", "-c:a", "aac",
                    str(fixture)], check=True)
    source = fixture.read_bytes()
    versions = {"after": binary}
    if baseline:
        versions = {"before": baseline, **versions}
    times = collections.defaultdict(list)
    with local_post(source) as (url, counts):
        for round_index in range(rounds):
            for version in (reversed(versions) if round_index % 2 else versions):
                counts.clear()
                start = time.monotonic()
                output = run_app(versions[version], url, work / f"{version}-{round_index}", env, legacy=version == "before")
                times[version].append(time.monotonic() - start)
                assert output.read_bytes() == source, "single-video output differs from the source"
                if version == "after":
                    assert counts["/post"] == 1, f"duplicate page requests: {counts}"
                print(f"{version} round {round_index + 1}: page={counts['/post']}, media={counts['/clip.mp4']}, "
                      f"{times[version][-1]:.3f} s", flush=True)
        check_cli(binary, url.removesuffix("/post"), source, work, env)
    for version, values in times.items():
        print(f"{version} median: {statistics.median(values):.3f} s")


def check_cli(binary, base, source, work, env):
    clip = base + "/clip.mp4"
    probe = subprocess.run([binary, "probe", "--json", "-"], env=env, input=f"复制链接 {clip}，打开观看\n{clip}\n",
                           capture_output=True, text=True, check=True, timeout=30)
    info, = json.loads(probe.stdout)["results"]
    assert info["url"] == clip and info["engine"] == "direct" and info["formats"][0]["id"] == "source"

    invalid = subprocess.run([binary, "download", "--connections", "17", clip], env=env,
                             capture_output=True, text=True, timeout=10)
    assert invalid.returncode == 2 and not invalid.stdout and "--connections" in invalid.stderr

    batch_dir = work / "batch output"
    missing = base + "/missing.mp4"
    batch = subprocess.run([binary, "download", missing, clip, "--json", "-o", batch_dir], env=env,
                           capture_output=True, text=True, timeout=30)
    assert batch.returncode == 1, batch.stderr
    failure, success = json.loads(batch.stdout)["results"]
    assert failure["url"] == missing and failure["error"] and "outputPath" not in failure
    assert success["url"] == clip and Path(success["outputPath"]).read_bytes() == source
    assert list(batch_dir.glob("*.mp4")) == [Path(success["outputPath"])]
    print("PASS standalone CLI input, JSON, usage errors and mixed batch results")


def check_collection_retry(binary, work, env):
    fake = work / "bin"
    fake.mkdir()
    downloader = fake / "yt-dlp"
    downloader.write_text(f"#!{sys.executable}\n" + """
import json, os, sys
from pathlib import Path
args = sys.argv[1:]
if '-J' in args:
    assert args[args.index('--playlist-items') + 1] == '1'
    print(json.dumps({'_type':'playlist', 'title':'100% media', 'entries':[{'id':'one'}], 'playlist_count':2}))
else:
    assert '--yes-playlist' in args
    folder = Path(args[args.index('-o') + 1].replace('%%', '%')).parent
    first = folder / '00001-one.mp4'
    first.write_bytes(b'first')
    print('OMNI_FILE ' + str(first), flush=True)
    if os.environ.get('SIMULATE_INTERRUPTION'):
        (folder / '00002-two.mp4.part').write_bytes(b'partial')
        print('ERROR: interrupted', flush=True)
        sys.exit(1)
    second = folder / '00002-two.mp4'
    second.write_bytes(b'second')
    print('OMNI_FILE ' + str(second), flush=True)
""")
    gallery = fake / "gallery-dl"
    gallery.write_text(f"#!{sys.executable}\nprint('[]')\n")
    downloader.chmod(0o755)
    gallery.chmod(0o755)
    custom = {**env, "PATH": str(fake) + os.pathsep + env["PATH"]}
    out = work / "downloads-100%"
    url = "https://x.com/example/status/1234"
    run_app(binary, url, out, {**custom, "SIMULATE_INTERRUPTION": "1"}, success=False)
    assert all(p.name.startswith(".") for p in out.iterdir()), "unfinished collection was published"
    folder = run_app(binary, url, out, custom)
    assert sorted(p.read_bytes() for p in folder.iterdir()) == [b"first", b"second"]
    print("PASS empty gallery falls back to video, failed collection stays private, retry publishes exactly two files")


def check_parallel_http(binary, baseline, rounds, work, env):
    # The first invocation supplies a repeatable extractor response. All later
    # yt-dlp downloads, HTTP transfers and ffmpeg merges use the real programs.
    fake = work / "http-bin"
    fake.mkdir()
    wrapper = fake / "yt-dlp"
    wrapper.write_text(f"#!{sys.executable}\n" + """
import os, sys
from pathlib import Path
if '-J' in sys.argv:
    print(Path(os.environ['FIXTURE_INFO']).read_text())
else:
    exe = os.environ['FIXTURE_YTDLP']
    os.execv(exe, [exe, *sys.argv[1:]])
""")
    wrapper.chmod(0o755)
    metadata = work / "public-video.json"
    custom = {**env, "PATH": str(fake) + os.pathsep + env["PATH"], "FIXTURE_INFO": str(metadata),
              "FIXTURE_YTDLP": shutil.which("yt-dlp")}
    source = (work / "source.mp4").read_bytes()
    # Both the 256 KiB prefix and the complete 6 MiB file are valid MP4s.
    for size in [MIB // 4, 6 * MIB]:
        padding = size - len(source)
        source += padding.to_bytes(4, "big") + b"free" + bytes(padding - 8)
    clip = work / "padded.mp4"
    clip.write_bytes(source)
    versions = {"before": baseline, "after": binary} if baseline else {"after": binary}
    with FixtureServer(clip) as server:
        threading.Thread(target=server.serve_forever, daemon=True).start()
        try:
            root = f"http://127.0.0.1:{server.server_port}"
            page = root + "/watch"
            video = dict(format_id="18", url=root + "/short.mp4", protocol="http", ext="mp4",
                         vcodec="avc1", acodec="aac", height=90, filesize=len(source),
                         downloader_options={"http_chunk_size": 2 * MIB})
            info = dict(id="test", title="HTTP test", extractor="youtube", extractor_key="Youtube", webpage_url=page)
            metadata.write_text(json.dumps({**info, **video, "formats": [video]}))
            times = collections.defaultdict(list)
            peaks = collections.defaultdict(list)
            for iteration in range(rounds):
                for name in reversed(versions) if iteration % 2 else versions:
                    server.reset_counts()
                    start = time.monotonic()
                    output = run_app(versions[name], page, work / f"http-{name}-{iteration}", custom,
                                     legacy=name == "before", flags=("--connections", "8"))
                    times[name].append(time.monotonic() - start)
                    assert output.read_bytes() == source
                    peaks[name].append(server.peak)
                    if name == "after":
                        assert server.peak == 3, (name, server.peak)
            for name, samples in times.items():
                print(f"HTTP preview {name}: median {statistics.median(samples):.3f} s, peak {max(peaks[name])}, identical bytes")
            tracks = [{**video, "format_id": "137", "acodec": "none"},
                      dict(format_id="140", url=root + "/small.m4a", protocol="http", ext="m4a",
                           vcodec="none", acodec="aac", filesize=MIB // 4)]
            metadata.write_text(json.dumps({**info, "requested_formats": tracks, "formats": tracks}))
            for slots in (1, 8):
                server.reset_counts()
                output = run_app(binary, page, work / f"mux-{slots}", custom, flags=("--connections", str(slots)))
                streams = subprocess.check_output(["ffprobe", "-v", "error", "-show_entries", "stream=codec_type",
                                                   "-of", "csv=p=0", output], text=True).splitlines()
                assert sorted(streams) == ["audio", "video"] and 1 <= server.peak <= slots
                assert slots == 1 or server.peak >= 3
            print("PASS selected HTTP tracks share the configured budget and produce playable video and audio")
        finally:
            server.shutdown()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, default=Path(__file__).resolve().parents[1] / ".build/release/omnifetch")
    parser.add_argument("--baseline", type=Path, help="previous OmniFetch executable")
    parser.add_argument("--rounds", type=int, default=3)
    args = parser.parse_args()
    if args.rounds < 1 or not all(shutil.which(tool) for tool in ["ffmpeg", "ffprobe", "yt-dlp"]):
        parser.error("requires ffmpeg, ffprobe and yt-dlp on PATH and at least one round")
    with tempfile.TemporaryDirectory(prefix="omnifetch-social-") as tmp:
        work = Path(tmp)
        home = work / "home"
        home.mkdir()
        env = {**os.environ, "HOME": str(home), "CFFIXED_USER_HOME": str(home), "XDG_CONFIG_HOME": str(home)}
        for name in ["OMNI_COOKIE", "OMNIFETCH_X_BEARER_TOKEN"]:
            env.pop(name, None)
        binary = args.binary.resolve()
        baseline = args.baseline.resolve() if args.baseline else None
        check_preview_reuse(binary, baseline, args.rounds, work, env)
        check_parallel_http(binary, baseline, args.rounds, work, env)
        check_collection_retry(binary, work, env)


if __name__ == "__main__":
    main()
