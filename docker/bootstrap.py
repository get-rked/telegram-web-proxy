#!/usr/bin/env python3
"""Idempotent first-run bootstrap for the Docker deployment."""
import hashlib
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
PROFILES_DIR = Path(os.environ.get("PROFILES_DIR", "/profiles"))
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


def canonical_secret(value):
    value = value.lower()
    return value[2:] if value.startswith("dd") else value


def valid_secret(value):
    if not isinstance(value, str):
        return False
    value = canonical_secret(value)
    if len(value) != 32:
        return False
    try:
        bytes.fromhex(value)
        return True
    except ValueError:
        return False


def read_secret_list(path):
    try:
        raw = path.read_text(encoding="ascii")
    except OSError as exc:
        fail(f"cannot read MTProxy secret file: {exc}")
    values = [canonical_secret(item.strip()).lower() for item in raw.splitlines() if item.strip()]
    if not values or any(not valid_secret(item) for item in values):
        fail("MTProxy secret file must contain one 32-hex secret per line")
    if len(values) != len(set(values)):
        fail("MTProxy secret file contains duplicate secrets")
    return values


def main():
    if not DOMAIN or any(ch.isspace() for ch in DOMAIN) or "/" in DOMAIN:
        fail("DOMAIN must be set to a hostname without scheme, path, or whitespace")
    CONFIG_DIR.mkdir(parents=True, exist_ok=True)
    MTPROXY_DIR.mkdir(parents=True, exist_ok=True)
    PROFILES_DIR.mkdir(parents=True, exist_ok=True)
    config_path = CONFIG_DIR / "config.json"
    profiles_path = PROFILES_DIR / "profiles.json"
    token_path = CONFIG_DIR / "token.key"
    secret_path = MTPROXY_DIR / "secret"
    panel_auth_path = CONFIG_DIR / "panel-auth.json"
    panel_credentials_path = CONFIG_DIR / "panel-credentials.txt"
    panel_route_path = CONFIG_DIR / "panel-route.caddy"

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
            secret = read_secret_list(secret_path)[0]
        else:
            secret = secrets.token_hex(16)
        profiles_doc = {"profiles": [{
            "name": "default",
            "secret": secret,
            "backend": "127.0.0.1:2398",
            "carrier_mode": "https"
        }]}
        atomic_write(profiles_path, (json.dumps(profiles_doc, indent=2) + "\n").encode(), 0o600)

    default_profiles = [p for p in profiles_doc["profiles"] if p.get("name") == "default"]
    if not default_profiles:
        fail("profiles.json must include a profile named 'default'")
    default_secret = default_profiles[0]["secret"]
    expected_secrets = [canonical_secret(p["secret"]).lower() for p in profiles_doc["profiles"]]
    if secret_path.exists():
        current_secrets = read_secret_list(secret_path)
        if set(current_secrets) != set(expected_secrets):
            fail("MTProxy secret list does not match profile secrets; refusing to overwrite either")
    else:
        atomic_write(secret_path, ("\n".join(expected_secrets) + "\n").encode("ascii"), 0o600)

    if config_path.exists():
        config = load_json(config_path)
        if not isinstance(config, dict):
            fail("config.json must contain a JSON object")
        if config.get("public_dir") and config.get("public_upstream"):
            fail("config.json must set only one of public_dir or public_upstream")
        if not config.get("public_dir") and not config.get("public_upstream"):
            fail("config.json must set public_dir or public_upstream")
        changed = False
        if config.get("public_hostname") != DOMAIN:
            config["public_hostname"] = DOMAIN
            changed = True
        if config.get("admin_listen") == "0.0.0.0:8081":
            # Upstream requires a loopback admin listener; the metrics bridge exposes it privately.
            config["admin_listen"] = "127.0.0.1:8081"
            changed = True
        if changed:
            backup(config_path)
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

    # Generate the private panel URL and credentials exactly once.
    credentials_created = False
    if panel_auth_path.exists():
        auth = load_json(panel_auth_path)
        if not isinstance(auth, dict) or not isinstance(auth.get("base_path"), str) or not isinstance(auth.get("username"), str) or not isinstance(auth.get("password_salt"), str) or not isinstance(auth.get("password_hash"), str):
            fail("panel-auth.json is invalid; refusing to replace panel credentials")
        base_path = auth["base_path"]
        if not base_path.startswith("/panel-") or "/" in base_path[1:]:
            fail("panel-auth.json contains an invalid base_path")
        if not panel_credentials_path.exists():
            fail("panel-credentials.txt is missing; refusing to rotate credentials automatically")
    else:
        base_path = "/panel-" + secrets.token_urlsafe(24)
        username = "admin_" + secrets.token_hex(4)
        password = secrets.token_urlsafe(24)
        salt = secrets.token_bytes(32)
        password_hash = hashlib.sha256(salt + password.encode("utf-8")).hexdigest()
        auth = {
            "base_path": base_path,
            "username": username,
            "password_salt": salt.hex(),
            "password_hash": password_hash,
        }
        atomic_write(panel_auth_path, (json.dumps(auth, indent=2) + "\n").encode(), 0o600)
        credentials = (
            f"URL: https://{DOMAIN}{base_path}/\n"
            f"LOGIN: {username}\n"
            f"PASSWORD: {password}\n"
        )
        atomic_write(panel_credentials_path, credentials.encode("utf-8"), 0o600)
        credentials_created = True

    # Caddy imports this generated route. The secret path is never placed in a public URL or log.
    route = (
        f"@panel_root_no_slash path {base_path}\n"
        f"redir @panel_root_no_slash {base_path}/ 308\n"
        f"handle_path {base_path}/* {{\n"
        "    reverse_proxy panel:8088 {\n"
        "        header_up X-Real-IP {client_ip}\n"
        "    }\n"
        "}\n"
    )
    if not panel_route_path.exists() or panel_route_path.read_text(encoding="utf-8") != route:
        atomic_write(panel_route_path, route.encode("utf-8"), 0o640)

    for path in (config_path, token_path, profiles_path, panel_auth_path, panel_route_path):
        os.chown(path, UID, GID)
    os.chown(secret_path, UID, GID)
    os.chown(PROFILES_DIR, UID, GID)
    os.chmod(PROFILES_DIR, 0o750)
    os.chmod(profiles_path, 0o600)
    os.chmod(token_path, 0o600)
    os.chmod(panel_auth_path, 0o600)
    os.chmod(panel_route_path, 0o640)
    os.chmod(panel_credentials_path, 0o600)
    os.chown(panel_credentials_path, UID, GID)
    os.chmod(secret_path, 0o600)
    print("bootstrap: configuration validated; existing secrets preserved; initialization complete")
    if credentials_created:
        print("bootstrap: PANEL CREDENTIALS (shown once; also saved in panel-credentials.txt):")
        print(f"  URL: https://{DOMAIN}{base_path}/")
        print(f"  LOGIN: {username}")
        print(f"  PASSWORD: {password}")


if __name__ == "__main__":
    main()
