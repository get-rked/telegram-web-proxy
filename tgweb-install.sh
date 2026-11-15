#!/usr/bin/env bash
# ============================================================================
#  tproxy-manager.sh — установка / обновление / удаление tproxy-server
#
#  Usage:
#    sudo ./tproxy-manager.sh                  # интерактивное меню
#    sudo ./tproxy-manager.sh install [опции]  # установка
#    sudo ./tproxy-manager.sh update  [опции]  # обновление (skip-tests, не трогает сайт)
#    sudo ./tproxy-manager.sh uninstall [--keep-web-server] [--yes]
#    sudo ./tproxy-manager.sh purge     [--yes]
# ============================================================================
set -Eeuo pipefail
trap 'if [[ -z "${NO_COLOR:-}" && "${TERM:-}" != "dumb" ]]; then printf "\\033[1;31m❌ ERROR\\033[0m at line %s: %s\\n" "$LINENO" "$BASH_COMMAND" >&2; else printf "❌ ERROR at line %s: %s\\n" "$LINENO" "$BASH_COMMAND" >&2; fi' ERR
umask 077

# ----------------------------- константы ------------------------------------
readonly REPO_URL="https://github.com/telegramdesktop/tproxy-server.git"
readonly UPSTREAM_COMMIT="c8adb8b7c6b7fc46c12ae3acb68be9070c26a8e8"
readonly REPO_DIR="/opt/tproxy-server"
readonly SITE_DIR_DEFAULT="/srv/tproxy-site"
readonly GO_FALLBACK_VERSION="1.26.5"
readonly GO_FALLBACK_SHA256="5c2c3b16caefa1d968a94c1daca04a7ca301a496d9b086e17ad77bb81393f053"
readonly CADDY_VERSION="2.11.4"
readonly MTPROXY_COMMIT="f36d8af769ffaeac36978d38c2c0f6d1104c2137"
readonly CADDY_SHA512="8220d1f013b6f27510247b2360c9e0ca9f018feebd82515f07635318b34ff9777ccc8fd0b6e6f2486ce3a33fe389fbb7db12d05baa474f4587509fb4f5ebf1c9"
readonly NGINX_SITE="/etc/nginx/sites-available/tproxy-server"
readonly NGINX_ENABLED="/etc/nginx/sites-enabled/tproxy-server"
readonly NGINX_MAP="/etc/nginx/conf.d/tproxy-websocket-map.conf"
readonly ACME_WEBROOT="/var/www/letsencrypt"
readonly DEFAULT_PORT=8080
readonly DEFAULT_ADMIN_PORT=8081
readonly SCRIPT_VERSION="1.0.1"

# ----------------------------- переменные -----------------------------------
MODE=""
WEB_SERVER="caddy"
WEB_SERVER_SET=0
KEEP_WEB_SERVER=0
HOSTNAME_ARG=""
EMAIL_ARG=""
SECRET_ARG=""
SECRET_PREFIX_MODE="plain"
SECRET_PREFIX_MODE_SET=0
BASE_PATH_ARG=""
SITE_DIR="$SITE_DIR_DEFAULT"
INSTALL_SITE=1
WORKERS_ARG=""
MAXCONN_ARG=""
NONINTERACTIVE="${NONINTERACTIVE:-0}"
RELAY_PORT=""
ADMIN_PORT=""
SKIP_TESTS="${SKIP_TESTS:-0}"
KEEP_WEB_SERVER=0
ASSUME_YES=0
GO_BIN=""

# ----------------------------- утилиты --------------------------------------
# Цветные статусы: цвет применяется только к ключу, текст сообщения не меняется.
# Для отключения цветов: NO_COLOR=1 ./tgweb-install.sh
die() {
  if [[ -z "${NO_COLOR:-}" && "${TERM:-}" != "dumb" ]]; then
    printf '\033[1;31m[ОШИБКА]\033[0m %s\n' "$*" >&2
  else
    printf '[ОШИБКА] %s\n' "$*" >&2
  fi
  exit 1
}
info() {
  if [[ -z "${NO_COLOR:-}" && "${TERM:-}" != "dumb" ]]; then
    printf '\033[1;34m[ИНФО]\033[0m %s\n' "$*"
  else
    printf '[ИНФО] %s\n' "$*"
  fi
}
ok() {
  if [[ -z "${NO_COLOR:-}" && "${TERM:-}" != "dumb" ]]; then
    printf '\033[1;32m[OK]\033[0m %s\n' "$*"
  else
    printf '[OK] %s\n' "$*"
  fi
}
warn() {
  if [[ -z "${NO_COLOR:-}" && "${TERM:-}" != "dumb" ]]; then
    printf '\033[1;33m[ВНИМАНИЕ]\033[0m %s\n' "$*" >&2
  else
    printf '[ВНИМАНИЕ] %s\n' "$*" >&2
  fi
}

# Цветные маркеры результатов проверок и состояний systemd.
status_mark() {
  local kind="$1" mark
  case "$kind" in
    ok) mark='[✓]' ;;
    fail) mark='[✗]' ;;
    warn) mark='[!]' ;;
    *) mark='[•]' ;;
  esac
  if [[ -z "${NO_COLOR:-}" && "${TERM:-}" != "dumb" ]]; then
    case "$kind" in
      ok) printf '\033[1;32m%s\033[0m' "$mark" ;;
      fail) printf '\033[1;31m%s\033[0m' "$mark" ;;
      warn) printf '\033[1;33m%s\033[0m' "$mark" ;;
      *) printf '\033[1;34m%s\033[0m' "$mark" ;;
    esac
  else
    printf '%s' "$mark"
  fi
}
status_word() {
  local state="$1"
  if [[ -z "${NO_COLOR:-}" && "${TERM:-}" != "dumb" ]]; then
    case "$state" in
      active) printf '\033[1;32m%s\033[0m' "$state" ;;
      inactive|failed) printf '\033[1;31m%s\033[0m' "$state" ;;
      *) printf '\033[1;33m%s\033[0m' "$state" ;;
    esac
  else
    printf '%s' "$state"
  fi
}

usage() {
  cat <<'EOF'
Usage:
  sudo ./tproxy-manager.sh                          # интерактивное меню
  sudo ./tproxy-manager.sh install   [опции установки]
  sudo ./tproxy-manager.sh update    [опции установки]
  sudo ./tproxy-manager.sh uninstall [--keep-caddy] [--yes]
  sudo ./tproxy-manager.sh purge     [--yes]

Опции установки/обновления:
  --hostname FQDN           Домен
  --web-server caddy|nginx  Веб-сервер (по умолчанию: caddy)
  --email EMAIL             Email для Let's Encrypt
  --secret SECRET           32 hex или dd + 32 hex
  --secret-prefix MODE       plain или dd (формат генерации)
  config [--output PATH]     Показать текущие настройки (секреты скрыты)
  diagnostics                Диагностика: службы, порты, конфигурации и ошибки
  backup [ABSOLUTE_PATH]     Резервная копия конфигураций
  restore ABSOLUTE_PATH      Восстановить конфигурации из архива
  --base-path SLUG|none     Базовый путь (default: генерируется)
  --site-dir PATH           Каталог сайта (default: /srv/tproxy-site)
  --no-site                 Не устанавливать сайт
  --workers N               MTProxy workers (default: 1)
  --max-connections N       MTProxy max connections (default: 4096)
  --port N                  Порт relay (default: 8080)
  --admin-port N            Admin-порт relay (default: 8081)
  --skip-tests              Не запускать go test
  --non-interactive, -y     Ничего не спрашивать
EOF
  return 0
}

# ----------------------------- валидаторы -----------------------------------
validate_hostname() {
  local h="$1"
  if [[ -z "$h" ]]; then echo "пусто"; return 1; fi
  if [[ ! "$h" =~ ^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$ ]] || [[ "$h" != *.* ]]; then
    echo "hostname должен быть lowercase ASCII DNS с точкой"; return 1
  fi
  return 0
}

validate_email() {
  local e="$1"
  if [[ "$e" =~ ^[A-Za-z0-9._+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]]; then return 0
  else echo "некорректный email"; return 1; fi
}

validate_secret() {
  local s="$1"
  if [[ "$s" =~ ^([0-9a-f]{32}|dd[0-9a-f]{32})$ ]]; then return 0
  else echo "секрет: 32 lowercase hex, опционально с префиксом dd"; return 1; fi
}

validate_port() {
  local p="$1"
  if ! [[ "$p" =~ ^[0-9]+$ ]]; then echo "порт должен быть числом"; return 1; fi
  if ! (( p >= 1024 && p <= 65535 )); then echo "порт должен быть 1024..65535"; return 1; fi
  return 0
}

validate_base_path() {
  local b="$1"
  if [[ "$b" == "none" ]]; then return 0; fi
  if [[ ! "$b" =~ ^[A-Za-z0-9][A-Za-z0-9_-]*(/[A-Za-z0-9][A-Za-z0-9_-]*)*$ ]]; then
    echo "base path: сегменты [A-Za-z0-9][A-Za-z0-9_-]*, разделитель /"; return 1
  fi
  if (( ${#b} > 128 )); then echo "base path ≤ 128 символов"; return 1; fi
  return 0
}

# ----------------------------- занятость портов -----------------------------
port_in_use()  { ss -lntp "sport = :$1" 2>/dev/null | grep -q LISTEN; }
port_owner()   { ss -lntp "sport = :$1" 2>/dev/null | awk 'NR>1{print $NF}' | head -n1; }
find_free_port() {
  local base="$1" p
  for (( p=base; p<base+200; p++ )); do
    if ! port_in_use "$p"; then echo "$p"; return 0; fi
  done
  return 1
}

# ----------------------------- интерактив -----------------------------------
prompt_value() {
  local __var="$1" label="$2" validator="$3"
  local input err
  while :; do
    read -r -p "$label: " input || die "ввод прерван"
    if [[ -z "$input" ]]; then echo "  ⚠️  обязательно"; continue; fi
    if err="$("$validator" "$input")"; then
      printf -v "$__var" '%s' "$input"; return 0
    else
      echo "  ⚠️  $err — попробуй ещё раз"
    fi
  done
}

prompt_port() {
  local var="$1" label="$2" default="$3"
  local input err
  while :; do
    read -r -p "$label [$default]: " input || die "ввод прерван"
    input="${input:-$default}"
    if ! err="$(validate_port "$input")"; then
      echo "  ⚠️  $err"; continue
    fi
    if port_in_use "$input"; then
      local owner alt
      owner="$(port_owner "$input")"
      alt="$(find_free_port "$input" || true)"
      echo "  ⚠️  порт $input занят${owner:+ ($owner)}"
      if [[ -n "$alt" ]]; then echo "      свободный рядом: $alt"; fi
      continue
    fi
    printf -v "$var" '%s' "$input"; return 0
  done
}

confirm() {
  local q="$1" ans
  if [[ "$ASSUME_YES" -eq 1 ]]; then return 0; fi
  read -r -p "$q [Y/n]: " ans || die "ввод прерван"
  ans="${ans:-Y}"
  if [[ "$ans" =~ ^[YyДд] ]]; then return 0; else return 1; fi
}

prompt_secret() {
  if [[ -n "$SECRET_ARG" ]]; then return 0; fi
  local choice format_choice
  echo
  echo "Секрет MTProxy — 32 hex (16 байт), можно с префиксом dd."
  if [[ "$SECRET_PREFIX_MODE_SET" -eq 0 ]]; then
    local default_choice=1
    [[ "$SECRET_PREFIX_MODE" == "dd" ]] && default_choice=2
    read -r -p "Формат секрета: [1] обычный  [2] dd-префикс: " format_choice
    case "${format_choice:-$default_choice}" in
      1) SECRET_PREFIX_MODE="plain" ;;
      2) SECRET_PREFIX_MODE="dd" ;;
      *) die "Выбери 1 или 2" ;;
    esac
  fi
  while :; do
    read -r -p "Сгенерировать? [Y] / ввести свой [n]: " choice
    choice="${choice:-Y}"
    if [[ "$choice" =~ ^[YyДд] ]]; then
      SECRET_ARG="$(openssl rand -hex 16)"
      [[ "$SECRET_PREFIX_MODE" == "dd" ]] && SECRET_ARG="dd${SECRET_ARG}"
      info "Секрет: $SECRET_ARG"
      return 0
    fi
    local s1 s2
    read -r -s -p "Секрет: " s1; echo
    read -r -s -p "Повтор: " s2; echo
    if [[ "$s1" != "$s2" ]]; then echo "  ⚠️  не совпало"; continue; fi
    if ! [[ "$s1" =~ ^([0-9a-f]{32}|dd[0-9a-f]{32})$ ]]; then
      echo "  ⚠️  32 hex (опционально dd-префикс)"; continue
    fi
    SECRET_ARG="$s1"; return 0
  done
}

interactive_fill() {
  local input err
  if [[ "$NONINTERACTIVE" == "1" ]]; then
    [[ -n "$HOSTNAME_ARG" ]] || die "--hostname обязателен в non-interactive"
    [[ -n "$EMAIL_ARG" ]] || die "--email обязателен в non-interactive"
    [[ -n "$RELAY_PORT" ]] || die "--port обязателен в non-interactive"
    [[ -n "$ADMIN_PORT" ]] || die "--admin-port обязателен в non-interactive"
    WORKERS_ARG="${WORKERS_ARG:-1}"
    MAXCONN_ARG="${MAXCONN_ARG:-4096}"
    if [[ -z "$SECRET_ARG" ]]; then
      SECRET_ARG="$(openssl rand -hex 16)"
      [[ "$SECRET_PREFIX_MODE" == "dd" ]] && SECRET_ARG="dd${SECRET_ARG}"
    fi
    validate_secret "$SECRET_ARG" >/dev/null || die "невалидный секрет"
    return 0
  fi

  echo
  echo "────────────────────────────────────────────────────────────"
  echo "  Установка tproxy-server"
  echo "  Обязательные параметры нужно заполнить; Enter у остальных"
  echo "  оставляет значение по умолчанию."
  echo "────────────────────────────────────────────────────────────"

  if [[ "$WEB_SERVER_SET" -eq 0 ]]; then
    echo "Веб-сервер: [1] Caddy (по умолчанию)  [2] Nginx"
    read -r -p "Выбор [1-2]: " input || die "ввод прерван"
    case "${input:-1}" in 1) WEB_SERVER=caddy ;; 2) WEB_SERVER=nginx ;; *) die "Выбери 1 или 2" ;; esac
  fi

  while :; do
    read -r -p "Домен (A-запись должна вести на IP адрес сервера): " input || die "ввод прерван"
    [[ -n "$input" ]] || { echo "  ⚠️  Укажи доменное имя"; continue; }
    if err="$(validate_hostname "$input")"; then HOSTNAME_ARG="$input"; break; fi
    echo "  ⚠️  $err"
  done

  while :; do
    read -r -p "Email для Let's Encrypt: " input || die "ввод прерван"
    [[ -n "$input" ]] || { echo "  ⚠️  Укажи email"; continue; }
    if err="$(validate_email "$input")"; then EMAIL_ARG="$input"; break; fi
    echo "  ⚠️  $err"
  done

  read -r -p "Base path [автоматически] (none — использовать корень домена): " input || die "ввод прерван"
  if [[ -n "$input" ]]; then
    validate_base_path "$input" >/dev/null || die "Некорректный base path"
    BASE_PATH_ARG="$input"
  fi

  echo
  echo "Внутренний порт приложения — на нём tproxy-server принимает запросы"
  echo "от локального веб-сервера. Обычно менять его не требуется."
  prompt_port RELAY_PORT "Порт приложения" "${DEFAULT_PORT}"

  echo
  echo "Служебный порт для проверки состояния приложения (health check)."
  prompt_port ADMIN_PORT "Порт проверки состояния" "${DEFAULT_ADMIN_PORT}"
  [[ "$ADMIN_PORT" == "$RELAY_PORT" ]] && die "Порт проверки состояния совпадает с портом приложения"

  prompt_secret

  WORKERS_ARG="${WORKERS_ARG:-1}"
  MAXCONN_ARG="${MAXCONN_ARG:-4096}"
  while :; do
    read -r -p "Количество MTProxy workers [$WORKERS_ARG]: " input || die "ввод прерван"
    input="${input:-$WORKERS_ARG}"
    if [[ "$input" =~ ^[1-9][0-9]*$ ]] && (( input <= 256 )); then WORKERS_ARG="$input"; break; fi
    echo "  ⚠️  workers должен быть числом от 1 до 256"
  done
  while :; do
    read -r -p "MTProxy max-connections [$MAXCONN_ARG]: " input || die "ввод прерван"
    input="${input:-$MAXCONN_ARG}"
    if [[ "$input" =~ ^[1-9][0-9]*$ ]]; then MAXCONN_ARG="$input"; break; fi
    echo "  ⚠️  max-connections должен быть положительным числом"
  done

  echo
  echo "Итоговые параметры установки:"
  echo "  Домен                    : $HOSTNAME_ARG"
  echo "  Email                    : $EMAIL_ARG"
  echo "  Base path                : ${BASE_PATH_ARG:-автоматически}"
  echo "  Порт приложения          : $RELAY_PORT"
  echo "  Порт проверки состояния  : $ADMIN_PORT"
  echo "  Секрет                   : ${SECRET_ARG:0:8}…${SECRET_ARG: -4}"
  echo "  Workers                  : $WORKERS_ARG"
  echo "  Max connections          : $MAXCONN_ARG"
  echo "  Каталог сайта            : $SITE_DIR"
  echo "────────────────────────────────────────────────────────────"
  confirm "Начать установку?" || die "установка отменена"
}
# ----------------------------- парсер флагов --------------------------------
parse_install_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --hostname)        [[ $# -ge 2 ]] || die "--hostname требует значение"; HOSTNAME_ARG="$2"; shift 2 ;;
      --web-server)      [[ $# -ge 2 ]] || die "--web-server требует caddy|nginx"; WEB_SERVER="$2"; WEB_SERVER_SET=1; shift 2 ;;
      --email)           EMAIL_ARG="$2";     shift 2 ;;
      --secret)          [[ $# -ge 2 ]] || die "--secret требует значение"; SECRET_ARG="$2"; shift 2 ;;
      --secret-prefix)   [[ $# -ge 2 ]] || die "--secret-prefix требует plain|dd"; SECRET_PREFIX_MODE="$2"; SECRET_PREFIX_MODE_SET=1; shift 2 ;;
      --base-path)       BASE_PATH_ARG="$2"; shift 2 ;;
      --site-dir)        SITE_DIR="$2";      shift 2 ;;
      --no-site)         INSTALL_SITE=0;     shift ;;
      --workers)         WORKERS_ARG="$2";   shift 2 ;;
      --max-connections) MAXCONN_ARG="$2";   shift 2 ;;
      --port)            RELAY_PORT="$2";    shift 2 ;;
      --admin-port)      ADMIN_PORT="$2";    shift 2 ;;
      --non-interactive|-y) NONINTERACTIVE=1; shift ;;
      --skip-tests)      SKIP_TESTS=1;       shift ;;
      *) die "Unknown arg: $1" ;;
    esac
  done
  if [[ -n "$HOSTNAME_ARG" ]]; then
    local e; e="$(validate_hostname "$HOSTNAME_ARG")" || die "hostname: $e"
  fi
  if [[ -n "$EMAIL_ARG" ]]; then
    validate_email "$EMAIL_ARG" >/dev/null || die "невалидный email"
  fi
  [[ "$WEB_SERVER" == "caddy" || "$WEB_SERVER" == "nginx" ]] || die "--web-server: допустимо caddy или nginx"
  [[ "$SECRET_PREFIX_MODE" == "plain" || "$SECRET_PREFIX_MODE" == "dd" ]] || die "--secret-prefix: допустимо plain или dd"
  if [[ -n "$SECRET_ARG" ]]; then
    validate_secret "$SECRET_ARG" >/dev/null || die "невалидный --secret"
  fi
  if [[ -n "$BASE_PATH_ARG" ]]; then
    validate_base_path "$BASE_PATH_ARG" >/dev/null || die "невалидный --base-path"
  fi
  if [[ -n "$RELAY_PORT" ]]; then
    local e; e="$(validate_port "$RELAY_PORT")" || die "--port: $e"
  fi
  if [[ -n "$ADMIN_PORT" ]]; then
    local e; e="$(validate_port "$ADMIN_PORT")" || die "--admin-port: $e"
  fi
  if [[ -n "$RELAY_PORT" && -n "$ADMIN_PORT" && "$RELAY_PORT" == "$ADMIN_PORT" ]]; then
    die "relay и admin порты должны различаться"
  fi
  if [[ -n "$WORKERS_ARG" ]]; then
    [[ "$WORKERS_ARG" =~ ^[1-9][0-9]*$ ]] && (( WORKERS_ARG <= 256 )) || die "--workers 1..256"
  fi
  if [[ -n "$MAXCONN_ARG" ]]; then
    [[ "$MAXCONN_ARG" =~ ^[1-9][0-9]*$ ]] || die "--max-connections положительное"
  fi
}

parse_uninstall_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --keep-web-server|--keep-caddy) KEEP_WEB_SERVER=1; shift ;;
      --yes|-y)     ASSUME_YES=1; shift ;;
      *) die "Unknown arg: $1" ;;
    esac
  done
}

# ----------------------------- системные проверки ---------------------------
require_root() { [[ $EUID -eq 0 ]] || die "Запусти через sudo/root"; }
check_arch()    { [[ "$(uname -m)" == "x86_64" ]] || die "Нужен x86_64"; ok "Архитектура: x86_64"; }

check_os() {
  [[ -r /etc/os-release ]] || die "Нет /etc/os-release"
  . /etc/os-release
  case "${ID:-}" in
    ubuntu) ok "OS: ${PRETTY_NAME:-Ubuntu}" ;;
    debian) ok "OS: ${PRETTY_NAME:-Debian}" ;;
    *) warn "Дистрибутив ${ID:-unknown} не проверен" ;;
  esac
}

# ============================================================================
#  УСТАНОВКА / ОБНОВЛЕНИЕ
# ============================================================================

package_installed() {
  dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q '^install ok installed$'
}

# Проверка совместимости существующей конфигурации веб-сервера с текущими параметрами.
caddy_config_compatible() {
  [[ -s /etc/caddy/Caddyfile && -x /usr/local/bin/caddy ]] || return 1
  grep -Fq '{$TPROXY_HOSTNAME}' /etc/caddy/Caddyfile || return 1
  grep -Fq "127.0.0.1:$RELAY_PORT" /etc/caddy/Caddyfile || return 1
  grep -Fq 'TPROXY_SITE_ROOT' /etc/caddy/Caddyfile || return 1
  grep -Fq 'TPROXY_HOSTNAME' /etc/caddy/Caddyfile || return 1
  grep -Fq 'ACME_EMAIL' /etc/caddy/Caddyfile || return 1
  [[ -s /etc/systemd/system/caddy.service ]] || return 1
  grep -Fq 'ExecStart=/usr/local/bin/caddy run' /etc/systemd/system/caddy.service || return 1
  grep -Fq -- '--config /etc/caddy/Caddyfile' /etc/systemd/system/caddy.service || return 1
  grep -Fq 'User=caddy' /etc/systemd/system/caddy.service || return 1
  local dropin=/etc/systemd/system/caddy.service.d/tproxy.conf
  [[ -s "$dropin" ]] || return 1
  grep -Fxq "Environment=TPROXY_HOSTNAME=$HOSTNAME_ARG" "$dropin" || return 1
  grep -Fxq "Environment=TPROXY_SITE_ROOT=$SITE_DIR" "$dropin" || return 1
  grep -Fxq "Environment=ACME_EMAIL=$EMAIL_ARG" "$dropin" || return 1
  TPROXY_HOSTNAME="$HOSTNAME_ARG" TPROXY_SITE_ROOT="$SITE_DIR" ACME_EMAIL="$EMAIL_ARG" /usr/local/bin/caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile >/dev/null 2>&1
}
nginx_config_compatible() {
  [[ -s "$NGINX_SITE" && -s "$NGINX_MAP" && -L "$NGINX_ENABLED" ]] || return 1
  [[ "$(readlink -f "$NGINX_ENABLED" 2>/dev/null || true)" == "$NGINX_SITE" ]] || return 1
  grep -Eq "server_name[[:space:]]+$HOSTNAME_ARG;" "$NGINX_SITE" || return 1
  grep -Fq 'listen 80;' "$NGINX_SITE" || return 1
  grep -Fq 'listen 443 ssl;' "$NGINX_SITE" || return 1
  grep -Fq "proxy_pass http://127.0.0.1:$RELAY_PORT;" "$NGINX_SITE" || return 1
  grep -Fq 'proxy_set_header Upgrade $http_upgrade;' "$NGINX_SITE" || return 1
  grep -Fq 'proxy_set_header Connection $connection_upgrade;' "$NGINX_SITE" || return 1
  grep -Fq 'proxy_buffering off;' "$NGINX_SITE" || return 1
  grep -Fq 'default upgrade;' "$NGINX_MAP" || return 1
  nginx -t >/dev/null 2>&1
}

# Печатает только TCP-порты, относящиеся к данной установке прокси.
proxy_ports_table() {
  local relay_addr="${1:-}" admin_addr="${2:-}" backend_addr="${3:-}"
  local relay_port="${relay_addr##*:}" admin_port="${admin_addr##*:}" backend_port="${backend_addr##*:}"
  local -a ports=(80 443)
  local p line local_addr process label existing seen found
  for p in "$relay_port" "$admin_port" "$backend_port"; do
    [[ "$p" =~ ^[0-9]+$ ]] || continue
    seen=0
    for existing in "${ports[@]}"; do [[ "$existing" == "$p" ]] && seen=1; done
    (( seen )) || ports+=("$p")
  done
  printf '  %-8s %-25s %-8s %s\n' "Порт" "Назначение" "Протокол" "Процесс / состояние"
  printf '  %-8s %-25s %-8s %s\n' "--------" "-------------------------" "--------" "-------------------------"
  for p in "${ports[@]}"; do
    case "$p" in
      80) label="HTTP / ACME" ;; 443) label="HTTPS / Web Proxy" ;;
      "$relay_port") label="tproxy-server relay" ;;
      "$admin_port") label="tproxy-server health" ;;
      "$backend_port") label="MTProxy backend" ;;
      *) label="Proxy component" ;;
    esac
    found=0
    while IFS= read -r line; do
      [[ -n "$line" ]] || continue
      local_addr="$(awk '{print $4}' <<< "$line")"
      process="$(awk '{print $6}' <<< "$line")"
      printf '  %-8s %-25s %-8s %s (%s)\n' "$p" "$label" "TCP" "${process:--}" "$local_addr"
      found=1
    done < <(ss -lntpH 2>/dev/null | awk -v suffix=":$p" '$4 ~ (suffix "$")')
    if (( ! found )); then printf '  %-8s %-25s %-8s %s\n' "$p" "$label" "TCP" "не слушает"; fi
  done
}
preflight_basics() {
  require_root
  local pkg svc state
  local -a required_packages=(ca-certificates curl nftables openssl coreutils dnsutils netcat-openbsd jq git build-essential qrencode iproute2 libssl-dev util-linux zlib1g-dev)
  local -a services=(tproxy-server.service mtproxy.service tproxy-firewall.service refresh-mtproxy-config.timer caddy.service nginx.service)
  ui_header "Предварительная проверка системы"
  echo "Проверка основных компонентов до ввода параметров установки."
  echo
  printf '  %-30s %s\n' "Базовые пакеты" "Состояние"
  printf '  %-30s %s\n' "------------------------------" "------------------------------"
  for pkg in "${required_packages[@]}"; do
    if package_installed "$pkg"; then
      printf '  %-30s %s\n' "$pkg" "$(status_mark ok) установлен"
    else
      printf '  %-30s %s\n' "$pkg" "$(status_mark warn) будет установлен"
    fi
  done
  echo
  printf '  %-30s %s\n' "Основной компонент" "Состояние"
  printf '  %-30s %s\n' "------------------------------" "------------------------------"
  if [[ -x /usr/local/bin/tproxy-server ]]; then
    printf '  %-30s %s\n' "tproxy-server" "$(status_mark ok) бинарный файл найден"
  else
    printf '  %-30s %s\n' "tproxy-server" "$(status_mark warn) потребуется установить/собрать"
  fi
  if [[ -x /opt/MTProxy/objs/bin/mtproto-proxy ]]; then
    printf '  %-30s %s\n' "MTProxy" "$(status_mark ok) бинарный файл найден"
  else
    printf '  %-30s %s\n' "MTProxy" "$(status_mark warn) потребуется собрать"
  fi
  if command -v caddy >/dev/null 2>&1 || [[ -x /usr/local/bin/caddy ]]; then
    printf '  %-30s %s\n' "Caddy" "$(status_mark ok) установлен"
  else
    printf '  %-30s %s\n' "Caddy" "$(status_mark info) не установлен"
  fi
  if command -v nginx >/dev/null 2>&1 || package_installed nginx; then
    printf '  %-30s %s\n' "Nginx" "$(status_mark ok) установлен"
  else
    printf '  %-30s %s\n' "Nginx" "$(status_mark info) не установлен"
  fi
  if [[ -d "$SITE_DIR" ]]; then
    printf '  %-30s %s\n' "Decoy-сайт ($SITE_DIR)" "$(status_mark ok) каталог существует"
  else
    printf '  %-30s %s\n' "Decoy-сайт ($SITE_DIR)" "$(status_mark info) будет создан"
  fi
  echo
  printf '  %-30s %s\n' "Служба" "Состояние"
  printf '  %-30s %s\n' "------------------------------" "------------------------------"
  for svc in "${services[@]}"; do
    if systemctl is-active --quiet "$svc" 2>/dev/null; then
      state="активна"
      printf '  %-30s %s\n' "$svc" "$(status_mark ok) $state"
    elif systemctl is-enabled --quiet "$svc" 2>/dev/null; then
      state="включена, но не активна"
      printf '  %-30s %s\n' "$svc" "$(status_mark warn) $state"
    elif systemctl list-unit-files "$svc" --no-legend 2>/dev/null | grep -q .; then
      printf '  %-30s %s\n' "$svc" "$(status_mark info) установлена, не активна"
    else
      printf '  %-30s %s\n' "$svc" "$(status_mark info) не обнаружена"
    fi
  done
  echo
  if ! command -v apt-get >/dev/null 2>&1 || ! command -v dpkg-query >/dev/null 2>&1; then
    die "Для установки требуются apt-get и dpkg-query (Debian/Ubuntu)."
  fi
  ok "Предварительная проверка завершена. Параметры установки ещё не запрашивались."
  echo
}
preflight_system() {
  require_root
  local pkg svc version go_minor port
  local -a required_packages=(ca-certificates curl nftables openssl coreutils dnsutils netcat-openbsd jq git build-essential qrencode iproute2 libssl-dev util-linux zlib1g-dev)
  local -a missing_packages=()
  echo
  echo "Проверяю совместимость выбранных параметров с текущей конфигурацией."
  for pkg in "${required_packages[@]}"; do
    package_installed "$pkg" || missing_packages+=("$pkg")
  done
  if command -v go >/dev/null 2>&1; then
    version="$(go version 2>/dev/null || true)"
    go_minor="$(go env GOVERSION 2>/dev/null | sed -E 's/^go1\.([0-9]+).*/\1/')"
    if [[ "$go_minor" =~ ^[0-9]+$ ]] && (( go_minor >= 20 )); then
      printf '  %-24s %s\n' "Go" "$(status_mark ok) $version"
    else
      printf '  %-24s %s\n' "Go" "$(status_mark warn) версия ниже 1.20; потребуется Go $GO_FALLBACK_VERSION"
    fi
  elif [[ -x "/opt/go${GO_FALLBACK_VERSION}/bin/go" ]]; then
    printf '  %-24s %s\n' "Go" "$(status_mark ok) найден в /opt/go${GO_FALLBACK_VERSION}"
  else
    printf '  %-24s %s\n' "Go" "$(status_mark warn) потребуется установить"
  fi
  if command -v caddy >/dev/null 2>&1; then
    version="$(caddy version 2>/dev/null | head -n1)"
    printf '  %-24s %s\n' "Caddy" "$(status_mark ok) $version"
  else
    printf '  %-24s %s\n' "Caddy" "$(status_mark warn) не установлен"
  fi
  if command -v nginx >/dev/null 2>&1 || package_installed nginx; then
    printf '  %-24s %s\n' "Nginx" "$(status_mark ok) установлен"
  else
    printf '  %-24s %s\n' "Nginx" "$(status_mark warn) не установлен"
  fi
  if [[ -d "$SITE_DIR" ]]; then
    printf '  %-24s %s\n' "Каталог сайта" "$(status_mark ok) уже существует: $SITE_DIR (содержимое сохраняется)"
  else
    printf '  %-24s %s\n' "Каталог сайта" "$(status_mark info) будет создан: $SITE_DIR"
  fi
  if [[ -x /opt/MTProxy/objs/bin/mtproto-proxy && -r /opt/MTProxy/.tproxy-commit ]] && grep -Fxq "$MTPROXY_COMMIT" /opt/MTProxy/.tproxy-commit && [[ -s /etc/mtproxy/proxy-secret && -s /etc/mtproxy/proxy-multi.conf ]]; then
    printf '  %-24s %s\n' "MTProxy" "$(status_mark ok) нужная сборка уже установлена"
  elif [[ -x /opt/MTProxy/objs/bin/mtproto-proxy ]]; then
    printf '  %-24s %s\n' "MTProxy" "$(status_mark warn) найдена другая/неполная сборка; установщик создаст резервную копию и обновит её"
  else
    printf '  %-24s %s\n' "MTProxy" "$(status_mark warn) потребуется собрать"
  fi
  if [[ "$MODE" == "install" ]] && { [[ -s /etc/tproxy-server/config.json ]] || systemctl is-active --quiet tproxy-server 2>/dev/null || [[ -x /usr/local/bin/tproxy-server ]]; }; then
    die "Обнаружена существующая установка tproxy-server. Для неё выбери «Обновить», чтобы не перезаписать текущую конфигурацию."
  fi
  local other_web="" switching_webserver=0
  if [[ "$WEB_SERVER" == "caddy" ]] && systemctl is-active --quiet nginx.service 2>/dev/null; then other_web="Nginx"
  elif [[ "$WEB_SERVER" == "nginx" ]] && systemctl is-active --quiet caddy.service 2>/dev/null; then other_web="Caddy"
  fi
  if [[ -n "$other_web" ]]; then
    if [[ "$MODE" == "update" && "$WEB_SERVER_SET" -eq 1 ]]; then
      switching_webserver=1
      warn "Обнаружен активный $other_web. Он будет заменён выбранным веб-сервером $WEB_SERVER."
      confirm "Подтвердить переключение веб-сервера?" || die "переключение отменено"
    else
      die "$other_web уже запущен и не выбран. Установщик не будет останавливать или удалять его автоматически."
    fi
  fi
  if [[ "$MODE" != "update" ]]; then
    for port in "$RELAY_PORT" "$ADMIN_PORT"; do
      if [[ -n "$port" ]] && ss -lntH 2>/dev/null | awk -v p=":$port" '$4 ~ (p "$") { found=1 } END { exit !found }'; then
        die "Порт $port уже занят. Выбери свободный порт или останови службу, которая его использует."
      fi
    done
  fi
  local selected_service
  [[ "$WEB_SERVER" == "caddy" ]] && selected_service=caddy.service || selected_service=nginx.service
  for port in 80 443; do
    if port_in_use "$port"; then
      if systemctl is-active --quiet "$selected_service" 2>/dev/null; then
        info "Порт $port уже использует выбранный веб-сервер $WEB_SERVER — повторно не занимаем его."
      elif [[ "$switching_webserver" -eq 1 ]]; then
        info "Порт $port сейчас использует $other_web; его переключение уже подтверждено."
      else
        die "Порт $port занят сторонней службой. Установщик не будет останавливать её автоматически."
      fi
    fi
  done
  echo
  if (("${#missing_packages[@]}")); then info "Потребуется установить только: ${missing_packages[*]}"
  else ok "Все системные пакеты уже установлены — повторная установка не требуется."; fi
  if [[ "$WEB_SERVER" == "caddy" ]] && command -v caddy >/dev/null 2>&1; then
    info "Найденный Caddy будет использован; бинарный файл не будет заменён."
    if caddy_config_compatible; then
      ok "Caddyfile, systemd unit и drop-in совместимы с текущими параметрами — перенастройка не потребуется."
    elif [[ -s /etc/caddy/Caddyfile ]]; then
      warn "Конфигурация Caddy не полностью совместима (домен, relay, site root, email, unit или проверка). Перед обновлением Caddyfile будет сохранён backup."
      confirm "Разрешить обновление конфигурации Caddy?" || die "настройка Caddy отменена"
    else info "Конфигурация Caddy отсутствует и будет создана."; fi
  elif [[ "$WEB_SERVER" == "nginx" ]] && command -v nginx >/dev/null 2>&1; then
    info "Nginx уже установлен; пакет повторно устанавливаться не будет."
    if nginx_config_compatible; then
      ok "Сайт Nginx и WebSocket map совместимы с текущими параметрами — перенастройка не потребуется."
    elif [[ -s "$NGINX_SITE" || -s "$NGINX_MAP" ]]; then
      warn "Конфигурация Nginx не полностью совместима (домен, relay, TLS, WebSocket map, symlink или nginx -t). Перед обновлением файлы будут сохранены в backup."
      confirm "Разрешить обновление конфигурации Nginx?" || die "настройка Nginx отменена"
    else info "Конфигурация Nginx отсутствует и будет создана."; fi
  fi
  confirm "Продолжить с учётом обнаруженных компонентов?" || die "установка отменена"
}

install_deps() {
  export DEBIAN_FRONTEND=noninteractive
  local -a required=(ca-certificates curl nftables openssl coreutils dnsutils netcat-openbsd jq git build-essential qrencode iproute2 libssl-dev util-linux zlib1g-dev)
  local -a missing=()
  local pkg
  for pkg in "${required[@]}"; do package_installed "$pkg" || missing+=("$pkg"); done
  if (("${#missing[@]}")); then
    info "Устанавливаю только отсутствующие пакеты: ${missing[*]}"
    apt-get update -qq
    apt-get install -y -qq --no-install-recommends "${missing[@]}"
    ok "Недостающие базовые пакеты установлены"
  else
    ok "Все базовые пакеты уже установлены; apt install пропущен"
  fi
}

install_nginx_packages() {
  export DEBIAN_FRONTEND=noninteractive
  local -a missing=()
  package_installed nginx || missing+=(nginx)
  package_installed certbot || missing+=(certbot)
  if (("${#missing[@]}")); then
    info "Устанавливаю отсутствующие компоненты Nginx: ${missing[*]}"
    apt-get update -qq
    apt-get install -y -qq --no-install-recommends "${missing[@]}"
  else
    ok "Nginx и Certbot уже установлены — повторная установка пропущена"
  fi
  systemctl enable nginx.service
}

get_public_ipv4() {
  local candidate
  for probe in https://api.ipify.org https://ifconfig.co/ip https://icanhazip.com; do
    candidate="$(curl --fail --silent --location --ipv4 --max-time 8 \
      --proto '=https' --proto-redir '=https' --tlsv1.2 "$probe" 2>/dev/null | tr -d '[:space:]')" || continue
    if [[ "$candidate" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
      printf '%s' "$candidate"
      return 0
    fi
  done
  return 1
}

ipv4_to_int() {
  local a b c d
  IFS=. read -r a b c d <<< "$1"
  [[ "$a" =~ ^[0-9]+$ && "$b" =~ ^[0-9]+$ && "$c" =~ ^[0-9]+$ && "$d" =~ ^[0-9]+$ ]] || return 1
  (( 10#$a <= 255 && 10#$b <= 255 && 10#$c <= 255 && 10#$d <= 255 )) || return 1
  printf '%u' "$(( (10#$a << 24) | (10#$b << 16) | (10#$c << 8) | 10#$d ))"
}

is_cloudflare_ipv4() {
  local address="$1" ranges="$2" cidr network prefix ip_num net_num mask
  ip_num="$(ipv4_to_int "$address")" || return 1
  while IFS= read -r cidr; do
    [[ "$cidr" == */* ]] || continue
    network="${cidr%/*}"
    prefix="${cidr#*/}"
    [[ "$prefix" =~ ^[0-9]+$ ]] && (( prefix >= 0 && prefix <= 32 )) || continue
    net_num="$(ipv4_to_int "$network")" || continue
    if (( prefix == 0 )); then mask=0; else mask=$(( (0xffffffff << (32 - prefix)) & 0xffffffff )); fi
    if (( (ip_num & mask) == (net_num & mask) )); then return 0; fi
  done <<< "$ranges"
  return 1
}

is_cloudflare_proxied_domain() {
  local hostname="$1" ranges="" address count=0 total=0
  local -a addresses=()
  mapfile -t addresses < <(dig +short A "$hostname" 2>/dev/null | grep -E '^([0-9]{1,3}\.){3}[0-9]{1,3}$' | sort -u)
  ((${#addresses[@]})) || return 1
  ranges="$(curl --fail --silent --location --max-time 8 --proto '=https' --proto-redir '=https' --tlsv1.2 https://www.cloudflare.com/ips-v4 2>/dev/null || true)"
  [[ -n "$ranges" ]] || return 1
  for address in "${addresses[@]}"; do ((total += 1)); if is_cloudflare_ipv4 "$address" "$ranges"; then ((count += 1)); fi; done
  (( total > 0 && count == total ))
}

check_dns() {
  info "Проверяю DNS для $HOSTNAME_ARG через системный DNS-резолвер…"
  local -a ips=()
  local public_ip="" matched=0 ip aaaa
  mapfile -t ips < <(dig +short A "$HOSTNAME_ARG" 2>/dev/null | grep -E '^([0-9]{1,3}\.){3}[0-9]{1,3}$' | sort -u)
  ((${#ips[@]})) || die "Системный DNS-резолвер не вернул A-запись для $HOSTNAME_ARG. Проверь DNS-настройки домена и сервера."
  if public_ip="$(get_public_ipv4)"; then
    for ip in "${ips[@]}"; do [[ "$ip" == "$public_ip" ]] && matched=1; done
    if (( matched )); then ok "DNS A-запись содержит публичный IPv4 сервера: $public_ip"
    elif is_cloudflare_proxied_domain "$HOSTNAME_ARG"; then
      info "IP-адреса, которые возвращает системный DNS (${ips[*]}), отличаются от публичного IP-адреса сервера ($public_ip)."
      ok "Cloudflare DNS Proxy включён: DNS возвращает адреса сети Cloudflare вместо исходного IP origin-сервера. Это штатное поведение проксируемой DNS-записи."
      info "Посетители получают edge-адреса Cloudflare, а запросы передаются через сеть Cloudflare на origin-сервер. Прямое совпадение DNS-адреса с IP сервера не требуется."
      info "Проверь режим SSL/TLS Full (strict) и доступность origin по TCP 80/443."
    else die "DNS A-запись (${ips[*]}) не совпадает с публичным IPv4 сервера ($public_ip) и не распознана как адреса Cloudflare. Проверь A-запись и настройки DNS Proxy."; fi
  else warn "Не удалось определить публичный IPv4 сервера; системный DNS вернул A-записи: ${ips[*]}. Сравнение пропущено."; fi
  aaaa="$(dig +short AAAA "$HOSTNAME_ARG" 2>/dev/null | grep ':' | sort -u | tr '\n' ' ' || true)"
  if [[ -n "$aaaa" ]]; then
    if is_cloudflare_proxied_domain "$HOSTNAME_ARG"; then
      info "DNS AAAA возвращает IPv6-адреса сети Cloudflare ($aaaa). При включённом DNS Proxy это адреса прокси-сети, а не прямые IPv6-адреса origin-сервера; IPv6-маршрут origin по ним не оценивается."
    elif ip -6 route get 2606:4700:4700::1111 2>/dev/null | grep -q 'src'; then
      warn "Системный DNS возвращает AAAA-запись ($aaaa). Убедись, что эти IPv6-адреса принадлежат origin-серверу и TCP 80/443 доступны по IPv6."
    else warn "Системный DNS возвращает AAAA-запись ($aaaa), но у сервера нет рабочего IPv6-маршрута. Если IPv6 на origin не настроен, удали AAAA или проверь настройки Cloudflare DNS Proxy."; fi
  else ok "AAAA-запись через системный DNS-резолвер не обнаружена"; fi
}

fetch_repo() {
  if [[ -d "$REPO_DIR/.git" ]]; then
    info "Получаю зафиксированную версию $UPSTREAM_COMMIT"
    git -C "$REPO_DIR" fetch --depth=1 origin "$UPSTREAM_COMMIT"
    git -C "$REPO_DIR" checkout --detach FETCH_HEAD
    git -C "$REPO_DIR" reset --hard "$UPSTREAM_COMMIT"
  else
    info "Клонирую $REPO_URL на зафиксированном commit $UPSTREAM_COMMIT"
    rm -rf "$REPO_DIR"
    install -d -m 0755 "$REPO_DIR"
    git -C "$REPO_DIR" init
    git -C "$REPO_DIR" remote add origin "$REPO_URL"
    git -C "$REPO_DIR" fetch --depth=1 origin "$UPSTREAM_COMMIT"
    git -C "$REPO_DIR" checkout --detach FETCH_HEAD
  fi
  local actual_commit
  actual_commit="$(git -C "$REPO_DIR" rev-parse HEAD)"
  [[ "$actual_commit" == "$UPSTREAM_COMMIT" ]] || die "Версия tproxy-server не совпадает с закреплённым commit"
  [[ -x "$REPO_DIR/deploy/install-mtproxy.sh" ]] || die "install-mtproxy.sh не найден"
  ok "Репозиторий: $(git -C "$REPO_DIR" rev-parse --short HEAD) (pinned)"
}

resolve_base_path() {
  if [[ "$BASE_PATH_ARG" == "none" ]]; then BASE_PATH_ARG=""; return 0; fi
  if [[ -n "$BASE_PATH_ARG" ]]; then return 0; fi
  if [[ -f /etc/tproxy-server/config.json ]]; then
    BASE_PATH_ARG="$(sed -n 's/.*"base_path"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
      /etc/tproxy-server/config.json | head -n1)"
    if [[ -n "$BASE_PATH_ARG" ]]; then
      info "Сохраняю существующий base_path: $BASE_PATH_ARG"
    fi
    return 0
  fi
  command -v base32 >/dev/null || die "base32 (coreutils) нужен для генерации base_path"
  BASE_PATH_ARG="$(head -c 10 /dev/urandom | base32 | tr 'A-Z' 'a-z')"
  info "Сгенерирован base_path: $BASE_PATH_ARG"
}

install_caddy() {
  if command -v caddy >/dev/null 2>&1; then
    local caddy_bin
    caddy_bin="$(command -v caddy)"
    if [[ "$caddy_bin" != /usr/local/bin/caddy && ! -x /usr/local/bin/caddy ]]; then
      ln -s "$caddy_bin" /usr/local/bin/caddy
      info "Создан совместимый путь /usr/local/bin/caddy → $caddy_bin"
    fi
    info "Использую уже установленный Caddy: $(caddy version 2>/dev/null | head -n1)"
  else
    info "Ставлю Caddy ${CADDY_VERSION}…"
    local archive dir
    archive="$(mktemp /tmp/caddy.XXXXXX.tar.gz)"
    dir="$(mktemp -d /tmp/caddy.XXXXXX)"
    trap 'rm -f "$archive"; rm -rf "$dir"' EXIT
    curl --fail --silent --show-error --location --proto '=https' --proto-redir '=https' --tlsv1.2 \
      --output "$archive" \
      "https://github.com/caddyserver/caddy/releases/download/v${CADDY_VERSION}/caddy_${CADDY_VERSION}_linux_amd64.tar.gz"
    test "$(sha512sum "$archive" | awk '{print $1}')" = "$CADDY_SHA512" \
      || die "Caddy checksum mismatch"
    tar -C "$dir" -xzf "$archive"
    install -m 0755 "$dir/caddy" /usr/local/bin/caddy
    rm -f "$archive"; rm -rf "$dir"
    trap - EXIT
    ok "Caddy установлен"
  fi
  if ! id caddy >/dev/null 2>&1; then
    useradd --system --home /var/lib/caddy --shell /usr/sbin/nologin caddy
  fi
  install -d -o root -g caddy -m 0750 /etc/caddy
  install -d -o caddy -g caddy -m 0750 /var/lib/caddy
}

install_nginx_config() {
  # Сохраняем файлы до записи новых настроек, не трогая остальные сайты Nginx.
  if [[ -e "$NGINX_SITE" ]]; then
    cp -a "$NGINX_SITE" "${NGINX_SITE}.before-tproxy.$(date +%Y%m%d%H%M%S)"
    warn "Существующая конфигурация Nginx сохранена в резервную копию."
  fi
  if [[ -e "$NGINX_MAP" ]]; then
    cp -a "$NGINX_MAP" "${NGINX_MAP}.before-tproxy.$(date +%Y%m%d%H%M%S)"
  fi
  install -d -m 0755 "$ACME_WEBROOT"
  local cert="/etc/letsencrypt/live/$HOSTNAME_ARG/fullchain.pem"
  local key="/etc/letsencrypt/live/$HOSTNAME_ARG/privkey.pem"
  cat > "$NGINX_SITE" <<EOF
server {
 listen 80;
 server_name $HOSTNAME_ARG;
 location ^~ /.well-known/acme-challenge/ { root $ACME_WEBROOT; }
 location / { return 301 https://\$host\$request_uri; }
}
EOF
  # Nginx needs explicit WebSocket upgrade handling and disabled buffering
  # for the relay's long-lived streaming/long-poll HTTP connections.
  cat > "$NGINX_MAP" <<'EOF'
map $http_upgrade $connection_upgrade {
    default upgrade;
    ''      '';
}
EOF
  ln -sfn "$NGINX_SITE" "$NGINX_ENABLED"
  # Системный default site не отключаем: точный server_name домена прокси
  # имеет приоритет и не требует удаления сторонней конфигурации.
  nginx -t || die "Nginx HTTP-конфигурация невалидна"
  systemctl restart nginx
  if [[ ! -s "$cert" || ! -s "$key" ]]; then
    certbot certonly --webroot -w "$ACME_WEBROOT" -d "$HOSTNAME_ARG" --email "$EMAIL_ARG" --agree-tos --non-interactive --keep-until-expiring || die "Не удалось получить TLS-сертификат"
  fi
  [[ -s "$cert" && -s "$key" ]] || die "Сертификат Nginx не найден"
  cat > "$NGINX_SITE" <<EOF
server {
 listen 80;
 server_name $HOSTNAME_ARG;
 location ^~ /.well-known/acme-challenge/ { root $ACME_WEBROOT; }
 location / { return 301 https://\$host\$request_uri; }
}
server {
 listen 443 ssl;
 server_name $HOSTNAME_ARG;
 ssl_certificate $cert;
 ssl_certificate_key $key;
 ssl_protocols TLSv1.2 TLSv1.3;
 location / {
  proxy_pass http://127.0.0.1:$RELAY_PORT;
  proxy_http_version 1.1;
  proxy_set_header Host \$host;
  proxy_set_header X-Real-IP \$remote_addr;
  proxy_set_header X-Forwarded-For \$remote_addr;
  proxy_set_header X-Forwarded-Proto https;
  proxy_set_header X-Forwarded-Host \$host;
  proxy_set_header Upgrade \$http_upgrade;
  proxy_set_header Connection \$connection_upgrade;
  proxy_buffering off;
  proxy_request_buffering off;
  proxy_cache off;
  proxy_read_timeout 3600s;
  proxy_send_timeout 3600s;
 }
}
EOF
  nginx -t || die "Nginx-конфигурация невалидна"
  # Применяем уже TLS-конфигурацию: до этого Nginx мог быть запущен
  # только с временным HTTP-only server block для выпуска сертификата.
  systemctl enable nginx.service
  systemctl reload nginx.service || systemctl restart nginx.service || die "Не удалось применить TLS-конфигурацию Nginx"
  install -d -m 0755 /etc/letsencrypt/renewal-hooks/deploy
  cat > /etc/letsencrypt/renewal-hooks/deploy/reload-tproxy-nginx <<EOF
#!/usr/bin/env bash
systemctl reload nginx.service
EOF
  chmod 0755 /etc/letsencrypt/renewal-hooks/deploy/reload-tproxy-nginx
  systemctl enable --now certbot.timer 2>/dev/null || true
  ok "Nginx настроен"
}

remove_caddy() {
  systemctl disable --now caddy.service 2>/dev/null || true
  # Удаляем и ручную установку скрипта, и возможную пакетную установку Caddy.
  rm -f /usr/local/bin/caddy /usr/bin/caddy
  rm -f /etc/systemd/system/caddy.service /lib/systemd/system/caddy.service /usr/lib/systemd/system/caddy.service
  rm -rf /etc/caddy /var/lib/caddy /var/log/caddy /etc/systemd/system/caddy.service.d
  if dpkg-query -W -f='${Status}' caddy 2>/dev/null | grep -q 'install ok installed'; then
    DEBIAN_FRONTEND=noninteractive apt-get purge -y caddy
  fi
  userdel -r caddy 2>/dev/null || true
  systemctl daemon-reload
  systemctl reset-failed caddy.service 2>/dev/null || true
}

remove_nginx() {
  systemctl stop nginx.service 2>/dev/null || true
  systemctl disable nginx.service 2>/dev/null || true
  rm -f "$NGINX_ENABLED" "$NGINX_SITE" "$NGINX_MAP" /etc/letsencrypt/renewal-hooks/deploy/reload-tproxy-nginx
  systemctl daemon-reload
  apt-get remove -y nginx nginx-common nginx-core 2>/dev/null || true
}

install_mtproxy_backend() {
  if [[ -x /opt/MTProxy/objs/bin/mtproto-proxy && -r /opt/MTProxy/.tproxy-commit ]] &&
     grep -Fxq "$MTPROXY_COMMIT" /opt/MTProxy/.tproxy-commit &&
     [[ -s /etc/mtproxy/proxy-secret && -s /etc/mtproxy/proxy-multi.conf ]]; then
    ok "MTProxy нужной версии уже установлен — сборка и обновление Telegram-конфигурации пропущены"
    return 0
  fi
  info "Собираю официальный MTProxy…"
  "$REPO_DIR/deploy/install-mtproxy.sh"
  ok "MTProxy собран"
}

ensure_go() {
  if command -v go >/dev/null 2>&1; then
    local minor
    minor="$(go env GOVERSION | sed -E 's/^go1\.([0-9]+).*/\1/')"
    if [[ "$minor" =~ ^[0-9]+$ ]] && (( minor >= 20 )); then
      GO_BIN="$(command -v go)"
      ok "Go: $(go version)"
      return 0
    fi
  fi
  info "Ставлю Go ${GO_FALLBACK_VERSION}…"
  local archive dir
  archive="$(mktemp /tmp/go.XXXXXX.tar.gz)"
  dir="$(mktemp -d /tmp/go.XXXXXX)"
  trap 'rm -f "$archive"; rm -rf "$dir"' EXIT
  curl --fail --silent --show-error --location --proto '=https' --proto-redir '=https' --tlsv1.2 \
    --output "$archive" "https://go.dev/dl/go${GO_FALLBACK_VERSION}.linux-amd64.tar.gz"
  test "$(sha256sum "$archive" | awk '{print $1}')" = "$GO_FALLBACK_SHA256" \
    || die "Go checksum mismatch"
  tar -C "$dir" -xzf "$archive"
  if [[ -e "/opt/go${GO_FALLBACK_VERSION}" ]]; then rm -rf "$dir/go"; else
    mv "$dir/go" "/opt/go${GO_FALLBACK_VERSION}"
  fi
  rm -f "$archive"; rm -rf "$dir"; trap - EXIT
  GO_BIN="/opt/go${GO_FALLBACK_VERSION}/bin/go"
  ok "Go: $("$GO_BIN" version)"
}

build_tproxy() {
  info "Собираю tproxy-server…"
  cd "$REPO_DIR"
  if [[ "$SKIP_TESTS" -ne 1 ]]; then
    info "  go test ./…"
    "$GO_BIN" test ./... || die "go test упал"
  else
    warn "  go test пропущен (--skip-tests)"
  fi
  "$GO_BIN" build -trimpath -ldflags='-s -w' -o /usr/local/bin/tproxy-server ./cmd/tproxy-server
  chown root:root /usr/local/bin/tproxy-server
  chmod 0755 /usr/local/bin/tproxy-server
  cd - >/dev/null
  ok "tproxy-server собран"
}

install_stub_site() {
  if [[ "$INSTALL_SITE" -ne 1 ]]; then info "Сайт пропущен (--no-site)"; return 0; fi
  if [[ -f "$SITE_DIR/index.html" ]]; then
    info "Сайт уже есть в $SITE_DIR — не трогаю"
    : # Существующий сайт и его права не изменяем
    : # Не меняем права пользовательского содержимого

    ok "Существующий сайт сохранён без изменений"
    return 0
  fi
  info "Ставлю сайт-заглушку в $SITE_DIR…"
  mkdir -p "$SITE_DIR/assets"

  cat > "$SITE_DIR/index.html" <<'HTML'
<!doctype html>
<html lang="ru">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Vibe Studio — код в потоке</title>
<meta name="description" content="Инструменты для тех, кто пишет код в потоке: быстрый фидбек, живые прототипы, ноль трения.">
<link rel="stylesheet" href="/assets/styles.css">
<link rel="icon" href="/assets/favicon.svg" type="image/svg+xml">
</head>
<body>
<div class="bg-orb orb-a"></div>
<div class="bg-orb orb-b"></div>

<header class="nav">
  <a class="brand" href="/"><span class="brand-mark">◆</span> Vibe<span class="brand-dim">Studio</span></a>
  <nav><a href="/about.html">Манифест</a><a href="/privacy.html">Приватность</a></nav>
</header>

<main class="hero">
  <p class="kicker">v0.1 · private beta</p>
  <h1>Код в&nbsp;потоке.<br><span class="grad">Без трения.</span></h1>
  <p class="lead">Мы делаем инструменты для вайбкодинга: пишешь мысль —&nbsp;получаешь работающий прототип. Никаких душных настроек, только ритм и&nbsp;фидбек.</p>

  <div class="cta-row">
    <a class="btn btn-primary" href="/about.html">Читать манифест →</a>
    <a class="btn btn-ghost" href="#features">Что внутри</a>
  </div>

  <section id="features" class="cards">
    <article class="card"><div class="card-icon">⚡</div><h3>Мгновенный фидбек</h3><p>Изменения видны сразу, без пересборки вселенной. Пиши —&nbsp;и смотри, как оживает.</p></article>
    <article class="card"><div class="card-icon">🧠</div><h3>Память контекста</h3><p>Студия помнит, что ты делал пять минут назад. Никаких «напомни, о чём мы».</p></article>
    <article class="card"><div class="card-icon">🎛️</div><h3>Один пульт</h3><p>Модели, промпты, диффы — в одном месте. Переключайся, не теряя нить.</p></article>
    <article class="card"><div class="card-icon">🌊</div><h3>Поток важнее</h3><p>Меньше кликов, больше мысли. Интерфейс уходит с дороги, когда ты в ритме.</p></article>
  </section>

  <section class="quote">
    <blockquote>«Вайбкодинг — это когда код пишется сам, а&nbsp;ты только задаёшь настроение.»</blockquote>
    <cite>— из внутреннего манифеста</cite>
  </section>

  <section class="status">
    <h2>Статус студии</h2>
    <ul>
      <li><span class="dot ok"></span> Шлюз студии — в норме</li>
      <li><span class="dot ok"></span> Синхронизация контекста — активна</li>
      <li><span class="dot warn"></span> Публичный бета-доступ — по инвайтам</li>
    </ul>
  </section>
</main>

<footer><p>© <span id="y"></span> Vibe Studio. Сделано в потоке.</p></footer>
<script>document.getElementById('y').textContent=new Date().getFullYear();</script>
</body>
</html>
HTML

  cat > "$SITE_DIR/about.html" <<'HTML'
<!doctype html>
<html lang="ru">
<head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Манифест — Vibe Studio</title>
<link rel="stylesheet" href="/assets/styles.css">
<link rel="icon" href="/assets/favicon.svg" type="image/svg+xml"></head>
<body>
<div class="bg-orb orb-a"></div><div class="bg-orb orb-b"></div>
<header class="nav"><a class="brand" href="/"><span class="brand-mark">◆</span> Vibe<span class="brand-dim">Studio</span></a>
<nav><a href="/">Главная</a><a href="/privacy.html">Приватность</a></nav></header>
<main class="page">
  <p class="kicker">manifesto</p>
  <h1>Мы верим в&nbsp;код, который пишется в&nbsp;потоке</h1>
  <p>Инструменты не должны требовать, чтобы ты сначала выучил их философию. Они должны подхватывать твою мысль и&nbsp;превращать её в&nbsp;работающий прототип.</p>
  <h2>Три принципа</h2>
  <ol class="principles">
    <li><strong>Меньше церемоний.</strong> Ноль конфигов перед первой строкой.</li>
    <li><strong>Фидбек быстрее мысли.</strong> Между «придумал» и&nbsp;«увидел» — секунды.</li>
    <li><strong>Состояние потока — приоритет.</strong> Всё, что мешает, уходит с&nbsp;дороги.</li>
  </ol>
  <p class="muted">Мы в&nbsp;закрытой бете. Если хочешь попробовать —&nbsp;следи за&nbsp;анонсами.</p>
</main>
<footer><p>© <span id="y"></span> Vibe Studio</p></footer>
<script>document.getElementById('y').textContent=new Date().getFullYear();</script>
</body></html>
HTML

  cat > "$SITE_DIR/privacy.html" <<'HTML'
<!doctype html>
<html lang="ru">
<head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Приватность — Vibe Studio</title>
<link rel="stylesheet" href="/assets/styles.css">
<link rel="icon" href="/assets/favicon.svg" type="image/svg+xml"></head>
<body>
<div class="bg-orb orb-a"></div><div class="bg-orb orb-b"></div>
<header class="nav"><a class="brand" href="/"><span class="brand-mark">◆</span> Vibe<span class="brand-dim">Studio</span></a>
<nav><a href="/">Главная</a><a href="/about.html">Манифест</a></nav></header>
<main class="page">
  <p class="kicker">privacy</p>
  <h1>Приватность</h1>
  <p>Мы не собираем персональные данные посетителей сайта. Серверные журналы содержат только агрегированные метрики без URL и&nbsp;заголовков.</p>
  <p>Если у&nbsp;тебя есть вопросы —&nbsp;пиши: <a href="mailto:hello@example.com">hello@example.com</a>.</p>
  <p class="muted">Обновлено: ноябрь 2026.</p>
</main>
<footer><p>© <span id="y"></span> Vibe Studio</p></footer>
<script>document.getElementById('y').textContent=new Date().getFullYear();</script>
</body></html>
HTML

  cat > "$SITE_DIR/assets/styles.css" <<'CSS'
:root{--bg:#07080f;--bg2:#0e1122;--panel:#121730;--fg:#eef1fb;--muted:#8f9ac4;--acc:#7cf0c0;--acc2:#7aa8ff;--acc3:#c78cff;--border:#1e2547;--radius:18px;--max:1040px}
*{box-sizing:border-box}
html,body{margin:0;height:100%}
body{font-family:ui-sans-serif,system-ui,-apple-system,"Segoe UI",Roboto,Ubuntu,sans-serif;background:var(--bg);color:var(--fg);line-height:1.6;display:flex;flex-direction:column;min-height:100vh;position:relative;overflow-x:hidden}
a{color:var(--acc2);text-decoration:none}
a:hover{text-decoration:underline}
.bg-orb{position:fixed;border-radius:50%;filter:blur(90px);opacity:.45;z-index:0;pointer-events:none}
.orb-a{width:520px;height:520px;background:radial-gradient(circle,var(--acc2),transparent 70%);top:-200px;right:-120px}
.orb-b{width:480px;height:480px;background:radial-gradient(circle,var(--acc3),transparent 70%);bottom:-220px;left:-160px}
.nav{position:relative;z-index:1;display:flex;align-items:center;justify-content:space-between;max-width:var(--max);margin:0 auto;padding:22px 20px;width:100%}
.brand{font-weight:800;letter-spacing:.2px;color:var(--fg);font-size:1.15rem}
.brand-mark{color:var(--acc);margin-right:4px}
.brand-dim{color:var(--muted);font-weight:600}
.nav nav a{color:var(--muted);margin-left:20px;font-size:.95rem}
.nav nav a:hover{color:var(--fg)}
.hero{position:relative;z-index:1;max-width:var(--max);margin:32px auto 80px;padding:0 20px;flex:1;text-align:center}
.kicker{display:inline-block;font-size:.8rem;letter-spacing:.18em;text-transform:uppercase;color:var(--acc);border:1px solid var(--border);border-radius:999px;padding:6px 14px;margin:0 0 22px;background:rgba(124,240,192,.06)}
.hero h1{font-size:clamp(2.2rem,6vw,4rem);line-height:1.05;margin:0 0 22px;font-weight:800;letter-spacing:-.02em}
.grad{background:linear-gradient(90deg,var(--acc),var(--acc2) 45%,var(--acc3));-webkit-background-clip:text;background-clip:text;color:transparent}
.lead{color:var(--muted);font-size:1.12rem;max-width:620px;margin:0 auto 34px}
.cta-row{display:flex;gap:12px;justify-content:center;flex-wrap:wrap;margin-bottom:56px}
.btn{display:inline-block;padding:12px 22px;border-radius:12px;font-weight:600;font-size:.98rem;transition:transform .15s ease,box-shadow .15s ease,background .15s ease;border:1px solid transparent}
.btn-primary{background:linear-gradient(135deg,var(--acc),var(--acc2));color:#04121a;box-shadow:0 10px 24px rgba(122,168,255,.28)}
.btn-primary:hover{transform:translateY(-2px);box-shadow:0 14px 30px rgba(122,168,255,.38);text-decoration:none}
.btn-ghost{color:var(--fg);border-color:var(--border);background:rgba(255,255,255,.02)}
.btn-ghost:hover{background:rgba(255,255,255,.06);text-decoration:none}
.cards{display:grid;grid-template-columns:repeat(auto-fit,minmax(230px,1fr));gap:16px;text-align:left;margin:0 0 64px}
.card{background:linear-gradient(180deg,var(--panel),var(--bg2));border:1px solid var(--border);border-radius:var(--radius);padding:22px;transition:transform .18s ease,border-color .18s ease}
.card:hover{transform:translateY(-4px);border-color:var(--acc2)}
.card-icon{width:38px;height:38px;border-radius:10px;display:flex;align-items:center;justify-content:center;background:rgba(122,168,255,.12);border:1px solid var(--border);margin-bottom:14px;font-size:1.1rem}
.card h3{margin:0 0 8px;font-size:1.05rem;letter-spacing:-.01em}
.card p{margin:0;color:var(--muted);font-size:.95rem}
.quote{border:1px solid var(--border);border-radius:var(--radius);background:linear-gradient(180deg,rgba(122,168,255,.06),transparent);padding:28px 24px;margin:0 0 64px}
.quote blockquote{margin:0 0 10px;font-size:1.25rem;line-height:1.4;font-weight:600;background:linear-gradient(90deg,var(--acc),var(--acc3));-webkit-background-clip:text;background-clip:text;color:transparent}
.quote cite{color:var(--muted);font-style:normal;font-size:.9rem}
.status{text-align:left;max-width:520px;margin:0 auto}
.status h2{font-size:1.05rem;margin:0 0 12px;letter-spacing:.02em;text-transform:uppercase;color:var(--muted)}
.status ul{list-style:none;margin:0;padding:0;display:grid;gap:8px}
.status li{display:flex;align-items:center;color:var(--fg);font-size:.98rem}
.dot{width:9px;height:9px;border-radius:50%;margin-right:10px;flex:0 0 auto}
.dot.ok{background:var(--acc);box-shadow:0 0 10px var(--acc)}
.dot.warn{background:#ffcf6e;box-shadow:0 0 10px #ffcf6e}
.page{position:relative;z-index:1;max-width:760px;margin:32px auto 80px;padding:0 20px;flex:1;width:100%}
.page h1{font-size:clamp(1.8rem,4vw,2.6rem);line-height:1.15;margin:0 0 18px;letter-spacing:-.02em}
.page h2{font-size:1.2rem;margin:28px 0 12px}
.page p{color:var(--muted)}
.page .muted{color:var(--muted);font-size:.92rem}
.principles{margin:0 0 20px;padding-left:1.2em;color:var(--muted)}
.principles li{margin-bottom:10px}
.principles strong{color:var(--fg)}
footer{position:relative;z-index:1;border-top:1px solid var(--border);padding:24px;text-align:center;color:var(--muted);font-size:.9rem;margin-top:auto}
CSS

  cat > "$SITE_DIR/assets/favicon.svg" <<'SVG'
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64">
<defs><linearGradient id="g" x1="0" x2="1" y1="0" y2="1">
<stop offset="0" stop-color="#7cf0c0"/><stop offset=".5" stop-color="#7aa8ff"/><stop offset="1" stop-color="#c78cff"/>
</linearGradient></defs>
<rect width="64" height="64" rx="16" fill="#07080f"/>
<path d="M32 12 L52 32 L32 52 L12 32 Z" fill="none" stroke="url(#g)" stroke-width="4" stroke-linejoin="round"/>
<circle cx="32" cy="32" r="5" fill="url(#g)"/>
</svg>
SVG

  chown root:root "$SITE_DIR" "$SITE_DIR/index.html" "$SITE_DIR/about.html" "$SITE_DIR/privacy.html" \
    "$SITE_DIR/assets" "$SITE_DIR/assets/styles.css" "$SITE_DIR/assets/favicon.svg"
  chmod 0755 "$SITE_DIR" "$SITE_DIR/assets"
  chmod 0644 "$SITE_DIR/index.html" "$SITE_DIR/about.html" "$SITE_DIR/privacy.html" \
    "$SITE_DIR/assets/styles.css" "$SITE_DIR/assets/favicon.svg"
  ok "Права файлов сайта-заглушки настроены (каталоги 0755, файлы 0644)"
}

ensure_tproxy_user() {
  if ! id tproxy >/dev/null 2>&1; then
    useradd --system --home /nonexistent --shell /usr/sbin/nologin tproxy
  fi
}

write_configs() {
  install -d -o root -g tproxy -m 0750 /etc/tproxy-server
  bash "$REPO_DIR/deploy/ensure-token-key.sh"

  cat > /etc/tproxy-server/config.json <<EOF
{
  "public_hostname": "$HOSTNAME_ARG",
  "base_path": "$BASE_PATH_ARG",
  "listen": "127.0.0.1:$RELAY_PORT",
  "admin_listen": "127.0.0.1:$ADMIN_PORT",
  "public_dir": "$SITE_DIR",
  "static_routes": "exact",
  "profiles_file": "/run/credentials/tproxy-server.service/profiles.json"
}
EOF

  cat > /etc/tproxy-server/profiles.json <<EOF
{"profiles":[{"name":"default","secret":"$SECRET_ARG","backend":"127.0.0.1:2398"}]}
EOF
  chown root:tproxy /etc/tproxy-server/config.json /etc/tproxy-server/profiles.json
  chmod 0640 /etc/tproxy-server/config.json
  chmod 0400 /etc/tproxy-server/profiles.json
  ok "config.json и profiles.json записаны (порты $RELAY_PORT / $ADMIN_PORT)"
}

write_mtproxy_env() {
  local backend_secret="$SECRET_ARG"
  if [[ "$backend_secret" == dd* ]] && (( ${#backend_secret} == 34 )); then
    backend_secret="${backend_secret:2}"
  fi

  local local_address="" public_address="" mtproxy_nat_args=""
  local_address="$(ip -4 route get 149.154.175.50 2>/dev/null |
    sed -n 's/.*[[:space:]]src[[:space:]]\+\([0-9.]\+\).*/\1/p' | head -n1)" || true

  local probe candidate
  for probe in https://api.ipify.org https://ifconfig.co/ip https://icanhazip.com; do
    candidate="$(curl --fail --silent --show-error --location --ipv4 --max-time 15 \
      --proto '=https' --proto-redir '=https' --tlsv1.2 "$probe" 2>/dev/null |
      tr -d '[:space:]')" || continue
    if [[ "$candidate" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
      public_address="$candidate"; break
    fi
  done
  if [[ -z "$public_address" ]]; then
    public_address="$(getent ahostsv4 "$HOSTNAME_ARG" 2>/dev/null | awk 'NR==1 {print $1}')" || true
  fi

  if [[ -n "$local_address" && -n "$public_address" && "$local_address" != "$public_address" ]]; then
    mtproxy_nat_args="--nat-info $local_address:$public_address"
    info "NAT: $local_address → $public_address, использую --nat-info"
  elif [[ "$local_address" =~ ^(10\.|127\.|169\.254\.|192\.168\.|172\.(1[6-9]|2[0-9]|3[01])\.) && -z "$mtproxy_nat_args" ]]; then
    warn "локальный IP $local_address приватный, публичный не определён."
    warn "Если MTProxy будет молчать — задай MTPROXY_NAT_ARGS в /etc/mtproxy/mtproxy.env"
  fi

  mkdir -p /etc/mtproxy
  cat > /etc/mtproxy/mtproxy.env <<EOF
MTPROXY_SECRET=$backend_secret
MTPROXY_WORKERS=${WORKERS_ARG:-1}
MTPROXY_MAX_CONNECTIONS=${MAXCONN_ARG:-4096}
MTPROXY_NAT_ARGS=$mtproxy_nat_args
EOF
  chown root:mtproxy /etc/mtproxy/mtproxy.env
  chmod 0640 /etc/mtproxy/mtproxy.env
  ok "mtproxy.env записан"
}

install_units() {
  local src dst
  local -A units=(
    ["$REPO_DIR/deploy/tproxy-server.service"]="/etc/systemd/system/tproxy-server.service"
    ["$REPO_DIR/deploy/mtproxy.service"]="/etc/systemd/system/mtproxy.service"
    ["$REPO_DIR/deploy/tproxy-firewall.service"]="/etc/systemd/system/tproxy-firewall.service"
    ["$REPO_DIR/deploy/refresh-mtproxy-config.service"]="/etc/systemd/system/refresh-mtproxy-config.service"
    ["$REPO_DIR/deploy/refresh-mtproxy-config.timer"]="/etc/systemd/system/refresh-mtproxy-config.timer"
  )
  for src in "${!units[@]}"; do
    dst="${units[$src]}"
    if [[ -f "$dst" ]] && cmp -s "$src" "$dst"; then
      info "  юнит без изменений: $(basename "$dst")"
    else
      [[ -f "$dst" ]] && cp -a "$dst" "${dst}.bak.$(date +%s)"
      install -m 0644 "$src" "$dst"
      info "  юнит обновлён: $(basename "$dst")"
    fi
  done
  install -m 0644 "$REPO_DIR/deploy/firewall.nft" /etc/tproxy-server/firewall.nft 2>/dev/null || true
  install -m 0755 "$REPO_DIR/deploy/refresh-mtproxy-config.sh" /usr/local/sbin/refresh-mtproxy-config 2>/dev/null || true
  ok "systemd units синхронизированы"
}

install_caddyfile() {
  if [[ -s /etc/caddy/Caddyfile ]] &&
     grep -Fq '{$TPROXY_HOSTNAME}' /etc/caddy/Caddyfile &&
     grep -Fq "127.0.0.1:$RELAY_PORT" /etc/caddy/Caddyfile; then
    ok "Caddyfile уже настроен для tproxy и relay-порта $RELAY_PORT — оставляю без изменений"
  else
    if [[ -e /etc/caddy/Caddyfile ]]; then
      cp -a /etc/caddy/Caddyfile "/etc/caddy/Caddyfile.before-tproxy.$(date +%Y%m%d%H%M%S)"
    fi
    install -m 0644 "$REPO_DIR/deploy/Caddyfile" /etc/caddy/Caddyfile
    sed -i -E "s#(reverse_proxy[[:space:]]+127\.0\.0\.1:)[0-9]+#\1${RELAY_PORT}#g" /etc/caddy/Caddyfile
    ok "Caddyfile установлен (reverse_proxy → 127.0.0.1:$RELAY_PORT)"
  fi

  if [[ -e /etc/systemd/system/caddy.service ]] && \
     ! cmp -s /etc/systemd/system/caddy.service "$REPO_DIR/deploy/caddy.service"; then
    cp -a /etc/systemd/system/caddy.service \
      "/etc/systemd/system/caddy.service.before-tproxy.$(date +%Y%m%d%H%M%S)"
  fi
  install -m 0644 "$REPO_DIR/deploy/caddy.service" /etc/systemd/system/caddy.service
  install -d -m 0755 /etc/systemd/system/caddy.service.d
  cat > /etc/systemd/system/caddy.service.d/tproxy.conf <<EOF
[Service]
Environment=TPROXY_HOSTNAME=$HOSTNAME_ARG
Environment=TPROXY_SITE_ROOT=$SITE_DIR
Environment=ACME_EMAIL=$EMAIL_ARG
EOF
  ok "caddy.service + drop-in установлены"
}

verify_site_permissions() {
  info "Проверяю права на $SITE_DIR…"
  local unreadable=0
  while IFS= read -r -d '' f; do
    if ! sudo -u tproxy test -r "$f"; then
      warn "tproxy не может прочитать: $f"
      unreadable=1
    fi
  done < <(find "$SITE_DIR" -type f -print0)
  if [[ $unreadable -eq 1 ]]; then
    die "tproxy не может читать сайт. Исправь права вручную; установщик не меняет права существующего сайта."
    :
    :
    :
  fi
  ok "Права на сайт в порядке"
}

validate_configs() {
  verify_site_permissions
  info "Валидация config.json…"
  /usr/local/bin/tproxy-server -config /etc/tproxy-server/config.json \
    -profiles-file /etc/tproxy-server/profiles.json -check \
    || die "tproxy-server -check упал"
  if [[ "$WEB_SERVER" == "caddy" ]]; then
    info "Валидация Caddyfile…"
    TPROXY_HOSTNAME="$HOSTNAME_ARG" TPROXY_SITE_ROOT="$SITE_DIR" ACME_EMAIL="$EMAIL_ARG" /usr/local/bin/caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile || die "caddy validate упал"
  else
    info "Валидация Nginx…"
    nginx -t || die "nginx -t упал"
  fi
  printf "%s\n" "$WEB_SERVER" > /etc/tproxy-server/web-server
  chmod 0640 /etc/tproxy-server/web-server
  ok "Конфиги валидны"
}

start_services() {
  systemctl daemon-reload
  systemctl enable tproxy-firewall.service 2>/dev/null || true
  systemctl enable mtproxy.service 2>/dev/null || true
  systemctl enable tproxy-server.service 2>/dev/null || true
  systemctl enable --now refresh-mtproxy-config.timer 2>/dev/null || true
  if [[ "$WEB_SERVER" == "caddy" ]]; then systemctl enable caddy.service 2>/dev/null || true; systemctl disable --now nginx.service 2>/dev/null || true; else systemctl enable nginx.service 2>/dev/null || true; systemctl disable --now caddy.service 2>/dev/null || true; fi

  systemctl is-active --quiet mtproxy || systemctl start mtproxy
  systemctl is-active --quiet tproxy-firewall || systemctl start tproxy-firewall
  systemctl is-active --quiet tproxy-server || systemctl start tproxy-server
  if [[ "$WEB_SERVER" == "caddy" ]]; then systemctl is-active --quiet caddy || systemctl start caddy; else systemctl is-active --quiet nginx || systemctl start nginx; systemctl enable --now certbot.timer 2>/dev/null || true; fi

  ok "Сервисы проверены/запущены"
}

wait_ready() {
  local attempt
  info "Ждём readyz на 127.0.0.1:$ADMIN_PORT (до 30с)…"
  for (( attempt=0; attempt<30; attempt++ )); do
    if curl --fail --silent --output /dev/null "http://127.0.0.1:$ADMIN_PORT/readyz"; then
      ok "relay готов"
      return 0
    fi
    sleep 1
  done
  warn "readyz не ответил за 30с"
  echo
  echo "=== Диагностика ==="
  echo "--- tproxy-server ---"
  systemctl status tproxy-server --no-pager -l 2>/dev/null | head -20 || true
  journalctl -u tproxy-server -n 20 --no-pager 2>/dev/null || true
  echo "--- mtproxy ---"
  systemctl status mtproxy --no-pager -l 2>/dev/null | head -15 || true
  echo "--- порты ---"
  ss -lntp 2>/dev/null | grep -E ":2398|:$RELAY_PORT|:$ADMIN_PORT" || true
  echo "--- права сайта ---"
  ls -la "$SITE_DIR" 2>/dev/null || true
  return 1
}

web_proxy_secret() {
  if [[ -z "$BASE_PATH_ARG" ]]; then printf %s "$SECRET_ARG"; return; fi
  {
    printf '\x70'
    printf "$(printf %s "$SECRET_ARG" | sed 's/../\\x&/g')"
  } | base64 | tr '+/' '-_' | tr -d '=\n'
}

generate_proxy_qr() {
  local link="$1" qr_file="${2:-/etc/tproxy-server/proxy-qr.png}"
  command -v qrencode >/dev/null 2>&1 || die "qrencode не установлен"
  install -d -m 0750 /etc/tproxy-server
  qrencode -o "$qr_file" -t PNG -s 8 -m 2 "$link"
  chmod 0600 "$qr_file"
  chown root:root "$qr_file"
  ok "QR-код сохранён: $qr_file (права 0600)"
}

print_proxy_qr_terminal() {
  local link="$1"
  [[ -n "$link" ]] || return 0
  command -v qrencode >/dev/null 2>&1 || die "qrencode не установлен"
  echo
  echo "QR-код для подключения (отсканируй камерой телефона):"
  qrencode -t ANSIUTF8 -m 2 "$link"
  echo
}

print_summary() {
  local client_address="$HOSTNAME_ARG"
  if [[ -n "$BASE_PATH_ARG" ]]; then
    client_address="$HOSTNAME_ARG/$BASE_PATH_ARG"
  fi
  local proxy_secret; proxy_secret="$(web_proxy_secret)"
  local proxy_link="https://t.me/webproxy?server=${client_address//\//%2F}&secret=$proxy_secret"
  generate_proxy_qr "$proxy_link"
  cat <<EOF

--------------------------------------------------------------------
tproxy-server развёрнут
--------------------------------------------------------------------
 Хостнейм:        $HOSTNAME_ARG
 Base path:       ${BASE_PATH_ARG:-<root>}
 Сайт:            https://$HOSTNAME_ARG/
 Relay-порт:      127.0.0.1:$RELAY_PORT
 Admin-порт:      127.0.0.1:$ADMIN_PORT

 Internal secret: $SECRET_ARG
 Proxy server:    $client_address
 Proxy secret:    $proxy_secret
 Proxy link:      $proxy_link
 QR image:        /etc/tproxy-server/proxy-qr.png

 Проверка:
   curl -fsS http://127.0.0.1:$ADMIN_PORT/healthz
   curl -fsS http://127.0.0.1:$ADMIN_PORT/readyz
   curl -fsS https://$HOSTNAME_ARG/

 Firewall — разрешить входящие TCP:
   - 80/tcp  — HTTP (редирект и ACME/Let's Encrypt)
   - 443/tcp — HTTPS (сайт и Web Proxy)

 Не открывать наружу:
   - $RELAY_PORT/tcp — relay слушает только 127.0.0.1
   - $ADMIN_PORT/tcp — admin/health слушает только 127.0.0.1
   - 2398/tcp и 8888/tcp — внутренние порты MTProxy,
     блокируются локальным firewall tproxy_backend.

 Правило относится и к firewall сервера, и к firewall
 провайдера/VPS (Security Group). UDP для этой конфигурации
 открывать не требуется.
--------------------------------------------------------------------
EOF
  print_proxy_qr_terminal "$proxy_link"
}


run_config() {
  local cfg=/etc/tproxy-server/config.json profiles=/etc/tproxy-server/profiles.json
  local envf=/etc/mtproxy/mtproxy.env host="" base="" relay="" admin="" public_dir="" email="" web_server=""
  local backend="" secret="" workers="" maxconn="" nat="" proxy_secret="" server="" link="" output=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --output) [[ $# -ge 2 ]] || die "--output требует путь"; output="$2"; shift 2 ;;
      *) die "Неизвестная опция config: $1" ;;
    esac
  done
  if [[ -r "$cfg" ]] && command -v jq >/dev/null 2>&1; then
    host="$(jq -r '.public_hostname // empty' "$cfg")"
    base="$(jq -r '.base_path // empty' "$cfg")"
    relay="$(jq -r '.listen // empty' "$cfg")"
    admin="$(jq -r '.admin_listen // empty' "$cfg")"
    public_dir="$(jq -r '.public_dir // empty' "$cfg")"
  fi
  if [[ -r "$profiles" ]] && command -v jq >/dev/null 2>&1; then
    secret="$(jq -r '.profiles[0].secret // empty' "$profiles")"
    backend="$(jq -r '.profiles[0].backend // empty' "$profiles")"
  fi
  if [[ -r /etc/tproxy-server/acme-email ]]; then
    email="$(head -n1 /etc/tproxy-server/acme-email | xargs || true)"
  fi
  if [[ -z "$email" && -r /etc/systemd/system/caddy.service.d/tproxy.conf ]]; then
    email="$(sed -n 's/^Environment=ACME_EMAIL=//p' /etc/systemd/system/caddy.service.d/tproxy.conf | head -n1)"
  fi
  if [[ -z "$email" && -d /etc/letsencrypt/renewal ]]; then
    email="$(grep -RhoE '^[[:space:]]*email[[:space:]]*=[[:space:]]*[^[:space:]]+' /etc/letsencrypt/renewal 2>/dev/null | head -n1 | cut -d= -f2- | xargs || true)"
  fi
  if [[ -r /etc/tproxy-server/web-server ]]; then
    web_server="$(cat /etc/tproxy-server/web-server)"
  elif systemctl is-enabled --quiet nginx 2>/dev/null; then
    web_server=nginx
  else
    web_server=caddy
  fi
  if [[ -r "$envf" ]]; then
    workers="$(sed -n 's/^MTPROXY_WORKERS=//p' "$envf" | head -n1)"
    maxconn="$(sed -n 's/^MTPROXY_MAX_CONNECTIONS=//p' "$envf" | head -n1)"
    nat="$(sed -n 's/^MTPROXY_NAT_ARGS=//p' "$envf" | head -n1)"
  fi
  if [[ -n "$host" && -n "$secret" ]]; then
    BASE_PATH_ARG="$base"; SECRET_ARG="$secret"
    proxy_secret="$(web_proxy_secret)"
    server="$host"; if [[ -n "$base" ]]; then server="$host/$base"; fi
    link="https://t.me/webproxy?server=${server//\//%2F}&secret=$proxy_secret"
    generate_proxy_qr "$link" >/dev/null
  fi
  local report
  report="$(cat <<EOF
==================== ТЕКУЩАЯ КОНФИГУРАЦИЯ ====================
  Домен                    : ${host:-<не задан>}
  Base path                : ${base:-<root / не задан>}
  Relay listen             : ${relay:-<не задан>}
  Admin listen             : ${admin:-<не задан>}
  MTProxy backend          : ${backend:-<не задан>}
  Публичный каталог        : ${public_dir:-<не задан>}
  Каталог сайта            : ${public_dir:-$SITE_DIR_DEFAULT}
  Конфигурация relay       : $cfg
  Профили                  : $profiles
  Переменные MTProxy       : $envf
  Workers                  : ${workers:-<не задан>}
  Max connections          : ${maxconn:-<не задан>}
  NAT args                 : ${nat:-<не задан>}
  E-mail для Let's Encrypt : ${email:-<не найден>}
  Веб-сервер               : ${web_server:-<не определён>}
  Формат секрета           : $(if [[ "$secret" == dd* ]]; then echo "dd + 32 hex"; elif [[ -n "$secret" ]]; then echo "32 hex"; else echo "<не задан>"; fi)
  Секрет клиента           : ${secret:-<не задан>}

Слушающие TCP-порты прокси:
$(proxy_ports_table "$relay" "$admin" "$backend")

Ссылки подключения:
${link:-<не удалось сформировать: проверь config.json и profiles.json>}
QR-код (PNG)          : ${link:+/etc/tproxy-server/proxy-qr.png}
==============================================================
EOF
)"
  if [[ -n "$output" ]]; then
    install -m 0600 /dev/null "$output"
    printf '%s\n' "$report" | sed -E 's/\x1B\[[0-9;]*[[:alpha:]]//g' > "$output"
    echo "Конфигурация сохранена: $output (0600)"
  else
    printf '%s\n' "$report"
  fi

  # Выводим состояния служб отдельно от многострочного отчёта,
  # чтобы ANSI-цвета гарантированно доходили до терминала.
  if [[ -n "$output" ]]; then
    {
      printf '\nСостояние служб:\n'
      for s in mtproxy tproxy-firewall tproxy-server refresh-mtproxy-config.timer "$web_server"; do
        state="$(systemctl is-active "$s" 2>/dev/null || true)"
        if [[ "$state" == active ]]; then
          mark='[✓]'
        elif [[ "$state" == inactive || "$state" == failed ]]; then
          mark='[✗]'
        else
          mark='[!]'
        fi
        printf '  %s %-28s %s\n' "$mark" "$s" "${state:-unknown}"
      done
    } >> "$output"
  else
    printf '\nСостояние служб:\n'
    for s in mtproxy tproxy-firewall tproxy-server refresh-mtproxy-config.timer "$web_server"; do
      state="$(systemctl is-active "$s" 2>/dev/null || true)"
      if [[ "$state" == active ]]; then
        mark="$(status_mark ok)"
      elif [[ "$state" == inactive || "$state" == failed ]]; then
        mark="$(status_mark fail)"
      else
        mark="$(status_mark warn)"
      fi
      printf '  %s %-28s %s\n' "$mark" "$s" "$(status_word "${state:-unknown}")"
    done
  fi
  if [[ -n "$link" ]]; then print_proxy_qr_terminal "$link"; fi
}

load_existing_config() {
  local cfg=/etc/tproxy-server/config.json profiles=/etc/tproxy-server/profiles.json
  local envf=/etc/mtproxy/mtproxy.env dropin=/etc/systemd/system/caddy.service.d/tproxy.conf v
  [[ -r "$cfg" && -r "$profiles" && -r "$envf" ]] || die "Не найдена полная установленная конфигурация; сначала выполни config"
  command -v jq >/dev/null 2>&1 || die "Для чтения настроек нужен jq"
  v="$(jq -er '.public_hostname | select(type == "string" and length > 0)' "$cfg")" || die "Не удалось прочитать hostname"
  [[ -n "$HOSTNAME_ARG" ]] || HOSTNAME_ARG="$v"
  v="$(jq -r '.base_path // "none"' "$cfg")"; [[ -n "$BASE_PATH_ARG" ]] || BASE_PATH_ARG="$v"
  v="$(jq -r '.listen // "" | split(":")[-1]' "$cfg")"; [[ -n "$RELAY_PORT" ]] || RELAY_PORT="$v"
  v="$(jq -r '.admin_listen // "" | split(":")[-1]' "$cfg")"; [[ -n "$ADMIN_PORT" ]] || ADMIN_PORT="$v"
  v="$(jq -r '.public_dir // empty' "$cfg")"; [[ -n "$v" ]] && SITE_DIR="$v"
  if [[ "$WEB_SERVER_SET" -eq 0 ]]; then if [[ -r /etc/tproxy-server/web-server ]]; then WEB_SERVER="$(< /etc/tproxy-server/web-server)"; elif systemctl is-enabled --quiet nginx 2>/dev/null; then WEB_SERVER=nginx; else WEB_SERVER=caddy; fi; fi
  v="$(jq -er '.profiles[0].secret | select(type == "string" and length > 0)' "$profiles")" || die "Не удалось прочитать секрет"
  [[ -n "$SECRET_ARG" ]] || SECRET_ARG="$v"
  if [[ "$SECRET_PREFIX_MODE_SET" -eq 0 ]]; then
    if [[ "$SECRET_ARG" == dd* ]]; then SECRET_PREFIX_MODE="dd"; else SECRET_PREFIX_MODE="plain"; fi
  fi
  v="$(sed -n 's/^MTPROXY_WORKERS=//p' "$envf" | head -n1)"; [[ -n "$WORKERS_ARG" ]] || WORKERS_ARG="${v:-1}"
  v="$(sed -n 's/^MTPROXY_MAX_CONNECTIONS=//p' "$envf" | head -n1)"; [[ -n "$MAXCONN_ARG" ]] || MAXCONN_ARG="${v:-4096}"
  if [[ -r /etc/tproxy-server/acme-email ]]; then
    v="$(head -n1 /etc/tproxy-server/acme-email | xargs || true)"
    [[ -n "$EMAIL_ARG" ]] || EMAIL_ARG="$v"
  fi
  if [[ -z "$EMAIL_ARG" && -r "$dropin" ]]; then
    v="$(sed -n 's/^Environment=ACME_EMAIL=//p' "$dropin" | head -n1)"
    [[ -n "$EMAIL_ARG" ]] || EMAIL_ARG="$v"
  fi
  if [[ -z "$EMAIL_ARG" && -d /etc/letsencrypt/renewal ]]; then
    v="$(grep -RhoE '^[[:space:]]*email[[:space:]]*=[[:space:]]*[^[:space:]]+' /etc/letsencrypt/renewal 2>/dev/null | head -n1 | cut -d= -f2- | xargs || true)"
    [[ -n "$EMAIL_ARG" ]] || EMAIL_ARG="$v"
  fi
  if [[ -z "$EMAIL_ARG" ]]; then
    if [[ "$NONINTERACTIVE" == "1" ]]; then
      die "Не удалось прочитать email; укажи --email"
    fi
    prompt_value EMAIL_ARG "Email для Let's Encrypt" validate_email
  fi
  validate_hostname "$HOSTNAME_ARG" >/dev/null || die "Некорректный текущий hostname"
  validate_email "$EMAIL_ARG" >/dev/null || die "Некорректный текущий email"
  install -d -m 0755 /etc/tproxy-server
  printf '%s\n' "$EMAIL_ARG" > /etc/tproxy-server/acme-email
  chmod 0600 /etc/tproxy-server/acme-email
  validate_port "$RELAY_PORT" >/dev/null || die "Некорректный текущий relay-порт"
  validate_port "$ADMIN_PORT" >/dev/null || die "Некорректный текущий admin-порт"
  validate_secret "$SECRET_ARG" >/dev/null || die "Некорректный текущий секрет"
  validate_base_path "$BASE_PATH_ARG" >/dev/null || die "Некорректный текущий base_path"
}

prompt_update_value() {
  local var="$1" label="$2" current="$3" validator="$4" input err
  while :; do
    read -r -p "$label [$current] (Enter — оставить): " input || die "ввод прерван"
    input="${input:-$current}"
    if err="$("$validator" "$input")"; then printf -v "$var" '%s' "$input"; return 0; fi
    echo "  ⚠️  $err — попробуй ещё раз"
  done
}

prompt_update_port() {
  local var="$1" label="$2" current="$3" input err
  while :; do
    read -r -p "$label [$current] (Enter — оставить): " input || die "ввод прерван"
    input="${input:-$current}"
    if ! err="$(validate_port "$input")"; then echo "  ⚠️  $err"; continue; fi
    if [[ "$input" != "$current" ]] && port_in_use "$input"; then echo "  ⚠️  порт $input уже занят"; continue; fi
    printf -v "$var" '%s' "$input"; return 0
  done
}

prompt_update_secret() {
  local answer s1 s2
  read -r -p "Секрет MTProxy [текущий сохранится] (Enter — оставить, n — заменить): " answer || die "ввод прерван"
  [[ "$answer" =~ ^[Nn]$ ]] || return 0
  while :; do
    read -r -s -p "Новый секрет (Enter — сгенерировать): " s1 || die "ввод прерван"; echo
    if [[ -z "$s1" ]]; then
      SECRET_ARG="$(openssl rand -hex 16)"
      [[ "$SECRET_PREFIX_MODE" == "dd" ]] && SECRET_ARG="dd$SECRET_ARG"
      info "Сгенерирован новый секрет"; return 0
    fi
    read -r -s -p "Повторите секрет: " s2 || die "ввод прерван"; echo
    [[ "$s1" == "$s2" ]] || { echo "  ⚠️  секреты не совпадают"; continue; }
    validate_secret "$s1" >/dev/null || { echo "  ⚠️  Неверный формат секрета"; continue; }
    SECRET_ARG="$s1"; return 0
  done
}

interactive_update_fill() {
  load_existing_config
  if [[ "$NONINTERACTIVE" == "1" ]]; then
    [[ "$RELAY_PORT" != "$ADMIN_PORT" ]] || die "relay- и admin-порты должны различаться"
    return 0
  fi
  echo
  echo "────────────────────────────────────────────────────────────"
  echo "  Обновление tproxy-server"
  echo "  Текущие значения указаны в [квадратных скобках]."
  echo "  Enter — оставить без изменений."
  echo "────────────────────────────────────────────────────────────"
  prompt_update_value HOSTNAME_ARG "Домен" "$HOSTNAME_ARG" validate_hostname
  # Email is retained from the existing ACME configuration; --email can override it.
  prompt_update_value BASE_PATH_ARG "Base path (none — корень)" "$BASE_PATH_ARG" validate_base_path
  prompt_update_port RELAY_PORT "Relay-порт" "$RELAY_PORT"
  prompt_update_port ADMIN_PORT "Admin-порт" "$ADMIN_PORT"
  [[ "$RELAY_PORT" != "$ADMIN_PORT" ]] || die "relay- и admin-порты должны различаться"
  prompt_update_secret

  local input
  while :; do
    read -r -p "MTProxy workers [$WORKERS_ARG] (Enter — оставить): " input || die "ввод прерван"
    input="${input:-$WORKERS_ARG}"
    if [[ "$input" =~ ^[1-9][0-9]*$ ]] && (( input <= 256 )); then WORKERS_ARG="$input"; break; fi
    echo "  ⚠️  workers должен быть числом от 1 до 256"
  done
  while :; do
    read -r -p "MTProxy max connections [$MAXCONN_ARG] (Enter — оставить): " input || die "ввод прерван"
    input="${input:-$MAXCONN_ARG}"
    if [[ "$input" =~ ^[1-9][0-9]*$ ]]; then MAXCONN_ARG="$input"; break; fi
    echo "  ⚠️  max connections должен быть положительным числом"
  done

  echo
  echo "Итоговые параметры:"
  echo "  Домен      : $HOSTNAME_ARG"
  echo "  Email      : $EMAIL_ARG"
  echo "  Base path  : $BASE_PATH_ARG"
  echo "  Relay port : $RELAY_PORT"
  echo "  Admin port : $ADMIN_PORT"
  echo "  Секрет     : сохранён / изменён (значение скрыто)"
  echo "  Workers    : $WORKERS_ARG"
  echo "  Max conns  : $MAXCONN_ARG"
  echo "  Каталог    : $SITE_DIR"
  confirm "Применить обновление?" || die "обновление отменено"
}


show_operation_overview() {
  echo
  echo "--------------------------------------------------------------------"
  if [[ "$MODE" == "update" ]]; then
    echo "  ПЕРЕД ОБНОВЛЕНИЕМ"
    cat <<'EOF'
  Будут обновлены исходники и компоненты, пересобран tproxy-server,
  обновлены конфигурации и перезапущены службы.
  Текущие настройки будут предложены по умолчанию, каталог сайта сохранится.
EOF
  else
    echo "  ПЕРЕД УСТАНОВКОЙ"
    cat <<'EOF'
  Сначала будет проверено, какие зависимости и компоненты уже установлены.
  Будут добавлены только отсутствующие пакеты; существующие Go, Caddy,
  Nginx и подходящая сборка MTProxy будут повторно использованы.
  Конфигурации сторонних сайтов сохраняются или резервируются перед изменением.
  Домен должен указывать на IP этого сервера.
EOF
  fi
  cat <<'EOF'

  ПОРТЫ
  - 80/tcp и 443/tcp — публичные HTTP/HTTPS для Caddy/Nginx; должны быть
    доступны извне. При установке их не должен занимать другой веб-сервер;
    при обновлении их может занимать уже установленный Caddy или Nginx.
  - 8080/tcp и 8081/tcp — внутренние порты приложения (127.0.0.1).
    При установке должны быть свободны; при смене портов при обновлении
    свободными должны быть новые значения. Не открывать в интернет.
  - 2398/tcp и 8888/tcp — внутренние порты MTProxy, закрыты firewall.

  В firewall VPS разреши входящие TCP 80 и 443. UDP не требуется.
  Нужен root-доступ; службы могут быть перезапущены.
EOF
  echo "--------------------------------------------------------------------"
  echo
}

run_install() {
  require_root
  check_arch
  check_os
  preflight_basics
  show_operation_overview
  if [[ "$MODE" == "update" ]]; then
    interactive_update_fill
  else
    interactive_fill
  fi
  preflight_system
  install -d -m 0755 /etc/tproxy-server
  printf '%s\n' "$EMAIL_ARG" > /etc/tproxy-server/acme-email
  chmod 0600 /etc/tproxy-server/acme-email
  install_deps
  check_dns
  fetch_repo
  resolve_base_path
  ensure_tproxy_user
  local previous_web_server=""
  previous_web_server="$(cat /etc/tproxy-server/web-server 2>/dev/null || true)"
  # Останавливаем конкурирующий веб-сервер ДО проверки/перезапуска выбранного:
  # иначе он продолжит занимать 80/443 (особенно при установке без marker-файла).
  if [[ "$WEB_SERVER" == "caddy" ]]; then
    if [[ "$previous_web_server" == "nginx" ]]; then
      warn "Предыдущий веб-сервер Nginx будет заменён на Caddy согласно выбранной конфигурации."
      confirm "Продолжить переключение Nginx → Caddy?" || die "переключение отменено"
      remove_nginx
    fi
    install_caddy
  else
    if [[ "$previous_web_server" == "caddy" ]]; then
      warn "Предыдущий веб-сервер Caddy будет заменён на Nginx согласно выбранной конфигурации."
      confirm "Продолжить переключение Caddy → Nginx?" || die "переключение отменено"
      remove_caddy
    fi
    install_nginx_packages
  fi
  install_mtproxy_backend
  ensure_go
  build_tproxy
  install_stub_site
  write_configs
  write_mtproxy_env
  install_units
  if [[ "$WEB_SERVER" == "caddy" ]]; then
    if caddy_config_compatible; then ok "Совместимая конфигурация Caddy уже существует — запись пропущена."
    else install_caddyfile; fi
  else
    if nginx_config_compatible; then ok "Совместимая конфигурация Nginx уже существует — запись и reload пропущены."
    else install_nginx_config; fi
  fi
  validate_configs
  start_services
  wait_ready || die "relay не стал ready"
  print_summary
}

# ============================================================================
#  УДАЛЕНИЕ
# ============================================================================

run_uninstall() {
  require_root
  local installed_web_server
  installed_web_server="$(cat /etc/tproxy-server/web-server 2>/dev/null || true)"
  # Совместимость со старыми установками без marker-файла.
  if [[ "$installed_web_server" != "caddy" && "$installed_web_server" != "nginx" ]]; then
    if systemctl is-active --quiet caddy.service || systemctl is-enabled --quiet caddy.service 2>/dev/null || \
       [[ -x /usr/local/bin/caddy || -x /usr/bin/caddy ]]; then
      installed_web_server="caddy"
    elif systemctl is-active --quiet nginx.service || systemctl is-enabled --quiet nginx.service 2>/dev/null || \
         dpkg-query -W -f='${Status}' nginx 2>/dev/null | grep -q 'install ok installed'; then
      installed_web_server="nginx"
    fi
  fi
  echo "------------------------------------------------------------"
  echo "  Удаление tproxy-server"
  echo "------------------------------------------------------------"
  echo "Будет удалено:"
  echo "  - сервисы: tproxy-server, mtproxy, tproxy-firewall, refresh-mtproxy-config"
  echo "  - каталоги: $REPO_DIR, /etc/tproxy-server, /etc/mtproxy; сайт $SITE_DIR сохраняется"
  echo "  - бинарники: /usr/local/bin/tproxy-server, /usr/local/bin/mtproxy"
  echo "  - nftables: inet tproxy_backend"
  echo "  - пользователи: tproxy, mtproxy"
  if [[ $KEEP_WEB_SERVER -eq 0 ]]; then echo "  - веб-сервер: будет спрошено отдельно"; else echo "  - веб-сервер: НЕ будет удалён (--keep-web-server)"; fi
  echo
  confirm "Продолжить?" || die "отменено"

  local svc
  for svc in tproxy-server mtproxy tproxy-firewall refresh-mtproxy-config.timer refresh-mtproxy-config.service; do
    systemctl stop "$svc" 2>/dev/null || true
    systemctl disable "$svc" 2>/dev/null || true
  done
  rm -f /etc/systemd/system/tproxy-server.service
  rm -f /etc/systemd/system/mtproxy.service
  rm -f /etc/systemd/system/tproxy-firewall.service
  rm -f /etc/systemd/system/refresh-mtproxy-config.service
  rm -f /etc/systemd/system/refresh-mtproxy-config.timer
  rm -rf /etc/systemd/system/tproxy-server.service.d
  rm -f /etc/tproxy-server/web-server
  systemctl daemon-reload

  nft delete table inet tproxy_backend 2>/dev/null || true

  rm -rf "$REPO_DIR" /etc/tproxy-server /etc/mtproxy
  info "Каталог сайта $SITE_DIR сохранён."
  rm -f /usr/local/bin/tproxy-server /usr/local/bin/mtproxy
  rm -f /usr/local/sbin/refresh-mtproxy-config

  userdel -r tproxy 2>/dev/null || true
  userdel -r mtproxy 2>/dev/null || true

  if [[ $KEEP_WEB_SERVER -eq 0 ]] && confirm "Удалить веб-сервер ${installed_web_server:-Caddy/Nginx}?"; then
    case "$installed_web_server" in caddy) remove_caddy ;; nginx) remove_nginx ;; *) warn "Не удалось определить установленный веб-сервер; веб-серверы не затронуты" ;; esac
  fi

  ok "Удаление завершено"
}

remove_decoy_site() {
  require_root
  local configured_site=""
  if command -v jq >/dev/null 2>&1 && [[ -r /etc/tproxy-server/config.json ]]; then
    configured_site="$(jq -r '.public_dir // empty' /etc/tproxy-server/config.json 2>/dev/null || true)"
  fi
  if [[ -n "$configured_site" && "$configured_site" == /* ]]; then SITE_DIR="$configured_site"; fi

  ui_header "Удаление decoy-сайта"
  if [[ ! -d "$SITE_DIR" ]]; then info "Каталог сайта не найден: $SITE_DIR"; return 0; fi
  if [[ ! -f "$SITE_DIR/index.html" ]] || ! grep -qF '<title>Vibe Studio — код в потоке</title>' "$SITE_DIR/index.html"; then
    warn "Каталог $SITE_DIR не распознан как штатный decoy-сайт Vibe Studio. Ничего не удалено."
    return 1
  fi
  info "Будет удалён только штатный decoy-сайт: $SITE_DIR"
  confirm "Удалить decoy-сайт?" || { info "Удаление отменено."; return 0; }
  rm -rf -- "$SITE_DIR"
  ok "Decoy-сайт удалён: $SITE_DIR"
}

remove_web_server_interactive() {
  require_root
  local installed_web_server
  installed_web_server="$(cat /etc/tproxy-server/web-server 2>/dev/null || true)"
  if [[ "$installed_web_server" != caddy && "$installed_web_server" != nginx ]]; then
    if systemctl is-active --quiet nginx.service || command -v nginx >/dev/null 2>&1; then installed_web_server=nginx
    elif systemctl is-active --quiet caddy.service || [[ -x /usr/local/bin/caddy || -x /usr/bin/caddy ]]; then installed_web_server=caddy
    else warn "Установленный Caddy/Nginx не обнаружен."; return 0; fi
  fi
  ui_header "Удаление веб-сервера"
  warn "Будет удалён $installed_web_server и его конфигурация."
  warn "Если прокси использует этот веб-сервер, публичное подключение перестанет работать до повторной настройки."
  if [[ "$installed_web_server" == caddy ]]; then warn "Удаление Caddy затрагивает /etc/caddy и данные Caddy."; fi
  confirm "Удалить $installed_web_server?" || { info "Удаление отменено."; return 0; }
  case "$installed_web_server" in caddy) remove_caddy ;; nginx) remove_nginx ;; esac
  ok "$installed_web_server удалён."
}

run_purge() {
  local configured_site=""
  if command -v jq >/dev/null 2>&1 && [[ -r /etc/tproxy-server/config.json ]]; then
    configured_site="$(jq -r '.public_dir // empty' /etc/tproxy-server/config.json 2>/dev/null || true)"
  fi
  if [[ -n "$configured_site" && "$configured_site" == /* ]]; then SITE_DIR="$configured_site"; fi
  KEEP_WEB_SERVER=0
  run_uninstall
  remove_decoy_site
}

# ============================================================================
#  МЕНЮ
# ============================================================================

diagnostics_command() {
  local failed=0 warnings=0 svc state file web_server host relay admin backend backend_port cert_path expiry
  web_server="$(cat /etc/tproxy-server/web-server 2>/dev/null || true)"
  [[ "$web_server" == "nginx" || "$web_server" == "caddy" ]] || {
    if systemctl is-enabled --quiet nginx 2>/dev/null; then web_server=nginx; else web_server=caddy; fi
  }
  host="$(jq -r '.public_hostname // empty' /etc/tproxy-server/config.json 2>/dev/null || true)"
  relay="$(jq -r '.listen // empty' /etc/tproxy-server/config.json 2>/dev/null || true)"
  admin="$(jq -r '.admin_listen // empty' /etc/tproxy-server/config.json 2>/dev/null || true)"
  backend="$(jq -r '.profiles[0].backend // empty' /etc/tproxy-server/profiles.json 2>/dev/null || true)"
  backend_port="${backend##*:}"

  echo
  echo "------------------------------------------------------------"
  echo "  ДИАГНОСТИКА И ПОИСК НЕИСПРАВНОСТЕЙ"
  echo "------------------------------------------------------------"

  echo
  echo "1. Состояние служб"
  for svc in tproxy-server mtproxy tproxy-firewall refresh-mtproxy-config.timer "$web_server"; do
    state="$(systemctl is-active "$svc" 2>/dev/null || true)"
    if [[ "$state" == active ]]; then
      printf '  %s %-30s %s\n' "$(status_mark ok)" "$svc" "$(status_word active)"
    else
      printf '  %s %-30s %s\n' "$(status_mark fail)" "$svc" "$(status_word "${state:-unknown}")"
      failed=1
    fi
  done

  echo
  echo "2. Конфигурационные файлы и права"
  for file in /etc/tproxy-server/config.json /etc/tproxy-server/profiles.json /etc/mtproxy/mtproxy.env; do
    if [[ ! -f "$file" ]]; then
      printf '  %s %s — отсутствует\n' "$(status_mark fail)" "$file"; failed=1
    elif [[ "$file" == *.json ]] && ! jq empty "$file" >/dev/null 2>&1; then
      printf '  %s %s — некорректный JSON\n' "$(status_mark fail)" "$file"; failed=1
    else
      printf '  %s %s — доступен (права %s)\n' "$(status_mark ok)" "$file" "$(stat -c %a "$file" 2>/dev/null || echo '?')"
    fi
  done

  echo
  echo "3. Сетевая цепочка и прослушиваемые порты"
  local port label
  for port in 80 443 "${relay##*:}" "${admin##*:}" "$backend_port"; do
    [[ "$port" =~ ^[0-9]+$ ]] || continue
    case "$port" in
      80) label="HTTP / ACME" ;; 443) label="HTTPS / веб-сервер" ;;
      "${admin##*:}") label="tproxy-server health" ;;
      "$backend_port") label="MTProxy backend (порт из конфигурации)" ;; *) label="tproxy-server relay" ;;
    esac
    if ss -lntH 2>/dev/null | awk -v p=":$port" '$4 ~ (p "$") { found=1 } END { exit !found }'; then
      printf '  %s %s слушает TCP-порт %s\n' "$(status_mark ok)" "$label" "$port"
    else
      printf '  %s %s не слушает TCP-порт %s\n' "$(status_mark fail)" "$label" "$port"; failed=1
    fi
  done
  if [[ -n "$host" ]] && command -v timeout >/dev/null 2>&1; then
    if timeout 5 bash -c 'exec 3<>/dev/tcp/"$1"/443' _ "$host" 2>/dev/null; then
      printf '  %s TCP-соединение с %s:443 установлено\n' "$(status_mark ok)" "$host"
    else
      printf '  %s TCP-соединение с %s:443 не установлено (возможна фильтрация извне)\n' "$(status_mark warn)" "$host"; warnings=1
    fi
  fi

  echo
  echo "4. Локальные endpoints и backend"
  if [[ -n "$admin" ]]; then
    for endpoint in healthz readyz; do
      if curl --fail --silent --max-time 4 "http://$admin/$endpoint" >/dev/null; then
        printf '  %s %s отвечает\n' "$(status_mark ok)" "$endpoint"
      else
        printf '  %s %s недоступен (%s)\n' "$(status_mark fail)" "$endpoint" "$admin"; failed=1
      fi
    done
  else
    printf '  %s Admin endpoint не задан\n' "$(status_mark fail)"; failed=1
  fi
  if [[ "$backend_port" =~ ^[0-9]+$ ]] && nc -z -w 3 127.0.0.1 "$backend_port" 2>/dev/null; then
    printf '  %s MTProxy backend доступен на 127.0.0.1:%s\n' "$(status_mark ok)" "$backend_port"
  else
    printf '  %s MTProxy backend недоступен (порт %s)\n' "$(status_mark fail)" "${backend_port:-не определён}"; failed=1
  fi

  echo
  echo "5. Веб-сервер, HTTPS и TLS"
  if [[ "$web_server" == nginx ]]; then
    if nginx -t 2>&1; then printf '  %s Nginx config valid\n' "$(status_mark ok)"; else printf '  %s Ошибка конфигурации Nginx\n' "$(status_mark fail)"; failed=1; fi
    cert_path="/etc/letsencrypt/live/$host/fullchain.pem"
  else
    if [[ -x /usr/local/bin/caddy && -s /etc/caddy/Caddyfile ]]; then
      if TPROXY_HOSTNAME="$host" TPROXY_SITE_ROOT="$(jq -r '.public_dir // empty' /etc/tproxy-server/config.json 2>/dev/null)" ACME_EMAIL="$(cat /etc/tproxy-server/acme-email 2>/dev/null || true)" /usr/local/bin/caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile >/dev/null 2>&1; then
        printf '  %s Caddy config valid\n' "$(status_mark ok)"
      else
        printf '  %s Ошибка конфигурации Caddy\n' "$(status_mark fail)"; failed=1
      fi
    else
      printf '  %s Caddyfile или бинарный файл отсутствует\n' "$(status_mark fail)"; failed=1
    fi
    cert_path=""
  fi

  if [[ -n "$cert_path" ]]; then
    if [[ -s "$cert_path" ]] && openssl x509 -in "$cert_path" -noout >/dev/null 2>&1; then
      expiry="$(openssl x509 -in "$cert_path" -noout -enddate | cut -d= -f2-)"
      if openssl x509 -in "$cert_path" -checkend 2592000 -noout >/dev/null 2>&1; then
        printf '  %s TLS-сертификат действителен более 30 дней (до %s)\n' "$(status_mark ok)" "$expiry"
      else
        printf '  %s TLS-сертификат истекает в ближайшие 30 дней или уже истёк (%s)\n' "$(status_mark warn)" "$expiry"
        warnings=1
      fi
    else
      printf '  %s TLS-сертификат не найден или повреждён: %s\n' "$(status_mark fail)" "$cert_path"; failed=1
    fi
  fi

  if [[ -n "$host" ]]; then
    if curl --fail --silent --show-error --max-time 8 --resolve "$host:443:127.0.0.1" "https://$host/" -o /dev/null; then
      printf '  %s HTTPS отвечает локально через выбранный vhost\n' "$(status_mark ok)"
    else
      printf '  %s HTTPS-проверка не пройдена (127.0.0.1:443, домен %s)\n' "$(status_mark fail)" "$host"; failed=1
    fi
    local -a dns_ips=()
    local dns_public_ip="" dns_matched=0 dns_ip
    mapfile -t dns_ips < <(dig +short A "$host" 2>/dev/null | grep -E '^([0-9]{1,3}\\.){3}[0-9]{1,3}$' | sort -u)
    if (("${#dns_ips[@]}")); then
      if dns_public_ip="$(get_public_ipv4)"; then
        for dns_ip in "${dns_ips[@]}"; do [[ "$dns_ip" == "$dns_public_ip" ]] && dns_matched=1; done
        if (( dns_matched )); then
          printf '  %s DNS A: %s — совпадает с публичным IP-адресом сервера (%s)\\n' "$(status_mark ok)" "${dns_ips[*]}" "$dns_public_ip"
        else
          printf '  %s IP-адреса, которые возвращает системный DNS (%s), отличаются от публичного IP-адреса сервера (%s)\\n' "$(status_mark warn)" "${dns_ips[*]}" "$dns_public_ip"
          warnings=1
          if is_cloudflare_proxied_domain "$host"; then
            printf '  %s Cloudflare DNS Proxy включён: DNS возвращает адреса сети Cloudflare вместо исходного IP origin-сервера. Это штатное поведение проксируемой DNS-записи\\n' "$(status_mark ok)"
            printf '  %s Посетители получают edge-адреса Cloudflare, а запросы передаются через сеть Cloudflare на origin-сервер; прямое совпадение DNS-адреса с IP сервера не требуется\\n' "$(status_mark ok)"
          else
            printf '  %s Адреса не распознаны как сеть Cloudflare — проверь A-запись домена и настройки DNS Proxy\\n' "$(status_mark fail)"
            failed=1
          fi
        fi
      else
        printf '  %s Не удалось определить публичный IP-адрес сервера; DNS A: %s\\n' "$(status_mark warn)" "${dns_ips[*]}"
        warnings=1
      fi
    else printf '  %s DNS A-запись не найдена через системный DNS-резолвер\\n' "$(status_mark fail)"; failed=1; fi
    local aaaa
    aaaa="$(dig +short AAAA "$host" 2>/dev/null | grep ':' | tr '\n' ' ' || true)"
    if [[ -n "$aaaa" ]]; then
      if is_cloudflare_proxied_domain "$host"; then
        printf '  %s DNS AAAA: %s — адреса сети Cloudflare, а не прямые IPv6-адреса origin-сервера; IPv6 origin по ним не оценивается\n' "$(status_mark ok)" "$aaaa"
      else printf '  %s DNS AAAA задан: %s — проверь IPv6 origin-сервера и доступность TCP 80/443 извне\n' "$(status_mark warn)" "$aaaa"; warnings=1; fi
    else printf '  %s DNS AAAA не задан через системный DNS-резолвер\n' "$(status_mark ok)"; fi
  else
    printf '  %s Домен не прочитан из config.json\n' "$(status_mark fail)"; failed=1
  fi

  echo
  echo "6. Порты и последние ошибки"
  echo
  echo "  Порты, относящиеся к прокси:"
  proxy_ports_table "$relay" "$admin" "$backend"
  echo
  echo "  Последние ошибки служб:"
  local log_json
  log_json="$(journalctl -u tproxy-server -u mtproxy -u tproxy-firewall -u "$web_server" -p err -n 12 --no-pager -o json 2>/dev/null || true)"
  if [[ -n "$log_json" ]] && command -v jq >/dev/null 2>&1; then
    while IFS= read -r log_row; do
      [[ -n "$log_row" ]] || continue
      printf '  %s\n' "$log_row"
    done < <(
      printf '%s\n' "$log_json" | jq -r '
        [
          (.__REALTIME_TIMESTAMP // "0" | tonumber / 1000000 | strftime("%Y-%m-%d %H:%M:%S")),
          (._SYSTEMD_UNIT // .SYSLOG_IDENTIFIER // "service"),
          (.MESSAGE // "" | gsub("[\\r\\n\\t]+"; " ") | .[0:110])
        ] | join(" | ")
      '
    )
  else
    printf '  %s Ошибок уровня error в доступном журнале не найдено\n' "$(status_mark ok)"
  fi

  echo
  echo "------------------------------------------------------------"
  if (( failed )); then
    warn "Диагностика завершена: обнаружены ошибки."
    return 1
  elif (( warnings )); then
    warn "Диагностика завершена: критических ошибок не найдено, есть предупреждения."
    return 0
  else
    ok "Диагностика завершена: основные проверки пройдены."
    return 0
  fi
}

backup_command() {
  local dest="${1:-/root/tproxy-backup-$(date +%Y%m%d-%H%M%S).tar.gz}"
  [[ "$dest" = /* ]] || die "Путь backup должен быть абсолютным"
  install -d -m 0700 "$(dirname "$dest")"
  [[ ! -e "$dest" ]] || die "Файл уже существует: $dest (не перезаписываю резервную копию)"

  local -a items=()
  local p
  for p in \
    etc/tproxy-server etc/mtproxy \
    etc/caddy/Caddyfile etc/caddy/Caddyfile.d \
    etc/nginx/sites-available/tproxy-server etc/nginx/sites-enabled/tproxy-server \
    etc/nginx/conf.d/tproxy-websocket-map.conf \
    etc/letsencrypt \
    etc/systemd/system/tproxy-server.service \
    etc/systemd/system/mtproxy.service \
    etc/systemd/system/tproxy-firewall.service \
    etc/systemd/system/refresh-mtproxy-config.service \
    etc/systemd/system/refresh-mtproxy-config.timer \
    etc/systemd/system/caddy.service \
    etc/systemd/system/caddy.service.d/tproxy.conf \
    etc/letsencrypt/renewal-hooks/deploy/reload-tproxy-nginx; do
    [[ ! -e "/$p" && ! -L "/$p" ]] || items+=("$p")
  done
  (("${#items[@]}")) || die "Нет файлов конфигурации для резервирования"

  local tmp="${dest}.tmp.$$"
  trap 'rm -f "$tmp"' RETURN
  tar -C / -czpf "$tmp" "${items[@]}"
  tar -tzf "$tmp" >/dev/null || die "Проверка созданного архива не пройдена"
  chmod 0600 "$tmp"
  mv -- "$tmp" "$dest"
  trap - RETURN
  ok "Резервная копия создана: $dest (0600)"
  info "В архив включено объектов: ${#items[@]}; включая конфигурацию выбранного веб-сервера и TLS."
}

restore_command() {
  local archive="${1:-}"
  [[ -n "$archive" && -f "$archive" ]] || die "Укажи существующий архив: restore /absolute/path/backup.tar.gz"
  [[ "$archive" = /* ]] || die "Путь к архиву должен быть абсолютным"
  tar -tzf "$archive" >/dev/null 2>&1 || die "Архив повреждён или имеет неподдерживаемый формат"

  local entry normalized
  while IFS= read -r entry; do
    normalized="${entry#./}"
    [[ "$normalized" != /* ]] || die "Небезопасный абсолютный путь в архиве: $entry"
    [[ ! "/$normalized/" =~ /\.\./ ]] || die "Небезопасный путь в архиве: $entry"
    case "$normalized" in
      etc/tproxy-server|etc/tproxy-server/*|etc/mtproxy|etc/mtproxy/*|etc/caddy|etc/caddy/*|etc/nginx|etc/nginx/*|etc/letsencrypt|etc/letsencrypt/*|etc/systemd/system/tproxy-server.service|etc/systemd/system/mtproxy.service|etc/systemd/system/tproxy-firewall.service|etc/systemd/system/refresh-mtproxy-config.service|etc/systemd/system/refresh-mtproxy-config.timer|etc/systemd/system/caddy.service|etc/systemd/system/caddy.service.d/*) ;;
      *) die "В архиве обнаружен путь вне разрешённого списка: $entry" ;;
    esac
  done < <(tar -tzf "$archive")

  echo "Внимание: восстановление перезапишет файлы конфигурации и TLS-сертификаты."
  confirm "Восстановить конфигурации из $archive?" || die "восстановление отменено"
  tar -C / -xzpf "$archive" || die "Ошибка распаковки резервной копии"
  systemctl daemon-reload
  ok "Файлы восстановлены. Проверь конфигурацию веб-сервера и состояние служб."
  info "Для проверки выполни: diagnostics"
}

ui_header() {
  local title="$1"
  echo
  if [[ -z "${NO_COLOR:-}" && "${TERM:-}" != "dumb" ]]; then
    printf '\033[1;34m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\033[0m\n'
    printf '  \033[1;34m◆\033[0m %s\n' "$title"
    printf '\033[1;34m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\033[0m\n'
  else
    printf '%s\n' '============================================================'
    printf '  %s\n' "$title"
    printf '%s\n' '============================================================'
  fi
}
ui_option() {
  local number="$1" icon="$2" label="$3"
  if [[ -z "${NO_COLOR:-}" && "${TERM:-}" != "dumb" ]]; then
    printf '  \033[1;34m%s)\033[0m %s %s\n' "$number" "$icon" "$label"
  else printf '  %s) %s %s\n' "$number" "$icon" "$label"; fi
}
show_deletion_menu() {
  local choice
  while true; do
    ui_header "Удаление компонентов"
    ui_option 1 "⚙" "Прокси и службы (веб-сервер и сайт оставить)"
    ui_option 2 "▣" "Decoy-сайт"
    ui_option 3 "◆" "Веб-сервер Caddy/Nginx"
    ui_option 4 "✖" "Всё: прокси, decoy-сайт и веб-сервер"
    ui_option 5 "↩" "Назад"
    echo
    read -r -p "Выбор [1-5]: " choice
    case "$choice" in
      1) KEEP_WEB_SERVER=1; run_uninstall; read -r -p "Enter — назад..." _ ;;
      2) remove_decoy_site; read -r -p "Enter — назад..." _ ;;
      3) remove_web_server_interactive; read -r -p "Enter — назад..." _ ;;
      4) run_purge; read -r -p "Enter — назад..." _ ;;
      5) return 0 ;;
      *) warn "Выбери пункт от 1 до 5." ;;
    esac
  done
}
show_tools_menu() {
  local choice archive
  while true; do
    ui_header "Инструменты"
    ui_option 1 "⌕" "Диагностика и поиск неисправностей"
    ui_option 2 "▤" "Создать резервную копию"
    ui_option 3 "↻" "Восстановить резервную копию"
    ui_option 4 "↩" "Назад"
    echo
    read -r -p "Выбор [1-4]: " choice
    case "$choice" in
      1) require_root; diagnostics_command || true; read -r -p "Enter — назад..." _ ;;
      2) read -r -p "Путь к архиву (Enter — по умолчанию): " archive; require_root; if [[ -n "$archive" ]]; then backup_command "$archive"; else backup_command; fi; read -r -p "Enter — назад..." _ ;;
      3) read -e -r -p "Абсолютный путь к архиву: " archive; [[ -n "$archive" ]] || { warn "Путь не указан"; continue; }; require_root; restore_command "$archive"; read -r -p "Enter — назад..." _ ;;
      4) return 0 ;;
      *) warn "Выбери пункт от 1 до 4." ;;
    esac
  done
}
show_menu() {
  local choice
  ui_header "tproxy-manager v${SCRIPT_VERSION}"
  ui_option 1 "⇧" "Установить tproxy-server"
  ui_option 2 "↻" "Обновить существующую установку"
  ui_option 3 "⌫" "Удаление"
  ui_option 4 "▤" "Текущая конфигурация"
  ui_option 5 "⚒" "Инструменты"
  ui_option 6 "⏻" "Выход"
  echo
  read -r -p "Выбор [1-6]: " choice
  case "$choice" in
    1) MODE=install ;;
    2) MODE=update; SKIP_TESTS=1 ;;
    3) MODE=delete ;;
    4) MODE=config ;;
    5) MODE=tools ;;
    6) exit 0 ;;
    *) warn "Неверный выбор." ;;
  esac
}

# ============================================================================
#  MAIN
# ============================================================================

main() {
  if [[ $# -eq 0 ]]; then
    while true; do
      MODE=""
      show_menu
      case "$MODE" in
        tools)
          show_tools_menu
          ;;
        delete)
          show_deletion_menu
          ;;
        config)
          require_root
          run_config
          read -r -p "Нажми Enter, чтобы вернуться в главное меню..." _
          ;;
        install)
          run_install
          return 0
          ;;
        update)
          run_install
          return 0
          ;;
        uninstall)
          run_uninstall
          return 0
          ;;
        purge)
          run_purge
          return 0
          ;;
      esac
    done
  fi

  MODE="$1"; shift
  case "$MODE" in
    install)   parse_install_args "$@"; run_install ;;
    update)    SKIP_TESTS=1; parse_install_args "$@"; run_install ;;
    uninstall) parse_uninstall_args "$@"; run_uninstall ;;
    purge)     parse_uninstall_args "$@"; run_purge ;;
    config)    require_root; run_config "$@" ;;
    diagnostics) require_root; diagnostics_command ;;
    backup)    require_root; backup_command "$@" ;;
    restore)   require_root; restore_command "$@" ;;
    -h|--help|help) usage; exit 0 ;;
    *) die "Unknown mode: $MODE (install|update|uninstall|purge|config|diagnostics|backup|restore)" ;;
  esac
}


main "$@"
