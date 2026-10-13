#!/usr/bin/env python3
"""Prefetch the exact signed-snapshot packages, then let apt verify/install them.

The regular mirror is much faster for unchanged Jammy packages. A removed
version falls back to the dated snapshot. Neither candidate can change the
version or digest selected by apt's authenticated package index.
"""
import concurrent.futures
import hashlib
from pathlib import Path
import shlex
import subprocess
import sys
import urllib.error
import urllib.request

packages = sys.argv[1:]
base = ["apt-get", "-o", "Acquire::ForceHash=SHA256", "-y", "--no-install-recommends"]
listing = subprocess.check_output(base + ["--print-uris", "--download-only", "install", *packages], text=True)
requests = []
for line in listing.splitlines():
    if not line.startswith("'"):
        continue
    url, name, size, digest = shlex.split(line)
    if Path(name).name != name or not digest.startswith("SHA256:"):
        raise RuntimeError(f"Unexpected apt package identity: {name} {digest}")
    requests.append((url, name, int(size), digest.split(":", 1)[1]))


def fetch(request):
    url, name, size, expected = request
    destination = Path("/var/cache/apt/archives") / name
    if destination.exists() and hashlib.sha256(destination.read_bytes()).hexdigest() == expected:
        return
    relative = url.split("/ubuntu/20250901T000000Z/", 1)
    candidates = ["https://archive.ubuntu.com/ubuntu/" + relative[1], url] if len(relative) == 2 else [url]
    failure = None
    for candidate in candidates:
        try:
            with urllib.request.urlopen(candidate, timeout=120) as response:
                data = response.read()
            if len(data) != size or hashlib.sha256(data).hexdigest() != expected:
                raise RuntimeError(f"Package digest mismatch: {name}")
            temporary = destination.with_name(name + ".download")
            temporary.write_bytes(data)
            temporary.replace(destination)
            print(f"Verified {name}", flush=True)
            return
        except (urllib.error.URLError, TimeoutError, RuntimeError) as error:
            failure = error
    raise RuntimeError(f"Cannot obtain exact package {name}: {failure}")


with concurrent.futures.ThreadPoolExecutor(max_workers=12) as pool:
    list(pool.map(fetch, requests))
subprocess.run(base + ["install", *packages], check=True)
