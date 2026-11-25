"""Compare Release downloads and queue writes using deterministic loopback fixtures."""

import argparse
import csv
import hashlib
import os
from pathlib import Path
import platform
import random
import re
import sys
import statistics
import subprocess
import tempfile
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PROJECT = Path(__file__).resolve().parents[1]
MIB = 1024 * 1024
SIZES = {"range": 256 * MIB, "small": MIB // 4, "fallback": 24 * MIB}
CASES = (*SIZES, "album", "queue")


def checksum(path, offset=0, length=None):
    digest = hashlib.sha256()
    with path.open("rb") as source:
        source.seek(offset)
        while length is None or length > 0:
            data = source.read(MIB if length is None else min(MIB, length))
            if not data:
                break
            digest.update(data)
            if length is not None:
                length -= len(data)
    return digest.digest()


class FixtureServer(ThreadingHTTPServer):
    daemon_threads = True
    request_queue_size = 96

    def __init__(self, source):
        super().__init__(("127.0.0.1", 0), FixtureHandler)
        self.source = source
        self.lock = threading.Lock()
        self.reset_counts()

    def reset_counts(self):
        with self.lock:
            self.requests = 0
            self.connections = set()

    def handle_error(self, request, client_address):
        # Cancelling an ignored range can reset a keep-alive socket.
        if not isinstance(sys.exc_info()[1], (ConnectionResetError, BrokenPipeError)):
            super().handle_error(request, client_address)


class FixtureHandler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    disable_nagle_algorithm = True

    def log_message(self, *args):
        pass

    def do_GET(self):
        name = Path(self.path).stem
        offset = 0
        if name.startswith("image-"):
            index = int(name.split("-")[1])
            length, offset = 65536, index * 196613
            time.sleep(0.15 if index % 7 == 1 else 0.012)
        else:
            length = SIZES[name]
            if name == "small":
                time.sleep(0.04)
        field = self.headers.get("Range", "")
        bounds = re.fullmatch(r"bytes=(\d+)-(\d*)", field)
        partial = bool(bounds) and (name != "fallback" or field == "bytes=0-0")
        start, end = 0, length - 1
        if partial:
            start = int(bounds[1])
            end = min(end, int(bounds[2])) if bounds[2] else end
        with self.server.lock:
            self.server.requests += 1
            self.server.connections.add(self.client_address)
        try:
            self.send_response(206 if partial else 200)
            self.send_header("Content-Length", str(end - start + 1))
            self.send_header("Content-Type", "application/octet-stream")
            self.send_header("Accept-Ranges", "bytes")
            self.send_header("ETag", f'"fixture-{name}"')
            if partial:
                self.send_header("Content-Range", f"bytes {start}-{end}/{length}")
            self.end_headers()
            with self.server.source.open("rb") as source:
                self.connection.sendfile(source, offset=offset + start, count=end - start + 1)
        except OSError:
            self.close_connection = True


def build(project, client):
    build_cmd = ["swift", "build", "-c", "release", "--package-path", str(project)]
    subprocess.run(build_cmd, check=True)
    artifacts = Path(subprocess.check_output(build_cmd + ["--show-bin-path"], text=True).strip())
    objects = sorted((artifacts / "OmniFetchCore.build").glob("*.swift.o"))
    subprocess.run(["swiftc", "-O", "-parse-as-library", "-target",
                    f"{platform.machine()}-apple-macos14.0", "-I", artifacts / "Modules",
                    Path(__file__).with_name("benchmark-client.swift"), *objects, "-o", client], check=True)
    binary = artifacts / "omnifetch"
    return (binary if binary.is_file() else artifacts / "OmniFetch"), client


def measure(programs, case, server, work, hashes, images):
    binary, client = programs
    url = f"http://127.0.0.1:{server.server_port}"
    with tempfile.TemporaryDirectory(dir=work) as folder:
        output = Path(folder)
        home = output / "home"
        home.mkdir()
        if case in SIZES:
            cmd = [binary, "--download", f"{url}/{case}.mp4", "--out", output, "--connections", "6"]
        else:
            cmd = [client, case, url, output]
        env = {**os.environ, "CFFIXED_USER_HOME": str(home)}
        env.pop("OMNI_COOKIE", None)
        server.reset_counts()
        start = time.perf_counter()
        result = subprocess.run(cmd, env=env, check=True, timeout=90, stdout=subprocess.PIPE, text=True)
        seconds = time.perf_counter() - start
        if case in SIZES:
            if checksum(output / f"{case}.mp4") != hashes[case]:
                raise ValueError(f"checksum mismatch in {case}")
        elif case == "album":
            actual = [checksum(output / "album" / f"{i:02d}.jpg") for i in range(1, 25)]
            if actual != images:
                raise ValueError("album checksum mismatch")
        else:
            seconds = float(result.stdout.strip())
        with server.lock:
            return seconds, server.requests, len(server.connections)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--baseline", type=Path, help="OmniFetch source directory to compare")
    parser.add_argument("--rounds", type=int, default=5)
    parser.add_argument("--csv", type=Path, help="save all measured samples")
    args = parser.parse_args()
    if args.rounds < 1:
        parser.error("--rounds must be positive")
    with tempfile.TemporaryDirectory(prefix="omnifetch-bench-") as folder:
        work = Path(folder).resolve()
        programs = {}
        if args.baseline:
            programs["before"] = build(args.baseline.resolve(), work / "before-client")
        programs["after"] = build(PROJECT, work / "after-client")
        fixture = work / "fixture.bin"
        rng = random.Random(43530)
        with fixture.open("wb") as output:
            for _ in range(SIZES["range"] // MIB):
                output.write(rng.randbytes(MIB))
        hashes = {case: checksum(fixture, 0, length) for case, length in SIZES.items()}
        images = [checksum(fixture, i * 196613, 65536) for i in range(1, 25)]
        rows = []
        with FixtureServer(fixture) as server:
            threading.Thread(target=server.serve_forever, daemon=True).start()
            try:
                for iteration in range(args.rounds):
                    for case in CASES:
                        order = reversed(programs) if iteration % 2 else programs
                        for version in order:
                            seconds, requests, peers = measure(programs[version], case, server, work, hashes, images)
                            rows.append(dict(scenario=case, version=version, run=iteration + 1,
                                             seconds=round(seconds, 6), http_requests=requests, tcp_connections=peers))
            finally:
                server.shutdown()
        if args.csv:
            with args.csv.open("w", newline="") as output:
                writer = csv.DictWriter(output, fieldnames=list(rows[0]))
                writer.writeheader()
                writer.writerows(rows)
        for case in CASES:
            for version in programs:
                samples = [r["seconds"] for r in rows if r["scenario"] == case and r["version"] == version]
                print(f"{case:10} {version:6} {statistics.median(samples):.4f} s")


if __name__ == "__main__":
    main()
