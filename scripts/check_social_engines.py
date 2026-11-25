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


def run_app(binary, url, destination, env, success=True, legacy=False):
    command = ["--download"] if legacy else ["download", "--json"]
    result = subprocess.run([binary, *command, url, "--out", destination], env=env,
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


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, default=Path(__file__).resolve().parents[1] / ".build/release/omnifetch")
    parser.add_argument("--baseline", type=Path, help="previous OmniFetch executable")
    parser.add_argument("--rounds", type=int, default=3)
    args = parser.parse_args()
    if args.rounds < 1 or not all(shutil.which(tool) for tool in ["ffmpeg", "yt-dlp"]):
        parser.error("requires ffmpeg, yt-dlp on PATH and at least one round")
    with tempfile.TemporaryDirectory(prefix="omnifetch-social-") as tmp:
        work = Path(tmp)
        home = work / "home"
        home.mkdir()
        env = {**os.environ, "HOME": str(home), "CFFIXED_USER_HOME": str(home), "XDG_CONFIG_HOME": str(home)}
        for name in ["OMNI_COOKIE", "OMNIFETCH_X_BEARER_TOKEN"]:
            env.pop(name, None)
        binary = args.binary.resolve()
        check_preview_reuse(binary, args.baseline.resolve() if args.baseline else None, args.rounds, work, env)
        check_collection_retry(binary, work, env)


if __name__ == "__main__":
    main()
