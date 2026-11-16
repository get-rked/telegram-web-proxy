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

die() { printf '[ОШИБКА] %s\n' "$*" >&2; exit 1; }
need_root() { [[ $EUID -eq 0 ]] || die 'Запусти команду через sudo.'; }
need_files() {
  [[ -r $CONFIG_FILE && -r $MT_ENV ]] || die 'Не найдена установленная конфигурация.';
  command -v jq >/dev/null 2>&1 || die 'Требуется jq.';
  ADMIN_PORT="$(jq -r '.admin_listen | split(":")[-1]' "$CONFIG_FILE")"
  HOSTNAME_VALUE="$(jq -r '.public_hostname // empty' "$CONFIG_FILE")"
  profile_storage_init
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

PROFILE_DIR=$CONFIG_DIR/profiles
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

profile_manifest_valid() {
  [[ -s "$PROFILES_FILE" ]] &&
    jq -e '
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
    ' "$PROFILES_FILE" >/dev/null 2>&1
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

profile_menu() {
  local choice name mode mode_label backend count file tmp selected profile_row
  while :; do
    clear
    ui_header "Профили подключений"
    printf '  Общий домен: %s\n' "$HOSTNAME_VALUE"
    while IFS= read -r profile_row; do
      name="$(cut -f1 <<< "$profile_row")"
      mode="$(cut -f2 <<< "$profile_row")"
      backend="$(cut -f3 <<< "$profile_row")"
      case "$mode" in
        https) mode_label="HTTPS" ;;
        https-lanes) mode_label="HTTPS · несколько каналов" ;;
        websocket) mode_label="WebSocket" ;;
        websocket-lanes) mode_label="WebSocket · несколько каналов" ;;
        *) mode_label="$mode" ;;
      esac
      printf '  ◆ %-20s | %-28s | backend %s\n' "$name" "$mode_label" "$backend"
    done < <(jq -r '.profiles[] | [.name, (.carrier_mode // "https"), .backend] | @tsv' "$PROFILES_FILE")
    echo
    ui_option 1 "＋" "Добавить профиль"
    ui_option 2 "↻" "Изменить Carrier mode"
    ui_option 3 "✖" "Удалить дополнительный профиль"
    ui_option 4 "←" "Назад"
    echo
    read -r -p "Выбор [1-4]: " choice
    case "$choice" in
      1)
        count="$(jq '.profiles | length' "$PROFILES_FILE")"
        (( count < 32 )) || { echo "Достигнут лимит 32 профиля."; read -r -p "Enter..." _; continue; }
        read -r -p "Имя профиля (латиница, цифры, _ и -): " name
        valid_name "$name" && [[ ! -e "$PROFILE_DIR/$name" ]] || { echo "Имя недопустимо или уже занято."; read -r -p "Enter..." _; continue; }
        profile_secret_prompt || { read -r -p "Enter..." _; continue; }
        if jq -e --arg s "$PROFILE_SECRET" '.profiles[] | select((.secret | ltrimstr("dd")) == ($s | ltrimstr("dd")))' "$PROFILES_FILE" >/dev/null; then
          echo "Секрет уже используется."; read -r -p "Enter..." _; continue
        fi
        echo "Carrier mode: [1] HTTPS [2] HTTPS с каналами [3] WebSocket [4] WebSocket с каналами"
        read -r -p "Выбор [1-4]: " choice
        case "$choice" in 1) mode=https ;; 2) mode=https-lanes ;; 3) mode=websocket ;; 4) mode=websocket-lanes ;; *) echo "Недопустимый режим."; continue ;; esac
        backend="$(jq -r '.profiles[0].backend' "$PROFILES_FILE")"
        install -d -o root -g tproxy -m 0750 "$PROFILE_DIR/$name"
        jq -n --arg n "$name" --arg s "$PROFILE_SECRET" --arg b "$backend" --arg m "$mode" '{name:$n,secret:$s,backend:$b,carrier_mode:$m}' > "$PROFILE_DIR/$name/profile.json"
        chown root:tproxy "$PROFILE_DIR/$name/profile.json"; chmod 0640 "$PROFILE_DIR/$name/profile.json"
        profile_manifest_sync; write_mtproxy_secrets; patch_mtproxy_unit
        systemctl restart mtproxy tproxy-server
        echo "Профиль $name добавлен."; read -r -p "Enter..." _ ;;
      2)
        profile_choose || continue
        echo "Carrier mode: [1] HTTPS [2] HTTPS с каналами [3] WebSocket [4] WebSocket с каналами"
        read -r -p "Выбор [1-4]: " choice
        case "$choice" in 1) mode=https ;; 2) mode=https-lanes ;; 3) mode=websocket ;; 4) mode=websocket-lanes ;; *) echo "Недопустимый режим."; continue ;; esac
        file="$PROFILE_DIR/$PROFILE_NAME/profile.json"; tmp="$(mktemp "$file.XXXXXX")"
        jq --arg m "$mode" '.carrier_mode = $m' "$file" > "$tmp"
        chown root:tproxy "$tmp"; chmod 0640 "$tmp"; mv -f "$tmp" "$file"
        profile_manifest_sync; systemctl restart tproxy-server
        echo "Carrier mode профиля $PROFILE_NAME изменён."; read -r -p "Enter..." _ ;;
      3)
        count="$(jq '.profiles | length' "$PROFILES_FILE")"; (( count > 1 )) || { echo "Нельзя удалить последний профиль."; read -r -p "Enter..." _; continue; }
        profile_choose || continue
        [[ "$PROFILE_NAME" != default ]] || { echo "Профиль default защищён."; read -r -p "Enter..." _; continue; }
        read -r -p "Удалить профиль $PROFILE_NAME? [y/N]: " selected
        [[ "$selected" =~ ^[YyДд]$ ]] || continue
        rm -rf -- "${PROFILE_DIR:?}/${PROFILE_NAME:?}"
        profile_manifest_sync; write_mtproxy_secrets; patch_mtproxy_unit
        systemctl restart mtproxy tproxy-server
        echo "Профиль $PROFILE_NAME удалён."; read -r -p "Enter..." _ ;;
      4) return 0 ;;
      *) echo "Неверный выбор."; sleep 1 ;;
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
