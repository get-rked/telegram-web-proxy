#!/usr/bin/env python3
"""Guarded native-to-Docker migration runner."""
import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent
UNITS = ("tproxy-server.service", "mtproxy.service", "caddy.service", "nginx.service")


class MigrationAbort(Exception):
    pass


def cmd(args, check=True, timeout=1800, show=False):
    p = subprocess.run(args, text=True, stdout=subprocess.PIPE,
                       stderr=subprocess.STDOUT, timeout=timeout)
    output = (p.stdout or "").strip()
    if show and output:
        print(output, flush=True)
    if check and p.returncode:
        raise MigrationAbort("{} failed:\n{}".format(" ".join(args), output))
    return output, p.returncode


def need(name):
    if not shutil.which(name):
        raise MigrationAbort("Не найдена команда: " + name)


def active(unit):
    return cmd(["systemctl", "is-active", "--quiet", unit], False)[1] == 0


def listeners(port):
    out, rc = cmd(["ss", "-H", "-ltnp"], False)
    if rc:
        raise MigrationAbort("Не удалось проверить порты через ss.")
    return [line.strip() for line in out.splitlines()
            if len(line.split()) >= 4 and re.search(r":{}$".format(port), line.split()[3])]


def selected_proxy(source, override):
    if override:
        return override
    f = source / "config/proxy/web-server"
    value = f.read_text().strip().lower() if f.is_file() else "caddy"
    if value not in ("caddy", "nginx"):
        raise MigrationAbort("Неизвестный reverse proxy: " + value)
    return value


def check_shared_proxy(source, proxy):
    config = json.loads((source / "config/proxy/config.json").read_text())
    domain = str(config.get("public_hostname", "")).lower()
    if proxy == "nginx":
        roots = (Path("/etc/nginx/sites-enabled"), Path("/etc/nginx/conf.d"))
        names = set()
        for root in roots:
            if root.is_dir():
                for f in root.iterdir():
                    try:
                        data = f.read_text(errors="ignore")
                    except (OSError, IsADirectoryError):
                        continue
                    names.update(x.lower() for block in re.findall(r"\bserver_name\s+([^;]+);", data)
                                 for x in block.split() if x != "_")
    else:
        f = Path("/etc/caddy/Caddyfile")
        names = set()
        if f.is_file():
            for line in f.read_text(errors="ignore").splitlines():
                s = line.strip()
                if s and not s.startswith("#") and "{" in s and not s.startswith(
                        ("route ", "handle ", "@", "(", "import ", "global", "servers")):
                    names.update(x.strip().lower() for x in s.split("{", 1)[0].split(",") if x.strip())
    other = sorted(x for x in names if x not in (domain, "localhost", "_", ":80", ":443"))
    if other:
        raise MigrationAbort("Найден общий {} с другими сайтами: {}. Автоматически останавливать его нельзя.".format(
            proxy, ", ".join(other)))


def main():
    parser = argparse.ArgumentParser(description="Проверка, подготовка и интерактивное переключение native → Docker.")
    parser.add_argument("--source-dir", type=Path, default=Path("/opt/telegram-web-proxy"))
    parser.add_argument("--web-server", choices=("caddy", "nginx"))
    parser.add_argument("--prepare-only", action="store_true",
                        help="Выполнить проверки, backup и сборку, но не останавливать службы.")
    args = parser.parse_args()

    if os.geteuid() != 0:
        raise MigrationAbort("Запусти скрипт от root: sudo python3 migrate-docker-auto.py")
    source = args.source_dir.resolve()
    if not source.is_dir() or not (source / "config/proxy/config.json").is_file():
        raise MigrationAbort("Не найдена действующая установка: " + str(source))
    if not (ROOT / "docker-compose.yml").is_file() or not (ROOT / "migrate-to-docker.py").is_file():
        raise MigrationAbort("Скрипт должен находиться в корне Docker-репозитория.")
    for name in ("python3", "docker", "systemctl", "ss", "tar", "iptables"):
        need(name)
    cmd(["docker", "compose", "version"])
    security, _ = cmd(["docker", "info", "--format", "{{json .SecurityOptions}}"], False)
    if "rootless" in security.lower():
        raise MigrationAbort("Rootless Docker несовместим с текущей схемой Fail2ban/DOCKER-USER.")

    proxy = selected_proxy(source, args.web_server)
    print("\n[1/6] Проверка служб и портов")
    running_units = [u for u in UNITS if active(u)]
    for u in UNITS:
        print("  {} {}".format("ACTIVE" if u in running_units else "inactive", u))
    for port in (80, 443):
        rows = listeners(port)
        print("  TCP/{}: {}".format(port, "; ".join(rows) if rows else "свободен"))
        for row in rows:
            if proxy not in row.lower():
                raise MigrationAbort("Порт {} занят не выбранным {}: {}".format(port, proxy, row))
    check_shared_proxy(source, proxy)

    profiles = ["--profile", proxy, "--profile", "mtproxy"]
    print("\n[2/6] Предварительная проверка миграции")
    cmd(["python3", str(ROOT / "migrate-to-docker.py"), "--source-dir", str(source),
         "--web-server", proxy])

    print("\n[3/6] Создание резервной копии и перенос конфигурации")
    cmd(["python3", str(ROOT / "migrate-to-docker.py"), "--source-dir", str(source),
         "--web-server", proxy, "--apply"], show=True)

    print("\n[4/6] Проверка Compose и сборка")
    cmd(["docker", "compose"] + profiles + ["config"])
    cmd(["docker", "compose"] + profiles + ["build"], timeout=3600, show=True)

    if args.prepare_only:
        print("\nПодготовка завершена. Старые службы не остановлены, Docker не запущен.")
        return 0

    stop_units = [u for u in running_units if u in (
        "tproxy-server.service", "mtproxy.service", proxy + ".service")]
    print("\n[5/6] Будут остановлены службы:")
    for unit in stop_units:
        print("  - " + unit)
    print("Исходные файлы и автозапуск служб сохраняются.")
    if input("Для продолжения введи SWITCH: ").strip() != "SWITCH":
        print("Переключение отменено; backup и подготовленные файлы сохранены.")
        return 0

    stopped = []
    try:
        for unit in stop_units:
            cmd(["systemctl", "stop", unit])
            stopped.append(unit)
        for port in (80, 443):
            rows = listeners(port)
            if rows:
                raise MigrationAbort("После остановки служб порт {} всё ещё занят: {}".format(port, rows))

        print("\n[6/6] Запуск Docker")
        cmd(["docker", "compose"] + profiles + ["up", "-d"], timeout=1800, show=True)
        deadline = time.time() + 180
        while time.time() < deadline:
            state, _ = cmd(["docker", "compose", "ps", "--format", "json"], False)
            rows = [x for x in state.splitlines() if x.strip()]
            if rows and all(("running" in x.lower() or "healthy" in x.lower()) for x in rows):
                break
            time.sleep(5)

        status, _ = cmd(["docker", "compose", "ps"], False)
        print(status)
        running, _ = cmd(["docker", "compose", "ps", "--services", "--status", "running"], False)
        required = {"relay", "panel", "fail2ban", "mtproxy", proxy}
        missing = sorted(required - set(running.splitlines()))
        if missing:
            raise MigrationAbort("Не все обязательные контейнеры работают: " + ", ".join(missing))
        _, rc = cmd(["iptables", "-S", "DOCKER-USER"], False)
        if rc:
            raise MigrationAbort("Не создана цепочка DOCKER-USER: Fail2ban не сможет блокировать Docker-трафик.")
        domain = json.loads((source / "config/proxy/config.json").read_text()).get("public_hostname", "")
        if shutil.which("curl"):
            code, _ = cmd(["curl", "-k", "-sS", "-o", "/dev/null", "-w", "%{http_code}",
                           "--max-time", "15", "https://{}/admin/".format(domain)], False)
            if code not in ("200", "301", "302", "401", "403"):
                raise MigrationAbort("Панель не отвечает корректно через HTTPS (HTTP {}).".format(code or "нет ответа"))
            print("Панель: HTTP " + code)
        print("\nDocker-миграция запущена. Проверь Web Proxy и MTProxy с внешнего устройства.")
        return 0
    except Exception as error:
        print("\nОшибка переключения: {}".format(error))
        print("Аварийный откат: останавливаю Docker и возвращаю native-службы.")
        cmd(["docker", "compose"] + profiles + ["down"], False, 600)
        for unit in reversed(stopped):
            cmd(["systemctl", "start", unit], False, 120)
        raise MigrationAbort("Переключение не завершено. Исходные файлы не удалялись; проверь логи.")


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (MigrationAbort, subprocess.TimeoutExpired) as error:
        print("\nОСТАНОВЛЕНО: {}".format(error), file=sys.stderr)
        sys.exit(1)
