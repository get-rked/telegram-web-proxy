#!/usr/bin/env bash
# ============================================================================
#  tproxy-manager.sh — установка / обновление / удаление tproxy-server
#
#  Usage:
#    sudo ./tproxy-manager.sh                  # интерактивное меню
#    sudo ./tgweb-install.sh install [опции]  # установка
#    sudo ./tgweb-install.sh update  [опции]  # обновление (skip-tests, не трогает сайт)
#    sudo ./tgweb-install.sh uninstall [--keep-web-server] [--yes]
#    sudo ./tproxy-manager.sh purge     [--yes]
# ============================================================================
set -Eeuo pipefail
trap 'if [[ -z "${NO_COLOR:-}" && "${TERM:-}" != "dumb" ]]; then printf "\\033[1;31m❌ ERROR\033[0m at line %s: %s\\n" "$LINENO" "$BASH_COMMAND" >&2; else printf "❌ ERROR at line %s: %s\\n" "$LINENO" "$BASH_COMMAND" >&2; fi' ERR
umask 077

# ----------------------------- константы ------------------------------------
readonly REPO_URL="https://github.com/telegramdesktop/tproxy-server.git"
readonly UPSTREAM_COMMIT="c8adb8b7c6b7fc46c12ae3acb68be9070c26a8e8"
readonly BASE_DIR="/opt/telegram-web-proxy"
readonly BIN_DIR="$BASE_DIR/bin"
readonly CONFIG_DIR="$BASE_DIR/config"
readonly PROXY_CONFIG_DIR="$CONFIG_DIR/proxy"
readonly MTPROXY_CONFIG_DIR="$CONFIG_DIR/mtproxy"
readonly DATA_DIR="$BASE_DIR/data"
readonly SOURCE_DIR="$BASE_DIR/src"
readonly MTPROXY_DIR="$SOURCE_DIR/mtproxy"
readonly REPO_DIR="$SOURCE_DIR/tproxy-server"
readonly SYSTEMD_DIR="$BASE_DIR/systemd"
readonly QR_DIR="$BASE_DIR/qr"
readonly BACKUP_DIR="$BASE_DIR/backups"
readonly SITE_DIR_DEFAULT="$DATA_DIR/website"
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
readonly SCRIPT_VERSION="1.0.2"

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
SITE_UPSTREAM_ARG=""
INSTALL_SITE=1
WORKERS_ARG=""
MAXCONN_ARG=""
NONINTERACTIVE="${NONINTERACTIVE:-0}"
RELAY_PORT=""
ADMIN_PORT=""
CARRIER_MODE_ARG="https"
CARRIER_MODE_SET=0
SKIP_TESTS="${SKIP_TESTS:-0}"
KEEP_WEB_SERVER=0
ASSUME_YES=0
GO_BIN=""
UPDATE_TRANSACTION_ACTIVE=0
UPDATE_ROLLBACK_ARCHIVE=""

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

# Redact credential-like values and request paths before displaying journal data.
redact_sensitive_log() {
  sed -E \
    -e 's/(authorization[=: ]+)(Bearer[[:space:]]+)?[^[:space:]&",;]+/\1[REDACTED]/Ig' \
    -e 's/((secret|token|password|bridge[_-]?token|api[_-]?key)[=: ]+)[^[:space:]&",;]+/\1[REDACTED]/Ig' \
    -e 's/([?&](secret|token|hash)=)[^&[:space:]"]+/\1[REDACTED]/Ig' \
    -e 's#(https?://[^/[:space:]]+/)[^?[:space:]"]+#\1[REDACTED_PATH]#g'
}

usage() {
  cat <<'EOF'
Usage:
  sudo ./tgweb-install.sh                          # интерактивное меню
  sudo ./tproxy-manager.sh install   [опции установки]
  sudo ./tproxy-manager.sh update    [опции установки]
  sudo ./tproxy-manager.sh uninstall [--keep-caddy] [--yes]
  sudo ./tgweb-install.sh purge     [--yes]
  sudo ./tgweb-install.sh profile list
  sudo ./tgweb-install.sh profile add ИМЯ (--secret СЕКРЕТ | --generate) [--carrier-mode MODE]
  sudo ./tgweb-install.sh profile set-carrier ИМЯ MODE
  sudo ./tgweb-install.sh profile delete ИМЯ --yes
  sudo ./tgweb-install.sh profile backup ИМЯ
  sudo ./tgweb-install.sh profile import ARCHIVE (--name ИМЯ | --replace-default) [--entry PATH] --yes
  sudo ./tgweb-install.sh upstream set-url http://127.0.0.1:PORT
  sudo ./tgweb-install.sh upstream set-dir /absolute/path
  sudo ./tgweb-install.sh services restart
  sudo ./tgweb-install.sh site remove [--yes]
  sudo ./tgweb-install.sh web-server remove [--yes]

Опции установки/обновления:
  --hostname FQDN           Домен
  --web-server caddy|nginx  Веб-сервер (по умолчанию: caddy)
  --email EMAIL             Email для Let's Encrypt
  --secret SECRET           32 hex или dd + 32 hex
  --secret-prefix MODE       plain или dd (формат генерации)
  --carrier-mode MODE        https|https-lanes|websocket|websocket-lanes
  config [--output PATH]     Показать текущие настройки (секреты скрыты)
  diagnostics                Диагностика: службы, порты, конфигурации и ошибки
  backup                     Создать резервную копию в стандартном каталоге
  restore [NUMBER]           Выбрать архив из списка и восстановить
  --base-path SLUG|none     Базовый путь (default: генерируется)
  --site-dir PATH           Каталог сайта (default: /opt/telegram-web-proxy/data/website)
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

  ui_header "Установка tproxy-server"
  echo "Обязательные параметры нужно заполнить; Enter у остальных"
  echo "оставляет значение по умолчанию."

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
  ui_separator
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
      --carrier-mode)    [[ $# -ge 2 ]] || die "--carrier-mode требует значение"; CARRIER_MODE_ARG="$2"; CARRIER_MODE_SET=1; shift 2 ;;
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
  [[ "$CARRIER_MODE_ARG" == "https" || "$CARRIER_MODE_ARG" == "https-lanes" || "$CARRIER_MODE_ARG" == "websocket" || "$CARRIER_MODE_ARG" == "websocket-lanes" ]] || die "--carrier-mode: допустимо https, https-lanes, websocket или websocket-lanes"
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

# Проверяет только маршрутизацию домена в Caddyfile. Не зависит от systemd
# unit/drop-in и состояния каталога сайта: decoy-сайт обслуживает tproxy-server.
caddyfile_routes_to_tproxy() {
  [[ -s /etc/caddy/Caddyfile ]] || return 1
  grep -Fq '{$TPROXY_HOSTNAME}' /etc/caddy/Caddyfile || return 1
  grep -Fq "reverse_proxy 127.0.0.1:$RELAY_PORT" /etc/caddy/Caddyfile
}

# Проверка полной совместимости Caddy с текущими параметрами.
caddy_config_compatible() {
  [[ -s /etc/caddy/Caddyfile && -x /usr/local/bin/caddy ]] || return 1
  grep -Fq '{$TPROXY_HOSTNAME}' /etc/caddy/Caddyfile || return 1
  grep -Fq "127.0.0.1:$RELAY_PORT" /etc/caddy/Caddyfile || return 1
  # Site root is consumed by tproxy-server via config.json and the systemd drop-in,
  # not by Caddyfile: Caddy proxies the complete domain to the relay backend.
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
  printf '\033[1;34m  %-8s %-25s %-8s %s\033[0m\n' "━━━━━━━━" "━━━━━━━━━━━━━━━━━━━━━━━━━" "━━━━━━━━" "━━━━━━━━━━━━━━━━━━━━━━━━━"
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
  printf '\033[1;34m  %-30s %s\033[0m\n' "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  for pkg in "${required_packages[@]}"; do
    if package_installed "$pkg"; then
      printf '  %-30s %s\n' "$pkg" "$(status_mark ok) установлен"
    else
      printf '  %-30s %s\n' "$pkg" "$(status_mark warn) будет установлен"
    fi
  done
  echo
  printf '  %-30s %s\n' "Основной компонент" "Состояние"
  printf '\033[1;34m  %-30s %s\033[0m\n' "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  if [[ -x "$BIN_DIR/tproxy-server" || -x $BIN_DIR/tproxy-server ]]; then
    printf '  %-30s %s\n' "tproxy-server" "$(status_mark ok) бинарный файл найден"
  else
    printf '  %-30s %s\n' "tproxy-server" "$(status_mark warn) потребуется установить/собрать"
  fi
  if [[ -x "$MTPROXY_DIR/objs/bin/mtproto-proxy" ]]; then
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
  printf '\033[1;34m  %-30s %s\033[0m\n' "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
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
# Обнаруживает существующий сайт только при однозначной конфигурации.
# Любой чужой домен или сложная схема приводит к безопасному отказу.
NGINX_EXISTING_LINK=""
inspect_existing_site() {
  local parser output rc source root caddy_bin
  command -v python3 >/dev/null 2>&1 || die "Для безопасного анализа конфигурации занятого веб-сервера требуется python3. Установи python3 и повтори запуск."
  parser="$(mktemp)" || die "Не удалось создать временный файл анализатора веб-конфигурации"
  cat > "$parser" <<'PYTHON'
import json, re, sys
kind, host = sys.argv[1:3]
data = sys.stdin.read()
def fail(msg):
    print(msg, file=sys.stderr); sys.exit(2)
if kind == 'nginx':
    text = re.sub(r'(?m)^\s*#(?! configuration file ).*$', '', data)
    blocks=[]; i=0; n=len(text); source='<unknown>'
    while i<n:
        marker=re.search(r'(?m)^\s*# configuration file (.+):\s*$', text[i:])
        m=re.search(r'\bserver\s*\{', text[i:])
        if marker and (not m or marker.start() < m.start()):
            source=marker.group(1).strip(); i += marker.end(); continue
        if not m: break
        start=i+m.start(); j=i+m.end(); depth=1; quote=None; esc=False
        while j<n and depth:
            c=text[j]
            if quote:
                if esc: esc=False
                elif c=='\\': esc=True
                elif c==quote: quote=None
            else:
                if c in ('"', "'"): quote=c
                elif c=='{': depth+=1
                elif c=='}': depth-=1
            j+=1
        if depth: fail('unbalanced nginx server block')
        blocks.append((source,text[start:j])); i=j
    relevant=[]
    for source,b in blocks:
        listens=re.findall(r'(?m)^\s*listen\s+([^;]+);',b)
        ports=set(p for v in listens for p in re.findall(r'(?<!\d)(80|443)(?!\d)',v))
        if not ports: continue
        names=[]
        for v in re.findall(r'(?m)^\s*server_name\s+([^;]+);',b): names += [x for x in v.split() if x not in ('_', '')]
        roots=re.findall(r'(?m)^\s*root\s+([^;]+);',b)
        if not names:
            fail('nginx default/catch-all server is configured on ports 80/443')
        if any(x.startswith('$') for x in names) or any(x != host for x in names): fail('another domain shares ports 80/443')
        if re.search(r'(?m)^\s*(alias|proxy_pass|fastcgi_pass|uwsgi_pass|grpc_pass)\s+',b): fail('matching nginx site is not a simple static-root site')
        if roots:
            if len(set(roots)) != 1: fail('multiple roots in matching nginx server block')
            relevant.append((roots[0].strip().strip(chr(34)).strip(chr(39)),source))
    if not relevant: sys.exit(1)
    if len(set(x[0] for x in relevant)) != 1: fail('multiple roots for requested domain')
    files=set(x[1] for x in relevant)
    if len(files) != 1: fail('requested domain is defined in multiple nginx config files')
    print(relevant[0][0]+'\t'+next(iter(files)))
elif kind == 'caddy':
    try: obj=json.loads(data)
    except Exception: fail('invalid Caddy adapted JSON')
    roots=[]; found=False
    def walk(x, hosts=None):
        global found
        if isinstance(x,dict):
            local=hosts; matcher=x.get('match')
            if isinstance(matcher,list):
                hs=[]
                for m in matcher:
                    if isinstance(m,dict) and 'host' in m: hs += m['host']
                if hs and any(h != host for h in hs): fail('another domain is configured in Caddy')
                if hs: local=hs
            if x.get('handler')=='vars' and 'root' in x and not local:
                fail('Caddy catch-all root route is ambiguous')
            if x.get('handler')=='vars' and 'root' in x and local:
                if any(h != host for h in local): fail('another domain is configured in Caddy')
                found=True; roots.append(x['root'])
            if x.get('handler') in ('file_server','reverse_proxy') and not local:
                fail('Caddy catch-all route is ambiguous')
            if x.get('handler')=='file_server' and local:
                if any(h != host for h in local): fail('another domain is configured in Caddy')
                found=True
            for v in x.values(): walk(v,local)
        elif isinstance(x,list):
            for v in x: walk(v,hosts)
    walk(obj)
    if not found or not roots: fail('matching Caddy site has no explicit document root')
    if len(set(roots)) != 1: fail('multiple roots for requested domain')
    print(roots[0])
else: fail('unknown web server')
PYTHON
  if [[ "$WEB_SERVER" == "nginx" ]]; then
    if ! command -v nginx >/dev/null 2>&1; then rm -f "$parser"; die "Порт 80/443 занят, но Nginx недоступен для анализа конфигурации."; fi
    set +e
    output="$(nginx -T 2>&1 | python3 "$parser" nginx "$HOSTNAME_ARG")"; rc=$?
    set -e
    rm -f "$parser"
    if (( rc != 0 )); then die "Не удалось безопасно определить сайт Nginx на 80/443 (чужой домен или неоднозначная конфигурация). Ничего не изменено."; fi
    root="$(printf '%s' "$output" | cut -f1)"; source="$(printf '%s' "$output" | cut -f2-)"
    [[ "$source" == /etc/nginx/sites-enabled/* && -L "$source" ]] || die "Сайт $HOSTNAME_ARG найден в $source, но это не отдельная ссылка sites-enabled. Автоматическая замена небезопасна."
    [[ -d "$root" && "$root" != / ]] || die "Корневой каталог существующего сайта недопустим или не найден: $root"
    [[ -f "$root/index.html" ]] || die "В каталоге $root нет index.html. Установщик не будет угадывать структуру сайта."
    NGINX_EXISTING_LINK="$source"
  else
    if grep -Eq '^[[:space:]]*import[[:space:]]|^[[:space:]]*\([^)]*\)[[:space:]]*\{' /etc/caddy/Caddyfile; then
      rm -f "$parser"
      die "В Caddyfile обнаружены import/snippet. Автоматическая замена может затронуть связанные сайты; настройку нужно выполнить вручную."
    fi
    caddy_bin="$(command -v caddy 2>/dev/null || true)"; [[ -x /usr/local/bin/caddy ]] && caddy_bin=/usr/local/bin/caddy
    [[ -n "$caddy_bin" ]] || { rm -f "$parser"; die "Порт 80/443 занят, но Caddy недоступен для анализа конфигурации."; }
    set +e
    output="$(TPROXY_HOSTNAME="$HOSTNAME_ARG" TPROXY_SITE_ROOT="$SITE_DIR" ACME_EMAIL="$EMAIL_ARG" "$caddy_bin" adapt --config /etc/caddy/Caddyfile --adapter caddyfile 2>/dev/null | python3 "$parser" caddy "$HOSTNAME_ARG")"; rc=$?
    set -e
    rm -f "$parser"
    if (( rc != 0 )); then die "Не удалось безопасно определить сайт Caddy на 80/443 (чужой домен или неоднозначная конфигурация). Ничего не изменено."; fi
    root="$output"
    [[ -d "$root" && "$root" != / ]] || die "Корневой каталог существующего сайта недопустим или не найден: $root"
    [[ -f "$root/index.html" ]] || die "В каталоге $root нет index.html. Установщик не будет угадывать структуру сайта."
  fi
  SITE_DIR="$(realpath "$root")"
  INSTALL_SITE=0
  ok "Обнаружен сайт домена $HOSTNAME_ARG. Будет использован его каталог $SITE_DIR; содержимое останется без изменений."
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
  if [[ -x "$MTPROXY_DIR/objs/bin/mtproto-proxy" && -r "$MTPROXY_DIR/.tproxy-commit" ]] && grep -Fxq "$MTPROXY_COMMIT" "$MTPROXY_DIR/.tproxy-commit" && [[ -s $MTPROXY_CONFIG_DIR/proxy-secret && -s $MTPROXY_CONFIG_DIR/proxy-multi.conf ]]; then
    printf '  %-24s %s\n' "MTProxy" "$(status_mark ok) нужная сборка уже установлена"
  elif [[ -x "$MTPROXY_DIR/objs/bin/mtproto-proxy" ]]; then
    printf '  %-24s %s\n' "MTProxy" "$(status_mark warn) найдена другая/неполная сборка; установщик создаст резервную копию и обновит её"
  else
    printf '  %-24s %s\n' "MTProxy" "$(status_mark warn) потребуется собрать"
  fi
  if [[ "$MODE" == "install" ]] && { [[ -s $PROXY_CONFIG_DIR/config.json ]] || systemctl is-active --quiet tproxy-server 2>/dev/null || [[ -x $BIN_DIR/tproxy-server ]]; }; then
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
  local web_port_busy=0
  for port in 80 443; do
    if port_in_use "$port"; then
      web_port_busy=1
      if ! systemctl is-active --quiet "$selected_service" 2>/dev/null; then
        if [[ "$switching_webserver" -eq 1 ]]; then
          die "Порт $port занят текущим веб-сервером $other_web. Автоматическое переключение при занятом сайте небезопасно; сначала освободи 80/443 или настрой выбранный сервер вручную."
        fi
        die "Порт $port занят сторонней службой. Установщик не будет останавливать её автоматически."
      fi
    fi
  done
  if (( web_port_busy )); then
    local managed_tproxy=0
    if [[ -s "$PROXY_CONFIG_DIR/config.json" ]] && command -v jq >/dev/null 2>&1 &&
       jq -e --arg host "$HOSTNAME_ARG" --arg site "$SITE_DIR" '.public_hostname == $host and .public_dir == $site' "$PROXY_CONFIG_DIR/config.json" >/dev/null 2>&1; then
      if [[ "$WEB_SERVER" == "nginx" ]] &&
         [[ -L "$NGINX_ENABLED" ]] &&
         grep -Fq "server_name $HOSTNAME_ARG;" "$NGINX_SITE" &&
         grep -Fq 'proxy_pass http://127.0.0.1:' "$NGINX_SITE"; then
        nginx_config_compatible || die "Текущая конфигурация Nginx для этого домена изменилась. Не перезаписываю занятый сайт автоматически; сначала проверь vhost вручную."
        managed_tproxy=1
      elif [[ "$WEB_SERVER" == "caddy" ]] && caddyfile_routes_to_tproxy; then
        # A matching Caddy virtual host is sufficient to identify our occupied
        # domain. Unit/drop-in drift must not block restoring backend-served
        # site files or cause an otherwise working Caddy instance to be replaced.
        managed_tproxy=1
      fi
    fi
    if (( managed_tproxy )); then
      info "Обнаружена действующая конфигурация tproxy-server; сохраняю public_dir из config.json: $SITE_DIR"
    else
      inspect_existing_site
    fi
  fi
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

check_telegram_connectivity() {
  info "Проверяю доступность Telegram до установки компонентов…"
  local core_ok=0 dc_ok=0 dc_ip
  local -a dc_ips=(149.154.175.50 149.154.167.51 149.154.175.100)

  if getent ahosts core.telegram.org >/dev/null 2>&1; then
    ok "DNS: core.telegram.org разрешается"
  else
    warn "DNS: не удалось разрешить core.telegram.org"
  fi

  if curl --fail --silent --show-error --location --max-time 12 \
      --proto '=https' --proto-redir '=https' --tlsv1.2 \
      --output /dev/null https://core.telegram.org; then
    core_ok=1
    ok "HTTPS: core.telegram.org доступен"
  else
    warn "HTTPS: core.telegram.org недоступен"
  fi

  for dc_ip in "${dc_ips[@]}"; do
    if timeout 5 bash -c 'exec 3<>"/dev/tcp/$1/443"' _ "$dc_ip" 2>/dev/null; then
      dc_ok=1
      ok "Telegram DC: TCP 443 доступен через $dc_ip"
      break
    fi
  done

  if (( ! dc_ok )); then
    warn "Не удалось установить TCP-соединение с проверенными адресами Telegram DC (порт 443). Работа MTProxy может быть невозможна."
    if [[ "$NONINTERACTIVE" == "1" ]]; then
      die "Проверка Telegram DC не пройдена; non-interactive установка остановлена"
    fi
    confirm "Продолжить несмотря на недоступность Telegram DC?" || die "установка отменена после проверки сети"
  fi
  if (( ! core_ok )); then
    warn "core.telegram.org недоступен по HTTPS. Проверка DC прошла отдельно; проверь сетевые ограничения и DNS."
  fi
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
      info "DNS A: ${ips[*]} (публичный IP сервера: $public_ip)"
      info "Cloudflare Proxy: включён — DNS возвращает адреса сети Cloudflare вместо IP origin-сервера; запросы посетителей перенаправляются через Cloudflare."
      info "Проверь режим SSL/TLS Full (strict) и доступность origin по TCP 80/443."
    else die "DNS A-запись (${ips[*]}) не совпадает с публичным IPv4 сервера ($public_ip) и не распознана как адреса Cloudflare. Проверь A-запись и настройки DNS Proxy."; fi
  else warn "Не удалось определить публичный IPv4 сервера; системный DNS вернул A-записи: ${ips[*]}. Сравнение пропущено."; fi
  aaaa="$(dig +short AAAA "$HOSTNAME_ARG" 2>/dev/null | grep ':' | sort -u | tr '\n' ' ' || true)"
  if [[ -n "$aaaa" ]]; then
    if is_cloudflare_proxied_domain "$HOSTNAME_ARG"; then
      info "DNS AAAA: $aaaa (IPv6-адреса сети Cloudflare, не origin-сервера)."
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
  if [[ -f $PROXY_CONFIG_DIR/config.json ]]; then
    BASE_PATH_ARG="$(sed -n 's/.*"base_path"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
      $PROXY_CONFIG_DIR/config.json | head -n1)"
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
    curl --fail --silent --show-error --location --proto '=https' --proto-redir '=https' --tlsv1.2 \
      --output "$archive" \
      "https://github.com/caddyserver/caddy/releases/download/v${CADDY_VERSION}/caddy_${CADDY_VERSION}_linux_amd64.tar.gz"
    test "$(sha512sum "$archive" | awk '{print $1}')" = "$CADDY_SHA512" \
      || die "Caddy checksum mismatch"
    tar -C "$dir" -xzf "$archive"
    install -m 0755 "$dir/caddy" /usr/local/bin/caddy
    rm -f "$archive"; rm -rf "$dir"
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
  if [[ -n "$NGINX_EXISTING_LINK" && "$NGINX_EXISTING_LINK" != "$NGINX_ENABLED" ]]; then
    rm -f -- "$NGINX_EXISTING_LINK"
    warn "Отключена только отдельная конфигурация прежнего сайта домена $HOSTNAME_ARG: $NGINX_EXISTING_LINK"
  fi
  install -d -m 0755 "$ACME_WEBROOT"
  local cert="/etc/letsencrypt/live/$HOSTNAME_ARG/fullchain.pem"
  local key="/etc/letsencrypt/live/$HOSTNAME_ARG/privkey.pem"
  cat > "$NGINX_SITE" <<EOF
server {
 listen 80;
 server_name $HOSTNAME_ARG;
 access_log off;
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
 access_log off;
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
  if [[ -x "$MTPROXY_DIR/objs/bin/mtproto-proxy" && -r "$MTPROXY_DIR/.tproxy-commit" ]] &&
     grep -Fxq "$MTPROXY_COMMIT" "$MTPROXY_DIR/.tproxy-commit" &&
     [[ -s $MTPROXY_CONFIG_DIR/proxy-secret && -s $MTPROXY_CONFIG_DIR/proxy-multi.conf ]]; then
    ok "MTProxy нужной версии уже установлен — сборка и обновление Telegram-конфигурации пропущены"
    return 0
  fi
  info "Собираю официальный MTProxy…"
  sed -i -e "s#/opt/MTProxy#$MTPROXY_DIR#g" -e "s#/etc/mtproxy#$MTPROXY_CONFIG_DIR#g" -e "s#/usr/local/bin/mtproxy#$BIN_DIR/mtproxy-proxy#g" "$REPO_DIR/deploy/install-mtproxy.sh"
  sed -i "s#/etc/mtproxy#$MTPROXY_CONFIG_DIR#g" "$REPO_DIR/deploy/refresh-mtproxy-config.sh"
  "$REPO_DIR/deploy/install-mtproxy.sh"
  ln -sfn "$MTPROXY_DIR/objs/bin/mtproto-proxy" "$BIN_DIR/mtproxy-proxy"
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
  curl --fail --silent --show-error --location --proto '=https' --proto-redir '=https' --tlsv1.2 \
    --output "$archive" "https://go.dev/dl/go${GO_FALLBACK_VERSION}.linux-amd64.tar.gz"
  test "$(sha256sum "$archive" | awk '{print $1}')" = "$GO_FALLBACK_SHA256" \
    || die "Go checksum mismatch"
  tar -C "$dir" -xzf "$archive"
  if [[ -e "/opt/go${GO_FALLBACK_VERSION}" ]]; then rm -rf "$dir/go"; else
    mv "$dir/go" "/opt/go${GO_FALLBACK_VERSION}"
  fi
  rm -f "$archive"; rm -rf "$dir"
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
  install -d -m 0755 "$BIN_DIR"
  local candidate="$BIN_DIR/tproxy-server.new.${BASHPID}"
  rm -f -- "$candidate"
  if ! "$GO_BIN" build -trimpath -ldflags='-s -w' -o "$candidate" ./cmd/tproxy-server; then
    rm -f -- "$candidate"
    cd - >/dev/null
    die "Сборка tproxy-server не удалась; установленный бинарник не изменён"
  fi
  chown root:root "$candidate"
  chmod 0755 "$candidate"
  # Same-filesystem rename promotes only a complete executable.
  mv -f -- "$candidate" "$BIN_DIR/tproxy-server"
  cd - >/dev/null
  ok "tproxy-server собран и атомарно установлен"
}

install_stub_site() {
  if [[ "$INSTALL_SITE" -ne 1 ]]; then info "Сайт пропущен (--no-site)"; return 0; fi
  if [[ -f "$SITE_DIR/index.html" && -s "$SITE_DIR/assets/styles.css" && -s "$SITE_DIR/assets/favicon.svg" ]]; then
    info "Сайт и его статические ресурсы уже есть в $SITE_DIR — не трогаю"
    ok "Существующий сайт сохранён без изменений"
    return 0
  fi
  if [[ -f "$SITE_DIR/index.html" ]] && ! grep -Fq 'De Kleine Markt' "$SITE_DIR/index.html"; then
    warn "Найден пользовательский сайт без полного набора ресурсов; содержимое не перезаписываю."
    return 0
  fi
  if [[ -f "$SITE_DIR/index.html" ]]; then
    warn "Обнаружен неполный встроенный сайт (нет CSS или favicon); восстанавливаю комплект файлов."
  else
    info "Устанавливаю демонстрационный магазин De Kleine Markt в $SITE_DIR…"
  fi
  mkdir -p "$SITE_DIR/assets"

  cat > "$SITE_DIR/index.html" <<'HTML'
<!doctype html>
<html lang="nl">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<meta name="theme-color" content="#f5f1e8">
<title>De Kleine Markt — lekker lokaal, elke dag</title>
<meta name="description" content="Een gezellige buurtwinkel met koffie, lekkers, delicatessen en fijne spullen voor thuis.">
<link rel="stylesheet" href="/assets/styles.css">
<link rel="icon" href="/assets/favicon.svg" type="image/svg+xml">
</head>
<body>
<div class="announcement">Welkom bij De Kleine Markt · klein assortiment, groot plezier</div>
<header class="site-header">
  <a class="brand" href="/" aria-label="De Kleine Markt — home"><span class="brand-icon">✳</span><span>de kleine <b>markt</b></span></a>
  <nav aria-label="Hoofdnavigatie"><a href="#assortiment">Assortiment</a><a href="/about.html">Ons verhaal</a><a href="/contact.html">Contact</a></nav>
  <a class="header-cta" href="#assortiment">Ontdek de winkel <span>↗</span></a>
</header>
<main>
  <section class="hero">
    <div class="hero-copy">
      <p class="eyebrow">GOED GEVONDEN, GOED GEKOZEN</p>
      <h1>Een beetje<br><em>bijzonder</em><br>voor elke dag.</h1>
      <p class="intro">Van versgemalen koffie tot iets lekkers voor bij de thee. Bij De Kleine Markt vind je fijne favorieten, mooie ingrediënten en kleine cadeautjes.</p>
      <a class="button" href="#assortiment">Bekijk ons assortiment <span>→</span></a>
      <p class="micro-note">Met aandacht uitgezocht · Voor thuis en onderweg</p>
    </div>
    <div class="hero-art" role="img" aria-label="Stilleven met brood, bloemen, koffie en fruit">
      <div class="art-sun"></div><div class="art-label">DAGELIJKS<br>LEKKERS</div>
      <div class="art-bowl"><span>✿</span></div><div class="art-leaf leaf-one"></div><div class="art-leaf leaf-two"></div>
      <div class="art-fruit fruit-one"></div><div class="art-fruit fruit-two"></div>
      <div class="art-caption">kleine vondsten,<br>grote glimlach</div>
    </div>
  </section>

  <section class="intro-strip"><span>✳ Met zorg gekozen</span><span>✳ Fijn voor jezelf</span><span>✳ Leuk om cadeau te doen</span></section>

  <section class="products section" id="assortiment">
    <div class="section-heading"><div><p class="eyebrow">UIT DE WINKEL</p><h2>Onze favorieten</h2></div><p>Een kleine greep uit de collectie. Er is altijd iets nieuws te ontdekken.</p></div>
    <div class="product-grid">
      <article class="product"><div class="product-art coffee"><span>☕</span><small>01 / KOFFIE & THEE</small></div><div class="product-info"><h3>Koffie & thee</h3><p>Bonen, losse thee en lekkere melanges.</p><span class="tag">Elke dag een goed moment</span></div></article>
      <article class="product"><div class="product-art pantry"><span>✿</span><small>02 / DELICATESSEN</small></div><div class="product-info"><h3>Delicatessen</h3><p>Olijfolie, jam, honing en smaakmakers.</p><span class="tag">Met aandacht geselecteerd</span></div></article>
      <article class="product"><div class="product-art bakery"><span>🥐</span><small>03 / BAKKERIJ</small></div><div class="product-info"><h3>Iets lekkers</h3><p>Koekjes, chocolade en knapperige crackers.</p><span class="tag">Voor bij de koffie</span></div></article>
      <article class="product"><div class="product-art home"><span> vase </span><small>04 / VOOR THUIS</small></div><div class="product-info"><h3>Mooi voor thuis</h3><p>Keramiek, servetten en kleine wooncadeaus.</p><span class="tag">Klein geluk</span></div></article>
      <article class="product"><div class="product-art cheese"><span>🧀</span><small>05 / HOLLANDS GOED</small></div><div class="product-info"><h3>Kaas & borrel</h3><p>Hollandse kazen, noten en borrelhapjes.</p><span class="tag">Samen smaakt beter</span></div></article>
      <article class="product"><div class="product-art gifts"><span>🎁</span><small>06 / CADEAUTJES</small></div><div class="product-info"><h3>Kleine cadeaus</h3><p>Attenties, kaarten en leuke pakketjes.</p><span class="tag">Zomaar of speciaal</span></div></article>
    </div>
  </section>

  <section class="quote-band"><p class="eyebrow">ONS IDEE</p><blockquote>“Het zijn vaak de kleine dingen die een gewone dag bijzonder maken.”</blockquote><a href="/about.html">Meer over onze winkel →</a></section>
  <section class="visit section"><div><p class="eyebrow">LOOP GERUST EVEN BINNEN</p><h2>Tot snel<br>in de winkel!</h2><p>Een plek voor dagelijkse favorieten, iets nieuws om te proeven en een praatje aan de toonbank.</p><a class="button button-dark" href="/contact.html">Praktische informatie <span>→</span></a></div><div class="visit-card"><div class="visit-flower">✳</div><p>DE KLEINE MARKT</p><strong>Goed gekozen.<br>Met plezier gegeven.</strong><small>Een fictief winkelconcept</small></div></section>
</main>
<footer><a class="brand footer-brand" href="/"><span class="brand-icon">✳</span><span>de kleine <b>markt</b></span></a><div class="footer-links"><a href="/about.html">Ons verhaal</a><a href="/contact.html">Contact</a><a href="/privacy.html">Privacy</a></div><p>© <span id="year"></span> De Kleine Markt · Conceptwebsite</p></footer>
<script>document.getElementById('year').textContent=new Date().getFullYear();</script>
</body>
</html>
HTML

  cat > "$SITE_DIR/about.html" <<'HTML'
<!doctype html>
<html lang="nl"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Ons verhaal — De Kleine Markt</title><link rel="stylesheet" href="/assets/styles.css"><link rel="icon" href="/assets/favicon.svg" type="image/svg+xml"></head>
<body><div class="announcement">Een fictief winkelconcept · De Kleine Markt</div><header class="site-header"><a class="brand" href="/"><span class="brand-icon">✳</span><span>de kleine <b>markt</b></span></a><nav><a href="/">Home</a><a href="/contact.html">Contact</a></nav><a class="header-cta" href="/#assortiment">Assortiment ↗</a></header>
<main class="text-page"><p class="eyebrow">ONS VERHAAL</p><h1>Goed gekozen.<br><em>Met aandacht.</em></h1><p class="large-copy">De Kleine Markt is bedacht als de buurtwinkel waar je graag even binnenloopt. Voor goede koffie, iets lekkers, een mooi ingrediënt of een klein cadeau.</p><h2>Klein, fijn en met aandacht</h2><p>We geloven dat een winkel niet groot hoeft te zijn om veel te bieden. Liever een overzichtelijke collectie met producten waar je blij van wordt. Van iets voor de voorraadkast tot een kleinigheid voor op tafel.</p><h2>Een plek voor alledaags geluk</h2><p>Een goed gesprek, een nieuwe smaak of een mooi ingepakt cadeautje: juist die kleine momenten maken de dag. Dat is het idee achter De Kleine Markt.</p><a class="button" href="/#assortiment">Ontdek de favorieten →</a><p class="notice">De Kleine Markt is een fictief concept voor demonstratiedoeleinden en vertegenwoordigt geen bestaande onderneming.</p></main>
<footer><a class="brand footer-brand" href="/"><span class="brand-icon">✳</span><span>de kleine <b>markt</b></span></a><div class="footer-links"><a href="/">Home</a><a href="/contact.html">Contact</a><a href="/privacy.html">Privacy</a></div><p>© <span id="year"></span> De Kleine Markt · Conceptwebsite</p></footer><script>document.getElementById('year').textContent=new Date().getFullYear();</script></body></html>
HTML

  cat > "$SITE_DIR/contact.html" <<'HTML'
<!doctype html>
<html lang="nl"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Contact & informatie — De Kleine Markt</title><link rel="stylesheet" href="/assets/styles.css"><link rel="icon" href="/assets/favicon.svg" type="image/svg+xml"></head>
<body><div class="announcement">Een fictief winkelconcept · De Kleine Markt</div><header class="site-header"><a class="brand" href="/"><span class="brand-icon">✳</span><span>de kleine <b>markt</b></span></a><nav><a href="/">Home</a><a href="/about.html">Ons verhaal</a></nav><a class="header-cta" href="/#assortiment">Assortiment ↗</a></header>
<main class="text-page"><p class="eyebrow">PRAKTISCHE INFORMATIE</p><h1>Kom je<br><em>even kijken?</em></h1><p class="large-copy">Hier vind je straks alle informatie over de winkel. Omdat dit een fictief winkelconcept is, zijn onderstaande gegevens demonstratiegegevens.</p><div class="contact-grid"><section><h2>Adres</h2><p>Geen bezoekadres — conceptwebsite</p></section><section><h2>E-mail</h2><p><a href="mailto:info@dekleinemarkt.example.invalid">info@dekleinemarkt.example.invalid</a></p></section><section><h2>Telefoon</h2><p>Niet beschikbaar — demonstratie</p></section><section><h2>Openingstijden</h2><p>Niet van toepassing — fictieve winkel</p></section></div><p class="notice">Dit is geen bestaande winkel. Het adres, telefoonnummer en contactgegevens van een bestaande onderneming worden bewust niet gebruikt.</p><a class="button" href="/">Terug naar de winkel →</a></main>
<footer><a class="brand footer-brand" href="/"><span class="brand-icon">✳</span><span>de kleine <b>markt</b></span></a><div class="footer-links"><a href="/about.html">Ons verhaal</a><a href="/contact.html">Contact</a><a href="/privacy.html">Privacy</a></div><p>© <span id="year"></span> De Kleine Markt · Conceptwebsite</p></footer><script>document.getElementById('year').textContent=new Date().getFullYear();</script></body></html>
HTML

  cat > "$SITE_DIR/privacy.html" <<'HTML'
<!doctype html>
<html lang="nl"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Privacy — De Kleine Markt</title><link rel="stylesheet" href="/assets/styles.css"><link rel="icon" href="/assets/favicon.svg" type="image/svg+xml"></head>
<body><div class="announcement">Een fictief winkelconcept · De Kleine Markt</div><header class="site-header"><a class="brand" href="/"><span class="brand-icon">✳</span><span>de kleine <b>markt</b></span></a><nav><a href="/">Home</a><a href="/contact.html">Contact</a></nav><a class="header-cta" href="/#assortiment">Assortiment ↗</a></header>
<main class="text-page"><p class="eyebrow">PRIVACY</p><h1>Jouw privacy<br><em>is belangrijk.</em></h1><p class="large-copy">Deze demonstratiewebsite bevat geen winkelwagen, account of contactformulier en vraagt niet om persoonsgegevens.</p><h2>Technische gegevens</h2><p>De webserver kan technische verbindingsgegevens verwerken die nodig zijn om de website te leveren en te beveiligen. De concrete verwerking hangt af van de serverconfiguratie van de beheerder.</p><h2>Cookies</h2><p>Deze voorbeeldwebsite plaatst zelf geen tracking- of marketingcookies.</p><p class="notice">De Kleine Markt is een fictief winkelconcept. Deze voorbeeldtekst is geen juridisch privacyadvies.</p><a class="button" href="/">Terug naar de winkel →</a></main>
<footer><a class="brand footer-brand" href="/"><span class="brand-icon">✳</span><span>de kleine <b>markt</b></span></a><div class="footer-links"><a href="/">Home</a><a href="/about.html">Ons verhaal</a><a href="/contact.html">Contact</a></div><p>© <span id="year"></span> De Kleine Markt · Conceptwebsite</p></footer><script>document.getElementById('year').textContent=new Date().getFullYear();</script></body></html>
HTML

  cat > "$SITE_DIR/assets/styles.css" <<'CSS'
:root{--paper:#f5f1e8;--ink:#24372d;--green:#315c45;--sage:#dce4d5;--orange:#d98250;--muted:#72776d;--line:#ded9cc;--serif:Georgia,"Times New Roman",serif;--sans:Arial,Helvetica,sans-serif}
*{box-sizing:border-box}html{scroll-behavior:smooth}body{margin:0;background:var(--paper);color:var(--ink);font-family:var(--sans);line-height:1.6}a{color:inherit;text-decoration:none}a:hover{text-decoration:underline}.announcement{background:var(--green);color:#fff;text-align:center;padding:8px 14px;font-size:.72rem;letter-spacing:.1em;text-transform:uppercase}.site-header{max-width:1180px;margin:auto;padding:22px 28px;display:flex;align-items:center;justify-content:space-between;gap:24px;border-bottom:1px solid var(--line)}.brand{display:flex;align-items:center;gap:9px;font-family:var(--serif);font-size:1.35rem;letter-spacing:-.04em;white-space:nowrap}.brand b{font-weight:700;color:var(--green)}.brand-icon{font-family:var(--sans);font-size:1.7rem;color:var(--orange)}nav{display:flex;gap:30px;font-size:.83rem;color:#586258}.header-cta{font-size:.78rem;font-weight:bold;border-bottom:1px solid var(--green);padding:8px 0;white-space:nowrap}.header-cta span{color:var(--orange)}
.hero{max-width:1180px;margin:auto;padding:76px 28px 82px;display:grid;grid-template-columns:1fr 1fr;align-items:center;gap:64px;min-height:570px}.eyebrow{font-size:.69rem;letter-spacing:.19em;font-weight:bold;color:var(--orange);margin:0 0 20px}.hero h1,.text-page h1{font-family:var(--serif);font-size:clamp(3.5rem,7vw,6.3rem);line-height:.96;letter-spacing:-.055em;font-weight:400;margin:0 0 25px}.hero h1 em,.text-page h1 em{color:var(--green);font-weight:400}.intro{max-width:450px;color:#646b60;font-size:1rem;line-height:1.85;margin:0 0 28px}.button{display:inline-flex;align-items:center;gap:26px;background:var(--green);color:white;padding:14px 20px;font-size:.8rem;font-weight:bold;letter-spacing:.02em}.button:hover{background:#244634;text-decoration:none}.button span{font-size:1.15rem}.micro-note{font-size:.7rem;color:#85877d;margin-top:18px;letter-spacing:.04em}
.hero-art{height:440px;position:relative;overflow:hidden;background:#d8dfce;border-radius:48% 48% 8px 8px;isolation:isolate}.hero-art:before{content:"";position:absolute;inset:18px;border:1px solid rgba(49,92,69,.24);border-radius:48% 48% 5px 5px}.art-sun{position:absolute;width:210px;height:210px;border-radius:50%;background:#e8a875;top:44px;right:60px}.art-label{position:absolute;top:42px;left:40px;font-size:.63rem;letter-spacing:.2em;line-height:1.7;color:var(--green);z-index:2}.art-bowl{position:absolute;width:230px;height:155px;left:50%;top:180px;transform:translateX(-50%);border-radius:20px 20px 110px 110px;background:#f1e6ce;box-shadow:inset 0 -14px 0 #c4b69b,0 24px 35px #6b775033;display:grid;place-items:center;font-size:4rem;color:#b66b45}.art-leaf{position:absolute;width:100px;height:180px;border-radius:100% 0 100% 0;background:#6e8c68;transform:rotate(-28deg);z-index:-1}.leaf-one{bottom:18px;left:12%}.leaf-two{bottom:35px;right:12%;transform:rotate(38deg);background:#8fa17b}.art-fruit{position:absolute;width:65px;height:65px;border-radius:50%;background:#d98250;bottom:70px;left:23%;box-shadow:inset -10px -8px 0 #b96c42}.fruit-two{width:47px;height:47px;left:auto;right:22%;bottom:95px;background:#e7bd63}.art-caption{position:absolute;right:30px;bottom:25px;font-family:var(--serif);font-style:italic;color:var(--green);font-size:1.2rem;line-height:1.1;text-align:right}
.intro-strip{background:#e8e4d8;display:flex;justify-content:center;gap:clamp(25px,8vw,110px);padding:22px 20px;color:var(--green);font-size:.75rem;letter-spacing:.04em}.section{max-width:1180px;margin:auto;padding:92px 28px}.section-heading{display:flex;justify-content:space-between;align-items:end;margin-bottom:34px;gap:30px}.section-heading h2,.visit h2{font:400 clamp(2.6rem,5vw,4rem)/1 var(--serif);letter-spacing:-.04em;margin:0}.section-heading>p{max-width:320px;color:var(--muted);font-size:.85rem;margin:0 0 5px}.product-grid{display:grid;grid-template-columns:repeat(3,1fr);gap:30px 22px}.product{background:#fbf9f3}.product-art{height:220px;display:flex;align-items:center;justify-content:center;position:relative;overflow:hidden;font-size:4.2rem}.product-art small{position:absolute;bottom:14px;left:17px;font-size:.58rem;letter-spacing:.15em;font-weight:bold;color:#536251}.coffee{background:#d9cbb8}.pantry{background:#dce3d1;color:#6d8666}.bakery{background:#eddbbf}.home{background:#d6dedb}.home span{font:italic 1.2rem var(--serif);border:3px solid #7b9a91;border-radius:40% 40% 12% 12%;padding:32px 18px;color:#52756b}.cheese{background:#e9d9a9}.gifts{background:#e8d2c6}.product-info{padding:17px 18px 20px}.product-info h3{font:400 1.45rem var(--serif);margin:0 0 4px}.product-info p{font-size:.78rem;color:var(--muted);margin:0 0 12px}.tag{font-size:.62rem;color:var(--green);border-bottom:1px solid #c6d0c1;padding-bottom:3px}
.quote-band{background:var(--green);color:#fff;text-align:center;padding:75px 24px}.quote-band .eyebrow{color:#e7b18a}.quote-band blockquote{font:400 clamp(1.8rem,4vw,3.3rem)/1.2 var(--serif);max-width:780px;margin:0 auto 22px;letter-spacing:-.025em}.quote-band>a{font-size:.78rem;border-bottom:1px solid #b5c7b8;padding-bottom:5px}.visit{display:grid;grid-template-columns:1fr 1fr;align-items:center;gap:70px}.visit h2{margin-bottom:20px}.visit>div>p:not(.eyebrow){color:var(--muted);max-width:390px;font-size:.9rem;margin-bottom:25px}.button-dark{background:#293c31}.visit-card{background:#e4d7c4;min-height:300px;padding:40px;display:flex;flex-direction:column;justify-content:center;align-items:center;text-align:center;outline:1px solid #c7bba8;outline-offset:-12px}.visit-flower{font-size:2.5rem;color:var(--orange)}.visit-card p{font-size:.65rem;letter-spacing:.2em;color:var(--green)}.visit-card strong{font:400 2rem/1.15 var(--serif)}.visit-card small{margin-top:22px;color:#77776c;font-size:.65rem}
footer{border-top:1px solid var(--line);padding:28px max(28px,calc((100% - 1124px)/2));display:grid;grid-template-columns:1fr auto;gap:12px;align-items:center}.footer-brand{font-size:1.1rem}.footer-links{display:flex;gap:22px;font-size:.75rem;color:var(--muted)}footer>p{grid-column:1/-1;margin:0;color:#929186;font-size:.65rem}
.text-page{max-width:760px;margin:85px auto 110px;padding:0 28px;min-height:50vh}.text-page h1{font-size:clamp(3.2rem,7vw,5.5rem)}.text-page h2{font:400 1.8rem var(--serif);margin:40px 0 10px}.text-page>p:not(.eyebrow){color:#666d62;line-height:1.9}.text-page .large-copy{font:400 1.45rem/1.55 var(--serif);color:var(--green);margin:30px 0 45px}.notice{margin:45px 0 28px;padding:16px 18px;background:#e9e5da;border-left:3px solid var(--orange);font-size:.78rem}.contact-grid{display:grid;grid-template-columns:1fr 1fr;gap:20px;margin:35px 0}.contact-grid section{padding:20px;background:#ebe7dc}.contact-grid h2{font-size:1.25rem;margin:0 0 8px}.contact-grid p{font-size:.82rem;margin:0;overflow-wrap:anywhere}
@media(max-width:760px){.site-header{padding:17px 18px;flex-wrap:wrap}.site-header nav{order:3;width:100%;justify-content:space-between;gap:12px}.header-cta{font-size:.7rem}.hero{grid-template-columns:1fr;padding:55px 22px;gap:38px}.hero h1{font-size:4.2rem}.hero-art{height:350px;max-width:520px;width:100%;margin:auto}.intro-strip{flex-wrap:wrap;gap:12px 25px;font-size:.68rem}.section{padding:65px 20px}.section-heading{display:block}.section-heading>p{margin-top:15px}.product-grid{grid-template-columns:repeat(2,minmax(0,1fr));gap:14px}.product-art{height:155px;font-size:3rem}.product-info{padding:13px}.product-info h3{font-size:1.2rem}.product-info p{font-size:.72rem}.visit{grid-template-columns:1fr;gap:35px}.visit-card{min-height:250px}.quote-band{padding:60px 22px}footer{padding:25px 20px;grid-template-columns:1fr}.footer-links{flex-wrap:wrap}footer>p{grid-column:auto}.text-page{margin:55px auto 75px;padding:0 22px}.contact-grid{grid-template-columns:1fr 1fr}}
@media(max-width:420px){.brand{font-size:1.15rem}.hero h1{font-size:3.6rem}.product-grid{grid-template-columns:1fr}.product-art{height:190px}.contact-grid{grid-template-columns:1fr}.header-cta{display:none}}
@media(prefers-reduced-motion:reduce){html{scroll-behavior:auto}*{transition:none!important}}
CSS

  cat > "$SITE_DIR/assets/favicon.svg" <<'SVG'
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64">
<rect width="64" height="64" rx="18" fill="#315c45"/>
<path d="M32 9l5.2 16.8L54 20l-10.5 14L58 45l-18-1.5L32 61l-8-17.5L6 47l12-13L7 20l17 6z" fill="#f5f1e8"/>
<circle cx="32" cy="33" r="5" fill="#d98250"/>
</svg>
SVG

  chown root:root "$SITE_DIR" "$SITE_DIR/index.html" "$SITE_DIR/about.html" "$SITE_DIR/contact.html" "$SITE_DIR/privacy.html" \
    "$SITE_DIR/assets" "$SITE_DIR/assets/styles.css" "$SITE_DIR/assets/favicon.svg"
  chmod 0755 "$SITE_DIR" "$SITE_DIR/assets"
  chmod 0644 "$SITE_DIR/index.html" "$SITE_DIR/about.html" "$SITE_DIR/contact.html" "$SITE_DIR/privacy.html" \
    "$SITE_DIR/assets/styles.css" "$SITE_DIR/assets/favicon.svg"
  ok "Файлы De Kleine Markt установлены (каталоги 0755, файлы 0644)"
}

ensure_tproxy_user() {
  if ! id tproxy >/dev/null 2>&1; then
    useradd --system --home /nonexistent --shell /usr/sbin/nologin tproxy
  fi
}

remove_legacy_compat_links() {
  local legacy target actual item
  local -a links=(
    "/etc/tproxy-server|$PROXY_CONFIG_DIR"
    "/etc/mtproxy|$MTPROXY_CONFIG_DIR"
    "/opt/tproxy-server|$REPO_DIR"
    "/opt/MTProxy|$MTPROXY_DIR"
    "/usr/local/bin/tproxy-server|$BIN_DIR/tproxy-server"
    "/usr/local/bin/mtproxy|$BIN_DIR/mtproxy-proxy"
    "/usr/local/sbin/refresh-mtproxy-config|$BIN_DIR/refresh-mtproxy-config"
  )
  for item in "${links[@]}"; do
    legacy="${item%%|*}"
    target="${item#*|}"
    if [[ -L "$legacy" ]]; then
      actual="$(readlink "$legacy" 2>/dev/null || true)"
      if [[ "$actual" == "$target" ]]; then
        rm -f -- "$legacy"
        info "Удалена устаревшая совместимая ссылка: $legacy"
      else
        die "Ссылка $legacy указывает не на ожидаемый путь ($actual); не удаляю её автоматически."
      fi
    elif [[ -e "$legacy" ]]; then
      die "Обнаружен старый объект $legacy. Перенеси его отдельным скриптом миграции и повтори запуск."
    fi
  done
}

prepare_layout() {
  require_root
  remove_legacy_compat_links
  install -d -m 0755 "$BASE_DIR" "$BIN_DIR" "$CONFIG_DIR" "$PROXY_CONFIG_DIR" "$MTPROXY_CONFIG_DIR" "$DATA_DIR" "$MTPROXY_DIR" "$SOURCE_DIR" "$SYSTEMD_DIR" "$QR_DIR" "$BACKUP_DIR"
  # The legacy standalone manager is no longer used; all its functions live here.
  rm -f "$BIN_DIR/tproxy-advanced"
}

profile_manifest_valid() {
  local file="${1:-$PROXY_CONFIG_DIR/profiles.json}"
  [[ -s "$file" ]] && jq -e '
    type == "object" and
    (.profiles | type == "array" and length >= 1 and length <= 32) and
    all(.profiles[];
      type == "object" and
      (.name | type == "string" and test("^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$")) and
      (.secret | type == "string" and test("^(dd)?[0-9a-f]{32}$")) and
      (.backend | type == "string" and test("^[^[:space:]]+:[0-9]+$")) and
      (.carrier_mode | (type == "string" and
        (. == "https" or . == "https-lanes" or . == "websocket" or . == "websocket-lanes")))
    ) and
    ([.profiles[].name] | length == (unique | length))
  ' "$file" >/dev/null 2>&1
}

profile_storage_rebuild() {
  local profile_dir="$PROXY_CONFIG_DIR/profiles"
  local count dir file name tmp
  local -a profile_files=()

  install -d -o root -g tproxy -m 0750 "$profile_dir"
  count="$(find "$profile_dir" -mindepth 1 -maxdepth 1 -type d | wc -l)"

  if (( count == 0 )); then
    if profile_manifest_valid; then
      # Migrate the legacy aggregate only when no per-profile source exists.
      while IFS= read -r name; do
        [[ "$name" =~ ^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$ ]] ||
          die "Недопустимое имя профиля в старом profiles.json"
        install -d -o root -g tproxy -m 0750 "$profile_dir/$name"
        jq --arg n "$name" '.profiles[] | select(.name == $n)' "$PROXY_CONFIG_DIR/profiles.json" > "$profile_dir/$name/profile.json" ||
          die "Не удалось перенести профиль $name"
        chown root:tproxy "$profile_dir/$name/profile.json"
        chmod 0640 "$profile_dir/$name/profile.json"
      done < <(jq -r '.profiles[].name' "$PROXY_CONFIG_DIR/profiles.json")
    elif [[ ! -s "$PROXY_CONFIG_DIR/config.json" || "${MODE:-}" == "install" ]]; then
      # Fresh installation: there is no previous profile data to preserve.
      install -d -o root -g tproxy -m 0750 "$profile_dir/default"
      jq -n --arg s "$SECRET_ARG" --arg m "$CARRIER_MODE_ARG" \
        '{name:"default",secret:$s,backend:"127.0.0.1:2398",carrier_mode:$m}' \
        > "$profile_dir/default/profile.json"
      chown root:tproxy "$profile_dir/default/profile.json"
      chmod 0640 "$profile_dir/default/profile.json"
    else
      die "profiles.json повреждён, а индивидуальных файлов профилей нет. Восстановление без исходных секретов невозможно."
    fi
  fi

  while IFS= read -r -d '' dir; do
    name="${dir##*/}"
    [[ "$name" =~ ^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$ ]] ||
      die "Недопустимое имя каталога профиля: $name"
    [[ -s "$dir/profile.json" ]] ||
      die "В каталоге профиля отсутствует profile.json: $dir"
  done < <(find "$profile_dir" -mindepth 1 -maxdepth 1 -type d -print0)

  if [[ -s "$profile_dir/default/profile.json" ]]; then
    profile_files+=("$profile_dir/default/profile.json")
  fi
  while IFS= read -r -d '' file; do
    [[ "$file" == "$profile_dir/default/profile.json" ]] || profile_files+=("$file")
  done < <(find "$profile_dir" -mindepth 2 -maxdepth 2 -type f -name profile.json -print0 | sort -z)

  (( ${#profile_files[@]} >= 1 && ${#profile_files[@]} <= 32 )) ||
    die "В хранилище должно быть от 1 до 32 файлов профилей"

  for file in "${profile_files[@]}"; do
    dir="${file%/profile.json}"
    name="${dir##*/}"
    jq -e --arg n "$name" '
      type == "object" and .name == $n and
      (.secret | type == "string" and test("^(dd)?[0-9a-f]{32}$")) and
      (.backend | type == "string" and test("^[^[:space:]]+:[0-9]+$")) and
      (.carrier_mode | (type == "string" and
        (. == "https" or . == "https-lanes" or . == "websocket" or . == "websocket-lanes")))
    ' "$file" >/dev/null 2>&1 || die "Некорректный файл профиля: $file"
  done

  tmp="$(mktemp "$PROXY_CONFIG_DIR/profiles.json.XXXXXX")"
  if ! jq -s '{profiles: .}' "${profile_files[@]}" > "$tmp" ||
     ! profile_manifest_valid "$tmp"; then
    rm -f "$tmp"
    die "Не удалось пересобрать profiles.json из индивидуальных файлов"
  fi
  chown root:tproxy "$tmp"
  chmod 0400 "$tmp"
  mv -f "$tmp" "$PROXY_CONFIG_DIR/profiles.json"
}

write_configs() {
  install -d -o root -g tproxy -m 0750 $PROXY_CONFIG_DIR
  sed -i "s#/etc/tproxy-server#$PROXY_CONFIG_DIR#g" "$REPO_DIR/deploy/ensure-token-key.sh"
  bash "$REPO_DIR/deploy/ensure-token-key.sh"

  if [[ -n "$SITE_UPSTREAM_ARG" ]]; then
    cat > "$PROXY_CONFIG_DIR/config.json" <<EOF
{
  "public_hostname": "$HOSTNAME_ARG",
  "base_path": "$BASE_PATH_ARG",
  "listen": "127.0.0.1:$RELAY_PORT",
  "admin_listen": "127.0.0.1:$ADMIN_PORT",
  "public_upstream": "$SITE_UPSTREAM_ARG",
  "static_routes": "exact",
  "profiles_file": "/run/credentials/tproxy-server.service/profiles.json"
}
EOF
  else
    cat > "$PROXY_CONFIG_DIR/config.json" <<EOF
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
  fi

  # Per-profile JSON files are authoritative. Read the selected profile,
  # apply the installer choices, and write back only that profile object.
  profile_storage_rebuild
  local profile_dir="$PROXY_CONFIG_DIR/profiles" profile_name profile_tmp
  profile_name="$(jq -r '.profiles[0].name' "$PROXY_CONFIG_DIR/profiles.json")"
  [[ "$profile_name" =~ ^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$ ]] || die "Недопустимое имя профиля: $profile_name"
  install -d -o root -g tproxy -m 0750 "$profile_dir/$profile_name"
  profile_tmp="$(mktemp "$profile_dir/$profile_name/profile.json.XXXXXX")"
  if ! jq --arg n "$profile_name" --arg secret "$SECRET_ARG" --arg mode "$CARRIER_MODE_ARG" --argjson update "$([[ "$MODE" == "update" ]] && echo true || echo false)" --argjson mode_set "$CARRIER_MODE_SET" '
      .profiles[] | select(.name == $n) |
      .secret = $secret | if ($update and ($mode_set == 0)) then . else .carrier_mode = $mode end
    ' "$PROXY_CONFIG_DIR/profiles.json" > "$profile_tmp" ||
     ! jq -e --arg n "$profile_name" '
      type == "object" and .name == $n and
      (.secret | type == "string" and test("^(dd)?[0-9a-f]{32}$")) and
      (.backend | type == "string" and test("^[^[:space:]]+:[0-9]+$")) and
      (.carrier_mode | type == "string" and
        (. == "https" or . == "https-lanes" or . == "websocket" or . == "websocket-lanes"))
    ' "$profile_tmp" >/dev/null; then
    rm -f "$profile_tmp"
    die "Не удалось сформировать индивидуальный файл профиля $profile_name"
  fi
  chown root:tproxy "$profile_tmp"
  chmod 0640 "$profile_tmp"
  mv -f "$profile_tmp" "$profile_dir/$profile_name/profile.json"

  # Rebuild the aggregate from validated per-profile objects. This prevents
  # accidentally writing the whole {"profiles":[...]} wrapper into profile.json.
  profile_storage_rebuild
  chown root:tproxy $PROXY_CONFIG_DIR/config.json $PROXY_CONFIG_DIR/profiles.json
  chmod 0640 $PROXY_CONFIG_DIR/config.json
  chmod 0400 $PROXY_CONFIG_DIR/profiles.json
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
    warn "Если MTProxy будет молчать — задай MTPROXY_NAT_ARGS в $MTPROXY_CONFIG_DIR/mtproxy.env"
  fi

  mkdir -p $MTPROXY_CONFIG_DIR
  local mtproxy_secrets="" profile_secret
  if [[ -s "$PROXY_CONFIG_DIR/profiles.json" ]] && command -v jq >/dev/null 2>&1; then
    while IFS= read -r profile_secret; do
      [[ -n "$profile_secret" ]] || continue
      profile_secret="${profile_secret#dd}"
      if [[ -n "$mtproxy_secrets" ]]; then mtproxy_secrets+=" -S "; fi
      mtproxy_secrets+="$profile_secret"
    done < <(jq -r '.profiles[].secret' "$PROXY_CONFIG_DIR/profiles.json")
  fi
  [[ -n "$mtproxy_secrets" ]] || mtproxy_secrets="$backend_secret"
  cat > "$MTPROXY_CONFIG_DIR/mtproxy.env" <<EOF
MTPROXY_SECRETS="$mtproxy_secrets"
MTPROXY_WORKERS=${WORKERS_ARG:-1}
MTPROXY_MAX_CONNECTIONS=${MAXCONN_ARG:-4096}
MTPROXY_NAT_ARGS=$mtproxy_nat_args
EOF
  chown root:mtproxy "$MTPROXY_CONFIG_DIR/mtproxy.env"
  chmod 0640 $MTPROXY_CONFIG_DIR/mtproxy.env
  ok "mtproxy.env записан"
}

install_units() {
  local name src dst
  local -a names=(tproxy-server.service mtproxy.service tproxy-firewall.service refresh-mtproxy-config.service refresh-mtproxy-config.timer)
  install -d -m 0755 "$SYSTEMD_DIR" "$PROXY_CONFIG_DIR" "$BIN_DIR"
  for name in "${names[@]}"; do
    src="$REPO_DIR/deploy/$name"
    dst="$SYSTEMD_DIR/$name"
    [[ -f "$src" ]] || die "Не найден шаблон службы: $src"
    sed \
      -e "s#/etc/tproxy-server#$PROXY_CONFIG_DIR#g" \
      -e "s#/etc/mtproxy#$MTPROXY_CONFIG_DIR#g" \
      -e "s#/opt/MTProxy#$MTPROXY_DIR#g" \
      -e "s#/usr/local/bin/tproxy-server#$BIN_DIR/tproxy-server#g" \
      -e "s#/usr/local/bin/mtproxy#$BIN_DIR/mtproxy-proxy#g" \
      -e "s#/usr/local/sbin/refresh-mtproxy-config#$BIN_DIR/refresh-mtproxy-config#g" \
      -e "s#/srv/tproxy-site#$SITE_DIR#g" "$src" > "$dst"
    if [[ "$name" == "mtproxy.service" ]]; then
      # All MTProxy runtime settings come from mtproxy.env. Keeping duplicate
      # Environment= entries here would override EnvironmentFile values.
      sed -i \
        -e '/^[[:space:]]*Environment=MTPROXY_WORKERS=/d' \
        -e '/^[[:space:]]*Environment=MTPROXY_MAX_CONNECTIONS=/d' \
        -e '/^[[:space:]]*Environment=MTPROXY_NAT_ARGS=/d' \
        -e 's/-S ${MTPROXY_SECRET}/-S $MTPROXY_SECRETS/' "$dst"
    elif [[ "$name" == "tproxy-server.service" ]]; then
      # Validate the exact systemd credential at service start. This catches
      # credential-path/schema mismatches that a temporary-file check cannot.
      sed -i "/^[[:space:]]*ExecStart=/i ExecStartPre=$BIN_DIR/tproxy-server -config $PROXY_CONFIG_DIR/config.json -check" "$dst"
    fi
    chmod 0644 "$dst"
    ln -sfn "$dst" "/etc/systemd/system/$name"
  done
  install -m 0644 "$REPO_DIR/deploy/firewall.nft" "$PROXY_CONFIG_DIR/firewall.nft"
  sed -e "s#/etc/mtproxy#$MTPROXY_CONFIG_DIR#g" "$REPO_DIR/deploy/refresh-mtproxy-config.sh" > "$BIN_DIR/refresh-mtproxy-config"
  chmod 0755 "$BIN_DIR/refresh-mtproxy-config"
  ok "Файлы служб размещены в $SYSTEMD_DIR и подключены через системные ссылки"
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

  # Render the upstream unit with this installation's actual site directory.
  # The upstream template defaults to /srv/tproxy-site, while this installer
  # stores the decoy site under SITE_DIR (normally /opt/telegram-web-proxy/data/website).
  local caddy_unit_tmp
  caddy_unit_tmp="$(mktemp)"
  if ! awk -v site_dir="$SITE_DIR" '
    $0 == "ReadOnlyPaths=/srv/tproxy-site" {
      print "ReadOnlyPaths=" site_dir
      replaced = 1
      next
    }
    { print }
    END { if (!replaced) exit 42 }
  ' "$REPO_DIR/deploy/caddy.service" > "$caddy_unit_tmp"; then
    rm -f "$caddy_unit_tmp"
    die "Не удалось адаптировать ReadOnlyPaths в caddy.service: шаблон изменился или не содержит ожидаемую директиву"
  fi

  if [[ -e /etc/systemd/system/caddy.service ]] && \
     ! cmp -s /etc/systemd/system/caddy.service "$caddy_unit_tmp"; then
    cp -a /etc/systemd/system/caddy.service \
      "/etc/systemd/system/caddy.service.before-tproxy.$(date +%Y%m%d%H%M%S)"
  fi
  install -m 0644 "$caddy_unit_tmp" /etc/systemd/system/caddy.service
  rm -f "$caddy_unit_tmp"
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
  local validation_profiles
  verify_site_permissions

  [[ -s "$PROXY_CONFIG_DIR/config.json" ]] ||
    die "config.json отсутствует или пуст"
  [[ -s "$PROXY_CONFIG_DIR/profiles.json" ]] ||
    die "profiles.json отсутствует или пуст"

  jq -e 'type == "object" and has("profiles") == false' \
    "$PROXY_CONFIG_DIR/config.json" >/dev/null ||
    die "config.json имеет неверную структуру или содержит поле profiles"

  # Use the same strict schema validator as profile storage/rebuild.
  # On failure, print only structural metadata; never print secrets.
  if ! profile_manifest_valid "$PROXY_CONFIG_DIR/profiles.json"; then
    warn "Диагностика структуры profiles.json (значения секретов не выводятся):"
    jq '{
      root_type: type,
      root_keys: (if type == "object" then keys else [] end),
      profiles_type: (.profiles | type),
      profiles_count: (if (.profiles | type) == "array" then (.profiles | length) else 0 end),
      profiles: (if (.profiles | type) == "array" then
        [.profiles | to_entries[] | {
          index: .key,
          item_type: (.value | type),
          name_type: (.value.name | type),
          name_nonempty: ((.value.name | type) == "string" and (.value.name | length) > 0),
          secret_type: (.value.secret | type),
          secret_nonempty: ((.value.secret | type) == "string" and (.value.secret | length) > 0),
          backend_type: (.value.backend | type),
          backend_nonempty: ((.value.backend | type) == "string" and (.value.backend | length) > 0),
          carrier_mode_type: (.value.carrier_mode | type),
          carrier_mode_value: (if (.value.carrier_mode | type) == "string" then .value.carrier_mode else null end)
        }] else [] end)
    }' "$PROXY_CONFIG_DIR/profiles.json" 2>/dev/null ||
      warn "Файл profiles.json не удалось разобрать как JSON"
    die "profiles.json не прошёл строгую проверку схемы; смотри безопасную диагностику выше"
  fi

  # Check the exact file passed to the binary, avoiding a race with replacement.
  validation_profiles="$(mktemp "$PROXY_CONFIG_DIR/profiles.validate.XXXXXX")"
  cp -- "$PROXY_CONFIG_DIR/profiles.json" "$validation_profiles"
  chown root:root "$validation_profiles"
  chmod 0400 "$validation_profiles"

  info "Валидация config.json и profiles.json…"
  if ! "$BIN_DIR/tproxy-server" \
      -config "$PROXY_CONFIG_DIR/config.json" \
      -profiles-file "$validation_profiles" \
      -check; then
    warn "Безопасная сводка profiles.json:"
    jq '{
      top_level_keys: (if type == "object" then keys else [] end),
      profiles_type: (.profiles | type),
      profiles_count: (.profiles | if type == "array" then length else 0 end),
      first_profile_keys: (.profiles[0] // {} | if type == "object" then keys else [] end)
    }' "$validation_profiles" 2>/dev/null || true
    rm -f -- "$validation_profiles"
    die "tproxy-server -check не прошёл; проверь config.json и profiles.json"
  fi
  rm -f -- "$validation_profiles"

  if [[ "$WEB_SERVER" == "caddy" ]]; then
    info "Валидация Caddyfile…"
    TPROXY_HOSTNAME="$HOSTNAME_ARG" TPROXY_SITE_ROOT="$SITE_DIR" ACME_EMAIL="$EMAIL_ARG" /usr/local/bin/caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile || die "caddy validate упал"
  else
    info "Валидация Nginx…"
    nginx -t || die "nginx -t упал"
  fi
  printf "%s\\n" "$WEB_SERVER" > "$PROXY_CONFIG_DIR/web-server"
  chmod 0640 "$PROXY_CONFIG_DIR/web-server"
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

# Полный перезапуск служб после успешного применения обновлённых файлов.
# Порядок важен: firewall и backend запускаются до внешнего веб-сервера.
restart_proxy_services() {
  local -a services=(
    tproxy-firewall.service
    mtproxy.service
    tproxy-server.service
  )
  if [[ "$WEB_SERVER" == "caddy" ]]; then
    services+=(caddy.service)
  else
    services+=(nginx.service)
  fi
  info "Перезапускаю все службы прокси после обновления…"
  systemctl restart "${services[@]}" || die "Не удалось перезапустить одну или несколько служб: ${services[*]}"
  systemctl restart refresh-mtproxy-config.timer 2>/dev/null || true
  ok "Службы перезапущены: ${services[*]}"
}

wait_ready() {
  local attempt health_ok ready_ok
  info "Ждём healthz и readyz на 127.0.0.1:$ADMIN_PORT (до 30с)…"
  for (( attempt=0; attempt<30; attempt++ )); do
    health_ok=0
    ready_ok=0
    curl --fail --silent --max-time 1 --output /dev/null "http://127.0.0.1:$ADMIN_PORT/healthz" && health_ok=1
    curl --fail --silent --max-time 1 --output /dev/null "http://127.0.0.1:$ADMIN_PORT/readyz" && ready_ok=1
    if (( health_ok && ready_ok )); then
      ok "healthz и readyz отвечают; relay готов"
      return 0
    fi
    sleep 1
  done
  warn "healthz/readyz не прошли проверку за 30с"
  echo
  echo "=== Диагностика ==="
  echo "--- tproxy-server ---"
  systemctl status tproxy-server --no-pager -l 2>/dev/null | head -20 || true
  journalctl -u tproxy-server -u mtproxy -n 20 --no-pager 2>/dev/null | redact_sensitive_log || true
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
  local link="$1" qr_file="${2:-$QR_DIR/proxy-qr.png}"
  command -v qrencode >/dev/null 2>&1 || die "qrencode не установлен"
  install -d -m 0750 "$QR_DIR"
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

 Секрет клиента:          $SECRET_ARG
 Адрес прокси-сервера:    $client_address
 Секрет прокси:            $proxy_secret
 Ссылка для подключения:  $proxy_link
 QR-код:                   $QR_DIR/proxy-qr.png

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
  local cfg="$PROXY_CONFIG_DIR/config.json" profiles="$PROXY_CONFIG_DIR/profiles.json"
  local envf="$MTPROXY_CONFIG_DIR/mtproxy.env" host="" base="" relay="" admin="" public_dir="" email="" web_server=""
  local backend="" secret="" workers="" maxconn="" proxy_secret="" server="" link="" output=""
  local public_upstream="" profile_name="" carrier_mode="" carrier_label="" count=0 index=0 choice=1
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --output) [[ $# -ge 2 ]] || die "--output требует путь"; output="$2"; shift 2 ;;
      *) die "Неизвестная опция config: $1" ;;
    esac
  done
  [[ -r "$profiles" ]] || die "Файл профилей не найден: $profiles"
  command -v jq >/dev/null 2>&1 || die "Для просмотра конфигурации нужен jq"
  count="$(jq '.profiles | length' "$profiles")"
  (( count > 0 )) || die "Список профилей пуст"
  if (( count > 1 )); then
    echo
    ui_header "Выбор профиля для просмотра"
    while IFS=$'\t' read -r profile_name carrier_mode; do
      index=$((index + 1))
      ui_option "$index" "◆" "$profile_name · $carrier_mode"
    done < <(jq -r '.profiles[] | [.name, (.carrier_mode // "https")] | @tsv' "$profiles")
    ui_option 0 "←" "Назад"
    read -r -p "Выбери профиль [0-$count]: " choice || die "ввод прерван"
    [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= count )) || { info "Просмотр отменён"; return 0; }
  fi
  index=$((choice - 1))
  profile_name="$(jq -r --argjson i "$index" '.profiles[$i].name' "$profiles")"
  secret="$(jq -r --argjson i "$index" '.profiles[$i].secret // empty' "$profiles")"
  backend="$(jq -r --argjson i "$index" '.profiles[$i].backend // empty' "$profiles")"
  carrier_mode="$(jq -r --argjson i "$index" '.profiles[$i].carrier_mode // "https"' "$profiles")"
  case "$carrier_mode" in
    https) carrier_label="HTTPS" ;;
    https-lanes) carrier_label="HTTPS с несколькими каналами" ;;
    websocket) carrier_label="WebSocket" ;;
    websocket-lanes) carrier_label="WebSocket с несколькими каналами" ;;
    *) carrier_label="$carrier_mode (неизвестный режим)" ;;
  esac
  if [[ -r "$cfg" ]]; then
    host="$(jq -r '.public_hostname // empty' "$cfg")"
    base="$(jq -r '.base_path // empty' "$cfg")"
    relay="$(jq -r '.listen // empty' "$cfg")"
    admin="$(jq -r '.admin_listen // empty' "$cfg")"
    public_dir="$(jq -r '.public_dir // empty' "$cfg")"
    public_upstream="$(jq -r '.public_upstream // empty' "$cfg")"
  fi
  if [[ -r "$PROXY_CONFIG_DIR/acme-email" ]]; then email="$(head -n1 "$PROXY_CONFIG_DIR/acme-email" | xargs || true)"; fi
  if [[ -z "$email" && -r /etc/systemd/system/caddy.service.d/tproxy.conf ]]; then
    email="$(sed -n 's/^Environment=ACME_EMAIL=//p' /etc/systemd/system/caddy.service.d/tproxy.conf | head -n1)"
  fi
  if [[ -z "$email" && -d /etc/letsencrypt/renewal ]]; then
    email="$(grep -RhoE '^[[:space:]]*email[[:space:]]*=[[:space:]]*[^[:space:]]+' /etc/letsencrypt/renewal 2>/dev/null | head -n1 | cut -d= -f2- | xargs || true)"
  fi
  if [[ -r "$PROXY_CONFIG_DIR/web-server" ]]; then web_server="$(cat "$PROXY_CONFIG_DIR/web-server")"
  elif systemctl is-enabled --quiet nginx 2>/dev/null; then web_server=nginx
  else web_server=caddy; fi
  if [[ -r "$envf" ]]; then
    workers="$(sed -n 's/^MTPROXY_WORKERS=//p' "$envf" | head -n1)"
    maxconn="$(sed -n 's/^MTPROXY_MAX_CONNECTIONS=//p' "$envf" | head -n1)"
  fi
  if [[ -n "$host" && -n "$secret" ]]; then
    BASE_PATH_ARG="$base"; SECRET_ARG="$secret"
    proxy_secret="$(web_proxy_secret)"
    server="$host"; [[ -z "$base" ]] || server="$host/$base"
    server="$(printf '%s' "$server" | sed 's#/#%2F#g')"
    link="https://t.me/webproxy?server=$server&secret=$proxy_secret"
    generate_proxy_qr "$link" >/dev/null
  fi
  local report config_separator
  if [[ -z "${NO_COLOR:-}" && "${TERM:-}" != "dumb" ]]; then
    config_separator="$(printf '\033[1;34m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\033[0m')"
  else
    config_separator='━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━'
  fi
  report="$(printf '%s\n' \
    "$config_separator" \
    "  Профиль                  : $profile_name" \
    "  Carrier mode             : $carrier_label" \
    "  Домен                    : $host" \
    "  Base path                : $base" \
    "  Публичный каталог        : $public_dir" \
    "  Public upstream          : $public_upstream" \
    "  Конфигурация relay       : $cfg" \
    "  Каталог профиля          : $PROXY_CONFIG_DIR/profiles/$profile_name" \
    "  Файл профиля             : $PROXY_CONFIG_DIR/profiles/$profile_name/profile.json" \
    "  Общий список профилей    : $profiles" \
    "  Переменные MTProxy       : $envf" \
    "  Backend                  : $backend" \
    "  Workers                  : $workers" \
    "  Max connections          : $maxconn" \
    "  E-mail для Let's Encrypt : $email" \
    "  Веб-сервер               : $web_server" \
    "  Формат секрета           : $(if [[ "$secret" == dd* ]]; then echo 'dd + 32 hex'; elif [[ -n "$secret" ]]; then echo '32 hex'; else echo '<не задан>'; fi)" \
    "  Секрет клиента           : $secret" \
    '' 'Слушающие TCP-порты прокси:' \
    "$(proxy_ports_table "$relay" "$admin" "$backend")" \
    '' 'Ссылка подключения:' "$link" \
    "QR-код (PNG): $QR_DIR/proxy-qr.png" \
    "$config_separator")"
  if [[ -n "$output" ]]; then
    install -m 0600 /dev/null "$output"
    printf '%s\n' "$report" | sed -E 's/\x1B\[[0-9;]*[[:alpha:]]//g' > "$output"
    echo "Конфигурация сохранена: $output (0600)"
  else printf '%s\n' "$report"; fi
  printf '\nСостояние служб:\n'
  local service state mark
  for service in mtproxy tproxy-firewall tproxy-server refresh-mtproxy-config.timer "$web_server"; do
    state="$(systemctl is-active "$service" 2>/dev/null || true)"
    if [[ "$state" == active ]]; then mark="$(status_mark ok)"
    elif [[ "$state" == inactive || "$state" == failed ]]; then mark="$(status_mark fail)"
    else mark="$(status_mark warn)"; fi
    printf '  %s %-28s %s\n' "$mark" "$service" "$(status_word "$state")"
  done
  [[ -z "$link" ]] || print_proxy_qr_terminal "$link"
}

load_existing_config() {
  local cfg="$PROXY_CONFIG_DIR/config.json" profiles="$PROXY_CONFIG_DIR/profiles.json"
  local envf="$MTPROXY_CONFIG_DIR/mtproxy.env" dropin=/etc/systemd/system/caddy.service.d/tproxy.conf v
  [[ -r "$cfg" && -r "$envf" ]] || die "Не найдена полная установленная конфигурация; сначала выполни config"
  command -v jq >/dev/null 2>&1 || die "Для чтения настроек нужен jq"
  profile_storage_rebuild
  v="$(jq -er '.public_hostname | select(type == "string" and length > 0)' "$cfg")" || die "Не удалось прочитать hostname"
  [[ -n "$HOSTNAME_ARG" ]] || HOSTNAME_ARG="$v"
  v="$(jq -r '.base_path // "none"' "$cfg")"; [[ -n "$BASE_PATH_ARG" ]] || BASE_PATH_ARG="$v"
  v="$(jq -r '.listen // "" | split(":")[-1]' "$cfg")"; [[ -n "$RELAY_PORT" ]] || RELAY_PORT="$v"
  v="$(jq -r '.admin_listen // "" | split(":")[-1]' "$cfg")"; [[ -n "$ADMIN_PORT" ]] || ADMIN_PORT="$v"
  v="$(jq -r '.public_dir // empty' "$cfg")"; [[ -n "$v" ]] && SITE_DIR="$v"
  SITE_UPSTREAM_ARG="$(jq -r '.public_upstream // empty' "$cfg")"
  if [[ "$WEB_SERVER_SET" -eq 0 ]]; then if [[ -r $PROXY_CONFIG_DIR/web-server ]]; then WEB_SERVER="$(< $PROXY_CONFIG_DIR/web-server)"; elif systemctl is-enabled --quiet nginx 2>/dev/null; then WEB_SERVER=nginx; else WEB_SERVER=caddy; fi; fi
  v="$(jq -er '.profiles[0].secret | select(type == "string" and length > 0)' "$profiles")" || die "Не удалось прочитать секрет"
  [[ -n "$SECRET_ARG" ]] || SECRET_ARG="$v"
  if [[ "$CARRIER_MODE_SET" -eq 0 ]]; then CARRIER_MODE_ARG="$(jq -r '.profiles[0].carrier_mode // "https"' "$profiles")"; fi
  if [[ "$SECRET_PREFIX_MODE_SET" -eq 0 ]]; then
    if [[ "$SECRET_ARG" == dd* ]]; then SECRET_PREFIX_MODE="dd"; else SECRET_PREFIX_MODE="plain"; fi
  fi
  v="$(sed -n 's/^MTPROXY_WORKERS=//p' "$envf" | head -n1)"; [[ -n "$WORKERS_ARG" ]] || WORKERS_ARG="${v:-1}"
  v="$(sed -n 's/^MTPROXY_MAX_CONNECTIONS=//p' "$envf" | head -n1)"; [[ -n "$MAXCONN_ARG" ]] || MAXCONN_ARG="${v:-4096}"
  if [[ -r $PROXY_CONFIG_DIR/acme-email ]]; then
    v="$(head -n1 $PROXY_CONFIG_DIR/acme-email | xargs || true)"
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
  install -d -m 0755 $PROXY_CONFIG_DIR
  printf '%s\n' "$EMAIL_ARG" > $PROXY_CONFIG_DIR/acme-email
  chmod 0600 $PROXY_CONFIG_DIR/acme-email
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
  ui_header "Обновление tproxy-server"
  echo "Текущие значения указаны в [квадратных скобках]."
  echo "Enter — оставить без изменений."
  prompt_update_value HOSTNAME_ARG "Домен" "$HOSTNAME_ARG" validate_hostname
  # Email is retained from the existing ACME configuration; --email can override it.
  prompt_update_value BASE_PATH_ARG "Base path (none — корень)" "$BASE_PATH_ARG" validate_base_path
  prompt_update_port RELAY_PORT "Relay-порт" "$RELAY_PORT"
  prompt_update_port ADMIN_PORT "Admin-порт" "$ADMIN_PORT"
  [[ "$RELAY_PORT" != "$ADMIN_PORT" ]] || die "relay- и admin-порты должны различаться"
  prompt_update_secret
  info "Carrier mode при обновлении не меняется. Для изменения выбери профиль в меню «Carrier mode и профили»."

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
  if [[ "$MODE" == "update" ]]; then
    ui_header "Перед обновлением"
    cat <<'EOF'
  Будут обновлены исходники и компоненты, пересобран tproxy-server,
  обновлены конфигурации и перезапущены службы.
  Текущие настройки будут предложены по умолчанию, каталог сайта сохранится.
  Перед изменениями будет создана rollback-копия бинарника и конфигураций.
  При неудачном health-check предыдущие файлы будут восстановлены автоматически.
EOF
  else
    ui_header "Перед установкой"
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
  ui_separator
  echo
}

begin_update_transaction() {
  [[ "$MODE" == "update" ]] || return 0
  install -d -m 0700 "$BACKUP_DIR"
  UPDATE_ROLLBACK_ARCHIVE="$BACKUP_DIR/update-rollback-$(date +%Y%m%d-%H%M%S)-${BASHPID}.tar.gz"
  local -a snapshot_items=()
  local path
  for path in \
    opt/telegram-web-proxy/bin/tproxy-server \
    opt/telegram-web-proxy/bin/mtproxy-proxy \
    opt/telegram-web-proxy/bin/refresh-mtproxy-config \
    opt/telegram-web-proxy/src/mtproxy \
    opt/telegram-web-proxy/config/proxy \
    opt/telegram-web-proxy/config/mtproxy \
    opt/telegram-web-proxy/systemd \
    etc/systemd/system/tproxy-server.service \
    etc/systemd/system/mtproxy.service \
    etc/systemd/system/tproxy-firewall.service \
    etc/systemd/system/refresh-mtproxy-config.service \
    etc/systemd/system/refresh-mtproxy-config.timer \
    etc/systemd/system/caddy.service \
    etc/systemd/system/caddy.service.d/tproxy.conf \
    etc/caddy/Caddyfile \
    etc/nginx/sites-available/tproxy-server \
    etc/nginx/sites-enabled/tproxy-server \
    etc/nginx/conf.d/tproxy-websocket-map.conf; do
    [[ -e "/$path" || -L "/$path" ]] && snapshot_items+=("$path")
  done
  (("${#snapshot_items[@]}")) || die "Не удалось создать rollback: установленные файлы не найдены"
  tar -C / -czpf "$UPDATE_ROLLBACK_ARCHIVE" "${snapshot_items[@]}" ||
    die "Не удалось создать резервную копию перед обновлением"
  chmod 0600 "$UPDATE_ROLLBACK_ARCHIVE"
  UPDATE_TRANSACTION_ACTIVE=1
  info "Создана точка отката обновления: $UPDATE_ROLLBACK_ARCHIVE"
}

rollback_update_transaction() {
  local archive="$UPDATE_ROLLBACK_ARCHIVE" old_web=""
  [[ -n "$archive" && -s "$archive" ]] || { warn "Архив отката не найден; автоматическое восстановление невозможно."; return 1; }
  warn "Обновление не прошло проверку. Возвращаю предыдущие бинарник и конфигурации…"
  systemctl stop tproxy-server mtproxy tproxy-firewall 2>/dev/null || true
  rm -f -- "$BIN_DIR/tproxy-server" "$BIN_DIR/mtproxy-proxy" "$BIN_DIR/refresh-mtproxy-config"
  rm -rf -- "$MTPROXY_DIR" "$PROXY_CONFIG_DIR" "$MTPROXY_CONFIG_DIR" "$SYSTEMD_DIR"
  rm -f -- \
    /etc/systemd/system/tproxy-server.service \
    /etc/systemd/system/mtproxy.service \
    /etc/systemd/system/tproxy-firewall.service \
    /etc/systemd/system/refresh-mtproxy-config.service \
    /etc/systemd/system/refresh-mtproxy-config.timer \
    /etc/systemd/system/caddy.service \
    /etc/systemd/system/caddy.service.d/tproxy.conf \
    /etc/caddy/Caddyfile \
    /etc/nginx/sites-available/tproxy-server \
    /etc/nginx/sites-enabled/tproxy-server \
    /etc/nginx/conf.d/tproxy-websocket-map.conf
  tar -C / -xzpf "$archive" || { warn "Не удалось распаковать rollback-архив: $archive"; return 1; }
  systemctl daemon-reload
  systemctl restart mtproxy tproxy-firewall tproxy-server 2>/dev/null || true
  old_web="$(cat "$PROXY_CONFIG_DIR/web-server" 2>/dev/null || true)"
  case "$old_web" in
    caddy) systemctl restart caddy 2>/dev/null || true ;;
    nginx) systemctl restart nginx 2>/dev/null || true ;;
  esac
  UPDATE_TRANSACTION_ACTIVE=0
  warn "Предыдущие файлы восстановлены. Проверь службы командой: diagnostics"
}

update_exit_handler() {
  local exit_code="$1"
  if (( exit_code != 0 )) && [[ "$UPDATE_TRANSACTION_ACTIVE" == "1" ]]; then
    rollback_update_transaction || true
  fi
  return "$exit_code"
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
  # До завершения preflight не создаём каталоги и не удаляем legacy-ссылки.
  begin_update_transaction
  prepare_layout
  install -d -m 0755 "$PROXY_CONFIG_DIR"
  printf '%s\n' "$EMAIL_ARG" > "$PROXY_CONFIG_DIR/acme-email"
  chmod 0600 "$PROXY_CONFIG_DIR/acme-email"
  install_deps
  check_telegram_connectivity
  check_dns
  fetch_repo
  resolve_base_path
  ensure_tproxy_user
  local previous_web_server=""
  previous_web_server="$(cat $PROXY_CONFIG_DIR/web-server 2>/dev/null || true)"
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
    if caddyfile_routes_to_tproxy; then
      ok "Существующий Caddyfile уже проксирует этот домен на relay — Caddyfile и systemd unit не изменяю."
    elif caddy_config_compatible; then
      ok "Совместимая конфигурация Caddy уже существует — запись пропущена."
    else
      install_caddyfile
    fi
  else
    if nginx_config_compatible; then ok "Совместимая конфигурация Nginx уже существует — запись и reload пропущены."
    else install_nginx_config; fi
  fi
  validate_configs
  start_services
  if [[ "$MODE" == "update" ]]; then
    restart_proxy_services
  fi
  wait_ready || die "relay не прошёл health-check"
  UPDATE_TRANSACTION_ACTIVE=0
  if [[ "$MODE" == "update" ]]; then
    ok "Обновление прошло health-check; rollback-копия сохранена: $UPDATE_ROLLBACK_ARCHIVE"
  fi
  print_summary
}

# ============================================================================
#  УДАЛЕНИЕ
# ============================================================================

run_uninstall() {
  require_root
  remove_legacy_compat_links
  local installed_web_server
  installed_web_server="$(cat $PROXY_CONFIG_DIR/web-server 2>/dev/null || true)"
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
  ui_header "Удаление tproxy-server"
  echo "Будет удалено:"
  echo "  - сервисы: tproxy-server, mtproxy, tproxy-firewall, refresh-mtproxy-config"
  echo "  - каталоги: $REPO_DIR, $PROXY_CONFIG_DIR, $MTPROXY_CONFIG_DIR, $MTPROXY_DIR; сайт $SITE_DIR сохраняется"
  echo "  - бинарники: $BIN_DIR/tproxy-server, $BIN_DIR/mtproxy-proxy"
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
  rm -f /etc/systemd/system/tproxy-server.service /etc/systemd/system/mtproxy.service /etc/systemd/system/tproxy-firewall.service /etc/systemd/system/refresh-mtproxy-config.service /etc/systemd/system/refresh-mtproxy-config.timer
  rm -f "$SYSTEMD_DIR"/tproxy-server.service "$SYSTEMD_DIR"/mtproxy.service "$SYSTEMD_DIR"/tproxy-firewall.service "$SYSTEMD_DIR"/refresh-mtproxy-config.service "$SYSTEMD_DIR"/refresh-mtproxy-config.timer
  rm -rf /etc/systemd/system/tproxy-server.service.d
  systemctl daemon-reload

  nft delete table inet tproxy_backend 2>/dev/null || true

  rm -rf "$REPO_DIR" "$MTPROXY_DIR" "$PROXY_CONFIG_DIR" "$MTPROXY_CONFIG_DIR" "$BIN_DIR/tproxy-server" "$BIN_DIR/mtproxy-proxy" "$BIN_DIR/refresh-mtproxy-config" "$QR_DIR"
  info "Каталог сайта $SITE_DIR сохранён."

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
  if command -v jq >/dev/null 2>&1 && [[ -r $PROXY_CONFIG_DIR/config.json ]]; then
    configured_site="$(jq -r '.public_dir // empty' "$PROXY_CONFIG_DIR/config.json" 2>/dev/null || true)"
  fi
  if [[ -n "$configured_site" && "$configured_site" == /* ]]; then SITE_DIR="$configured_site"; fi

  ui_header "Удаление decoy-сайта"
  if [[ ! -d "$SITE_DIR" ]]; then
    info "Каталог сайта не найден: $SITE_DIR"
    return 0
  fi

  warn "Будет полностью удалён каталог сайта и всё его содержимое: $SITE_DIR"
  confirm "Удалить сайт из $SITE_DIR без проверки его содержимого?" || {
    info "Удаление отменено."
    return 0
  }

  rm -rf -- "$SITE_DIR"
  ok "Каталог сайта удалён: $SITE_DIR"
}
remove_web_server_interactive() {
  require_root
  local installed_web_server
  installed_web_server="$(cat $PROXY_CONFIG_DIR/web-server 2>/dev/null || true)"
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
  if command -v jq >/dev/null 2>&1 && [[ -r $PROXY_CONFIG_DIR/config.json ]]; then
    configured_site="$(jq -r '.public_dir // empty' $PROXY_CONFIG_DIR/config.json 2>/dev/null || true)"
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
  web_server="$(cat "$PROXY_CONFIG_DIR/web-server" 2>/dev/null || true)"
  [[ "$web_server" == "nginx" || "$web_server" == "caddy" ]] || {
    if systemctl is-enabled --quiet nginx 2>/dev/null; then web_server=nginx; else web_server=caddy; fi
  }
  host="$(jq -r '.public_hostname // empty' "$PROXY_CONFIG_DIR/config.json" 2>/dev/null || true)"
  relay="$(jq -r '.listen // empty' "$PROXY_CONFIG_DIR/config.json" 2>/dev/null || true)"
  admin="$(jq -r '.admin_listen // empty' "$PROXY_CONFIG_DIR/config.json" 2>/dev/null || true)"
  backend="$(jq -r '.profiles[0].backend // empty' "$PROXY_CONFIG_DIR/profiles.json" 2>/dev/null || true)"
  backend_port="${backend##*:}"

  ui_header "Диагностика и поиск неисправностей"

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
  for file in "$PROXY_CONFIG_DIR/config.json" "$PROXY_CONFIG_DIR/profiles.json" "$MTPROXY_CONFIG_DIR/mtproxy.env"; do
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
    if nginx -t >/dev/null 2>&1; then printf '  %s Конфигурация Nginx корректна\n' "$(status_mark ok)"; else printf '  %s Ошибка конфигурации Nginx (подробности: nginx -t)\n' "$(status_mark fail)"; failed=1; fi
    cert_path="/etc/letsencrypt/live/$host/fullchain.pem"
  else
    if [[ -x /usr/local/bin/caddy && -s /etc/caddy/Caddyfile ]]; then
      if TPROXY_HOSTNAME="$host" TPROXY_SITE_ROOT="$(jq -r '.public_dir // empty' "$PROXY_CONFIG_DIR/config.json" 2>/dev/null)" ACME_EMAIL="$(cat "$PROXY_CONFIG_DIR/acme-email" 2>/dev/null || true)" /usr/local/bin/caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile >/dev/null 2>&1; then
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
    mapfile -t dns_ips < <(dig +short A "$host" 2>/dev/null | grep -E '^([0-9]{1,3}\.){3}[0-9]{1,3}$' | sort -u)
    if (("${#dns_ips[@]}")); then
      if dns_public_ip="$(get_public_ipv4)"; then
        for dns_ip in "${dns_ips[@]}"; do [[ "$dns_ip" == "$dns_public_ip" ]] && dns_matched=1; done
        if (( dns_matched )); then
          printf '  %s DNS A: %s (совпадает с IPv4-адресом сервера)\n' "$(status_mark ok)" "${dns_ips[*]}"
        else
          printf '  %s DNS A: %s (публичный IP сервера: %s)\n' "$(status_mark warn)" "${dns_ips[*]}" "$dns_public_ip"
          if is_cloudflare_proxied_domain "$host"; then
            printf '  %s Cloudflare Proxy: включён — DNS возвращает адреса сети Cloudflare вместо IP origin-сервера.\n' "$(status_mark warn)"
          else
            printf '  %s DNS A: %s (не совпадает с IP сервера и не распознана как Cloudflare)\n' "$(status_mark fail)" "${dns_ips[*]}"
            printf '  %s Проверь A-запись и DNS Proxy\n' "$(status_mark fail)"
            failed=1
          fi
        fi
      else
        printf '  %s DNS A: %s (не удалось определить публичный IP сервера)\n' "$(status_mark warn)" "${dns_ips[*]}"
        warnings=1
      fi
    else printf '  %s DNS A-запись не найдена через системный DNS-резолвер\n' "$(status_mark fail)"; failed=1; fi
    local aaaa
    local -a server_ipv6=()
    local ipv6_matched=0 dns_ipv6 server_ipv6_addr
    aaaa="$(dig +short AAAA "$host" 2>/dev/null | grep ':' | sort -u | tr '\n' ' ' || true)"
    if [[ -n "$aaaa" ]]; then
      mapfile -t server_ipv6 < <(ip -6 -o addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | sort -u)
      for dns_ipv6 in $aaaa; do
        for server_ipv6_addr in "${server_ipv6[@]}"; do
          [[ "$dns_ipv6" == "$server_ipv6_addr" ]] && ipv6_matched=1
        done
      done
      if (( ipv6_matched )); then
        printf '  %s DNS AAAA: %s (совпадает с IPv6-адресом сервера)\n' "$(status_mark ok)" "$aaaa"
      else
        printf '  %s DNS AAAA: %s (не совпадает с IPv6-адресами сервера; если используется Cloudflare DNS Proxy, это ожидаемо — проверь статус Proxy для AAAA-записи)\n' "$(status_mark warn)" "$aaaa"
        warnings=1
      fi
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
      ' | redact_sensitive_log
    )
  else
    printf '  %s Ошибок уровня error в доступном журнале не найдено\n' "$(status_mark ok)"
  fi

  ui_separator
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
  (($# == 0)) || die "Путь сохранения резервной копии задавать нельзя. Архивы сохраняются в $BACKUP_DIR"
  install -d -m 0700 "$BACKUP_DIR"
  local dest
  dest="$BACKUP_DIR/tproxy-backup-$(date +%Y%m%d-%H%M%S).tar.gz"
  [[ ! -e "$dest" ]] || die "Файл уже существует: $dest (не перезаписываю резервную копию)"

  local -a items=()
  local p
  for p in \
    opt/telegram-web-proxy/config opt/telegram-web-proxy/systemd opt/telegram-web-proxy/qr opt/telegram-web-proxy/data/website \
    opt/telegram-web-proxy/bin opt/telegram-web-proxy/src \
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

  local tmp="${dest}.tmp.$"
  trap 'rm -f "$tmp"' RETURN
  tar -C / -czpf "$tmp" "${items[@]}"
  tar -tzf "$tmp" >/dev/null || die "Проверка созданного архива не пройдена"
  chmod 0600 "$tmp"
  mv -- "$tmp" "$dest"
  trap - RETURN
  ok "Резервная копия создана: $dest (0600)"
  info "Все резервные копии хранятся в одном каталоге: $BACKUP_DIR"
  info "В архив включено объектов: ${#items[@]}; включая конфигурацию выбранного веб-сервера и TLS."
}

list_backup_archives() {
  [[ -d "$BACKUP_DIR" ]] || return 0
  find "$BACKUP_DIR" -maxdepth 1 -type f -name 'tproxy-backup-*.tar.gz' -printf '%f\0' | sort -zr
}

restore_command() {
  local selection="${1:-}" archive="" i size
  local -a archives=()
  mapfile -d '' -t archives < <(list_backup_archives)
  (("${#archives[@]}")) || die "Резервные копии не найдены в $BACKUP_DIR"

  if [[ -n "$selection" && "$selection" =~ ^[0-9]+$ ]]; then
    selection=$((10#$selection))
    (( selection >= 1 && selection <= ${#archives[@]} )) || die "Номер архива вне списка."
    archive="$BACKUP_DIR/${archives[selection-1]}"
  elif [[ -z "$selection" ]]; then
    echo
    ui_header "Доступные резервные копии"
    for i in "${!archives[@]}"; do
      printf '  %2d) %-42s  ' "$((i+1))" "${archives[i]}"
      size="$(du -h -- "$BACKUP_DIR/${archives[i]}")" || die "Не удалось определить размер архива: ${archives[i]}"
      printf '%s\n' "${size%%[[:space:]]*}"
    done
    echo
    read -r -p "Выбери номер архива (0 — отмена): " selection || die "Ввод прерван."
    [[ "$selection" != "0" ]] || { info "Восстановление отменено."; RESTORE_CANCELLED=1; return 0; }
    [[ "$selection" =~ ^[0-9]+$ ]] || die "Неверный номер архива."
    selection=$((10#$selection))
    (( selection >= 1 && selection <= ${#archives[@]} )) || die "Неверный номер архива."
    archive="$BACKUP_DIR/${archives[selection-1]}"
  else
    die "Укажи номер архива из списка, а не путь к файлу."
  fi

  [[ -f "$archive" ]] || die "Выбранный архив не найден: $archive"
  tar -tzf "$archive" >/dev/null 2>&1 || die "Архив повреждён или имеет неподдерживаемый формат"

  local entry normalized
  while IFS= read -r entry; do
    normalized="${entry#./}"
    [[ "$normalized" != /* ]] || die "Небезопасный абсолютный путь в архиве: $entry"
    [[ ! "/$normalized/" =~ /\.\./ ]] || die "Небезопасный путь в архиве: $entry"
    case "$normalized" in
      opt/telegram-web-proxy/config|opt/telegram-web-proxy/config/*|opt/telegram-web-proxy/systemd|opt/telegram-web-proxy/systemd/*|opt/telegram-web-proxy/qr|opt/telegram-web-proxy/qr/*|opt/telegram-web-proxy/data|opt/telegram-web-proxy/data/*|opt/telegram-web-proxy/bin|opt/telegram-web-proxy/bin/*|opt/telegram-web-proxy/src|opt/telegram-web-proxy/src/*|etc/caddy|etc/caddy/*|etc/nginx|etc/nginx/*|etc/letsencrypt|etc/letsencrypt/*|etc/systemd/system/tproxy-server.service|etc/systemd/system/mtproxy.service|etc/systemd/system/tproxy-firewall.service|etc/systemd/system/refresh-mtproxy-config.service|etc/systemd/system/refresh-mtproxy-config.timer|etc/systemd/system/caddy.service|etc/systemd/system/caddy.service.d/*) ;;
      *) die "В архиве обнаружен путь вне разрешённого списка: $entry" ;;
    esac
  done < <(tar -tzf "$archive")

  echo "Внимание: восстановление перезапишет файлы конфигурации и TLS-сертификаты."
  confirm "Восстановить конфигурации из $archive?" || die "восстановление отменено"
  tar -C / -xzpf "$archive" || die "Ошибка распаковки резервной копии"
  systemctl daemon-reload

  # Перезапускаем восстановленные компоненты, чтобы процессы перечитали файлы.
  local service web_server
  local -a restored_services=(
    mtproxy.service
    tproxy-server.service
    tproxy-firewall.service
    refresh-mtproxy-config.timer
  )
  web_server="$(cat "$CONFIG_DIR/web-server" 2>/dev/null || true)"
  case "$web_server" in
    caddy) restored_services+=(caddy.service) ;;
    nginx) restored_services+=(nginx.service) ;;
    *)
      if systemctl cat caddy.service >/dev/null 2>&1; then
        restored_services+=(caddy.service)
      elif systemctl cat nginx.service >/dev/null 2>&1; then
        restored_services+=(nginx.service)
      fi
      ;;
  esac

  for service in "${restored_services[@]}"; do
    if systemctl cat "$service" >/dev/null 2>&1; then
      printf '\t'
      info "Перезапускаю $service..."
      systemctl restart "$service" || die "Не удалось перезапустить $service после восстановления. Проверь: journalctl -u $service -n 50"
      printf '\t'
      ok "$service перезапущена"
    else
      printf '\t'
      info "$service не установлена — пропускаю"
    fi
  done

  printf '\t'
  ok "Конфигурации восстановлены, доступные службы перезапущены."
  printf '\t'
  info "Для проверки выполни: diagnostics"
}

ui_separator() {
  if [[ -z "${NO_COLOR:-}" && "${TERM:-}" != "dumb" ]]; then
    printf '\033[1;34m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\033[0m\n'
  else
    printf '%s\n' '━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━'
  fi
}
ui_header() {
  local title="$1"
  echo
  ui_separator
  if [[ -z "${NO_COLOR:-}" && "${TERM:-}" != "dumb" ]]; then
    printf '  \033[1;34m◆\033[0m %s\n' "$title"
  else
    printf '  %s\n' "$title"
  fi
  ui_separator
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
# Carrier mode, profile and public_upstream management.
# These operations are embedded in the main installer to keep deployment single-file.
CONFIG_FILE="$PROXY_CONFIG_DIR/config.json"
PROFILES_FILE="$PROXY_CONFIG_DIR/profiles.json"
MT_ENV="$MTPROXY_CONFIG_DIR/mtproxy.env"
UNIT_FILE="$SYSTEMD_DIR/mtproxy.service"
HOSTNAME_VALUE=""
PROFILE_DIR="$PROXY_CONFIG_DIR/profiles"
PROFILE_NAME=""
PROFILE_SECRET=""

need_root() { require_root; }
need_files() {
  [[ -r "$CONFIG_FILE" && -r "$MT_ENV" ]] || die "Не найдена установленная конфигурация."
  command -v jq >/dev/null 2>&1 || die "Требуется jq."
  ADMIN_PORT="$(jq -r '.admin_listen | split(":")[-1]' "$CONFIG_FILE")"
  HOSTNAME_VALUE="$(jq -r '.public_hostname // empty' "$CONFIG_FILE")"
  profile_storage_init
}

valid_secret() { [[ $1 =~ ^(dd)?[0-9a-f]{32}$ ]]; }
valid_name() { [[ $1 =~ ^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$ ]]; }
valid_mode() { [[ $1 == https || $1 == https-lanes || $1 == websocket || $1 == websocket-lanes ]]; }

write_mtproxy_secrets() {
  local secrets args tmp seen="" canonical secret count backend
  count="$(jq '.profiles | length' "$PROFILES_FILE")"
  (( count >= 1 && count <= 32 )) || die 'Количество профилей должно быть от 1 до 32.'
  backend="$(jq -r '.profiles[0].backend' "$PROFILES_FILE")"
  jq -e --arg b "$backend" 'all(.profiles[]; .backend == $b)' "$PROFILES_FILE" >/dev/null || die 'Все профили должны использовать один backend в этой версии.'
  secrets="$(jq -r '.profiles[].secret' "$PROFILES_FILE")"
  [[ -n $secrets ]] || die 'Список профилей пуст.'
  args=
  while IFS= read -r secret; do
    valid_secret "$secret" || die 'Обнаружен секрет с недопустимым форматом.'
    canonical="${secret#dd}"
    case "$seen" in *" $canonical "*) die 'Два профиля используют одинаковый backend secret (учитывая dd-префикс).' ;; esac
    seen+=" $canonical "
    if [[ -n $args ]]; then args+=' -S '; fi
    args+="$canonical"
  done <<< "$secrets"
  tmp="$(mktemp "${MT_ENV}.XXXXXX")"
  awk '!/^MTPROXY_SECRET=|^MTPROXY_SECRETS=/' "$MT_ENV" > "$tmp"
  printf 'MTPROXY_SECRETS="%s"\n' "$args" >> "$tmp"
  chown root:mtproxy "$tmp"
  chmod 0640 "$tmp"
  mv -f "$tmp" "$MT_ENV"
}

patch_mtproxy_unit() {
  local target="$UNIT_FILE"
  [[ -f $target ]] || die "Не найден unit-файл: $target"
  sed -i 's/-S ${MTPROXY_SECRET}/-S $MTPROXY_SECRETS/' "$target"
  grep -Fq -- '-S $MTPROXY_SECRETS' "$target" || die 'Не удалось обновить ExecStart MTProxy.'
  systemctl daemon-reload
}

PROFILE_DIR=$PROXY_CONFIG_DIR/profiles
PROFILE_NAME=""
PROFILE_SECRET=""

profile_manifest_sync() {
  local tmp dir file expected_name
  local -a profile_files=()
  [[ -d "$PROFILE_DIR" ]] || die "Не найден каталог профилей: $PROFILE_DIR"

  while IFS= read -r -d '' dir; do
    file="$dir/profile.json"
    expected_name="${dir##*/}"
    valid_name "$expected_name" || die "Недопустимое имя каталога профиля: $expected_name"
    [[ -s "$file" ]] || die "В каталоге профиля отсутствует profile.json: $dir"
    jq -e --arg n "$expected_name" '
      type == "object" and
      .name == $n and
      (.secret | type == "string" and test("^(dd)?[0-9a-f]{32}$")) and
      (.backend | type == "string" and test("^[^[:space:]]+:[0-9]+$")) and
      (.carrier_mode | (type == "string" and
        (. == "https" or . == "https-lanes" or . == "websocket" or . == "websocket-lanes")))
    ' "$file" >/dev/null || die "Некорректная структура файла профиля: $file"
  done < <(find "$PROFILE_DIR" -mindepth 1 -maxdepth 1 -type d -print0)

  if [[ -s "$PROFILE_DIR/default/profile.json" ]]; then
    profile_files+=("$PROFILE_DIR/default/profile.json")
  fi
  while IFS= read -r -d '' file; do
    [[ "$file" == "$PROFILE_DIR/default/profile.json" ]] || profile_files+=("$file")
  done < <(find "$PROFILE_DIR" -mindepth 2 -maxdepth 2 -type f -name profile.json -print0 | sort -z)

  (( ${#profile_files[@]} > 0 )) || die "В каталогах не найдено ни одного профиля."
  (( ${#profile_files[@]} <= 32 )) || die "В хранилище не может быть более 32 профилей."

  tmp="$(mktemp "$PROFILES_FILE.XXXXXX")"
  if ! jq -s '{profiles: .}' "${profile_files[@]}" > "$tmp" ||
     ! jq -e '
       type == "object" and
       (.profiles | type == "array" and length >= 1 and length <= 32) and
       ([.profiles[].name] | length == (unique | length))
     ' "$tmp" >/dev/null; then
    rm -f "$tmp"
    die "Не удалось собрать корректный общий список профилей."
  fi
  chown root:tproxy "$tmp"
  chmod 0400 "$tmp"
  mv -f "$tmp" "$PROFILES_FILE"
}

profile_storage_init() {
  install -d -o root -g tproxy -m 0750 "$PROFILE_DIR"
  local count name file
  count="$(find "$PROFILE_DIR" -mindepth 1 -maxdepth 1 -type d | wc -l)"

  if (( count == 0 )); then
    if profile_manifest_valid; then
      # One-time migration from the legacy aggregate into per-profile files.
      while IFS= read -r name; do
        [[ -n "$name" ]] || continue
        valid_name "$name" || die "Недопустимое имя профиля в старой конфигурации: $name"
        install -d -o root -g tproxy -m 0750 "$PROFILE_DIR/$name"
        jq --arg n "$name" '.profiles[] | select(.name == $n)' "$PROFILES_FILE" > "$PROFILE_DIR/$name/profile.json" ||
          die "Не удалось перенести профиль $name."
        chown root:tproxy "$PROFILE_DIR/$name/profile.json"
        chmod 0640 "$PROFILE_DIR/$name/profile.json"
      done < <(jq -r '.profiles[].name' "$PROFILES_FILE")
    else
      die "profiles.json повреждён, а индивидуальных файлов профилей нет. Автоматическое восстановление невозможно без исходных секретов."
    fi
  fi

  # Per-profile files are authoritative. Always rebuild the aggregate,
  # repairing a missing, malformed, or outdated profiles.json in-place.
  profile_manifest_sync
}
profile_choose() {
  local count choice i name
  count="$(jq '.profiles | length' "$PROFILES_FILE")"
  if (( count == 1 )); then PROFILE_NAME="$(jq -r '.profiles[0].name' "$PROFILES_FILE")"; return 0; fi
  ui_header "Выбор профиля"
  i=0
  while IFS= read -r name; do i=$((i+1)); ui_option "$i" "◆" "$name"; done < <(jq -r '.profiles[].name' "$PROFILES_FILE")
  ui_option 0 "←" "Назад"
  read -r -p "Выбери профиль [0-$count]: " choice
  [[ "$choice" =~ ^[0-9]+$ ]] && (( choice > 0 && choice <= count )) || return 1
  PROFILE_NAME="$(jq -r --argjson i "$choice" '.profiles[$i-1].name' "$PROFILES_FILE")"
}

profile_secret_prompt() {
  local format choice first second
  echo "Формат секрета: [1] обычный (32 hex) [2] с префиксом dd"
  read -r -p "Выбор [1-2]: " format
  case "$format" in 1) format='plain' ;; 2) format='dd' ;; *) echo "Недопустимый выбор."; return 1 ;; esac
  read -r -p "Сгенерировать секрет автоматически? [Y/n]: " choice
  if [[ ! "$choice" =~ ^[Nn]$ ]]; then
    PROFILE_SECRET="$(openssl rand -hex 16)"
    [[ "$format" == dd ]] && PROFILE_SECRET="dd$PROFILE_SECRET"
    echo "Секрет сгенерирован."
    return 0
  fi
  while :; do
    read -r -s -p "Введите секрет: " first; echo
    read -r -s -p "Повторите секрет: " second; echo
    [[ "$first" == "$second" ]] || { echo "Секреты не совпадают."; continue; }
    valid_secret "$first" || { echo "Нужны 32 hex-символа, опционально dd."; continue; }
    if [[ "$format" == dd && "$first" != dd* ]]; then echo "Нужен префикс dd."; continue; fi
    if [[ "$format" == plain && "$first" == dd* ]]; then echo "Убери префикс dd."; continue; fi
    PROFILE_SECRET="$first"; return 0
  done
}

profile_backup_menu() {
  local file dest stamp
  profile_choose || return 0
  file="$PROFILE_DIR/$PROFILE_NAME/profile.json"
  [[ -s "$file" ]] || die "Файл профиля не найден."
  install -d -o root -g root -m 0700 "$BACKUP_DIR/profile-backups"
  stamp="$(date +%Y%m%d-%H%M%S)"
  dest="$BACKUP_DIR/profile-backups/trpoxy-profile-backup-${PROFILE_NAME}-${stamp}.tar.gz"
  [[ ! -e "$dest" ]] || die "Архив уже существует: $dest"
  tar -C "$PROXY_CONFIG_DIR" -czpf "$dest" "profiles/$PROFILE_NAME/profile.json"
  tar -tzf "$dest" | grep -Fxq "profiles/$PROFILE_NAME/profile.json" || die "Проверка архива профиля не пройдена."
  chmod 0600 "$dest"
  ok "Профиль $PROFILE_NAME сохранён: $dest"
}

profile_archive_list() {
  local archive
  for archive in "$BACKUP_DIR"/profile-backups/trpoxy-profile-backup-*.tar.gz "$BACKUP_DIR"/profile-backups/profile-*.tar.gz; do
    [[ -f "$archive" ]] || continue
    # Full-system backups are never valid profile-import sources.
    tar -tzf "$archive" 2>/dev/null | grep -Eq '^profiles/[^/]+/profile\.json$' || continue
    printf '%s\n' "$archive"
  done | sort -r
}

profile_import_menu() {
  local selection archive entry profile_path extracted name secret backend mode target target_mode active_backend relay_port
  local count choice canonical existing_secret destination tmp rollback_dir backend_port profile_choice backup_dir backup_file
  local -a archives=() profile_paths=()
  mapfile -t archives < <(profile_archive_list)
  ((${#archives[@]})) || { warn "Архивы профилей и полные резервные копии не найдены."; return 0; }
  ui_header "Импорт профиля из резервной копии"
  for i in "${!archives[@]}"; do
    if [[ -z "${NO_COLOR:-}" && "${TERM:-}" != "dumb" ]]; then
      printf '  \033[1;34m%2d)\033[0m %s\n' "$((i+1))" "${archives[$i]##*/}"
    else
      printf '  %2d) %s\n' "$((i+1))" "${archives[$i]##*/}"
    fi
  done
  read -r -p "Выбери архив (0 — отмена): " selection || return 0
  [[ "$selection" =~ ^[0-9]+$ ]] || { warn "Неверный номер."; return 0; }
  (( selection > 0 && selection <= ${#archives[@]} )) || return 0
  archive="${archives[selection-1]}"
  tar -tzf "$archive" >/dev/null 2>&1 || { warn "Архив повреждён."; return 0; }
  while IFS= read -r entry; do
    entry="${entry#./}"
    case "$entry" in
      profiles/*/profile.json|opt/telegram-web-proxy/config/proxy/profiles/*/profile.json) profile_paths+=("$entry") ;;
    esac
  done < <(tar -tzf "$archive")
  ((${#profile_paths[@]})) || { warn "В архиве не найден файл профиля."; return 0; }
  if ((${#profile_paths[@]} > 1)); then
    echo "В архиве найдены профили:"
    for i in "${!profile_paths[@]}"; do
      if [[ -z "${NO_COLOR:-}" && "${TERM:-}" != "dumb" ]]; then
        printf '  \033[1;34m%2d)\033[0m %s\n' "$((i+1))" "${profile_paths[$i]}"
      else
        printf '  %2d) %s\n' "$((i+1))" "${profile_paths[$i]}"
      fi
    done
    read -r -p "Выбери профиль для импорта (0 — отмена): " profile_choice || return 0
    [[ "$profile_choice" =~ ^[0-9]+$ ]] && ((profile_choice > 0 && profile_choice <= ${#profile_paths[@]})) || return 0
    profile_path="${profile_paths[profile_choice-1]}"
  else
    profile_path="${profile_paths[0]}"
  fi
  extracted="$(mktemp)"
  if ! tar -xOzf "$archive" "$profile_path" > "$extracted" 2>/dev/null; then rm -f "$extracted"; warn "Не удалось прочитать профиль."; return 0; fi
  if ! jq -e 'type == "object" and (.name | type == "string" and test("^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$")) and (.secret | type == "string" and test("^(dd)?[0-9a-f]{32}$")) and (.backend | type == "string" and test("^127\\.0\\.0\\.1:[0-9]{1,5}$")) and (.carrier_mode | type == "string" and (. == "https" or . == "https-lanes" or . == "websocket" or . == "websocket-lanes"))' "$extracted" >/dev/null; then
    rm -f "$extracted"; warn "Профиль не прошёл проверку или содержит неподдерживаемый backend."; return 0
  fi
  name="$(jq -r ".name" "$extracted")"
  secret="$(jq -r ".secret" "$extracted")"
  backend="$(jq -r ".backend" "$extracted")"
  mode="$(jq -r ".carrier_mode" "$extracted")"
  active_backend="$(jq -r ".profiles[0].backend" "$PROFILES_FILE")"
  relay_port="$(jq -r ".listen | split(\":\")[-1]" "$CONFIG_FILE")"
  printf "\nПараметры профиля:\n  Имя: %s\n  Backend: %s\n  Carrier mode: %s\n  Секрет: скрыт\n" "$name" "$backend" "$mode"
  if [[ "$backend" != "$active_backend" ]]; then
    echo "В текущей версии все профили используют один общий backend: $active_backend"
    read -r -p "Переназначить импортируемый профиль на активный backend? [y/N]: " choice
    if [[ ! "$choice" =~ ^[YyДд]$ ]]; then rm -f "$extracted"; info "Импорт отменён."; return 0; fi
    backend="$active_backend"
  fi
  backend_port="${backend##*:}"
  if ! validate_port "$backend_port" >/dev/null 2>&1 || [[ "$backend_port" == "$relay_port" || "$backend_port" == "$ADMIN_PORT" ]]; then
    rm -f "$extracted"; warn "Backend порт конфликтует с relay/admin портом или недопустим."; return 0
  fi
  ui_header "Действие с импортируемым профилем"
  ui_option 1 "＋" "Создать новый профиль или заменить существующий"
  ui_option 2 "↻" "Заменить системный профиль default"
  ui_option 0 "←" "Отмена"
  echo
  read -r -p "Выбор [0-2]: " target_mode || { rm -f "$extracted"; return 0; }
  case "$target_mode" in
    1)
      read -r -p "Имя нового профиля [$name]: " target || { rm -f "$extracted"; return 0; }
      target="${target:-$name}"
      if ! valid_name "$target"; then rm -f "$extracted"; warn "Недопустимое имя профиля."; return 0; fi
      ;;
    2)
      target="default"
      [[ -s "$PROFILE_DIR/default/profile.json" ]] || { rm -f "$extracted"; warn "Профиль default не найден; заменить его невозможно."; return 0; }
      read -r -p "Заменить текущий профиль default импортируемым профилем? [y/N]: " choice
      if [[ ! "$choice" =~ ^[YyДд]$ ]]; then rm -f "$extracted"; info "Импорт отменён."; return 0; fi
      ;;
    0|"") rm -f "$extracted"; info "Импорт отменён."; return 0 ;;
    *) rm -f "$extracted"; warn "Неверный выбор."; return 0 ;;
  esac
  count="$(jq ".profiles | length" "$PROFILES_FILE")"
  destination="$PROFILE_DIR/$target/profile.json"
  if [[ -e "$PROFILE_DIR/$target" ]]; then
    if [[ "$target" != "default" || "$target_mode" != "2" ]]; then
      read -r -p "Профиль $target существует. Заменить его? [y/N]: " choice
      if [[ ! "$choice" =~ ^[YyДд]$ ]]; then rm -f "$extracted"; info "Импорт отменён."; return 0; fi
    fi
  elif (( count >= 32 )); then rm -f "$extracted"; warn "Достигнут лимит 32 профиля."; return 0; fi
  canonical="${secret#dd}"
  while IFS= read -r existing_secret; do
    [[ -n "$existing_secret" ]] || continue
    if [[ "${existing_secret#dd}" == "$canonical" ]]; then
      destination_secret="$(jq -r '.secret' "$destination" 2>/dev/null || true)"
      if [[ -f "$destination" && "${destination_secret#dd}" == "$canonical" ]]; then continue; fi
      rm -f "$extracted"; warn "Этот секрет уже используется другим профилем."; return 0
    fi
  done < <(jq -r ".profiles[].secret" "$PROFILES_FILE")
  tmp="$(mktemp)"
  jq --arg n "$target" --arg b "$backend" '.name=$n | .backend=$b' "$extracted" > "$tmp"
  rm -f "$extracted"
  chown root:tproxy "$tmp"; chmod 0640 "$tmp"
  rollback_dir="$(mktemp -d)"
  cp -a "$PROFILES_FILE" "$rollback_dir/profiles.json"
  if [[ "$target" == "default" ]]; then
    backup_dir="$BACKUP_DIR/profile-backups"
    install -d -o root -g root -m 0700 "$backup_dir"
    backup_file="$backup_dir/trpoxy-profile-backup-default-before-import-$(date +%Y%m%d-%H%M%S).tar.gz"
    tar -C "$PROXY_CONFIG_DIR" -czpf "$backup_file" "profiles/default/profile.json" || {
      rm -rf "$rollback_dir" "$tmp"; warn "Не удалось сохранить текущий default; импорт отменён."; return 0;
    }
    chmod 0600 "$backup_file"
    info "Текущий default сохранён: $backup_file"
  fi
  if [[ -f "$destination" ]]; then cp -a "$destination" "$rollback_dir/profile.json"; fi
  install -d -o root -g tproxy -m 0750 "$PROFILE_DIR/$target"
  mv -f "$tmp" "$destination"
  chown root:tproxy "$destination"; chmod 0640 "$destination"
  if ! profile_manifest_sync || ! "$BASE_DIR/bin/tproxy-server" -config "$CONFIG_FILE" -profiles-file "$PROFILES_FILE" -check; then
    if [[ -f "$rollback_dir/profile.json" ]]; then cp -a "$rollback_dir/profile.json" "$destination"; else rm -rf -- "${PROFILE_DIR:?}/${target:?}"; fi
    cp -a "$rollback_dir/profiles.json" "$PROFILES_FILE"; rm -rf "$rollback_dir"
    die "Импорт не прошёл проверку; исходная конфигурация восстановлена."
  fi
  if ! write_mtproxy_secrets || ! patch_mtproxy_unit || ! systemctl restart mtproxy tproxy-server; then
    if [[ -f "$rollback_dir/profile.json" ]]; then cp -a "$rollback_dir/profile.json" "$destination"; else rm -rf -- "${PROFILE_DIR:?}/${target:?}"; fi
    cp -a "$rollback_dir/profiles.json" "$PROFILES_FILE"; rm -rf "$rollback_dir"
    die "Не удалось применить профиль; исходная конфигурация восстановлена."
  fi
  rm -rf "$rollback_dir"
  ok "Профиль $target импортирован и проверен."
}

profile_menu() {
  local choice name mode mode_label backend count file tmp selected profile_row
  while :; do
    ui_header "Carrier mode и профили"
    printf "  Общий домен: %s\n" "$HOSTNAME_VALUE"
    while IFS= read -r profile_row; do
      name="$(cut -f1 <<< "$profile_row")"; mode="$(cut -f2 <<< "$profile_row")"; backend="$(cut -f3 <<< "$profile_row")"
      case "$mode" in https) mode_label="HTTPS" ;; https-lanes) mode_label="HTTPS · несколько каналов" ;; websocket) mode_label="WebSocket" ;; websocket-lanes) mode_label="WebSocket · несколько каналов" ;; *) mode_label="$mode" ;; esac
      printf "  ◆ %-20s | %-28s | backend %s\n" "$name" "$mode_label" "$backend"
    done < <(jq -r '.profiles[] | [.name, (.carrier_mode // "https"), .backend] | @tsv' "$PROFILES_FILE")
    echo
    ui_option 1 "+" "Добавить профиль"
    ui_option 2 "↻" "Изменить Carrier mode выбранного профиля"
    ui_option 3 "✖" "Удалить дополнительный профиль"
    ui_option 4 "▤" "Создать резервную копию профиля"
    ui_option 5 "⇧" "Импортировать профиль из резервной копии"
    ui_option 6 "←" "Назад"
    echo
    read -r -p "Выбор [1-6]: " choice
    case "$choice" in
      1)
        count="$(jq ".profiles | length" "$PROFILES_FILE")"; (( count < 32 )) || { warn "Достигнут лимит 32 профиля."; continue; }
        read -r -p "Имя профиля: " name
        valid_name "$name" && [[ ! -e "$PROFILE_DIR/$name" ]] || { warn "Имя недопустимо или уже занято."; continue; }
        profile_secret_prompt || continue
        if jq -e --arg s "$PROFILE_SECRET" '.profiles[] | select((.secret | ltrimstr("dd")) == ($s | ltrimstr("dd")))' "$PROFILES_FILE" >/dev/null; then warn "Секрет уже используется."; continue; fi
        echo "Carrier mode: [1] HTTPS [2] HTTPS с каналами [3] WebSocket [4] WebSocket с каналами"
        read -r -p "Выбор [1-4]: " choice
        case "$choice" in 1) mode=https ;; 2) mode=https-lanes ;; 3) mode=websocket ;; 4) mode=websocket-lanes ;; *) warn "Недопустимый режим."; continue ;; esac
        backend="$(jq -r ".profiles[0].backend" "$PROFILES_FILE")"
        install -d -o root -g tproxy -m 0750 "$PROFILE_DIR/$name"
        jq -n --arg n "$name" --arg s "$PROFILE_SECRET" --arg b "$backend" --arg m "$mode" '{name:$n,secret:$s,backend:$b,carrier_mode:$m}' > "$PROFILE_DIR/$name/profile.json"
        chown root:tproxy "$PROFILE_DIR/$name/profile.json"; chmod 0640 "$PROFILE_DIR/$name/profile.json"
        profile_manifest_sync; write_mtproxy_secrets; patch_mtproxy_unit
        systemctl restart mtproxy tproxy-server || die "Не удалось перезапустить службы после добавления профиля."
        ok "Профиль $name добавлен." ;;
      2)
        profile_choose || continue
        echo "Carrier mode: [1] HTTPS [2] HTTPS с каналами [3] WebSocket [4] WebSocket с каналами"
        read -r -p "Выбор [1-4]: " choice
        case "$choice" in 1) mode=https ;; 2) mode=https-lanes ;; 3) mode=websocket ;; 4) mode=websocket-lanes ;; *) warn "Недопустимый режим."; continue ;; esac
        file="$PROFILE_DIR/$PROFILE_NAME/profile.json"; tmp="$(mktemp "$file.XXXXXX")"
        jq --arg m "$mode" '.carrier_mode = $m' "$file" > "$tmp"
        chown root:tproxy "$tmp"; chmod 0640 "$tmp"; mv -f "$tmp" "$file"
        profile_manifest_sync
        "$BASE_DIR/bin/tproxy-server" -config "$CONFIG_FILE" -profiles-file "$PROFILES_FILE" -check || die "Carrier mode не прошёл проверку конфигурации."
        systemctl restart tproxy-server || die "Не удалось перезапустить tproxy-server."
        ok "Carrier mode профиля $PROFILE_NAME изменён." ;;
      3)
        count="$(jq ".profiles | length" "$PROFILES_FILE")"; (( count > 1 )) || { warn "Нельзя удалить последний профиль."; continue; }
        profile_choose || continue
        [[ "$PROFILE_NAME" != default ]] || { warn "Профиль default защищён."; continue; }
        read -r -p "Удалить профиль $PROFILE_NAME? [y/N]: " selected
        [[ "$selected" =~ ^[YyДд]$ ]] || continue
        rm -rf -- "${PROFILE_DIR:?}/${PROFILE_NAME:?}"
        profile_manifest_sync; write_mtproxy_secrets; patch_mtproxy_unit
        systemctl restart mtproxy tproxy-server || die "Не удалось перезапустить службы после удаления профиля."
        ok "Профиль $PROFILE_NAME удалён." ;;
      4) profile_backup_menu ;;
      5) profile_import_menu; continue ;;
      6) return 0 ;;
      *) warn "Неверный выбор." ;;
    esac
    read -r -p "Enter — продолжить..." _
  done
}
upstream_menu() {
  local current answer tmp backup port http_code selected=0 i
  local -a ports=() codes=()
  current="$(jq -r '.public_upstream // empty' "$CONFIG_FILE")"

  while :; do
    ui_header "Публичный сайт · public_upstream"
    if [[ -n $current ]]; then
      printf '  Текущий источник: %s\n\n' "$current"
      ui_option 1 "↩" "Отключить upstream и выбрать каталог сайта"
      ui_option 2 "↻" "Обновить список локальных приложений"
      ui_option 3 "←" "Назад"
      echo
      read -r -p "Выбор [1-3]: " answer
      case "$answer" in
        1)
          read -r -e -p "Каталог сайта [абсолютный путь]: " answer
          [[ $answer == /* && -d $answer ]] || { printf '[ОШИБКА] Каталог не найден или путь не абсолютный.\n'; read -r -p 'Enter — продолжить...' _; return 0; }
          tmp="$(mktemp "${CONFIG_FILE}.XXXXXX")"
          jq --arg d "$answer" 'del(.public_upstream) | .public_dir = $d' "$CONFIG_FILE" > "$tmp"
          break
          ;;
        2) current="";;
        3|"") return 0 ;;
        *) printf '  Выбери пункт от 1 до 3.\n'; sleep 1 ;;
      esac
      [[ -n $current ]] && continue
    fi

    ui_header "Выбор локального HTTP-приложения"
    printf '  Поиск работающих HTTP-сервисов на localhost...\n\n'
    ports=()
    codes=()
    while IFS= read -r port; do
      [[ $port =~ ^[0-9]+$ ]] || continue
      [[ $port != "$ADMIN_PORT" && $port != "8080" ]] || continue
      http_code="$(curl -sS --connect-timeout 0.4 --max-time 1 -o /dev/null -w '%{http_code}' "http://127.0.0.1:$port/" 2>/dev/null || true)"
      if [[ $http_code =~ ^[1-5][0-9]{2}$ ]]; then
        ports+=("$port")
        codes+=("$http_code")
      fi
    done < <(ss -H -lnt 2>/dev/null | awk '{print $4}' | sed 's/.*://' | grep -E '^[0-9]+$' | sort -nu)

    if (( ${#ports[@]} == 0 )); then
      printf '  [!] Не найдено доступных HTTP-приложений на 127.0.0.1.\n'
      printf '  Запусти приложение и повтори поиск.\n\n'
      ui_option 1 "↻" "Повторить поиск"
      ui_option 2 "←" "Назад"
      echo
      read -r -p "Выбор [1-2]: " answer
      case "$answer" in 1) continue ;; *) return 0 ;; esac
    fi

    printf '  Найденные приложения:\n'
    for ((i=0; i<${#ports[@]}; i++)); do
      ui_option "$((i+1))" "●" "http://127.0.0.1:${ports[$i]}  [HTTP ${codes[$i]}]"
    done
    printf '\n'
    ui_option "$((${#ports[@]}+1))" "↻" "Обновить список"
    ui_option "$((${#ports[@]}+2))" "←" "Назад"
    echo
    read -r -p "Выбери приложение [1-$((${#ports[@]}+2))]: " answer
    if [[ $answer == "$((${#ports[@]}+1))" ]]; then continue; fi
    if [[ $answer == "$((${#ports[@]}+2))" || -z $answer ]]; then return 0; fi
    if [[ $answer =~ ^[0-9]+$ ]] && (( answer >= 1 && answer <= ${#ports[@]} )); then
      selected=$((answer-1))
      port="${ports[$selected]}"
      tmp="$(mktemp "${CONFIG_FILE}.XXXXXX")"
      jq --arg u "http://127.0.0.1:$port" 'del(.public_dir) | .public_upstream = $u' "$CONFIG_FILE" > "$tmp"
      break
    fi
    printf '  [!] Неверный выбор.\n'
    sleep 1
  done

  chown root:tproxy "$tmp"
  chmod 0640 "$tmp"
  backup="${CONFIG_FILE}.before-upstream.$(date +%Y%m%d-%H%M%S)"
  cp -a "$CONFIG_FILE" "$backup"
  mv -f "$tmp" "$CONFIG_FILE"
  if ! "$BASE_DIR/bin/tproxy-server" -config "$CONFIG_FILE" -profiles-file "$PROFILES_FILE" -check; then
    cp -a "$backup" "$CONFIG_FILE"
    die 'Проверка конфигурации не пройдена; исходная конфигурация восстановлена.'
  fi
  systemctl restart tproxy-server
  printf '\n[OK] Публичный сайт настроен.\n'
  read -r -p 'Нажми Enter, чтобы вернуться в меню...' _
}
carrier_tools_menu() {
  need_root
  need_files
  local choice
  while :; do
    ui_header "Дополнительные возможности"
    ui_option 1 "▤" "Carrier mode и профили"
    ui_option 2 "⇄" "Публичный сайт (public_upstream)"
    ui_option 3 "←" "Назад"
    echo
    read -r -p "Выбор [1-3]: " choice
    case "$choice" in
      1) profile_menu ;;
      2) upstream_menu ;;
      3|"") return 0 ;;
      *) warn "Неверный выбор."; sleep 1 ;;
    esac
  done
}

restart_proxy_services() {
  require_root
  local unit failed=0 restarted=0 web_server
  local -a units=(tproxy-firewall.service mtproxy.service tproxy-server.service)

  web_server="$(cat "$PROXY_CONFIG_DIR/web-server" 2>/dev/null || true)"
  case "$web_server" in
    nginx) units+=(nginx.service) ;;
    caddy) units+=(caddy.service) ;;
    *)
      if systemctl cat nginx.service >/dev/null 2>&1; then units+=(nginx.service)
      elif systemctl cat caddy.service >/dev/null 2>&1; then units+=(caddy.service)
      fi
      ;;
  esac
  units+=(refresh-mtproxy-config.timer)

  echo
  ui_header "Перезапуск служб прокси"
  for unit in "${units[@]}"; do
    if ! systemctl cat "$unit" >/dev/null 2>&1; then
      printf '  [—] %-36s не установлена, пропуск\n' "$unit"
      continue
    fi
    if systemctl restart "$unit"; then
      printf '  [OK] %s перезапущена\n' "$unit"
      restarted=$((restarted + 1))
    else
      printf '  [ОШИБКА] Не удалось перезапустить %s\n' "$unit"
      failed=1
    fi
  done
  echo
  if (( failed )); then
    warn "Перезапуск завершён с ошибками. Проверь состояние служб: systemctl --failed"
    return 1
  elif (( restarted == 0 )); then
    warn "Не найдено установленных служб прокси для перезапуска."
    return 1
  else
    ok "Перезапущено служб/таймеров: $restarted"
    return 0
  fi
}

show_tools_menu() {
  local choice
  while true; do
    ui_header "Инструменты"
    ui_option 1 "⌕" "Диагностика и поиск неисправностей"
    ui_option 2 "▤" "Создать резервную копию"
    ui_option 3 "↻" "Восстановить резервную копию"
    ui_option 4 "◉" "Carrier mode, профили, public upstream"
    ui_option 5 "⟳" "Перезапустить все службы прокси"
    ui_option 6 "↩" "Назад"
    echo
    read -r -p "Выбор [1-6]: " choice
    case "$choice" in
      1) require_root; diagnostics_command || true; read -r -p "Enter — назад..." _ ;;
      2) require_root; backup_command; read -r -p "Enter — назад..." _ ;;
      3) require_root; RESTORE_CANCELLED=0; restore_command; (( RESTORE_CANCELLED == 1 )) || read -r -p "Enter — назад..." _ ;;
      4) carrier_tools_menu ;;
      5) restart_proxy_services || true; read -r -p "Enter — назад..." _ ;;
      6) return 0 ;;
      *) warn "Выбери пункт от 1 до 6." ;;
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
    2) MODE=update ;;
    3) MODE=delete ;;
    4) MODE=config ;;
    5) MODE=tools ;;
    6) exit 0 ;;
    *) warn "Неверный выбор." ;;
  esac
}

ui_separator() {
  if [[ -z "${NO_COLOR:-}" && "${TERM:-}" != "dumb" ]]; then
    printf '\033[1;34m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\033[0m\n'
  else
    printf '%s\n' '━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━'
  fi
}
ui_header() {
  local title="$1"
  echo
  ui_separator
  if [[ -z "${NO_COLOR:-}" && "${TERM:-}" != "dumb" ]]; then
    printf '  \033[1;34m◆\033[0m %s\n' "$title"
  else
    printf '  %s\n' "$title"
  fi
  ui_separator
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
# Carrier mode, profile and public_upstream management.
# These operations are embedded in the main installer to keep deployment single-file.
CONFIG_FILE="$PROXY_CONFIG_DIR/config.json"
PROFILES_FILE="$PROXY_CONFIG_DIR/profiles.json"
MT_ENV="$MTPROXY_CONFIG_DIR/mtproxy.env"
UNIT_FILE="$SYSTEMD_DIR/mtproxy.service"
HOSTNAME_VALUE=""
PROFILE_DIR="$PROXY_CONFIG_DIR/profiles"
PROFILE_NAME=""
PROFILE_SECRET=""

need_root() { require_root; }
need_files() {
  [[ -r "$CONFIG_FILE" && -r "$MT_ENV" ]] || die "Не найдена установленная конфигурация."
  command -v jq >/dev/null 2>&1 || die "Требуется jq."
  ADMIN_PORT="$(jq -r '.admin_listen | split(":")[-1]' "$CONFIG_FILE")"
  HOSTNAME_VALUE="$(jq -r '.public_hostname // empty' "$CONFIG_FILE")"
  profile_storage_init
}

valid_secret() { [[ $1 =~ ^(dd)?[0-9a-f]{32}$ ]]; }
valid_name() { [[ $1 =~ ^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$ ]]; }
valid_mode() { [[ $1 == https || $1 == https-lanes || $1 == websocket || $1 == websocket-lanes ]]; }

write_mtproxy_secrets() {
  local secrets args tmp seen="" canonical secret count backend
  count="$(jq '.profiles | length' "$PROFILES_FILE")"
  (( count >= 1 && count <= 32 )) || die 'Количество профилей должно быть от 1 до 32.'
  backend="$(jq -r '.profiles[0].backend' "$PROFILES_FILE")"
  jq -e --arg b "$backend" 'all(.profiles[]; .backend == $b)' "$PROFILES_FILE" >/dev/null || die 'Все профили должны использовать один backend в этой версии.'
  secrets="$(jq -r '.profiles[].secret' "$PROFILES_FILE")"
  [[ -n $secrets ]] || die 'Список профилей пуст.'
  args=
  while IFS= read -r secret; do
    valid_secret "$secret" || die 'Обнаружен секрет с недопустимым форматом.'
    canonical="${secret#dd}"
    case "$seen" in *" $canonical "*) die 'Два профиля используют одинаковый backend secret (учитывая dd-префикс).' ;; esac
    seen+=" $canonical "
    if [[ -n $args ]]; then args+=' -S '; fi
    args+="$canonical"
  done <<< "$secrets"
  tmp="$(mktemp "${MT_ENV}.XXXXXX")"
  awk '!/^MTPROXY_SECRET=|^MTPROXY_SECRETS=/' "$MT_ENV" > "$tmp"
  printf 'MTPROXY_SECRETS="%s"\n' "$args" >> "$tmp"
  chown root:mtproxy "$tmp"
  chmod 0640 "$tmp"
  mv -f "$tmp" "$MT_ENV"
}

patch_mtproxy_unit() {
  local target="$UNIT_FILE"
  [[ -f $target ]] || die "Не найден unit-файл: $target"
  sed -i 's/-S ${MTPROXY_SECRET}/-S $MTPROXY_SECRETS/' "$target"
  grep -Fq -- '-S $MTPROXY_SECRETS' "$target" || die 'Не удалось обновить ExecStart MTProxy.'
  systemctl daemon-reload
}

PROFILE_DIR=$PROXY_CONFIG_DIR/profiles
PROFILE_NAME=""
PROFILE_SECRET=""

profile_manifest_sync() {
  local tmp dir file expected_name
  local -a profile_files=()
  [[ -d "$PROFILE_DIR" ]] || die "Не найден каталог профилей: $PROFILE_DIR"

  while IFS= read -r -d '' dir; do
    file="$dir/profile.json"
    expected_name="${dir##*/}"
    valid_name "$expected_name" || die "Недопустимое имя каталога профиля: $expected_name"
    [[ -s "$file" ]] || die "В каталоге профиля отсутствует profile.json: $dir"
    jq -e --arg n "$expected_name" '
      type == "object" and
      .name == $n and
      (.secret | type == "string" and test("^(dd)?[0-9a-f]{32}$")) and
      (.backend | type == "string" and test("^[^[:space:]]+:[0-9]+$")) and
      (.carrier_mode | (type == "string" and
        (. == "https" or . == "https-lanes" or . == "websocket" or . == "websocket-lanes")))
    ' "$file" >/dev/null || die "Некорректная структура файла профиля: $file"
  done < <(find "$PROFILE_DIR" -mindepth 1 -maxdepth 1 -type d -print0)

  if [[ -s "$PROFILE_DIR/default/profile.json" ]]; then
    profile_files+=("$PROFILE_DIR/default/profile.json")
  fi
  while IFS= read -r -d '' file; do
    [[ "$file" == "$PROFILE_DIR/default/profile.json" ]] || profile_files+=("$file")
  done < <(find "$PROFILE_DIR" -mindepth 2 -maxdepth 2 -type f -name profile.json -print0 | sort -z)

  (( ${#profile_files[@]} > 0 )) || die "В каталогах не найдено ни одного профиля."
  (( ${#profile_files[@]} <= 32 )) || die "В хранилище не может быть более 32 профилей."

  tmp="$(mktemp "$PROFILES_FILE.XXXXXX")"
  if ! jq -s '{profiles: .}' "${profile_files[@]}" > "$tmp" ||
     ! jq -e '
       type == "object" and
       (.profiles | type == "array" and length >= 1 and length <= 32) and
       ([.profiles[].name] | length == (unique | length))
     ' "$tmp" >/dev/null; then
    rm -f "$tmp"
    die "Не удалось собрать корректный общий список профилей."
  fi
  chown root:tproxy "$tmp"
  chmod 0400 "$tmp"
  mv -f "$tmp" "$PROFILES_FILE"
}

profile_storage_init() {
  install -d -o root -g tproxy -m 0750 "$PROFILE_DIR"
  local count name file
  count="$(find "$PROFILE_DIR" -mindepth 1 -maxdepth 1 -type d | wc -l)"

  if (( count == 0 )); then
    if profile_manifest_valid; then
      # One-time migration from the legacy aggregate into per-profile files.
      while IFS= read -r name; do
        [[ -n "$name" ]] || continue
        valid_name "$name" || die "Недопустимое имя профиля в старой конфигурации: $name"
        install -d -o root -g tproxy -m 0750 "$PROFILE_DIR/$name"
        jq --arg n "$name" '.profiles[] | select(.name == $n)' "$PROFILES_FILE" > "$PROFILE_DIR/$name/profile.json" ||
          die "Не удалось перенести профиль $name."
        chown root:tproxy "$PROFILE_DIR/$name/profile.json"
        chmod 0640 "$PROFILE_DIR/$name/profile.json"
      done < <(jq -r '.profiles[].name' "$PROFILES_FILE")
    else
      die "profiles.json повреждён, а индивидуальных файлов профилей нет. Автоматическое восстановление невозможно без исходных секретов."
    fi
  fi

  # Per-profile files are authoritative. Always rebuild the aggregate,
  # repairing a missing, malformed, or outdated profiles.json in-place.
  profile_manifest_sync
}
profile_choose() {
  local count choice i name
  count="$(jq '.profiles | length' "$PROFILES_FILE")"
  if (( count == 1 )); then PROFILE_NAME="$(jq -r '.profiles[0].name' "$PROFILES_FILE")"; return 0; fi
  ui_header "Выбор профиля"
  i=0
  while IFS= read -r name; do i=$((i+1)); ui_option "$i" "◆" "$name"; done < <(jq -r '.profiles[].name' "$PROFILES_FILE")
  ui_option 0 "←" "Назад"
  read -r -p "Выбери профиль [0-$count]: " choice
  [[ "$choice" =~ ^[0-9]+$ ]] && (( choice > 0 && choice <= count )) || return 1
  PROFILE_NAME="$(jq -r --argjson i "$choice" '.profiles[$i-1].name' "$PROFILES_FILE")"
}

profile_secret_prompt() {
  local format choice first second
  echo "Формат секрета: [1] обычный (32 hex) [2] с префиксом dd"
  read -r -p "Выбор [1-2]: " format
  case "$format" in 1) format='plain' ;; 2) format='dd' ;; *) echo "Недопустимый выбор."; return 1 ;; esac
  read -r -p "Сгенерировать секрет автоматически? [Y/n]: " choice
  if [[ ! "$choice" =~ ^[Nn]$ ]]; then
    PROFILE_SECRET="$(openssl rand -hex 16)"
    [[ "$format" == dd ]] && PROFILE_SECRET="dd$PROFILE_SECRET"
    echo "Секрет сгенерирован."
    return 0
  fi
  while :; do
    read -r -s -p "Введите секрет: " first; echo
    read -r -s -p "Повторите секрет: " second; echo
    [[ "$first" == "$second" ]] || { echo "Секреты не совпадают."; continue; }
    valid_secret "$first" || { echo "Нужны 32 hex-символа, опционально dd."; continue; }
    if [[ "$format" == dd && "$first" != dd* ]]; then echo "Нужен префикс dd."; continue; fi
    if [[ "$format" == plain && "$first" == dd* ]]; then echo "Убери префикс dd."; continue; fi
    PROFILE_SECRET="$first"; return 0
  done
}

profile_backup_menu() {
  local file dest stamp
  profile_choose || return 0
  file="$PROFILE_DIR/$PROFILE_NAME/profile.json"
  [[ -s "$file" ]] || die "Файл профиля не найден."
  install -d -o root -g root -m 0700 "$BACKUP_DIR/profile-backups"
  stamp="$(date +%Y%m%d-%H%M%S)"
  dest="$BACKUP_DIR/profile-backups/trpoxy-profile-backup-${PROFILE_NAME}-${stamp}.tar.gz"
  [[ ! -e "$dest" ]] || die "Архив уже существует: $dest"
  tar -C "$PROXY_CONFIG_DIR" -czpf "$dest" "profiles/$PROFILE_NAME/profile.json"
  tar -tzf "$dest" | grep -Fxq "profiles/$PROFILE_NAME/profile.json" || die "Проверка архива профиля не пройдена."
  chmod 0600 "$dest"
  ok "Профиль $PROFILE_NAME сохранён: $dest"
}

profile_archive_list() {
  local archive
  for archive in "$BACKUP_DIR"/profile-backups/trpoxy-profile-backup-*.tar.gz "$BACKUP_DIR"/profile-backups/profile-*.tar.gz; do
    [[ -f "$archive" ]] || continue
    # Full-system backups are never valid profile-import sources.
    tar -tzf "$archive" 2>/dev/null | grep -Eq '^profiles/[^/]+/profile\.json$' || continue
    printf '%s\n' "$archive"
  done | sort -r
}

profile_import_menu() {
  local selection archive entry profile_path extracted name secret backend mode target target_mode active_backend relay_port
  local count choice canonical existing_secret destination tmp rollback_dir backend_port profile_choice backup_dir backup_file
  local -a archives=() profile_paths=()
  mapfile -t archives < <(profile_archive_list)
  ((${#archives[@]})) || { warn "Архивы профилей и полные резервные копии не найдены."; return 0; }
  ui_header "Импорт профиля из резервной копии"
  for i in "${!archives[@]}"; do
    if [[ -z "${NO_COLOR:-}" && "${TERM:-}" != "dumb" ]]; then
      printf '  \033[1;34m%2d)\033[0m %s\n' "$((i+1))" "${archives[$i]##*/}"
    else
      printf '  %2d) %s\n' "$((i+1))" "${archives[$i]##*/}"
    fi
  done
  read -r -p "Выбери архив (0 — отмена): " selection || return 0
  [[ "$selection" =~ ^[0-9]+$ ]] || { warn "Неверный номер."; return 0; }
  (( selection > 0 && selection <= ${#archives[@]} )) || return 0
  archive="${archives[selection-1]}"
  tar -tzf "$archive" >/dev/null 2>&1 || { warn "Архив повреждён."; return 0; }
  while IFS= read -r entry; do
    entry="${entry#./}"
    case "$entry" in
      profiles/*/profile.json|opt/telegram-web-proxy/config/proxy/profiles/*/profile.json) profile_paths+=("$entry") ;;
    esac
  done < <(tar -tzf "$archive")
  ((${#profile_paths[@]})) || { warn "В архиве не найден файл профиля."; return 0; }
  if ((${#profile_paths[@]} > 1)); then
    echo "В архиве найдены профили:"
    for i in "${!profile_paths[@]}"; do
      if [[ -z "${NO_COLOR:-}" && "${TERM:-}" != "dumb" ]]; then
        printf '  \033[1;34m%2d)\033[0m %s\n' "$((i+1))" "${profile_paths[$i]}"
      else
        printf '  %2d) %s\n' "$((i+1))" "${profile_paths[$i]}"
      fi
    done
    read -r -p "Выбери профиль для импорта (0 — отмена): " profile_choice || return 0
    [[ "$profile_choice" =~ ^[0-9]+$ ]] && ((profile_choice > 0 && profile_choice <= ${#profile_paths[@]})) || return 0
    profile_path="${profile_paths[profile_choice-1]}"
  else
    profile_path="${profile_paths[0]}"
  fi
  extracted="$(mktemp)"
  if ! tar -xOzf "$archive" "$profile_path" > "$extracted" 2>/dev/null; then rm -f "$extracted"; warn "Не удалось прочитать профиль."; return 0; fi
  if ! jq -e 'type == "object" and (.name | type == "string" and test("^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$")) and (.secret | type == "string" and test("^(dd)?[0-9a-f]{32}$")) and (.backend | type == "string" and test("^127\\.0\\.0\\.1:[0-9]{1,5}$")) and (.carrier_mode | type == "string" and (. == "https" or . == "https-lanes" or . == "websocket" or . == "websocket-lanes"))' "$extracted" >/dev/null; then
    rm -f "$extracted"; warn "Профиль не прошёл проверку или содержит неподдерживаемый backend."; return 0
  fi
  name="$(jq -r ".name" "$extracted")"
  secret="$(jq -r ".secret" "$extracted")"
  backend="$(jq -r ".backend" "$extracted")"
  mode="$(jq -r ".carrier_mode" "$extracted")"
  active_backend="$(jq -r ".profiles[0].backend" "$PROFILES_FILE")"
  relay_port="$(jq -r ".listen | split(\":\")[-1]" "$CONFIG_FILE")"
  printf "\nПараметры профиля:\n  Имя: %s\n  Backend: %s\n  Carrier mode: %s\n  Секрет: скрыт\n" "$name" "$backend" "$mode"
  if [[ "$backend" != "$active_backend" ]]; then
    echo "В текущей версии все профили используют один общий backend: $active_backend"
    read -r -p "Переназначить импортируемый профиль на активный backend? [y/N]: " choice
    if [[ ! "$choice" =~ ^[YyДд]$ ]]; then rm -f "$extracted"; info "Импорт отменён."; return 0; fi
    backend="$active_backend"
  fi
  backend_port="${backend##*:}"
  if ! validate_port "$backend_port" >/dev/null 2>&1 || [[ "$backend_port" == "$relay_port" || "$backend_port" == "$ADMIN_PORT" ]]; then
    rm -f "$extracted"; warn "Backend порт конфликтует с relay/admin портом или недопустим."; return 0
  fi
  ui_header "Действие с импортируемым профилем"
  ui_option 1 "＋" "Создать новый профиль или заменить существующий"
  ui_option 2 "↻" "Заменить системный профиль default"
  ui_option 0 "←" "Отмена"
  echo
  read -r -p "Выбор [0-2]: " target_mode || { rm -f "$extracted"; return 0; }
  case "$target_mode" in
    1)
      read -r -p "Имя нового профиля [$name]: " target || { rm -f "$extracted"; return 0; }
      target="${target:-$name}"
      if ! valid_name "$target"; then rm -f "$extracted"; warn "Недопустимое имя профиля."; return 0; fi
      ;;
    2)
      target="default"
      [[ -s "$PROFILE_DIR/default/profile.json" ]] || { rm -f "$extracted"; warn "Профиль default не найден; заменить его невозможно."; return 0; }
      read -r -p "Заменить текущий профиль default импортируемым профилем? [y/N]: " choice
      if [[ ! "$choice" =~ ^[YyДд]$ ]]; then rm -f "$extracted"; info "Импорт отменён."; return 0; fi
      ;;
    0|"") rm -f "$extracted"; info "Импорт отменён."; return 0 ;;
    *) rm -f "$extracted"; warn "Неверный выбор."; return 0 ;;
  esac
  count="$(jq ".profiles | length" "$PROFILES_FILE")"
  destination="$PROFILE_DIR/$target/profile.json"
  if [[ -e "$PROFILE_DIR/$target" ]]; then
    if [[ "$target" != "default" || "$target_mode" != "2" ]]; then
      read -r -p "Профиль $target существует. Заменить его? [y/N]: " choice
      if [[ ! "$choice" =~ ^[YyДд]$ ]]; then rm -f "$extracted"; info "Импорт отменён."; return 0; fi
    fi
  elif (( count >= 32 )); then rm -f "$extracted"; warn "Достигнут лимит 32 профиля."; return 0; fi
  canonical="${secret#dd}"
  while IFS= read -r existing_secret; do
    [[ -n "$existing_secret" ]] || continue
    if [[ "${existing_secret#dd}" == "$canonical" ]]; then
      destination_secret="$(jq -r '.secret' "$destination" 2>/dev/null || true)"
      if [[ -f "$destination" && "${destination_secret#dd}" == "$canonical" ]]; then continue; fi
      rm -f "$extracted"; warn "Этот секрет уже используется другим профилем."; return 0
    fi
  done < <(jq -r ".profiles[].secret" "$PROFILES_FILE")
  tmp="$(mktemp)"
  jq --arg n "$target" --arg b "$backend" '.name=$n | .backend=$b' "$extracted" > "$tmp"
  rm -f "$extracted"
  chown root:tproxy "$tmp"; chmod 0640 "$tmp"
  rollback_dir="$(mktemp -d)"
  cp -a "$PROFILES_FILE" "$rollback_dir/profiles.json"
  if [[ "$target" == "default" ]]; then
    backup_dir="$BACKUP_DIR/profile-backups"
    install -d -o root -g root -m 0700 "$backup_dir"
    backup_file="$backup_dir/trpoxy-profile-backup-default-before-import-$(date +%Y%m%d-%H%M%S).tar.gz"
    tar -C "$PROXY_CONFIG_DIR" -czpf "$backup_file" "profiles/default/profile.json" || {
      rm -rf "$rollback_dir" "$tmp"; warn "Не удалось сохранить текущий default; импорт отменён."; return 0;
    }
    chmod 0600 "$backup_file"
    info "Текущий default сохранён: $backup_file"
  fi
  if [[ -f "$destination" ]]; then cp -a "$destination" "$rollback_dir/profile.json"; fi
  install -d -o root -g tproxy -m 0750 "$PROFILE_DIR/$target"
  mv -f "$tmp" "$destination"
  chown root:tproxy "$destination"; chmod 0640 "$destination"
  if ! profile_manifest_sync || ! "$BASE_DIR/bin/tproxy-server" -config "$CONFIG_FILE" -profiles-file "$PROFILES_FILE" -check; then
    if [[ -f "$rollback_dir/profile.json" ]]; then cp -a "$rollback_dir/profile.json" "$destination"; else rm -rf -- "${PROFILE_DIR:?}/${target:?}"; fi
    cp -a "$rollback_dir/profiles.json" "$PROFILES_FILE"; rm -rf "$rollback_dir"
    die "Импорт не прошёл проверку; исходная конфигурация восстановлена."
  fi
  if ! write_mtproxy_secrets || ! patch_mtproxy_unit || ! systemctl restart mtproxy tproxy-server; then
    if [[ -f "$rollback_dir/profile.json" ]]; then cp -a "$rollback_dir/profile.json" "$destination"; else rm -rf -- "${PROFILE_DIR:?}/${target:?}"; fi
    cp -a "$rollback_dir/profiles.json" "$PROFILES_FILE"; rm -rf "$rollback_dir"
    die "Не удалось применить профиль; исходная конфигурация восстановлена."
  fi
  rm -rf "$rollback_dir"
  ok "Профиль $target импортирован и проверен."
}

profile_menu() {
  local choice name mode mode_label backend count file tmp selected profile_row
  while :; do
    ui_header "Carrier mode и профили"
    printf "  Общий домен: %s\n" "$HOSTNAME_VALUE"
    while IFS= read -r profile_row; do
      name="$(cut -f1 <<< "$profile_row")"; mode="$(cut -f2 <<< "$profile_row")"; backend="$(cut -f3 <<< "$profile_row")"
      case "$mode" in https) mode_label="HTTPS" ;; https-lanes) mode_label="HTTPS · несколько каналов" ;; websocket) mode_label="WebSocket" ;; websocket-lanes) mode_label="WebSocket · несколько каналов" ;; *) mode_label="$mode" ;; esac
      printf "  ◆ %-20s | %-28s | backend %s\n" "$name" "$mode_label" "$backend"
    done < <(jq -r '.profiles[] | [.name, (.carrier_mode // "https"), .backend] | @tsv' "$PROFILES_FILE")
    echo
    ui_option 1 "+" "Добавить профиль"
    ui_option 2 "↻" "Изменить Carrier mode выбранного профиля"
    ui_option 3 "✖" "Удалить дополнительный профиль"
    ui_option 4 "▤" "Создать резервную копию профиля"
    ui_option 5 "⇧" "Импортировать профиль из резервной копии"
    ui_option 6 "←" "Назад"
    echo
    read -r -p "Выбор [1-6]: " choice
    case "$choice" in
      1)
        count="$(jq ".profiles | length" "$PROFILES_FILE")"; (( count < 32 )) || { warn "Достигнут лимит 32 профиля."; continue; }
        read -r -p "Имя профиля: " name
        valid_name "$name" && [[ ! -e "$PROFILE_DIR/$name" ]] || { warn "Имя недопустимо или уже занято."; continue; }
        profile_secret_prompt || continue
        if jq -e --arg s "$PROFILE_SECRET" '.profiles[] | select((.secret | ltrimstr("dd")) == ($s | ltrimstr("dd")))' "$PROFILES_FILE" >/dev/null; then warn "Секрет уже используется."; continue; fi
        echo "Carrier mode: [1] HTTPS [2] HTTPS с каналами [3] WebSocket [4] WebSocket с каналами"
        read -r -p "Выбор [1-4]: " choice
        case "$choice" in 1) mode=https ;; 2) mode=https-lanes ;; 3) mode=websocket ;; 4) mode=websocket-lanes ;; *) warn "Недопустимый режим."; continue ;; esac
        backend="$(jq -r ".profiles[0].backend" "$PROFILES_FILE")"
        install -d -o root -g tproxy -m 0750 "$PROFILE_DIR/$name"
        jq -n --arg n "$name" --arg s "$PROFILE_SECRET" --arg b "$backend" --arg m "$mode" '{name:$n,secret:$s,backend:$b,carrier_mode:$m}' > "$PROFILE_DIR/$name/profile.json"
        chown root:tproxy "$PROFILE_DIR/$name/profile.json"; chmod 0640 "$PROFILE_DIR/$name/profile.json"
        profile_manifest_sync; write_mtproxy_secrets; patch_mtproxy_unit
        systemctl restart mtproxy tproxy-server || die "Не удалось перезапустить службы после добавления профиля."
        ok "Профиль $name добавлен." ;;
      2)
        profile_choose || continue
        echo "Carrier mode: [1] HTTPS [2] HTTPS с каналами [3] WebSocket [4] WebSocket с каналами"
        read -r -p "Выбор [1-4]: " choice
        case "$choice" in 1) mode=https ;; 2) mode=https-lanes ;; 3) mode=websocket ;; 4) mode=websocket-lanes ;; *) warn "Недопустимый режим."; continue ;; esac
        file="$PROFILE_DIR/$PROFILE_NAME/profile.json"; tmp="$(mktemp "$file.XXXXXX")"
        jq --arg m "$mode" '.carrier_mode = $m' "$file" > "$tmp"
        chown root:tproxy "$tmp"; chmod 0640 "$tmp"; mv -f "$tmp" "$file"
        profile_manifest_sync
        "$BASE_DIR/bin/tproxy-server" -config "$CONFIG_FILE" -profiles-file "$PROFILES_FILE" -check || die "Carrier mode не прошёл проверку конфигурации."
        systemctl restart tproxy-server || die "Не удалось перезапустить tproxy-server."
        ok "Carrier mode профиля $PROFILE_NAME изменён." ;;
      3)
        count="$(jq ".profiles | length" "$PROFILES_FILE")"; (( count > 1 )) || { warn "Нельзя удалить последний профиль."; continue; }
        profile_choose || continue
        [[ "$PROFILE_NAME" != default ]] || { warn "Профиль default защищён."; continue; }
        read -r -p "Удалить профиль $PROFILE_NAME? [y/N]: " selected
        [[ "$selected" =~ ^[YyДд]$ ]] || continue
        rm -rf -- "${PROFILE_DIR:?}/${PROFILE_NAME:?}"
        profile_manifest_sync; write_mtproxy_secrets; patch_mtproxy_unit
        systemctl restart mtproxy tproxy-server || die "Не удалось перезапустить службы после удаления профиля."
        ok "Профиль $PROFILE_NAME удалён." ;;
      4) profile_backup_menu ;;
      5) profile_import_menu; continue ;;
      6) return 0 ;;
      *) warn "Неверный выбор." ;;
    esac
    read -r -p "Enter — продолжить..." _
  done
}
upstream_menu() {
  local current answer tmp backup port http_code selected=0 i
  local -a ports=() codes=()
  current="$(jq -r '.public_upstream // empty' "$CONFIG_FILE")"

  while :; do
    ui_header "Публичный сайт · public_upstream"
    if [[ -n $current ]]; then
      printf '  Текущий источник: %s\n\n' "$current"
      ui_option 1 "↩" "Отключить upstream и выбрать каталог сайта"
      ui_option 2 "↻" "Обновить список локальных приложений"
      ui_option 3 "←" "Назад"
      echo
      read -r -p "Выбор [1-3]: " answer
      case "$answer" in
        1)
          read -r -e -p "Каталог сайта [абсолютный путь]: " answer
          [[ $answer == /* && -d $answer ]] || { printf '[ОШИБКА] Каталог не найден или путь не абсолютный.\n'; read -r -p 'Enter — продолжить...' _; return 0; }
          tmp="$(mktemp "${CONFIG_FILE}.XXXXXX")"
          jq --arg d "$answer" 'del(.public_upstream) | .public_dir = $d' "$CONFIG_FILE" > "$tmp"
          break
          ;;
        2) current="";;
        3|"") return 0 ;;
        *) printf '  Выбери пункт от 1 до 3.\n'; sleep 1 ;;
      esac
      [[ -n $current ]] && continue
    fi

    ui_header "Выбор локального HTTP-приложения"
    printf '  Поиск работающих HTTP-сервисов на localhost...\n\n'
    ports=()
    codes=()
    while IFS= read -r port; do
      [[ $port =~ ^[0-9]+$ ]] || continue
      [[ $port != "$ADMIN_PORT" && $port != "8080" ]] || continue
      http_code="$(curl -sS --connect-timeout 0.4 --max-time 1 -o /dev/null -w '%{http_code}' "http://127.0.0.1:$port/" 2>/dev/null || true)"
      if [[ $http_code =~ ^[1-5][0-9]{2}$ ]]; then
        ports+=("$port")
        codes+=("$http_code")
      fi
    done < <(ss -H -lnt 2>/dev/null | awk '{print $4}' | sed 's/.*://' | grep -E '^[0-9]+$' | sort -nu)

    if (( ${#ports[@]} == 0 )); then
      printf '  [!] Не найдено доступных HTTP-приложений на 127.0.0.1.\n'
      printf '  Запусти приложение и повтори поиск.\n\n'
      ui_option 1 "↻" "Повторить поиск"
      ui_option 2 "←" "Назад"
      echo
      read -r -p "Выбор [1-2]: " answer
      case "$answer" in 1) continue ;; *) return 0 ;; esac
    fi

    printf '  Найденные приложения:\n'
    for ((i=0; i<${#ports[@]}; i++)); do
      ui_option "$((i+1))" "●" "http://127.0.0.1:${ports[$i]}  [HTTP ${codes[$i]}]"
    done
    printf '\n'
    ui_option "$((${#ports[@]}+1))" "↻" "Обновить список"
    ui_option "$((${#ports[@]}+2))" "←" "Назад"
    echo
    read -r -p "Выбери приложение [1-$((${#ports[@]}+2))]: " answer
    if [[ $answer == "$((${#ports[@]}+1))" ]]; then continue; fi
    if [[ $answer == "$((${#ports[@]}+2))" || -z $answer ]]; then return 0; fi
    if [[ $answer =~ ^[0-9]+$ ]] && (( answer >= 1 && answer <= ${#ports[@]} )); then
      selected=$((answer-1))
      port="${ports[$selected]}"
      tmp="$(mktemp "${CONFIG_FILE}.XXXXXX")"
      jq --arg u "http://127.0.0.1:$port" 'del(.public_dir) | .public_upstream = $u' "$CONFIG_FILE" > "$tmp"
      break
    fi
    printf '  [!] Неверный выбор.\n'
    sleep 1
  done

  chown root:tproxy "$tmp"
  chmod 0640 "$tmp"
  backup="${CONFIG_FILE}.before-upstream.$(date +%Y%m%d-%H%M%S)"
  cp -a "$CONFIG_FILE" "$backup"
  mv -f "$tmp" "$CONFIG_FILE"
  if ! "$BASE_DIR/bin/tproxy-server" -config "$CONFIG_FILE" -profiles-file "$PROFILES_FILE" -check; then
    cp -a "$backup" "$CONFIG_FILE"
    die 'Проверка конфигурации не пройдена; исходная конфигурация восстановлена.'
  fi
  systemctl restart tproxy-server
  printf '\n[OK] Публичный сайт настроен.\n'
  read -r -p 'Нажми Enter, чтобы вернуться в меню...' _
}
carrier_tools_menu() {
  need_root
  need_files
  local choice
  while :; do
    ui_header "Дополнительные возможности"
    ui_option 1 "▤" "Carrier mode и профили"
    ui_option 2 "⇄" "Публичный сайт (public_upstream)"
    ui_option 3 "←" "Назад"
    echo
    read -r -p "Выбор [1-3]: " choice
    case "$choice" in
      1) profile_menu ;;
      2) upstream_menu ;;
      3|"") return 0 ;;
      *) warn "Неверный выбор."; sleep 1 ;;
    esac
  done
}

restart_proxy_services() {
  require_root
  local unit failed=0 restarted=0 web_server
  local -a units=(tproxy-firewall.service mtproxy.service tproxy-server.service)

  web_server="$(cat "$PROXY_CONFIG_DIR/web-server" 2>/dev/null || true)"
  case "$web_server" in
    nginx) units+=(nginx.service) ;;
    caddy) units+=(caddy.service) ;;
    *)
      if systemctl cat nginx.service >/dev/null 2>&1; then units+=(nginx.service)
      elif systemctl cat caddy.service >/dev/null 2>&1; then units+=(caddy.service)
      fi
      ;;
  esac
  units+=(refresh-mtproxy-config.timer)

  echo
  ui_header "Перезапуск служб прокси"
  for unit in "${units[@]}"; do
    if ! systemctl cat "$unit" >/dev/null 2>&1; then
      printf '  [—] %-36s не установлена, пропуск\n' "$unit"
      continue
    fi
    if systemctl restart "$unit"; then
      printf '  [OK] %s перезапущена\n' "$unit"
      restarted=$((restarted + 1))
    else
      printf '  [ОШИБКА] Не удалось перезапустить %s\n' "$unit"
      failed=1
    fi
  done
  echo
  if (( failed )); then
    warn "Перезапуск завершён с ошибками. Проверь состояние служб: systemctl --failed"
    return 1
  elif (( restarted == 0 )); then
    warn "Не найдено установленных служб прокси для перезапуска."
    return 1
  else
    ok "Перезапущено служб/таймеров: $restarted"
    return 0
  fi
}

show_tools_menu() {
  local choice
  while true; do
    ui_header "Инструменты"
    ui_option 1 "⌕" "Диагностика и поиск неисправностей"
    ui_option 2 "▤" "Создать резервную копию"
    ui_option 3 "↻" "Восстановить резервную копию"
    ui_option 4 "◉" "Carrier mode, профили, public upstream"
    ui_option 5 "⟳" "Перезапустить все службы прокси"
    ui_option 6 "↩" "Назад"
    echo
    read -r -p "Выбор [1-6]: " choice
    case "$choice" in
      1) require_root; diagnostics_command || true; read -r -p "Enter — назад..." _ ;;
      2) require_root; backup_command; read -r -p "Enter — назад..." _ ;;
      3) require_root; restore_command; read -r -p "Enter — назад..." _ ;;
      4) carrier_tools_menu ;;
      5) restart_proxy_services || true; read -r -p "Enter — назад..." _ ;;
      6) return 0 ;;
      *) warn "Выбери пункт от 1 до 6." ;;
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
    2) MODE=update ;;
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
    update)    parse_install_args "$@"; run_install ;;
    uninstall) parse_uninstall_args "$@"; run_uninstall ;;
    purge)     parse_uninstall_args "$@"; run_purge ;;
    config)    require_root; run_config "$@" ;;
    diagnostics) require_root; diagnostics_command ;;
    backup)    require_root; backup_command "$@" ;;
    restore)   require_root; restore_command "$@" ;;
    profile)   profile_cli "$@" ;;
    upstream)  upstream_cli "$@" ;;
    services)  require_root; [[ "${1:-}" == restart && $# -eq 1 ]] || die "Использование: services restart"; restart_proxy_services ;;
    site)      [[ "${1:-}" == remove ]] || die "Использование: site remove [--yes]"; shift; ASSUME_YES=0; parse_uninstall_args "$@"; remove_decoy_site ;;
    web-server) [[ "${1:-}" == remove ]] || die "Использование: web-server remove [--yes]"; shift; ASSUME_YES=0; parse_uninstall_args "$@"; remove_web_server_interactive ;;
    -h|--help|help) usage; exit 0 ;;
    *) die "Неизвестная команда: $MODE (install|update|uninstall|purge|config|diagnostics|backup|restore|profile|upstream|services|site|web-server)" ;;
  esac
}



# CLI-интерфейс операций, ранее доступных только из меню.
profile_cli() {
  need_root; need_files
  local action="${1:-}" name="" mode="https" secret="" prefix="plain" count backend file tmp canonical archive="" target="" entry="" yes=0
  shift || true
  case "$action" in
    list)
      (($# == 0)) || die "profile list"
      printf '%-20s %-18s %s\n' "ИМЯ" "CARRIER MODE" "BACKEND"
      jq -r '.profiles[] | [.name, (.carrier_mode // "https"), .backend] | @tsv' "$PROFILES_FILE" |
        while IFS=$'\t' read -r name mode backend; do printf '%-20s %-18s %s\n' "$name" "$mode" "$backend"; done ;;
    add)
      (($# >= 1)) || die "profile add ИМЯ (--secret СЕКРЕТ | --generate) [--carrier-mode MODE]"
      name="$1"; shift
      while (($#)); do case "$1" in
        --secret) (($# >= 2)) || die "--secret требует значение"; secret="$2"; shift 2 ;;
        --generate) secret=GENERATE; shift ;;
        --carrier-mode) (($# >= 2)) || die "--carrier-mode требует значение"; mode="$2"; shift 2 ;;
        --secret-prefix) (($# >= 2)) || die "--secret-prefix требует значение"; prefix="$2"; shift 2 ;;
        *) die "Неизвестный параметр profile add: $1" ;; esac; done
      valid_name "$name" && valid_mode "$mode" || die "Недопустимое имя или Carrier mode."
      [[ ! -e "$PROFILE_DIR/$name" ]] || die "Профиль уже существует."
      [[ "$prefix" == plain || "$prefix" == dd ]] || die "Допустимы plain и dd."
      if [[ "$secret" == GENERATE ]]; then secret="$(openssl rand -hex 16)"; [[ "$prefix" == dd ]] && secret="dd$secret"
      else valid_secret "$secret" || die "Укажи --secret или --generate с корректным секретом."
        [[ "$prefix" != dd || "$secret" == dd* ]] || die "Секрет должен иметь префикс dd."
        [[ "$prefix" != plain || "$secret" != dd* ]] || die "Для plain секрет не должен иметь префикс dd."; fi
      canonical="${secret#dd}"
      jq -e --arg s "$canonical" '.profiles[] | select((.secret | ltrimstr("dd")) == $s)' "$PROFILES_FILE" >/dev/null && die "Секрет уже используется."
      count="$(jq '.profiles | length' "$PROFILES_FILE")"; (( count < 32 )) || die "Достигнут лимит 32 профиля."
      backend="$(jq -r '.profiles[0].backend' "$PROFILES_FILE")"
      install -d -o root -g tproxy -m 0750 "$PROFILE_DIR/$name"
      tmp="$(mktemp "$PROFILE_DIR/$name/profile.json.XXXXXX")"
      jq -n --arg n "$name" --arg s "$secret" --arg b "$backend" --arg m "$mode" '{name:$n,secret:$s,backend:$b,carrier_mode:$m}' > "$tmp"
      chown root:tproxy "$tmp"; chmod 0640 "$tmp"; mv -f "$tmp" "$PROFILE_DIR/$name/profile.json"
      profile_manifest_sync; write_mtproxy_secrets; patch_mtproxy_unit
      systemctl restart mtproxy tproxy-server || die "Не удалось перезапустить службы."
      ok "Профиль $name добавлен. Секрет: $secret" ;;
    set-carrier)
      (($# == 2)) || die "profile set-carrier ИМЯ MODE"
      name="$1"; mode="$2"; valid_name "$name" && valid_mode "$mode" || die "Недопустимое имя или Carrier mode."
      file="$PROFILE_DIR/$name/profile.json"; [[ -s "$file" ]] || die "Профиль не найден."
      tmp="$(mktemp "$file.XXXXXX")"; jq --arg m "$mode" '.carrier_mode=$m' "$file" > "$tmp"
      chown root:tproxy "$tmp"; chmod 0640 "$tmp"; mv -f "$tmp" "$file"; profile_manifest_sync
      "$BASE_DIR/bin/tproxy-server" -config "$CONFIG_FILE" -profiles-file "$PROFILES_FILE" -check || die "Проверка конфигурации не пройдена."
      systemctl restart tproxy-server || die "Не удалось перезапустить tproxy-server."
      ok "Carrier mode профиля $name изменён." ;;
    delete)
      [[ $# -eq 2 && "$2" == --yes ]] || die "profile delete ИМЯ --yes"
      name="$1"; valid_name "$name" || die "Недопустимое имя."
      [[ "$name" != default ]] || die "Профиль default защищён."
      [[ -d "$PROFILE_DIR/$name" ]] || die "Профиль не найден."
      count="$(jq '.profiles | length' "$PROFILES_FILE")"; (( count > 1 )) || die "Нельзя удалить последний профиль."
      rm -rf -- "${PROFILE_DIR:?}/${name:?}"
      profile_manifest_sync; write_mtproxy_secrets; patch_mtproxy_unit
      systemctl restart mtproxy tproxy-server || die "Не удалось перезапустить службы."
      ok "Профиль $name удалён." ;;
    backup)
      (($# == 1)) || die "profile backup ИМЯ"
      name="$1"; valid_name "$name" || die "Недопустимое имя."
      [[ -s "$PROFILE_DIR/$name/profile.json" ]] || die "Профиль не найден."
      install -d -o root -g root -m 0700 "$BACKUP_DIR/profile-backups"
      archive="$BACKUP_DIR/profile-backups/trpoxy-profile-backup-${name}-$(date +%Y%m%d-%H%M%S).tar.gz"
      [[ ! -e "$archive" ]] || die "Архив уже существует."
      tar -C "$PROXY_CONFIG_DIR" -czpf "$archive" "profiles/$name/profile.json"
      tar -tzf "$archive" | grep -Fxq "profiles/$name/profile.json" || die "Проверка архива не пройдена."
      chmod 0600 "$archive"; ok "Архив создан: $archive" ;;
    import)
      (($# >= 2)) || die "profile import ARCHIVE (--name ИМЯ | --replace-default) [--entry PATH] --yes"
      archive="$1"; shift; [[ -f "$archive" ]] || die "Архив не найден."
      while (($#)); do case "$1" in
        --name) (($# >= 2)) || die "--name требует значение"; target="$2"; shift 2 ;;
        --replace-default) target=default; shift ;;
        --entry) (($# >= 2)) || die "--entry требует значение"; entry="$2"; shift 2 ;;
        --yes) yes=1; shift ;;
        *) die "Неизвестный параметр profile import: $1" ;; esac; done
      (( yes )) || die "Для импорта требуется --yes."
      valid_name "$target" || die "Укажи --name или --replace-default."
      tar -tzf "$archive" >/dev/null 2>&1 || die "Архив повреждён."
      local -a entries=()
      while IFS= read -r file; do file="${file#./}"; case "$file" in profiles/*/profile.json|opt/telegram-web-proxy/config/proxy/profiles/*/profile.json) entries+=("$file") ;; esac; done < <(tar -tzf "$archive")
      ((${#entries[@]} > 0)) || die "В архиве нет профилей."
      if [[ -z "$entry" ]]; then ((${#entries[@]} == 1)) || die "В архиве несколько профилей; укажи --entry."; entry="${entries[0]}"; fi
      local found=0 candidate; for candidate in "${entries[@]}"; do [[ "$candidate" == "$entry" ]] && found=1; done
      (( found )) || die "Путь --entry не найден."
      tmp="$(mktemp)"; tar -xOzf "$archive" "$entry" > "$tmp" || { rm -f "$tmp"; die "Не удалось извлечь профиль."; }
      jq -e 'type=="object" and (.name|type=="string" and test("^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$")) and (.secret|type=="string" and test("^(dd)?[0-9a-f]{32}$")) and (.backend|type=="string" and test("^127\\.0\\.0\\.1:[0-9]{1,5}$")) and (.carrier_mode|type=="string" and (.=="https" or .=="https-lanes" or .=="websocket" or .=="websocket-lanes"))' "$tmp" >/dev/null || { rm -f "$tmp"; die "Профиль не прошёл проверку."; }
      secret="$(jq -r '.secret' "$tmp")"; canonical="${secret#dd}"; backend="$(jq -r '.profiles[0].backend' "$PROFILES_FILE")"
      count="$(jq '.profiles | length' "$PROFILES_FILE")"; file="$PROFILE_DIR/$target/profile.json"
      if [[ -e "$PROFILE_DIR/$target" ]]; then [[ "$target" == default ]] || info "Существующий профиль будет заменён."
      else (( count < 32 )) || { rm -f "$tmp"; die "Достигнут лимит 32 профиля."; }; fi
      local existing oldsecret
      while IFS= read -r existing; do [[ -n "$existing" ]] || continue
        if [[ "${existing#dd}" == "$canonical" ]]; then oldsecret="$(jq -r '.secret' "$file" 2>/dev/null || true)"; [[ -f "$file" && "${oldsecret#dd}" == "$canonical" ]] || { rm -f "$tmp"; die "Секрет уже используется."; }; fi
      done < <(jq -r '.profiles[].secret' "$PROFILES_FILE")
      local rollback; rollback="$(mktemp -d)"; cp -a "$PROFILES_FILE" "$rollback/profiles.json"
      cp -a "$MT_ENV" "$rollback/mtproxy.env"
      cp -a "$UNIT_FILE" "$rollback/mtproxy.service"
      if [[ "$target" == default ]]; then
        [[ -f "$file" ]] || { rm -rf "$rollback" "$tmp"; die "Профиль default не найден."; }
        install -d -o root -g root -m 0700 "$BACKUP_DIR/profile-backups"
        local pre
        pre="$BACKUP_DIR/profile-backups/trpoxy-profile-backup-default-before-import-$(date +%Y%m%d-%H%M%S).tar.gz"
        tar -C "$PROXY_CONFIG_DIR" -czpf "$pre" profiles/default/profile.json || { rm -rf "$rollback" "$tmp"; die "Не удалось сохранить default."; }; chmod 0600 "$pre"
      fi
      [[ ! -f "$file" ]] || cp -a "$file" "$rollback/profile.json"
      jq --arg n "$target" --arg b "$backend" '.name=$n | .backend=$b' "$tmp" > "$tmp.new"; rm -f "$tmp"
      chown root:tproxy "$tmp.new"; chmod 0640 "$tmp.new"; install -d -o root -g tproxy -m 0750 "$PROFILE_DIR/$target"; mv -f "$tmp.new" "$file"
      if ! profile_manifest_sync || ! "$BASE_DIR/bin/tproxy-server" -config "$CONFIG_FILE" -profiles-file "$PROFILES_FILE" -check || ! write_mtproxy_secrets || ! patch_mtproxy_unit || ! systemctl restart mtproxy tproxy-server; then
        [[ ! -f "$rollback/profile.json" ]] || cp -a "$rollback/profile.json" "$file"
        [[ -f "$rollback/profile.json" ]] || rm -rf -- "${PROFILE_DIR:?}/${target:?}"
        cp -a "$rollback/profiles.json" "$PROFILES_FILE"
        cp -a "$rollback/mtproxy.env" "$MT_ENV"
        cp -a "$rollback/mtproxy.service" "$UNIT_FILE"
        systemctl daemon-reload
        systemctl restart mtproxy tproxy-server 2>/dev/null || true
        rm -rf "$rollback"; die "Импорт не прошёл проверку; исходная конфигурация восстановлена."
      fi
      rm -rf "$rollback"; ok "Профиль импортирован: $target" ;;
    *) die "profile {list|add|set-carrier|delete|backup|import} ..." ;;
  esac
}

upstream_cli() {
  need_root; need_files
  local action="${1:-}" value="${2:-}" tmp backup
  [[ -n "$action" && -n "$value" ]] || die "upstream set-url URL | set-dir PATH"
  shift 2 || true; (($# == 0)) || die "Лишние аргументы."
  tmp="$(mktemp "$CONFIG_FILE.XXXXXX")"
  case "$action" in
    set-url) [[ "$value" =~ ^http://127\.0\.0\.1:[0-9]{1,5}$ ]] || { rm -f "$tmp"; die "URL должен иметь вид http://127.0.0.1:PORT."; }
      local upstream_port="${value##*:}" relay_port admin_port
      (( upstream_port >= 1 && upstream_port <= 65535 )) || { rm -f "$tmp"; die "Порт upstream должен находиться в диапазоне 1–65535."; }
      relay_port="$(jq -r '.listen | split(":")[-1]' "$CONFIG_FILE")"
      admin_port="$(jq -r '.admin_listen | split(":")[-1]' "$CONFIG_FILE")"
      [[ "$upstream_port" != "$relay_port" && "$upstream_port" != "$admin_port" ]] || { rm -f "$tmp"; die "Upstream не может использовать relay/admin порт."; }
      jq --arg u "$value" 'del(.public_dir) | .public_upstream=$u' "$CONFIG_FILE" > "$tmp" ;;
    set-dir) [[ "$value" == /* && -d "$value" ]] || { rm -f "$tmp"; die "Нужен существующий абсолютный каталог."; }
      jq --arg d "$value" 'del(.public_upstream) | .public_dir=$d' "$CONFIG_FILE" > "$tmp" ;;
    *) rm -f "$tmp"; die "Допустимы set-url и set-dir." ;; esac
  chown root:tproxy "$tmp"; chmod 0640 "$tmp"; backup="${CONFIG_FILE}.before-upstream.$(date +%Y%m%d-%H%M%S)"
  cp -a "$CONFIG_FILE" "$backup"; mv -f "$tmp" "$CONFIG_FILE"
  if ! "$BASE_DIR/bin/tproxy-server" -config "$CONFIG_FILE" -profiles-file "$PROFILES_FILE" -check; then cp -a "$backup" "$CONFIG_FILE"; die "Проверка не пройдена; конфигурация восстановлена."; fi
  systemctl restart tproxy-server || { cp -a "$backup" "$CONFIG_FILE"; systemctl restart tproxy-server || true; die "Перезапуск не удался; конфигурация восстановлена."; }
  ok "Настройка публичного сайта обновлена."
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  trap 'update_exit_handler "$?"' EXIT
  main "$@"
fi
