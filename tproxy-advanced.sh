#!/usr/bin/env bash
# Advanced operations for Telegram Web Proxy 1.0.2.
set -Eeuo pipefail
umask 077

BASE_DIR=/opt/telegram-web-proxy
CONFIG_DIR=$BASE_DIR/config/proxy
MTPROXY_CONFIG_DIR=$BASE_DIR/config/mtproxy
PROFILES_FILE=$CONFIG_DIR/profiles.json
CONFIG_FILE=$CONFIG_DIR/config.json
MT_ENV=$MTPROXY_CONFIG_DIR/mtproxy.env
UNIT_FILE=$BASE_DIR/systemd/mtproxy.service
ADMIN_PORT=8081
HOSTNAME_VALUE=
WEB_SERVER=caddy

die() { printf '[ОШИБКА] %s\n' "$*" >&2; exit 1; }
need_root() { [[ $EUID -eq 0 ]] || die 'Запусти команду через sudo.'; }
need_files() {
  [[ -r $CONFIG_FILE && -r $PROFILES_FILE && -r $MT_ENV ]] || die 'Не найдена установленная конфигурация.';
  command -v jq >/dev/null 2>&1 || die 'Требуется jq.';
  ADMIN_PORT="$(jq -r '.admin_listen | split(":")[-1]' "$CONFIG_FILE")"
  HOSTNAME_VALUE="$(jq -r '.public_hostname // empty' "$CONFIG_FILE")"
  WEB_SERVER="$(cat "$CONFIG_DIR/web-server" 2>/dev/null || echo caddy)"
}
valid_secret() { [[ $1 =~ ^(dd)?[0-9a-f]{32}$ ]]; }
valid_name() { [[ $1 =~ ^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$ ]]; }
valid_mode() { [[ $1 == https || $1 == https-lanes || $1 == websocket || $1 == websocket-lanes ]]; }

ui_header() {
  local title="$1"
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
  else
    printf '  %s) %s %s\n' "$number" "$icon" "$label"
  fi
}

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

profile_menu() {
  local choice name secret mode backend count index profile_name profile_mode profile_backend
  while :; do
    clear
    ui_header "Профили и carrier mode"
    printf '  Текущие профили:\n'
    index=0
    while IFS=$'\t' read -r profile_name profile_mode profile_backend; do
      index=$((index + 1))
      printf '  %2d. %-20s | %-16s | backend %s\n' "$index" "$profile_name" "$profile_mode" "$profile_backend"
    done < <(jq -r '.profiles[] | [.name, (.carrier_mode // "https"), .backend] | @tsv' "$PROFILES_FILE")
    echo
    ui_option 1 "＋" "Добавить профиль"
    ui_option 2 "↻" "Изменить carrier mode профиля"
    ui_option 3 "✖" "Удалить дополнительный профиль"
    ui_option 4 "←" "Назад"
    echo
    read -r -p 'Выбор [1-4]: ' choice
    case "$choice" in
      1)
        count="$(jq '.profiles | length' "$PROFILES_FILE")"
        (( count < 32 )) || { echo 'Достигнут лимит 32 профиля.'; read -r -p 'Enter...' _; continue; }
        read -r -p 'Имя профиля: ' name
        valid_name "$name" || { echo 'Недопустимое имя'; read -r -p 'Enter...' _; continue; }
        if jq -e --arg n "$name" '.profiles[] | select(.name == $n)' "$PROFILES_FILE" >/dev/null; then echo 'Такое имя уже существует'; read -r -p 'Enter...' _; continue; fi
        backend="$(jq -r '.profiles[0].backend' "$PROFILES_FILE")"
        echo "Все профили используют общий backend $backend и одну политику MTProxy."
        read -r -s -p 'Новый секрет (32 hex, опционально dd): ' secret; echo
        valid_secret "$secret" || { echo 'Недопустимый секрет'; read -r -p 'Enter...' _; continue; }
        if jq -e --arg s "$secret" '.profiles[] | select((.secret | ltrimstr("dd")) == ($s | ltrimstr("dd")))' "$PROFILES_FILE" >/dev/null; then echo 'Секрет уже используется (включая dd-префикс)'; read -r -p 'Enter...' _; continue; fi
        echo 'Carrier mode: 1) https  2) https-lanes  3) websocket  4) websocket-lanes'
        read -r -p 'Выбор [1-4]: ' choice
        case "$choice" in 1) mode=https ;; 2) mode=https-lanes ;; 3) mode=websocket ;; 4) mode=websocket-lanes ;; *) echo 'Неверный режим'; continue ;; esac
        local tmp; tmp="$(mktemp "${PROFILES_FILE}.XXXXXX")"
        jq --arg n "$name" --arg s "$secret" --arg b "$backend" --arg m "$mode" '.profiles += [{"name":$n,"secret":$s,"backend":$b,"carrier_mode":$m}]' "$PROFILES_FILE" > "$tmp"
        chown root:tproxy "$tmp"; chmod 0400 "$tmp"; mv -f "$tmp" "$PROFILES_FILE"
        write_mtproxy_secrets; patch_mtproxy_unit
        systemctl restart mtproxy tproxy-server
        echo "Профиль $name добавлен."
        read -r -p 'Enter...' _ ;;
      2)
        read -r -p 'Имя профиля: ' name
        jq -e --arg n "$name" '.profiles[] | select(.name == $n)' "$PROFILES_FILE" >/dev/null || { echo 'Профиль не найден'; read -r -p 'Enter...' _; continue; }
        echo 'Carrier mode: 1) https  2) https-lanes  3) websocket  4) websocket-lanes'
        read -r -p 'Выбор [1-4]: ' choice
        case "$choice" in 1) mode=https ;; 2) mode=https-lanes ;; 3) mode=websocket ;; 4) mode=websocket-lanes ;; *) echo 'Неверный режим'; continue ;; esac
        local tmp; tmp="$(mktemp "${PROFILES_FILE}.XXXXXX")"
        jq --arg n "$name" --arg m "$mode" '(.profiles[] | select(.name == $n)).carrier_mode = $m' "$PROFILES_FILE" > "$tmp"
        chown root:tproxy "$tmp"; chmod 0400 "$tmp"; mv -f "$tmp" "$PROFILES_FILE"
        systemctl restart tproxy-server
        echo "Carrier mode профиля $name изменён."
        read -r -p 'Enter...' _ ;;
      3)
        count="$(jq '.profiles | length' "$PROFILES_FILE")"
        (( count > 1 )) || { echo 'Нельзя удалить последний профиль.'; read -r -p 'Enter...' _; continue; }
        read -r -p 'Имя дополнительного профиля: ' name
        [[ $name != default ]] || { echo 'Профиль default защищён.'; read -r -p 'Enter...' _; continue; }
        jq -e --arg n "$name" '.profiles[] | select(.name == $n)' "$PROFILES_FILE" >/dev/null || { echo 'Профиль не найден'; read -r -p 'Enter...' _; continue; }
        local tmp; tmp="$(mktemp "${PROFILES_FILE}.XXXXXX")"
        jq --arg n "$name" '.profiles |= map(select(.name != $n))' "$PROFILES_FILE" > "$tmp"
        chown root:tproxy "$tmp"; chmod 0400 "$tmp"; mv -f "$tmp" "$PROFILES_FILE"
        write_mtproxy_secrets; patch_mtproxy_unit
        systemctl restart mtproxy tproxy-server
        echo "Профиль $name удалён."
        read -r -p 'Enter...' _ ;;
      4) return 0 ;;
      *) echo 'Неверный выбор'; sleep 1 ;;
    esac
  done
}

upstream_menu() {
  local current answer tmp backup port http_code selected=0 i
  local -a ports=() codes=()
  current="$(jq -r '.public_upstream // empty' "$CONFIG_FILE")"

  while :; do
    clear
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

    clear
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
main() {
  need_root
  need_files
  case "${1:-menu}" in
    profiles) profile_menu ;;
    upstream) upstream_menu ;;
    menu)
      local choice
      while :; do
        clear
        ui_header "Дополнительные возможности"
        ui_option 1 "▤" "Carrier mode и профили"
        ui_option 2 "⇄" "Публичный сайт (public_upstream)"
        ui_option 3 "←" "Назад"
        echo
        read -r -p "Выбор [1-3]: " choice
        case "$choice" in
          1) profile_menu ;;
          2) upstream_menu ;;
          3|"") break ;;
          *) echo 'Неверный выбор'; sleep 1 ;;
        esac
      done ;;
    *) die 'Использование: tproxy-advanced.sh [profiles|upstream|menu]' ;;
  esac
}
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
