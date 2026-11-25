# Web Admin Panel

Отдельная административная панель Telegram Web Proxy.

## Архитектура

- Go HTTP backend, доступен только на `127.0.0.1:18765`.
- SQLite хранит случайный URL basepath, логин, Argon2id-хеш пароля и хеши сессий.
- HTML-шаблоны встраиваются в бинарный файл через `go:embed`.
- Все операции с профилями, диагностикой и архивами вызывают штатный `tgweb-install.sh` с фиксированными аргументами.
- Caddy или Nginx проксирует только случайный URL панели на localhost.
- Fail2ban отслеживает неудачные входы из журнала systemd.

## Первичный доступ

При первом запуске генерируются отдельные случайные basepath, логин и пароль. Они записываются один раз в:

`/opt/telegram-web-proxy/data/panel/panel-credentials.txt`

Файл и SQLite-база создаются с правами доступа только для root. Пароль в SQLite хранится как Argon2id-хеш. После успешного входа файл с реквизитами можно перенести в защищённое хранилище и удалить.

## Сборка и проверки

```sh
go mod tidy
go test ./...
go vet ./...
go build -trimpath -ldflags="-s -w" -o tproxy-panel .
```

Для SQLite-драйвера требуется CGO и C-компилятор. Установщик обеспечивает Go 1.24+ и build-essential.

## Доступные операции

- просмотр, создание, удаление, импорт и экспорт профилей;
- отдельная конфигурация каждого профиля: публичный адрес, клиентский секрет, HTTPS- и tg://-ссылки Telegram и QR-код для прямой ссылки;
- изменение Carrier mode и безопасная ротация секрета с обновлением манифеста и перезапуском сервисов;
- запуск штатной диагностики;
- создание и восстановление полных резервных копий.

Внутренний backend-порт и сырой JSON конфигурации не показываются в интерфейсе. Экспорт профиля создаёт архив и сразу запускает его скачивание. Все действия изменения профиля выполняются через валидируемые команды установщика.
## Защита от SQL-инъекций

- Все значения, поступающие от пользователя и используемые в SQL, передаются отдельными аргументами через плейсхолдеры `?` драйвера SQLite.
- Динамическая сборка SQL из логинов, паролей, имён профилей, HTTP-параметров или содержимого загружаемых файлов запрещена.
- Имена таблиц и структура запросов фиксированы в исходном коде; пользовательский ввод не может менять SQL-синтаксис.
- Входные значения дополнительно валидируются на уровне HTTP-обработчиков. Валидация не заменяет параметризацию.
- Регрессионный тест проверяет попытку входа с логином `' OR 1=1 --`: она не должна создавать сессию, при этом обычная авторизация должна продолжать работать.

При добавлении новых SQL-операций необходимо использовать `Query`, `QueryRow` и `Exec` с плейсхолдерами и отдельными аргументами. Не использовать `fmt.Sprintf`, конкатенацию строк или шаблоны для подстановки пользовательских данных в SQL.


### MTProxy runtime settings in the panel

The profile table displays Workers and Max Connections from `mtproxy.env`. These are settings of the shared MTProxy service, not independent per-profile limits; the same values are therefore shown for each profile. The profile editor validates Workers (1–256) and Max Connections (1–1,000,000), updates the service environment file atomically, and restarts MTProxy. If applying the change fails, the previous profile and runtime settings are restored.

Confirmation and status messages are rendered inside the dashboard using the panel's own dialog and toast styles; browser-native `alert()` and `confirm()` prompts are not used.


## Fail2ban для прокси

Установщик управляет только собственными файлами `tproxy-*` и не перезаписывает SSH- или `recidive`-jail.

- `tproxy-panel`: неудачные входы в административную панель из systemd journal.
- `tproxy-nginx-scan` / `tproxy-caddy-scan`: запросы к типовым exploit/scanner-путям с кодами 400/403/404/444 из отдельного access log выбранного веб-сервера.
- `tproxy-server-abuse` и `tproxy-mtproxy-abuse`: только явные маркеры `[SECURITY]`, `[ABUSE]` или `[AUTH_FAIL]` с полем `remote=`. Обычные ошибки Telegram, handshake, secret, timeout и transport не являются причиной блокировки. Если сервис не пишет такие маркеры, диагностика прямо сообщает, что источника событий нет; искусственные события не генерируются.

Для Nginx используется отдельный access log без query string и logrotate (7 архивов). Для Caddy — JSON access log с удалением query string и ограниченной внутренней ротацией. Если домен распознан как Cloudflare-proxied, установщик получает актуальные официальные IPv4/IPv6-сети Cloudflare и настраивает доверие к ним для извлечения реального IP клиента; при неудаче загрузки списков установка прекращается, чтобы не банить общий edge IP.

Диагностика проверяет службу, синтаксис конфигурации, загрузку каждого jail, источник событий и только числовую статистику блокировок. Списки IP-адресов не выводятся. Команда «Перезапустить все службы прокси» не перезапускает Fail2ban.


### Если Fail2ban не создаёт управляющий сокет

Установщик устанавливает `python3-systemd` явно: он нужен jail с `backend = systemd`. После перезапуска установщик ждёт управляющий сокет до 15 секунд. Если служба не поднимается, до отката печатаются очищенные от IP-адресов и секретов `systemctl status`, журнал Fail2ban текущей загрузки и результат `fail2ban-client -t`.

Для ручной проверки на сервере:

```bash
sudo systemctl status fail2ban.service --no-pager -l
sudo journalctl -u fail2ban.service -b -n 80 --no-pager
sudo fail2ban-client -t
/usr/bin/python3 -c 'import systemd.journal; print("systemd backend: OK")'
```

Отсутствие `/run/fail2ban/fail2ban.sock` само по себе не указывает на ошибку фильтра: сначала нужно проверить, почему завершился демон. Не создавайте сокет вручную и не отключайте проверку доступности.
