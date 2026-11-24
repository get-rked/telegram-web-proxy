#!/usr/bin/env python3
"""Refresh Telegram's official MTProxy routing config once per day with rollback."""
import os
import signal
import time
import urllib.error
import urllib.request
from pathlib import Path

DATA = Path(os.environ.get("MTPROXY_DATA_DIR", "/var/lib/mtproxy"))
CONFIG = DATA / "proxy-multi.conf"
BACKUP = DATA / "proxy-multi.conf.previous"
URL = "https://core.telegram.org/getProxyConfig"
INTERVAL = int(os.environ.get("MTPROXY_REFRESH_INTERVAL", "86400"))


def download():
    request = urllib.request.Request(URL, headers={"User-Agent": "telegram-web-proxy-config-updater/1"})
    with urllib.request.urlopen(request, timeout=30) as response:
        data = response.read(4 * 1024 * 1024 + 1)
    if not data or len(data) > 4 * 1024 * 1024:
        raise RuntimeError("routing config is empty or exceeds 4 MiB")
    return data


def atomic_write(path, data):
    temp = path.with_name(path.name + ".new")
    with open(temp, "wb") as stream:
        stream.write(data)
        stream.flush()
        os.fsync(stream.fileno())
    os.chmod(temp, 0o600)
    os.replace(temp, path)


def stats_ready():
    try:
        with urllib.request.urlopen("http://127.0.0.1:8888/stats", timeout=2) as response:
            return response.status == 200
    except (OSError, urllib.error.URLError):
        return False


def restart_proxy():
    try:
        command = Path("/proc/1/cmdline").read_bytes()
    except OSError as exc:
        raise RuntimeError("cannot inspect MTProxy process") from exc
    if b"mtproto-proxy" not in command:
        raise RuntimeError("PID 1 is not the MTProxy process; refusing to signal")
    os.kill(1, signal.SIGTERM)


def wait_ready(timeout=90):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if stats_ready():
            return True
        time.sleep(2)
    return False


def main():
    if not CONFIG.is_file() or CONFIG.stat().st_size == 0:
        raise RuntimeError("initial proxy-multi.conf is missing")
    while True:
        time.sleep(INTERVAL)
        try:
            fresh = download()
        except Exception as exc:
            print(f"mtproxy-updater: refresh download failed; keeping current config ({type(exc).__name__})", flush=True)
            continue
        current = CONFIG.read_bytes()
        if fresh == current:
            print("mtproxy-updater: routing config is already current", flush=True)
            continue
        atomic_write(BACKUP, current)
        atomic_write(CONFIG, fresh)
        try:
            restart_proxy()
            if wait_ready():
                print("mtproxy-updater: routing config updated and MTProxy is healthy", flush=True)
                continue
            raise RuntimeError("MTProxy did not become healthy after config update")
        except Exception as exc:
            print(f"mtproxy-updater: update failed; rolling back ({type(exc).__name__})", flush=True)
            atomic_write(CONFIG, current)
            restart_proxy()
            if not wait_ready():
                raise RuntimeError("MTProxy failed to recover after routing config rollback") from exc


if __name__ == "__main__":
    DATA.mkdir(parents=True, exist_ok=True)
    main()
