# Telegram Web Proxy — Docker Manager

**Версия скрипта: 1.2.0**

Основной способ установки и обслуживания — единый Docker Manager для Ubuntu/Debian x86_64. При первом запуске установщик самостоятельно сохраняет прежнюю установку (если она есть), разворачивает репозиторий в **/opt/telegram-web-proxy/**, устанавливает Docker Engine и Compose, затем предлагает перенести действующую native-конфигурацию или выполнить чистую установку.

В Docker-развёртывание входят **Telegram Web Proxy (tproxy-server), MTProxy, Caddy или Nginx, панель управления и Fail2ban**. Существующая native-установка не удаляется автоматически: её архив и подготовленные для миграции настройки сохраняются отдельно.

> Для установки и обслуживания нужны права root. Установщик меняет пакеты, Docker, сетевые правила и службы. Перед началом проверь DNS домена и доступность TCP-портов 80/443.

## Возможности

- Интерактивное меню с отображением версии скрипта.
- Установка и обновление tproxy-server и MTProxy.
- Выбор Caddy или Nginx в качестве HTTPS reverse proxy.
- TLS: автоматическое управление сертификатами Caddy либо Certbot/Let's Encrypt для Nginx.
- Генерация секрета MTProxy или использование собственного; форматы `plain` и `dd`.
- Автоматический или пользовательский base path Web Proxy.
- Настройка числа MTProxy workers и максимального количества соединений.
- Создание штатного decoy-сайта. Если в каталоге уже есть `index.html`, скрипт не перезаписывает сайт и не меняет его права.
- Настройка systemd-служб и локального firewall backend на nftables.
- Проверка конфигурации и готовности сервисов после установки.
- Предварительная проверка DNS/HTTPS-доступности `core.telegram.org` и TCP-доступности Telegram DC.
- Атомарная установка нового бинарника и автоматический rollback бинарника/конфигураций при провале health-check обновления.
- Сокрытие чувствительных значений в выводе диагностических журналов; отключено access-журналирование Nginx для vhost прокси.
- Просмотр текущих параметров, состояний служб и слушающих TCP-портов.
- Формирование Telegram-ссылки подключения и QR-кода (терминал + PNG).
- Управление несколькими профилями: добавление, удаление и индивидуальный Carrier mode.
- Настройка публичного сайта через локальный `public_upstream`.
- Перезапуск всех установленных служб прокси из меню инструментов.
- Диагностика, резервное копирование и восстановление конфигураций.
- Раздельное удаление прокси, штатного decoy-сайта и веб-сервера.

## Требования и подготовка

- Ubuntu или Debian; другие дистрибутивы скриптом не проверяются.
- Архитектура **x86_64**.
- Доступ root или запуск через `sudo`.
- Домен с A-записью, указывающей на публичный IPv4 сервера.
- Доступность входящих TCP-портов **80 и 443** и отсутствие конфликтующих служб на этих портах.
- Доступ сервера в интернет для установки пакетов и загрузки исходников/бинарных файлов.
- Работающие systemd и nftables.

Если используется Cloudflare Proxy, скрипт распознаёт адреса Cloudflare и не требует совпадения DNS-ответа с IP origin-сервера. DNS-проверка выполняется через resolver 1.1.1.1.

Во время установки скрипт устанавливает необходимые зависимости, включая инструменты сборки, `git`, `curl`, `openssl`, `jq`, `qrencode`, `nftables`, `dnsutils` и `netcat-openbsd`. Если подходящей версии Go нет, используется закреплённая версия Go. Caddy устанавливается в закреплённой версии с проверкой контрольной суммы; Nginx и Certbot устанавливаются из репозиториев пакетов ОС.

## Архитектура и порты

Внешние HTTP/HTTPS-запросы принимает выбранный веб-сервер. Он завершает TLS и проксирует запросы на локальный tproxy-server, который взаимодействует с MTProxy.

| Порт | Назначение | Доступ |
|---|---|---|
| TCP 80 | HTTP, редирект и ACME/Let's Encrypt | Открыть извне |
| TCP 443 | HTTPS, сайт и Web Proxy | Открыть извне |
| TCP 8080 | Relay tproxy-server по умолчанию | Только localhost |
| TCP 8081 | Admin/health tproxy-server по умолчанию | Только localhost |
| TCP 2398 | Backend MTProxy в текущей конфигурации | Внутренний |
| TCP 8888 | Служебный порт MTProxy в типовой конфигурации | Внутренний |

Relay и admin endpoint привязаны к loopback-интерфейсу. Backend-порты MTProxy защищаются локальным правилом nftables `inet tproxy_backend`. Не открывайте relay, admin и внутренние порты MTProxy в firewall провайдера или сервера. Для описанной конфигурации входящий UDP не требуется.

Если заданы нестандартные relay/admin-порты, они также должны оставаться доступными только локально. Фактические порты можно посмотреть командой `config`.

## Быстрый старт

### 1. Подготовьте DNS и firewall

Создай A-запись домена, например `proxy.example.com`, указывающую на публичный IP сервера. Разреши входящие TCP 80 и 443 в firewall VPS и сервера. Убедись, что эти порты не заняты посторонними службами.

### 2. Запусти одноразовый установщик

```bash
curl -fsSL https://raw.githubusercontent.com/get-rked/telegram-web-proxy/feature/docker-web-panel/tgweb-install.sh -o /tmp/tgweb-install.sh
sudo bash /tmp/tgweb-install.sh
```

Установщик сам:
1. Архивирует существующий `/opt/telegram-web-proxy/` в `/var/backups/telegram-web-proxy/`.
2. Если обнаруживает native-конфигурацию, извлекает её в отдельный staging-каталог для переноса.
3. Разворачивает Git-репозиторий в `/opt/telegram-web-proxy/`.
4. Устанавливает Docker Engine и Compose.
5. Запускает единое интерактивное меню Docker Manager.

В меню выбери **«Установить / перенести Web Proxy в Docker»**. При обнаружении прежней конфигурации будет предложен контролируемый перенос. Если прежней конфигурации нет, установщик запросит домен и email и выполнит чистую установку (по умолчанию Caddy).

Для последующего управления используй:
```bash
sudo /opt/telegram-web-proxy/tgweb-install.sh
```

Установщик и все файлы проекта после первого запуска находятся в одном каталоге. Для получения обновлений используй пункт **«Обновить код и Docker-образы»** в меню или команду `docker update`.

## Команды

Общий формат:

```bash
sudo ./tgweb-install.sh <команда> [параметры]
```

### Установка

Установка выполняется через Docker Manager. Команды `install` и `docker install` запускают один и тот же сценарий: если сохранена native-конфигурация, выполняется контролируемый перенос; иначе запрашиваются домен и email и создаётся новая Docker-установка.

```bash
sudo /opt/telegram-web-proxy/tgweb-install.sh docker install
```


### Docker-установка и обслуживание

Docker Manager — основной режим работы установщика. Интерактивное меню открывается командой:
```bash
sudo /opt/telegram-web-proxy/tgweb-install.sh
```

Основные команды:
```bash
# Автоматически определить: чистая установка или перенос сохранённой native-конфигурации
sudo /opt/telegram-web-proxy/tgweb-install.sh docker install

# Чистая установка с параметрами
sudo /opt/telegram-web-proxy/tgweb-install.sh docker install --web-server caddy --hostname proxy.example.com --email admin@example.com

# Обновить Git-код, затем образы и контейнеры
sudo /opt/telegram-web-proxy/tgweb-install.sh docker update

# Удалить контейнеры и сеть, сохранив конфигурацию и volumes
sudo /opt/telegram-web-proxy/tgweb-install.sh docker uninstall

# Удалить контейнеры и локальные образы; volumes оставить
sudo /opt/telegram-web-proxy/tgweb-install.sh docker purge

# Дополнительно удалить volumes (необратимая потеря данных панели/TLS/MTProxy)
sudo /opt/telegram-web-proxy/tgweb-install.sh docker purge --volumes

sudo /opt/telegram-web-proxy/tgweb-install.sh docker status
sudo /opt/telegram-web-proxy/tgweb-install.sh docker restart
sudo /opt/telegram-web-proxy/tgweb-install.sh docker logs panel
sudo /opt/telegram-web-proxy/tgweb-install.sh docker backup
```

**Важно:** `docker uninstall` и `docker purge` без `--volumes` сохраняют тома и файлы конфигурации. Нативные systemd-службы и архив прежней установки не удаляются Docker-командами. `docker backup` включает файлы проекта, в том числе `.env` и приватные настройки, но не содержимое Docker volumes.
### Обновление

Команда обновляет Git-репозиторий fast-forward способом, затем повторно запускает актуальный установщик для проверки Compose, загрузки внешних образов, пересборки локальных образов и применения изменений.

```bash
sudo /opt/telegram-web-proxy/tgweb-install.sh docker update
```

Обновление останавливается, если в репозитории есть локальные изменения. Это защищает изменённые конфигурации и сайт от перезаписи. Перед обновлением сохрани или отдельно перенеси локальные правки.


### Текущая конфигурация

```bash
sudo /opt/telegram-web-proxy/tgweb-install.sh docker status
```

Команда показывает состояния контейнеров и выбранный reverse proxy. Секреты и пароль панели в вывод не включаются.


### Диагностика

Для первичной диагностики используй статус и логи контейнеров:
```bash
sudo /opt/telegram-web-proxy/tgweb-install.sh docker status
sudo /opt/telegram-web-proxy/tgweb-install.sh docker logs relay
sudo /opt/telegram-web-proxy/tgweb-install.sh docker logs caddy
sudo /opt/telegram-web-proxy/tgweb-install.sh docker logs mtproxy
```

При проверке Web Proxy обязательно проверь подключение в Telegram-клиенте, а не только HTTP-ответ сайта.


### Резервная копия и восстановление

```bash
sudo /opt/telegram-web-proxy/tgweb-install.sh docker backup
```

Архив файлов проекта создаётся в `/var/backups/telegram-web-proxy-docker/` с правами `0600`. В него входят `.env`, приватные настройки и сайт. Именованные Docker volumes в этот архив не входят; для сохранения данных панели, TLS и MTProxy не удаляй volumes.


### Удаление

Удалить контейнеры и сеть, сохранив файлы и volumes:
```bash
sudo /opt/telegram-web-proxy/tgweb-install.sh docker uninstall
```

Удалить контейнеры и локальные образы, оставив volumes:
```bash
sudo /opt/telegram-web-proxy/tgweb-install.sh docker purge
```

Полная очистка с удалением volumes требует явного флага `--volumes` и подтверждения `DELETE VOLUMES`:
```bash
sudo /opt/telegram-web-proxy/tgweb-install.sh docker purge --volumes
```

Удаление Docker-проекта не удаляет архив прежней native-установки и её systemd units.


## Параметры установки и обновления

| Параметр | Описание |
|---|---|
| `--hostname FQDN` | Домен Web Proxy в нижнем регистре, например `proxy.example.com` |
| `--web-server caddy\|nginx` | Выбор веб-сервера; по умолчанию Caddy |
| `--email EMAIL` | Email для Let's Encrypt |
| `--secret SECRET` | Секрет: 32 строчных hex-символа или `dd` + 32 hex-символа |
| `--secret-prefix plain\|dd` | Формат генерируемого секрета |
| `--base-path SLUG\|none` | Пользовательский путь Web Proxy или `none` для корня домена; без параметра генерируется автоматически |
| `--site-dir PATH` | Каталог сайта; по умолчанию `/opt/telegram-web-proxy/data/website` |
| `--no-site` | Не создавать штатный decoy-сайт |
| `--workers N` | Число MTProxy workers, от 1 до 256; по умолчанию 1 |
| `--max-connections N` | Максимальное число соединений MTProxy; по умолчанию 4096 |
| `--port N` | Локальный relay-порт; по умолчанию 8080 |
| `--admin-port N` | Локальный admin/health-порт; по умолчанию 8081 |
| `--skip-tests` | Пропустить `go test ./...` при сборке |
| `--non-interactive` | Не задавать интерактивные вопросы при установке/обновлении |
| `-y` | В установке/обновлении — non-interactive; в удалении — автоматическое подтверждение |

Relay- и admin-порты должны различаться и находиться в диапазоне 1024–65535. При интерактивной установке скрипт проверяет, не заняты ли выбранные порты.

Пример с собственным секретом и base path:

```bash
sudo ./tgweb-install.sh install \
  --hostname proxy.example.com \
  --email admin@example.com \
  --secret 0123456789abcdef0123456789abcdef \
  --base-path my-proxy \
  --port 8080 \
  --admin-port 8081
```

## Дополнительные настройки и профили

В главном меню открой **Инструменты → Carrier mode, профили, public upstream**. Внутри доступны управление профилями и настройка публичного сайта (`public_upstream`). В этом меню также можно перезапустить все установленные службы прокси через пункт **Перезапустить все службы прокси**.

- **Carrier mode** задаётся отдельно для каждого профиля: https, https-lanes, websocket, websocket-lanes.
- **Добавление профиля** использует выбор формата секрета (`plain` или `dd`), автоматическую генерацию либо ручной ввод с повторным подтверждением, а также выбор Carrier mode. Секреты профилей должны быть уникальными.
- **Несколько профилей** поддерживаются: максимум 32 профиля с уникальными именами и секретами. Домен, base path, relay/admin-порты и backend остаются общими. Все профили используют один loopback backend и общую политику MTProxy; установщик формирует повторяющиеся аргументы `-S` для одного процесса MTProxy. Нельзя удалить профиль `default` или последний оставшийся профиль.
- **Просмотр текущей конфигурации** сразу открывает единственный профиль. Если профилей несколько, сначала предлагается выбрать нужный. В отчёте отображаются имя профиля, его Carrier mode, секрет и ссылка подключения вместе с общими параметрами.
- **public_upstream** позволяет направить публичный сайт на уже работающий HTTP-сервис по адресу http://127.0.0.1:PORT. Менеджер сканирует локальные TCP-порты, проверяет HTTP-ответы и предлагает найденные приложения для выбора. Переключение можно отменить возвратом к локальному public_dir.

Профильные настройки хранятся раздельно: /opt/telegram-web-proxy/config/proxy/profiles/<имя>/profile.json. Общие настройки сервера остаются в config.json, а установщик собирает из профильных файлов агрегированный profiles.json для совместимости с tproxy-server. При первом открытии менеджера существующий profiles.json автоматически раскладывается по каталогам профилей. MTProxy использует общий mtproxy.env, содержащий набор секретов всех профилей.

Обновление сохраняет дополнительные профили и применяет параметры установки/обновления к основному профилю `default`. Изменение Carrier mode в менеджере затрагивает только выбранный профиль. При добавлении/удалении профиля набор секретов MTProxy синхронизируется, затем перезапускаются `mtproxy` и `tproxy-server`. При изменении Carrier mode перезапускается `tproxy-server`.

### Управление профилями из командной строки

Операции с профилями доступны без запуска интерактивного меню. Все команды выполняются от root или через `sudo`.

Список профилей:

```bash
sudo ./tgweb-install.sh profile list
```

Создание профиля с автоматически сгенерированным секретом:

```bash
sudo ./tgweb-install.sh profile add mobile --generate --carrier-mode https
```

Создание профиля с заданным секретом:

```bash
sudo ./tgweb-install.sh profile add mobile \
  --secret 0123456789abcdef0123456789abcdef \
  --carrier-mode websocket
```

Для генерации секрета с префиксом `dd` используется `--secret-prefix dd`.

Изменение Carrier mode:

```bash
sudo ./tgweb-install.sh profile set-carrier mobile websocket-lanes
```

Удаление дополнительного профиля. Операция требует явного подтверждения:

```bash
sudo ./tgweb-install.sh profile delete mobile --yes
```

Создание резервной копии профиля:

```bash
sudo ./tgweb-install.sh profile backup mobile
```

Импорт профиля из архива с созданием нового профиля или заменой существующего:

```bash
sudo ./tgweb-install.sh profile import /path/to/profile-backup.tar.gz --name mobile --yes
```

Замена системного профиля `default`:

```bash
sudo ./tgweb-install.sh profile import /path/to/profile-backup.tar.gz --replace-default --yes
```

Если архив содержит несколько профилей, необходимо указать `--entry` с точным путём к нужному файлу внутри архива. Список файлов можно получить командой:

```bash
tar -tzf /path/to/profile-backup.tar.gz
```

При импорте проверяются структура профиля, формат секрета и совместимость backend. Перед заменой `default` создаётся отдельная резервная копия текущего профиля. Параметр `--yes` обязателен, поскольку импорт изменяет рабочую конфигурацию.

### Управление публичным сайтом из командной строки

Назначить локальное HTTP-приложение в качестве `public_upstream`:

```bash
sudo ./tgweb-install.sh upstream set-url http://127.0.0.1:3000
```

Вернуться к обслуживанию сайта из локального каталога:

```bash
sudo ./tgweb-install.sh upstream set-dir /opt/telegram-web-proxy/data/website
```

Для `set-url` поддерживается локальный адрес вида `http://127.0.0.1:PORT`. После изменения конфигурации выполняется проверка `tproxy-server -check` и перезапуск службы. При неудачной проверке исходный `config.json` восстанавливается.

### Обслуживание и удаление компонентов из командной строки

Перезапуск установленных служб прокси:

```bash
sudo ./tgweb-install.sh services restart
```

Удаление decoy-сайта:

```bash
sudo ./tgweb-install.sh site remove --yes
```

Удаление выбранного веб-сервера:

```bash
sudo ./tgweb-install.sh web-server remove --yes
```

Команды удаления без `--yes` запрашивают подтверждение интерактивно. Удаление сайта затрагивает весь настроенный каталог сайта и его содержимое. Удаление веб-сервера может привести к прекращению внешнего доступа к Web Proxy.

## Ссылка подключения и QR-код

После установки или обновления скрипт выводит Telegram-ссылку и QR-код в терминале. Команда `config` повторно формирует ссылку и QR по текущей конфигурации.

PNG сохраняется в:

```text
/opt/telegram-web-proxy/qr/proxy-qr.png
```

Файл создаётся с правами `0600`, каталог QR — с ограниченными правами. Секрет, ссылка и QR-код дают доступ к прокси: не публикуйте и не передавайте их посторонним.

## Файлы и каталоги

Основной каталог приложения:

```text
/opt/telegram-web-proxy/
├── bin/       # бинарники и служебные скрипты
├── config/
│   ├── proxy/ # config.json, profiles.json, profiles/<имя>/profile.json
│   └── mtproxy/
├── data/
│   └── website/ # decoy-сайт по умолчанию
├── src/       # исходники tproxy-server и MTProxy
├── systemd/   # шаблоны/копии unit-файлов
├── qr/        # QR-код подключения
└── backups/   # резервные копии по умолчанию
```

Системные файлы и службы:

| Путь / имя | Назначение |
|---|---|
| `/opt/telegram-web-proxy/config/proxy/config.json` | Настройки tproxy-server, домен, адреса и каталог сайта |
| `/opt/telegram-web-proxy/config/proxy/profiles/` | Отдельный каталог настроек каждого профиля |
| `/opt/telegram-web-proxy/config/proxy/profiles/<имя>/profile.json` | Имя, секрет, backend и Carrier mode выбранного профиля |
| `/opt/telegram-web-proxy/config/proxy/profiles.json` | Сводный файл всех профилей для tproxy-server |
| `/opt/telegram-web-proxy/config/proxy/acme-email` | Email Let's Encrypt |
| `/opt/telegram-web-proxy/config/proxy/web-server` | Выбранный веб-сервер |
| `/opt/telegram-web-proxy/config/mtproxy/mtproxy.env` | Параметры MTProxy |
| `/opt/telegram-web-proxy/qr/proxy-qr.png` | QR-код подключения |
| `/usr/local/bin/tproxy-server` | Совместимая ссылка на бинарник tproxy-server |
| `/usr/local/bin/mtproxy` | Совместимая ссылка на бинарник MTProxy |
| `/usr/local/bin/refresh-mtproxy-config` | Совместимая ссылка на служебный скрипт |
| `/etc/caddy/Caddyfile` | Конфигурация Caddy |
| `/etc/nginx/sites-available/tproxy-server` | Конфигурация Nginx |
| `/etc/nginx/conf.d/tproxy-websocket-map.conf` | WebSocket map для Nginx |
| `/etc/letsencrypt/` | Сертификаты и настройки Certbot при использовании Nginx |
| `/etc/systemd/system/` | Установленные systemd units |
| `/var/www/letsencrypt` | ACME webroot |

Caddy и Nginx — альтернативные варианты: для Web Proxy одновременно используется выбранный веб-сервер. При переключении скрипт удаляет конфигурацию предыдущего веб-сервера, если она была зарегистрирована как текущая.

## Безопасность и важные замечания

- Не передавайте третьим лицам секрет MTProxy, Telegram-ссылку, QR-код и отчёт `config`.
- Не открывайте в интернет локальные relay/admin-порты и backend-порты MTProxy.
- Не запускайте `purge --yes`, не проверив, какой веб-сервер и decoy-сайт будут удалены.
- Существующий пользовательский сайт не перезаписывается при установке, если в целевом каталоге уже есть `index.html`.
- При обычном `uninstall` каталог сайта сохраняется. При `purge` скрипт удаляет только распознанный штатный decoy-сайт.
- Не размещайте собственные изменения в каталоге исходников upstream: при обновлении он синхронизируется с закреплённой версией.
- Перед изменениями на рабочем сервере создавайте резервную копию и проверяйте восстановление на тестовой системе.

## Справка

```bash
sudo ./tgweb-install.sh --help
```

## Используемые компоненты

- [telegramdesktop/tproxy-server](https://github.com/telegramdesktop/tproxy-server) — relay и Web Proxy.
- [Caddy](https://caddyserver.com/) — HTTPS, TLS и reverse proxy.
- [Nginx](https://nginx.org/) — альтернативный веб-сервер и reverse proxy.
- [Certbot](https://certbot.eff.org/) — выпуск и продление TLS-сертификатов для Nginx.
- [MTProxy](https://github.com/TelegramMessenger/MTProxy) — backend прокси.
- [qrencode](https://github.com/fukuchi/libqrencode) — генерация QR-кодов.
