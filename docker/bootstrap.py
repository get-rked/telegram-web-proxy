#!/usr/bin/env python3
"""Idempotent first-run bootstrap for the Docker deployment."""
import json
import os
import secrets
import shutil
import sys
import tempfile
from datetime import datetime, timezone
from pathlib import Path

CONFIG_DIR = Path(os.environ.get("TPROXY_CONFIG_DIR", "/config"))
MTPROXY_DIR = Path(os.environ.get("MTPROXY_DIR", "/mtproxy"))
DOMAIN = os.environ.get("DOMAIN", "").strip().lower()
UID = int(os.environ.get("TPROXY_UID", "10001"))
GID = int(os.environ.get("TPROXY_GID", "10001"))


def fail(message):
    print(f"bootstrap: ERROR: {message}", file=sys.stderr)
    raise SystemExit(1)


def backup(path):
    if not path.exists():
        return
    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    target = path.with_name(f"{path.name}.backup-{stamp}")
    suffix = 1
    while target.exists():
        target = path.with_name(f"{path.name}.backup-{stamp}-{suffix}")
        suffix += 1
    shutil.copy2(path, target)
    print(f"bootstrap: backup created: {target.name}")


def atomic_write(path, data, mode=0o640):
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, temp_name = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    try:
        with os.fdopen(fd, "wb") as stream:
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
        os.chmod(temp_name, mode)
        os.replace(temp_name, path)
        dir_fd = os.open(path.parent, os.O_DIRECTORY)
        try:
            os.fsync(dir_fd)
        finally:
            os.close(dir_fd)
    finally:
        if os.path.exists(temp_name):
            os.unlink(temp_name)


def load_json(path):
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        fail(f"cannot read valid JSON from {path}: {exc}")


def valid_secret(value):
    if not isinstance(value, str) or len(value) != 32:
        return False
    try:
        bytes.fromhex(value)
        return True
    except ValueError:
        return False


def main():
    if not DOMAIN or any(ch.isspace() for ch in DOMAIN) or "/" in DOMAIN:
        fail("DOMAIN must be set to a hostname without scheme, path, or whitespace")
    CONFIG_DIR.mkdir(parents=True, exist_ok=True)
    MTPROXY_DIR.mkdir(parents=True, exist_ok=True)
    config_path = CONFIG_DIR / "config.json"
    profiles_path = CONFIG_DIR / "profiles.json"
    token_path = CONFIG_DIR / "token.key"
    secret_path = MTPROXY_DIR / "secret"

    # Validate and preserve an existing profile file; otherwise create one.
    if profiles_path.exists():
        profiles_doc = load_json(profiles_path)
        profiles = profiles_doc.get("profiles") if isinstance(profiles_doc, dict) else None
        if not isinstance(profiles, list) or not profiles:
            fail("profiles.json must contain a non-empty profiles array")
        for item in profiles:
            if not isinstance(item, dict) or not valid_secret(item.get("secret")):
                fail("every profile must contain a 16-byte hex secret")
    else:
        if secret_path.exists():
            secret = secret_path.read_text(encoding="ascii").strip()
            if not valid_secret(secret):
                fail("existing MTProxy secret must be exactly 32 hex characters")
        else:
            secret = secrets.token_hex(16)
        profiles_doc = {"profiles": [{
            "name": "default",
            "secret": secret,
            "backend": "127.0.0.1:2398",
            "carrier_mode": "https"
        }]}
        atomic_write(profiles_path, (json.dumps(profiles_doc, indent=2) + "\n").encode(), 0o640)

    default_profiles = [p for p in profiles_doc["profiles"] if p.get("name") == "default"]
    if not default_profiles:
        fail("profiles.json must include a profile named 'default'")
    default_secret = default_profiles[0]["secret"]
    if secret_path.exists():
        current_secret = secret_path.read_text(encoding="ascii").strip()
        if not valid_secret(current_secret):
            fail("existing MTProxy secret must be exactly 32 hex characters")
        if current_secret.lower() != default_secret.lower():
            fail("MTProxy secret does not match the default profile secret; refusing to overwrite either")
    else:
        atomic_write(secret_path, (default_secret.lower() + "\n").encode("ascii"), 0o600)

    if config_path.exists():
        config = load_json(config_path)
        if not isinstance(config, dict):
            fail("config.json must contain a JSON object")
        if config.get("public_dir") and config.get("public_upstream"):
            fail("config.json must set only one of public_dir or public_upstream")
        if not config.get("public_dir") and not config.get("public_upstream"):
            fail("config.json must set public_dir or public_upstream")
        if config.get("public_hostname") != DOMAIN:
            backup(config_path)
            config["public_hostname"] = DOMAIN
            atomic_write(config_path, (json.dumps(config, indent=2) + "\n").encode(), 0o640)
    else:
        config = {
            "public_hostname": DOMAIN,
            "base_path": "",
            "listen": "127.0.0.1:8080",
            "admin_listen": "127.0.0.1:8081",
            "public_dir": "/srv/tproxy-site",
            "token_key_file": "/etc/tproxy-server/token.key",
            "static_routes": "exact",
            "enable_pprof": False
        }
        atomic_write(config_path, (json.dumps(config, indent=2) + "\n").encode(), 0o640)

    if token_path.exists():
        if token_path.stat().st_size != 32:
            fail("existing token.key must be exactly 32 random bytes; refusing to replace it")
    else:
        atomic_write(token_path, secrets.token_bytes(32), 0o600)

    for path in (config_path, profiles_path, token_path):
        os.chown(path, UID, GID)
    os.chown(secret_path, UID, GID)
    os.chmod(token_path, 0o600)
    os.chmod(secret_path, 0o600)
    print("bootstrap: configuration validated; existing secrets preserved; initialization complete")


if __name__ == "__main__":
    main()
