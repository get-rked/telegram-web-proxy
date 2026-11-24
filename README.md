# Telegram Web Proxy — Docker Manager

**Версия скрипта: 1.2.2**

Основной способ установки и обслуживания — единый Docker Manager для Ubuntu/Debian x86_64. При первом запуске установщик самостоятельно сохраняет прежнюю установку (если она есть) и разворачивает репозиторий в **/opt/telegram-web-proxy/**. После выбора установки в меню он устанавливает Docker Engine и Compose, затем предлагает перенести действующую native-конфигурацию или выполнить чистую установку.

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
4. Запускает единое интерактивное меню Docker Manager.
5. При выборе установки устанавливает Docker Engine и Compose, затем выполняет перенос или чистую установку.

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


## Параметры Docker-установки

Для чистой установки доступны параметры:

| Параметр | Описание |
|---|---|
| `--web-server caddy\|nginx` | Выбор reverse proxy; по умолчанию Caddy |
| `--hostname FQDN` | Домен Web Proxy |
| `--email EMAIL` | Email для ACME/Let's Encrypt |

Пример:
```bash
sudo /opt/telegram-web-proxy/tgweb-install.sh docker install --web-server caddy --hostname proxy.example.com --email admin@example.com
```

Для переноса существующей native-установки домен и параметры берутся из сохранённой конфигурации. Caddy получает TLS автоматически. Для чистой установки с Nginx на данный момент нужно заранее положить сертификаты в `docker/nginx/certs/fullchain.pem` и `docker/nginx/certs/privkey.pem`.

Параметры MTProxy (`MTPROXY_WORKERS`, `MTPROXY_MAX_CONNECTIONS`, `MTPROXY_NAT_INFO`, `MTPROXY_REFRESH_INTERVAL`) задаются в `.env` в каталоге проекта. Приватные настройки и сгенерированные ключи находятся в `docker/` и не должны публиковаться.

## Настройки Web Proxy и профили

При переносе native-конфигурации установщик сохраняет профильные настройки и переносит их в Docker. При чистой установке создаётся профиль `default`; управление дополнительными профилями через Docker-панель будет расширяться отдельно. Старые команды `profile`, `upstream`, `services`, `site` и `web-server` относятся к native-менеджеру и не предназначены для текущего Docker-режима.

## Файлы и каталоги

Единый каталог проекта и установщика:
```text
/opt/telegram-web-proxy/
├── tgweb-install.sh
├── docker-compose.yml
├── .env                         # домен, ACME email и параметры MTProxy
├── docker/
│   ├── config/                  # конфигурация relay и token.key
│   ├── profiles/                # профили Web Proxy
│   ├── mtproxy/                 # секреты и runtime-файлы MTProxy
│   ├── private/                 # приватная авторизация панели
│   ├── private-credentials/     # реквизиты панели
│   ├── generated/               # сгенерированные маршруты панели
│   ├── site/                    # публичный сайт
│   ├── security/                # Fail2ban и журналы безопасности
│   ├── Caddyfile
│   └── nginx/
├── panel/                       # исходники панели
└── bin/, config/, data/, src/, systemd/, qr/, backups/
                                # сохранённые файлы прежней native-установки
```

Резервная копия исходной native-установки создаётся в `/var/backups/telegram-web-proxy/`, а её конфигурация для миграции — в `/var/lib/telegram-web-proxy/`. Docker-резервные копии файлов проекта находятся в `/var/backups/telegram-web-proxy-docker/`.

Docker volumes:
- `panel-data` — база и состояние панели;
- `caddy-data`, `caddy-config` — состояние TLS и Caddy;
- `mtproxy-data` — данные MTProxy;
- `fail2ban-data` — состояние Fail2ban.

## Ссылка подключения и QR-код

В текущем Docker Manager автоматическое формирование Telegram-ссылки и QR-кода пока не реализовано. Для проверки Web Proxy используй домен, указанный при установке, и обязательно проверь фактическое подключение в Telegram-клиенте. HTTP-ответ сайта сам по себе не доказывает, что Web Proxy работает.

## Безопасность и важные замечания

- Не публикуй `.env`, `docker/private/`, `docker/private-credentials/`, `docker/mtproxy/secret`, `docker/config/` и резервные копии: в них могут находиться ключи и учётные данные.
- Не открывай в интернет внутренние relay/admin-порты и backend-порты MTProxy.
- `docker uninstall` удаляет контейнеры и сеть, сохраняя конфигурации и volumes.
- `docker purge` без `--volumes` удаляет контейнеры и локальные образы, но сохраняет volumes. Флаг `--volumes` удаляет данные панели, TLS, MTProxy и Fail2ban.
- При переносе native-службы останавливаются, но их unit-файлы и автозапуск сохраняются для отката. После успешной проверки Docker нужно отдельно решить вопрос с отключением автозапуска native-служб, чтобы они не пытались занять порты после перезагрузки.
- Пользовательский сайт сохраняется при обновлении Docker Manager.

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
