# Docker deployment — экспериментальная ветка

Это Docker-архитектура: закреплённая версия Telegram relay, отдельная панель управления, SQLite для аудита и выбираемый reverse proxy.

**Reverse proxy можно выбрать:**
- **Caddy** — автоматическое получение и продление TLS-сертификатов Let's Encrypt.
- **Nginx** — отдельная конфигурация для TLS-сертификата, который вы заранее размещаете на хосте.

Запускайте только один reverse proxy одновременно: оба используют опубликованные relay порты 80 и 443.

## Подготовка\n\nУстановка разворачивает Telegram Web Proxy: HTTPS-транспорт обслуживает `tproxy-server` через Caddy или Nginx. Для текущей версии relay нужен локальный MTProto backend на `127.0.0.1:2398`; он работает только внутри сетевого namespace relay и не является самостоятельным публичным прокси.

```bash
cp .env.example .env
# Укажите DOMAIN и ACME_EMAIL; при необходимости измените RELAY_PORT и ADMIN_PORT.
# Логин, пароль и секретный URL панели генерируются автоматически.
# config.json, profiles.json, token.key и общий MTProxy secret
# будут созданы автоматически при первом запуске.
# DOMAIN должен быть настоящим DNS-именем вашего сервера.
```

## Вариант 1: Caddy (автоматический TLS)

DNS-запись домена должна указывать на сервер, а входящие TCP-порты 80 и 443 должны быть доступны.

```bash
docker compose --profile caddy --profile webproxy config
docker compose --profile caddy --profile webproxy build
docker compose --profile caddy --profile webproxy up -d
docker compose logs -f caddy
```

Caddy самостоятельно запросит и будет продлевать сертификат. Данные сертификатов хранятся в volume `caddy-data`.

## Вариант 2: Nginx (свой TLS-сертификат)

Nginx ожидает два файла на хосте:

- `docker/nginx/certs/fullchain.pem` — сертификат и цепочка.
- `docker/nginx/certs/privkey.pem` — закрытый ключ.

Получите сертификат любым удобным способом (например, Certbot на хосте), затем:

```bash
mkdir -p docker/nginx/certs
# Поместите fullchain.pem и privkey.pem в эту директорию.
chmod 600 docker/nginx/certs/privkey.pem
docker compose --profile nginx --profile webproxy config
docker compose --profile nginx --profile webproxy build
docker compose --profile nginx --profile webproxy up -d
docker compose logs -f nginx
```

Nginx перенаправляет HTTP на HTTPS, обслуживает панель по случайному приватному Base Path и передаёт остальные запросы relay. Автоматическое получение/обновление сертификатов для Nginx пока не входит в эту конфигурацию — обновляйте файлы сертификата на хосте и перезапускайте Nginx после обновления:

```bash
docker compose --profile nginx restart nginx
```

## Защита панели и Fail2ban

Fail2ban запускается вместе с Docker Compose в host network mode, чтобы блокировки
действовали на входящий трафик Docker, а не только внутри отдельного контейнера.
Он использует цепочку `DOCKER-USER` и отдельную цепочку `TPROXY-F2B`; правила
не очищают и не заменяют существующие firewall-правила хоста.

Включены три сценария:
- `tproxy-panel`: неудачные попытки входа в панель — блокировка на
  час с увеличением срока при повторных нарушениях;
- `tproxy-caddy-probes`: повторные запросы к типовым секретным и административным
  путям вроде `/.env`, `/wp-admin`, `/phpmyadmin` и `/xmlrpc.php`;
- `nginx-botsearch`: сигнатуры сканирования для Nginx access log.

Панель пишет неуспешные попытки входа в `docker/security/logs/auth.log`.
Reverse proxy пишет в access log только обращения к характерным сканерским путям
(обычный Web Proxy трафик не записывается); Caddy ограничивает размер и срок хранения
этих логов. Дополнительно сама панель ограничивает
повторный подбор: после 10 неверных попыток с одного IP за 10 минут следующие
запросы получают HTTP 429 на 15 минут. Для Nginx включён лимит 30 запросов в минуту
с burst 20 на сгенерированный приватный Base Path; Caddy использует блокировку неуспешной авторизации через
Fail2ban и встроенный лимит панели. Для Cloudflare proxy в Caddy и Nginx настроены официальные доверенные IPv4/IPv6
диапазоны Cloudflare и извлечение `CF-Connecting-IP`; заголовок принимается только
от адресов из этих диапазонов. Диапазоны также добавлены в `ignoreip`, чтобы
ошибка конфигурации не привела к блокировке edge-узла Cloudflare. Список диапазонов
сверяется с официальным API `https://api.cloudflare.com/client/v4/ips`; при
изменениях Cloudflare обновите CIDR в `docker/Caddyfile`, `docker/nginx/default.conf`
и `docker/security/fail2ban/jail.d/`. Панель получает
проверенный адрес через `X-Real-IP`: Caddy формирует его из фактического соединения,
Nginx использует `$remote_addr`. Не публикуйте порт панели напрямую и не
подключайте к её внутренней сети недоверенные контейнеры.

Проверка и просмотр блокировок:

```bash
docker compose ps fail2ban
docker compose logs --tail=100 fail2ban
docker compose exec fail2ban fail2ban-client status
docker compose exec fail2ban fail2ban-client status tproxy-panel
```

Разблокировать конкретный адрес:

```bash
docker compose exec fail2ban fail2ban-client set tproxy-panel unbanip 203.0.113.10
```

Для безопасного allowlist добавляйте доверенные адреса в `ignoreip` соответствующего
jail-файла до запуска. Не добавляйте широкие публичные диапазоны: это отключит
защиту для целых сетей. Для прямого подключения блокировка применяется на уровне Docker-хоста через
`DOCKER-USER`. При проксировании через Cloudflare сетевой пакет приходит от edge-IP,
поэтому Fail2ban дополнительно создаёт отдельную запись блокировки для каждого jail
в `docker/security/logs/banlist`; панель проверяет её по реальному IP посетителя и
возвращает HTTP 429. Записи автоматически перестают действовать через 7 дней
(максимальный срок бана в настройке). Это позволяет блокировать конкретного
посетителя за Cloudflare, не блокируя общий IP Cloudflare для остальных.

## Внутренний MTProto backend Web Proxy

Важно: этот контейнер — **внутренний backend**, необходимый текущей реализации `tproxy-server` для завершения MTProto-потоков, приходящих через Web Proxy. Он не публикует отдельный MTProxy-порт в интернет и не формирует ссылку `tg://proxy`. Пользователю выдаётся только ссылка Web Proxy (`t.me/webproxy`). Удалить backend без замены реализации relay нельзя: Web Proxy перестанет передавать трафик Telegram.\n\nОфициальный MTProxy собирается из закреплённого upstream commit
`69f2f083b57bbd94932cb9f4f32155f33e719ff1`. Он запускается отдельным контейнером
в сетевом namespace relay и слушает внутренний порт `2398`; статистика доступна
только внутри namespace на `127.0.0.1:8888/stats`. Порт 2398 не публикуется на
хост. Relay подключает профиль к `127.0.0.1:2398`.

**Секреты должны совпадать в двух источниках:**
- `docker/mtproxy/secret` — по одному 32-hex секрету на строку;
- `secret` каждого профиля в `docker/profiles/profiles.json`.

Bootstrap сверяет полный набор секретов и останавливается при несовпадении.
Префикс `dd` сохраняется в профиле Web Proxy, но снимается при формировании
аргумента `-S` для MTProxy. Все существующие профили передаются MTProxy через
повторяющиеся аргументы `-S`. При первом запуске без готовых файлов bootstrap
создаёт default и генерирует секрет атомарно. При изменении hostname существующий
config.json предварительно резервируется.

При первом старте контейнер загружает официальные `proxy-secret` и
`proxy-multi.conf` с Telegram и сохраняет их в volume `mtproxy-data`. Отдельный
непривилегированный exporter передаёт статистику MTProxy панели через приватную
Docker-сеть; исходный endpoint `8888` остаётся доступен только по loopback.
Upstream рекомендует обновлять routing config ежедневно. Контейнер обновляет
его каждые 24 часа (интервал настраивается через `MTPROXY_REFRESH_INTERVAL` в
секундах), атомарно заменяет файл и перезапускает MTProxy. Если новый конфиг не
позволяет процессу запуститься, предыдущая версия восстанавливается. Секрет
Telegram `proxy-secret` обновляется только при первоначальном скачивании.
MTProxy запускается с одним worker по умолчанию.

Выбрав Caddy или Nginx, добавьте профиль `mtproxy` к команде запуска:

```bash
docker compose --profile caddy --profile webproxy up -d --build
# либо:
docker compose --profile nginx --profile webproxy up -d --build
```

Проверка состояния:

```bash
docker compose logs --tail=100 mtproxy
docker compose exec mtproxy curl -fsS http://127.0.0.1:8888/stats
```

## Диагностика, метрики и резервные копии

В панели доступны проверки relay `/healthz` и `/readyz`, доступности MTProxy
stats, а также файла профилей. Метрики включают CPU, RAM, диск контейнера, число
горутин панели, активные сессии/потоки relay, счётчики ошибок, объём трафика и
основные значения MTProxy stats. Показатели relay берутся из официального
Prometheus endpoint закреплённого upstream.

Резервная копия создаётся вручную из панели и содержит `config.json`,
`profiles.json` и manifest в tar.gz. Архивы имеют права `0600`, доступны для
скачивания, автоматически ограничены двадцатью последними копиями. Manifest версии 2 содержит SHA-256 для `config.json` и `profiles.json`;
восстановление проверяет обе суммы, схему профилей и архив до начала записи.
Затем создаются дополнительные копии текущих файлов, `config.json` и
`profiles.json` заменяются атомарно, а список MTProxy-секретов синхронизируется
с восстановленными профилями. При ошибке записи профилей конфигурация откатывается.
Старые архивы manifest версии 1 остаются поддерживаемыми без проверки SHA-256.

## Панель и ограничения текущего этапа

При первом запуске bootstrap генерирует случайный приватный Base Path, логин и пароль панели. Реквизиты выводятся в лог bootstrap один раз и сохраняются в `docker/private-credentials/panel-credentials.txt` с правами `0600` (файл доступен только root на хосте). Хеш пароля и соль хранятся отдельно в `docker/private/panel-auth.json`; сгенерированные route-файлы для Caddy и Nginx находятся в `docker/generated/` и исключены из Git. Base Path не записывается в access log. При повторном запуске bootstrap сохраняет существующие реквизиты. После установки посмотреть реквизиты можно командой `sudo cat docker/private-credentials/panel-credentials.txt` или через `docker compose logs bootstrap` сразу после первого запуска.\n\nПанель использует собственную адаптивную форму входа и защищённую HttpOnly/Secure/SameSite cookie-сессию (12 часов); стандартный HTTP Basic Auth не используется. SQLite хранится в именованном томе `panel-data`. Из панели можно создавать, редактировать и удалять профили. Секрет нового профиля показывается один раз при создании; список профилей не раскрывает секреты. Профиль `default` нельзя удалить или переименовать, поскольку его секрет синхронизирован с MTProxy.

Изменения сохраняются атомарно, перед записью создаётся резервная копия `profiles.json`. Admin API relay остаётся привязанным к loopback; порт задаётся через `ADMIN_PORT` в `.env` (по умолчанию 8081). Stats bridge в namespace relay проксирует только фиксированные endpoints /healthz, /readyz, /metrics и /stats на внутренний порт 9090; этот порт не публикуется на хост. Relay-supervisor проверяет новую конфигурацию и перезапускает relay только после успешной проверки. При невалидном файле текущий relay продолжает работать. Применение обновления вызывает кратковременный перезапуск relay.
