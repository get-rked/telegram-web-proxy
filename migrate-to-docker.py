#!/usr/bin/env python3
"""Prepare a non-destructive migration of an existing native install into Docker."""
from __future__ import annotations
import argparse, hashlib, ipaddress, json, os, re, secrets, shutil, sys, tarfile, tempfile
from datetime import datetime, timezone
from pathlib import Path

REPO = Path(__file__).resolve().parent
DEFAULT_SOURCE = Path('/opt/telegram-web-proxy')
HEX_RE = re.compile(r'^(?:dd)?[0-9a-fA-F]{32}$')
NAME_RE = re.compile(r'^[A-Za-z0-9][A-Za-z0-9 _.-]{0,63}$')
MODES = {'https', 'https-lanes', 'websocket', 'websocket-lanes'}

class MigrationError(Exception): pass

def read_json(path: Path):
    try: return json.loads(path.read_text(encoding='utf-8'))
    except Exception as exc: raise MigrationError(f'Не удалось прочитать JSON {path}: {exc}')

def parse_env(path: Path):
    values = {}
    if not path.exists(): return values
    for line in path.read_text(encoding='utf-8').splitlines():
        line = line.strip()
        if not line or line.startswith('#') or '=' not in line: continue
        k, v = line.split('=', 1); k = k.strip(); v = v.strip()
        if len(v) >= 2 and v[0] == v[-1] and v[0] in "'\"": v = v[1:-1]
        if re.fullmatch(r'[A-Za-z_][A-Za-z0-9_]*', k): values[k] = v
    return values

def update_env_text(path: Path, updates: dict[str, str]):
    lines = path.read_text(encoding='utf-8').splitlines() if path.exists() else []
    seen = set(); output = []
    def render(value):
        if re.fullmatch(r'[A-Za-z0-9_./:@+-]+', value): return value
        return "'" + value.replace("'", "\\'") + "'"
    for line in lines:
        stripped = line.strip()
        if not stripped or stripped.startswith('#') or '=' not in line:
            output.append(line); continue
        key = line.split('=', 1)[0].strip()
        if key in updates:
            output.append(f'{key}={render(updates[key])}'); seen.add(key)
        else: output.append(line)
    for key, value in updates.items():
        if key not in seen: output.append(f'{key}={render(value)}')
    return ('\n'.join(output).rstrip() + '\n').encode()

def profile_list(source: Path):
    aggregate = source / 'config/proxy/profiles.json'
    profiles = None
    if aggregate.is_file():
        doc = read_json(aggregate)
        profiles = doc.get('profiles') if isinstance(doc, dict) else None
    if not isinstance(profiles, list) or not profiles:
        root = source / 'config/proxy/profiles'
        profiles = []
        if root.is_dir():
            for f in sorted(root.glob('*/profile.json')):
                profiles.append(read_json(f))
    if not isinstance(profiles, list) or not 1 <= len(profiles) <= 32:
        raise MigrationError('Не найден корректный profiles.json или индивидуальные файлы профилей (1–32).')
    names, canonical_secrets = set(), set()
    result = []
    for p in profiles:
        if not isinstance(p, dict): raise MigrationError('Запись профиля должна быть JSON-объектом.')
        name, secret, backend, mode = (p.get(k) for k in ('name','secret','backend','carrier_mode'))
        if not isinstance(name, str) or not NAME_RE.fullmatch(name): raise MigrationError(f'Недопустимое имя профиля: {name!r}')
        if name in names: raise MigrationError(f'Повтор имени профиля: {name}')
        if not isinstance(secret, str) or not HEX_RE.fullmatch(secret): raise MigrationError(f'Некорректный секрет профиля {name}.')
        canonical = secret[2:] if secret.lower().startswith('dd') else secret
        canonical = canonical.lower()
        if canonical in canonical_secrets: raise MigrationError(f'Повтор секрета у профиля {name}.')
        if not isinstance(backend, str) or ':' not in backend: raise MigrationError(f'Некорректный backend профиля {name}.')
        host, port = backend.rsplit(':', 1)
        try:
            if not ipaddress.ip_address(host).is_loopback or not 1 <= int(port) <= 65535: raise ValueError()
        except ValueError: raise MigrationError(f'Backend профиля {name} должен быть loopback IP:port.')
        if mode not in MODES: raise MigrationError(f'Некорректный carrier_mode профиля {name}.')
        names.add(name); canonical_secrets.add(canonical)
        result.append(dict(name=name, secret=secret, backend=backend, carrier_mode=mode))
    if 'default' not in names: raise MigrationError('В конфигурации отсутствует обязательный профиль default.')
    result.sort(key=lambda x: (x['name'] != 'default', x['name'].lower()))
    return result

def canonical_secret(s): return s[2:] if s.lower().startswith('dd') else s

def atomic_write(path: Path, data: bytes, mode=0o600):
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix='.' + path.name + '.', dir=path.parent)
    try:
        with os.fdopen(fd, 'wb') as f: f.write(data); f.flush(); os.fsync(f.fileno())
        os.chmod(tmp, mode); os.replace(tmp, path)
    finally:
        if os.path.exists(tmp): os.unlink(tmp)

def tree_manifest(root: Path):
    """Return a deterministic content manifest without following symlinks."""
    result = {".": ("dir",)}
    for current, dirs, files in os.walk(root, topdown=True, followlinks=False):
        current_path = Path(current)
        kept_dirs = []
        for name in sorted(dirs):
            path = current_path / name
            rel = path.relative_to(root).as_posix()
            if path.is_symlink():
                result[rel] = ("symlink", os.readlink(path))
            else:
                result[rel] = ("dir",)
                kept_dirs.append(name)
        dirs[:] = kept_dirs
        for name in sorted(files):
            path = current_path / name
            rel = path.relative_to(root).as_posix()
            if path.is_symlink():
                result[rel] = ("symlink", os.readlink(path))
            elif path.is_file():
                digest = hashlib.sha256()
                size = 0
                with path.open("rb") as stream:
                    for chunk in iter(lambda: stream.read(1024 * 1024), b""):
                        digest.update(chunk)
                        size += len(chunk)
                result[rel] = ("file", size, digest.hexdigest())
            else:
                raise MigrationError(f'Неподдерживаемый специальный файл в каталоге сайта: {path}')
    return result


def copy_tree_atomic(src: Path, dst: Path):
    if not src.is_dir():
        raise MigrationError(f'Каталог сайта не найден: {src}')
    dst.parent.mkdir(parents=True, exist_ok=True)
    source_manifest = tree_manifest(src)
    temp = Path(tempfile.mkdtemp(prefix='.site-migration-', dir=dst.parent))
    shutil.rmtree(temp)
    previous = None
    try:
        shutil.copytree(src, temp, symlinks=True)
        copied_manifest = tree_manifest(temp)
        if copied_manifest != source_manifest:
            raise MigrationError('Контрольная сумма или структура копии сайта не совпадает с источником.')
        if dst.exists() or dst.is_symlink():
            stamp = datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%S.%fZ')
            previous = dst.with_name(dst.name + '.before-migration.' + stamp)
            suffix = 1
            while previous.exists() or previous.is_symlink():
                previous = dst.with_name(dst.name + f'.before-migration.{stamp}.{suffix}')
                suffix += 1
            os.replace(dst, previous)
        os.replace(temp, dst)
        if tree_manifest(dst) != source_manifest:
            failed = dst.with_name(dst.name + '.failed-migration.' +
                                   datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%S.%fZ'))
            os.replace(dst, failed)
            if previous is not None:
                os.replace(previous, dst)
            raise MigrationError(
                f'Проверка сайта после установки не пройдена; новая копия сохранена в {failed}.'
            )
        if previous is not None:
            print(f'Предыдущий каталог сайта сохранён без удаления: {previous}')
    except Exception:
        if temp.exists():
            shutil.rmtree(temp)
        if previous is not None and previous.exists() and not dst.exists():
            os.replace(previous, dst)
        raise


def verify_backup(archive: Path):
    """Read every archived regular file so gzip/tar corruption is detected."""
    with tarfile.open(archive, 'r:gz') as tar:
        members = tar.getmembers()
        if not members:
            raise MigrationError('Резервная копия пуста.')
        for member in members:
            if member.isfile():
                stream = tar.extractfile(member)
                if stream is None:
                    raise MigrationError(f'Не удалось прочитать файл из резервной копии: {member.name}')
                while stream.read(1024 * 1024):
                    pass
    digest = hashlib.sha256()
    with archive.open('rb') as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b''):
            digest.update(chunk)
    checksum = archive.with_suffix(archive.suffix + '.sha256')
    atomic_write(checksum, (digest.hexdigest() + '  ' + archive.name + '\n').encode(), 0o600)
    return checksum


def backup_paths(paths, backup_root: Path):
    backup_root.mkdir(parents=True, exist_ok=True)
    os.chmod(backup_root, 0o700)
    stamp = datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%S.%fZ')
    archive = backup_root / f'docker-migration-{stamp}.tar.gz'
    with tarfile.open(archive, 'w:gz') as tar:
        for path in paths:
            if path.exists() or path.is_symlink():
                tar.add(path, arcname=str(path).lstrip('/'))
    os.chmod(archive, 0o600)
    verify_backup(archive)
    return archive

def nginx_certificates(repo: Path, domain: str):
    conf = Path('/etc/nginx/sites-available/tproxy-server')
    if not conf.is_file(): raise MigrationError('Выбран Nginx, но /etc/nginx/sites-available/tproxy-server не найден.')
    text = conf.read_text(errors='replace')
    cert = re.search(r'^\s*ssl_certificate\s+([^;]+);', text, re.M)
    key = re.search(r'^\s*ssl_certificate_key\s+([^;]+);', text, re.M)
    if not cert or not key: raise MigrationError('Не удалось найти ssl_certificate и ssl_certificate_key в конфигурации Nginx.')
    cert_path, key_path = Path(cert.group(1).strip()), Path(key.group(1).strip())
    if not cert_path.is_file() or not key_path.is_file(): raise MigrationError('Файлы TLS-сертификата Nginx не найдены.')
    target = repo / 'docker/nginx/certs'
    return [(cert_path, target / 'fullchain.pem', 0o644), (key_path, target / 'privkey.pem', 0o600)]

def main():
    ap = argparse.ArgumentParser(description='Перенос существующей native-конфигурации Telegram Web Proxy в Docker.')
    ap.add_argument('--source-dir', type=Path, default=DEFAULT_SOURCE)
    ap.add_argument('--web-server', choices=('caddy','nginx'))
    ap.add_argument('--apply', action='store_true', help='Выполнить перенос. Без этого флага работает только проверка.')
    args = ap.parse_args()
    if os.geteuid() != 0:
        raise MigrationError('Запусти скрипт от root: sudo python3 migrate-to-docker.py')
    source, repo = args.source_dir.resolve(), REPO
    config_src = source / 'config/proxy/config.json'
    if not config_src.is_file(): raise MigrationError(f'Не найден файл действующей конфигурации: {config_src}')
    config = read_json(config_src)
    if not isinstance(config, dict): raise MigrationError('config.json должен содержать JSON-объект.')
    if config.get('public_upstream'):
        raise MigrationError('Включён public_upstream. Автоматический перенос локального upstream в Docker не поддерживается; сначала нужно отдельно спроектировать его подключение.')
    domain = str(config.get('public_hostname', '')).strip().lower()
    if not domain or '/' in domain or any(c.isspace() for c in domain): raise MigrationError('В config.json отсутствует корректный public_hostname.')
    profiles = profile_list(source)
    mt_env = parse_env(source / 'config/mtproxy/mtproxy.env')
    env_path = repo / '.env'; env = parse_env(env_path)
    if env.get('DOMAIN') and env['DOMAIN'].lower() != domain:
        raise MigrationError(f'DOMAIN в .env ({env["DOMAIN"]}) не совпадает с public_hostname ({domain}).')
    web_file = source / 'config/proxy/web-server'
    selected = args.web_server or (web_file.read_text().strip().lower() if web_file.exists() else 'caddy')
    if selected not in ('caddy','nginx'): raise MigrationError(f'Неизвестный текущий веб-сервер: {selected}')
    email_file = source / 'config/proxy/acme-email'
    email = env.get('ACME_EMAIL') or (email_file.read_text().strip() if email_file.exists() else '')
    if not email: raise MigrationError('Не найден ACME_EMAIL: проверь .env или config/proxy/acme-email.')
    if mt_env.get('MTPROXY_SECRETS'):
        found = {canonical_secret(x).lower() for x in re.findall(r'(?:dd)?[0-9a-fA-F]{32}', mt_env['MTPROXY_SECRETS'])}
        expected = {canonical_secret(p['secret']).lower() for p in profiles}
        if found and found != expected: raise MigrationError('MTPROXY_SECRETS в mtproxy.env не совпадает с секретами profiles.json; автоматический перенос остановлен.')
    site_path = Path(config.get('public_dir') or source / 'data/website')
    if not site_path.is_absolute(): site_path = source / site_path
    if not site_path.is_dir(): raise MigrationError(f'Каталог сайта из config.json не найден: {site_path}')
    token_src = source / 'config/proxy/token.key'
    if not token_src.is_file():
        alt = Path('/etc/tproxy-server/token.key')
        if alt.is_file(): token_src = alt
    token_data = token_src.read_bytes() if token_src.is_file() else secrets.token_bytes(32)
    if len(token_data) != 32: raise MigrationError(f'token.key должен содержать ровно 32 байта: {token_src}')
    listen = config.get('listen', '127.0.0.1:8080')
    if not isinstance(listen, str) or ':' not in listen:
        raise MigrationError('Поле listen должно содержать loopback IP и TCP-порт.')
    listen_host, listen_port = listen.rsplit(':', 1)
    try:
        if not ipaddress.ip_address(listen_host.strip('[]')).is_loopback or not 1 <= int(listen_port) <= 65535:
            raise ValueError()
    except ValueError:
        raise MigrationError('Поле listen должно содержать loopback IP и допустимый TCP-порт.')
    config.update(public_hostname=domain, admin_listen='127.0.0.1:8081', public_dir='/srv/tproxy-site', token_key_file='/etc/tproxy-server/token.key')
    config.pop('profiles_file', None)
    nat_info = ''
    nat_args = mt_env.get('MTPROXY_NAT_ARGS', '').strip()
    if nat_args:
        match = re.fullmatch(r'--nat-info\s+([0-9.]+):([0-9.]+)', nat_args)
        if not match:
            raise MigrationError('MTPROXY_NAT_ARGS имеет неизвестный формат; автоматический перенос NAT-параметров остановлен.')
        try:
            nat_info = f'{ipaddress.IPv4Address(match.group(1))}:{ipaddress.IPv4Address(match.group(2))}'
        except ipaddress.AddressValueError:
            raise MigrationError('MTPROXY_NAT_ARGS содержит некорректные IPv4-адреса.')
    generated_panel_password = len(env.get('PANEL_PASSWORD', '')) < 16 or env.get('PANEL_PASSWORD', '').startswith('replace-with-')
    env.update(DOMAIN=domain, ACME_EMAIL=email, PANEL_USER=env.get('PANEL_USER','admin'), PANEL_PASSWORD=env.get('PANEL_PASSWORD') if len(env.get('PANEL_PASSWORD', '')) >= 16 and not env.get('PANEL_PASSWORD', '').startswith('replace-with-') else secrets.token_urlsafe(24), MTPROXY_WORKERS=mt_env.get('MTPROXY_WORKERS','1'), MTPROXY_MAX_CONNECTIONS=mt_env.get('MTPROXY_MAX_CONNECTIONS','4096'))
    if not re.fullmatch(r'[1-9][0-9]*', env['MTPROXY_WORKERS']): env['MTPROXY_WORKERS']='1'
    if not re.fullmatch(r'[1-9][0-9]*', env['MTPROXY_MAX_CONNECTIONS']):
        raise MigrationError('MTPROXY_MAX_CONNECTIONS в mtproxy.env должен быть положительным целым числом.')
    env_updates = {'DOMAIN': domain, 'ACME_EMAIL': email, 'PANEL_USER': env['PANEL_USER'], 'PANEL_PASSWORD': env['PANEL_PASSWORD'], 'TPROXY_LISTEN': listen, 'MTPROXY_WORKERS': env['MTPROXY_WORKERS'], 'MTPROXY_MAX_CONNECTIONS': env['MTPROXY_MAX_CONNECTIONS'], 'MTPROXY_NAT_INFO': nat_info}
    env_text = update_env_text(env_path, env_updates).decode()
    outputs = [
        (repo/'docker/config/config.json', (json.dumps(config, indent=2)+'\n').encode(), 0o600),
        (repo/'docker/config/token.key', token_data, 0o600),
        (repo/'docker/profiles/profiles.json', (json.dumps({'profiles':profiles}, indent=2)+'\n').encode(), 0o600),
        (repo/'docker/mtproxy/secret', ('\n'.join(canonical_secret(p['secret']).lower() for p in profiles)+'\n').encode(), 0o600),
        (env_path, env_text.encode(), 0o600),
    ]
    certs = nginx_certificates(repo, domain) if selected == 'nginx' else []
    site_previous = repo/'docker/site.before-migration'
    if site_previous.exists():
        raise MigrationError(f'Остался предыдущий каталог миграции: {site_previous}; проверь его вручную.')
    backup_root = Path('/var/backups/telegram-web-proxy-docker-migration')
    backup_candidates = [source/'config/proxy', source/'config/mtproxy', site_path, env_path, repo/'docker/config', repo/'docker/profiles', repo/'docker/mtproxy/secret', repo/'docker/site', repo/'docker/nginx/certs'] + [src for src, _, _ in certs]
    print(f'Источник: {source}')
    print(f'Домен: {domain}; reverse proxy: {selected}; профилей: {len(profiles)}')
    print('Будут подготовлены: docker/config/config.json, token.key, docker/profiles/profiles.json, docker/mtproxy/secret, docker/site и .env' + ('; Nginx TLS files' if certs else ''))
    print('Секреты профилей сохраняются; префикс dd сохраняется в profiles.json и снимается только в MTProxy secret file.')
    print('Нативные службы и исходные файлы скрипт НЕ останавливает и НЕ изменяет.')
    if not args.apply:
        print('DRY-RUN: проверка пройдена. Для выполнения добавь --apply.')
        return 0
    archive = backup_paths(backup_candidates, backup_root)
    for path, data, mode in outputs: atomic_write(path, data, mode)
    for src, dst, mode in certs:
        atomic_write(dst, src.read_bytes(), mode)
    copy_tree_atomic(site_path, repo/'docker/site')
    print(f'Резервная копия: {archive}')
    print('Миграция подготовлена. Нативные службы всё ещё работают.')
    print('Перед запуском Docker останови native Caddy/Nginx и MTProxy/tproxy-server, чтобы не было конфликта портов и двух экземпляров backend.')
    if generated_panel_password:
        print('Создан новый пароль панели (сохрани его сейчас): PANEL_USER=' + env['PANEL_USER'] + ' PANEL_PASSWORD=' + env['PANEL_PASSWORD'])
    else:
        print('Существующие учётные данные панели сохранены в .env.')
    print('Далее запускай только один профиль reverse proxy и профиль MTProxy согласно docker/README.md.')
    return 0

if __name__ == '__main__':
    try: raise SystemExit(main())
    except MigrationError as exc:
        print(f'migrate-to-docker: ERROR: {exc}', file=sys.stderr); raise SystemExit(1)
