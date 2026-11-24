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


def compose(args, check=True, timeout=1800, show=False):
    command = [
        "docker", "compose",
        "--project-directory", str(ROOT),
        "--project-name", "telegram-web-proxy",
        "-f", str(ROOT / "docker-compose.yml"),
    ] + list(args)
    return cmd(command, check=check, timeout=timeout, show=show)


def active(unit):
    return cmd(["systemctl", "is-active", "--quiet", unit], False)[1] == 0


def running_project_containers():
    """Inspect Docker labels directly; Compose config may require the not-yet-created .env."""
    output, rc = cmd([
        "docker", "ps",
        "--filter", "label=com.docker.compose.project=telegram-web-proxy",
        "--format", "{{.Names}}",
    ], False)
    if rc:
        raise MigrationAbort("Не удалось проверить работающие контейнеры Docker: " + output)
    return [line.strip() for line in output.splitlines() if line.strip()]


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


def caddy_site_names(caddyfile_text):
    """Return only top-level Caddy site labels, ignoring global and nested directives."""
    names = set()
    depth = 0
    for raw_line in caddyfile_text.splitlines():
        line = raw_line.split("#", 1)[0].strip()
        if not line:
            continue
        # Environment placeholders contain braces but are not Caddy block delimiters.
        structural = re.sub(r"\{\$[^}]+\}", "", line)
        if depth == 0 and "{" in structural:
            address = structural.split("{", 1)[0].strip()
            # Parenthesized top-level blocks are named snippets, not site addresses.
            if address and not address.startswith("("):
                for item in address.split(","):
                    item = item.strip().lower()
                    if item:
                        names.add(item)
        depth += structural.count("{") - structural.count("}")
        if depth < 0:
            raise MigrationAbort("Некорректная структура блоков в Caddyfile.")
    if depth != 0:
        raise MigrationAbort("Незакрытый блок в Caddyfile; безопасная проверка невозможна.")
    return names


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
            text = f.read_text(errors="ignore")
            if re.search(r"(?m)^\s*import\s+", text):
                raise MigrationAbort(
                    "В Caddyfile найден import. Автоматическая проверка подключаемых конфигураций "
                    "не поддерживается; проверь их вручную перед остановкой Caddy."
                )
            names = caddy_site_names(text)
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
    security, info_rc = cmd(["docker", "info", "--format", "{{json .SecurityOptions}}"], False)
    if info_rc:
        raise MigrationAbort("Docker daemon не запущен или недоступен текущему пользователю.")
    existing = running_project_containers()
    if existing:
        raise MigrationAbort("В этом Docker-проекте уже работают контейнеры: " + ", ".join(existing) +
                             ". Сначала разберись с существующим запуском; автоматическая миграция остановлена.")
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
    compose(profiles + ["config", "--quiet"])
    compose(profiles + ["build"], timeout=3600, show=True)

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
        compose(profiles + ["up", "-d"], timeout=1800, show=True)
        required = {"relay", "panel", "fail2ban", "mtproxy", "mtproxy-firewall", proxy}
        deadline = time.time() + 240
        service_states = {}
        while time.time() < deadline:
            ids, ids_rc = compose(["ps", "-q", "--all"], False)
            service_states = {}
            if ids_rc == 0 and ids.strip():
                inspected, inspect_rc = cmd([
                    "docker", "inspect", *ids.split(),
                    "--format",
                    '{{index .Config.Labels "com.docker.compose.service"}}|{{.State.Status}}|{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}'
                ], False)
                if inspect_rc == 0:
                    for line in inspected.splitlines():
                        parts = line.split("|", 2)
                        if len(parts) == 3 and parts[0]:
                            service_states[parts[0]] = (parts[1].lower(), parts[2].lower())

            ready = all(
                name in service_states
                and service_states[name][0] == "running"
                and service_states[name][1] in ("none", "healthy")
                for name in required
            )
            if ready:
                break
            time.sleep(5)

        status, _ = compose(["ps", "-a"], False)
        print(status)
        not_ready = sorted(
            name for name in required
            if name not in service_states
            or service_states[name][0] != "running"
            or service_states[name][1] not in ("none", "healthy")
        )
        if not_ready:
            print("\nДиагностика неготовых сервисов:")
            for name in not_ready:
                state = service_states.get(name, ("missing", "unknown"))
                print("  {}: state={}, health={}".format(name, state[0], state[1]))
                logs, _ = compose(["logs", "--no-color", "--tail=100", name], False)
                if logs:
                    print(logs)
            raise MigrationAbort("Не готовы обязательные сервисы: " + ", ".join(not_ready))
        _, rc = cmd(["iptables", "-S", "DOCKER-USER"], False)
        if rc:
            raise MigrationAbort("Не создана цепочка DOCKER-USER: Fail2ban не сможет блокировать Docker-трафик.")
        domain = json.loads((source / "config/proxy/config.json").read_text()).get("public_hostname", "")
        if shutil.which("curl"):
            auth_path = ROOT / "docker/private/panel-auth.json"
            try:
                panel_base_path = json.loads(auth_path.read_text()).get("base_path", "")
            except (OSError, json.JSONDecodeError) as error:
                raise MigrationAbort("Не удалось прочитать сгенерированный Base Path панели: {}".format(error))
            if not isinstance(panel_base_path, str) or not panel_base_path.startswith("/panel-"):
                raise MigrationAbort("Bootstrap не создал корректный приватный Base Path панели.")
            url = "https://{}{}{}/".format(domain, panel_base_path, "" )
            code = ""
            for attempt in range(12):
                code, _ = cmd(["curl", "-k", "-sS", "-o", "/dev/null", "-w", "%{http_code}",
                               "--max-time", "10", "--resolve", "{}:443:127.0.0.1".format(domain), url], False)
                if code in ("200", "301", "302"):
                    break
                time.sleep(5)
            if code not in ("200", "301", "302"):
                raise MigrationAbort("Панель не отвечает по сгенерированному Base Path через HTTPS (HTTP {}).".format(code or "нет ответа"))
            print("Панель: HTTP " + code + " ({})".format(url))
            web_url = "https://{}/".format(domain)
            web_code = ""
            for attempt in range(12):
                web_code, _ = cmd([
                    "curl", "-k", "-sS", "-o", "/dev/null", "-w", "%{http_code}",
                    "--max-time", "10", "--resolve", "{}:443:127.0.0.1".format(domain), web_url
                ], False)
                if web_code in ("200", "301", "302"):
                    break
                time.sleep(5)
            if web_code not in ("200", "301", "302"):
                proxy_logs, _ = compose(["logs", "--no-color", "--tail=80", proxy, "relay"], False)
                if proxy_logs:
                    print("\nЛоги reverse proxy и relay:\n" + proxy_logs)
                raise MigrationAbort(
                    "Web Proxy не отвечает через HTTPS (HTTP {}). Проверка upstream не пройдена.".format(
                        web_code or "нет ответа"
                    )
                )
            print("Web Proxy: HTTP " + web_code + " ({})".format(web_url))
        print("\nDocker-миграция запущена. Проверь Web Proxy и MTProxy с внешнего устройства.")
        return 0
    except Exception as error:
        print("\nОшибка переключения: {}".format(error))
        print("Аварийный откат: останавливаю Docker и возвращаю native-службы.")
        compose(profiles + ["down"], False, 600)
        for unit in reversed(stopped):
            cmd(["systemctl", "start", unit], False, 120)
        raise MigrationAbort("Переключение не завершено. Исходные файлы не удалялись; проверь логи.")


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (MigrationAbort, subprocess.TimeoutExpired) as error:
        print("\nОСТАНОВЛЕНО: {}".format(error), file=sys.stderr)
        sys.exit(1)
