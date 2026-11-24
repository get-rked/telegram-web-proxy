# Telegram Web Proxy — Docker Manager

**Версия скрипта: 1.2.3**

Установщик разворачивает и обслуживает Telegram Web Proxy только в Docker. Поддерживается Ubuntu/Debian x86_64 с systemd и apt. В состав проекта входят tproxy-server, MTProxy, Caddy или Nginx, панель управления и Fail2ban.

**Native → Docker миграции нет.** Установщик не ищет прежнюю native-конфигурацию, не читает её параметры и не переносит файлы или службы. Если каталог `/opt/telegram-web-proxy` уже существует и не является актуальным Git checkout проекта, при первом развёртывании он сохраняется целиком в резервной копии и отдельно переименованном каталоге; содержимое не анализируется и не импортируется.

## Возможности

- Чистая Docker-установка и обновление Docker-образов.
- Выбор Caddy (автоматический TLS) или Nginx (собственные TLS-сертификаты).
- Настройка домена и email Let's Encrypt.
- Отдельный выбор relay- и admin-портов с проверкой занятости до запуска контейнеров.
- Генерация Web Proxy секрета или ввод собственного; формат без префикса или с `dd`.
- Сохранение выбранного `dd` в профиле Web Proxy и нормализация секрета для MTProxy.
- Защищённая панель управления, Fail2ban, диагностика, логи и резервные копии.
- Сохранение пользовательского сайта и Docker volumes при штатном обновлении.

## Требования и подготовка

- Ubuntu или Debian, архитектура x86_64.
- Root или запуск через `sudo`.
- DNS A-запись домена на публичный IPv4 сервера.
- Доступные входящие TCP-порты 80 и 443.
- Свободные выбранные relay/admin порты на хосте. По умолчанию это 8080 и 8081; при занятости установщик предложит выбрать другие.
- Доступ в интернет для установки пакетов и сборки образов.

## Архитектура и порты

| Порт | Назначение | Доступ |
|---|---|---|
| TCP 80 | HTTP, редирект и ACME | Открыть извне |
| TCP 443 | HTTPS, сайт и Web Proxy | Открыть извне |
| TCP 8080 | Relay tproxy-server по умолчанию | Внутри Docker, loopback |
| TCP 8081 | Admin/health по умолчанию | Внутри Docker, loopback |
| TCP 2398 | Backend MTProxy | Внутренний |
| TCP 8888 | Статистика MTProxy | Внутренний |

Relay и admin-порты задаются в `.env` как `RELAY_PORT` и `ADMIN_PORT`, а в конфигурации приложения привязываются к `127.0.0.1`. Эти порты не публикуются на хост и не должны открываться в firewall. Установщик дополнительно проверяет, что выбранные номера не заняты локальными службами, чтобы не повторять запуск с конфликтующими значениями.

## Быстрый старт

Подготовь DNS и разреши входящие TCP 80/443. Затем запусти одноразовый установщик:

```bash
curl -fsSL https://raw.githubusercontent.com/get-rked/telegram-web-proxy/feature/docker-web-panel/tgweb-install.sh -o /tmp/tgweb-install.sh
sudo bash /tmp/tgweb-install.sh
```

После загрузки репозитория открой Docker Manager и выбери **«Новая Docker-установка»**. Установщик последовательно запросит:

1. Reverse proxy: Caddy или Nginx.
2. Домен и email.
3. Relay-порт (по умолчанию 8080).
4. Admin-порт (по умолчанию 8081).
5. Формат секрета Web Proxy: обычный или с префиксом `dd`.
6. Сгенерировать секрет или ввести собственный.

Если порт занят, установщик не продолжит запуск с этим значением: он покажет владельца и ближайший свободный порт, после чего попросит повторить ввод. Relay/admin-порты записываются в `.env` и используются bootstrap, relay и metrics bridge.

Основной установщик после первого запуска:
```bash
sudo /opt/telegram-web-proxy/tgweb-install.sh
```

## Команды

Новая Docker-установка:
```bash
sudo /opt/telegram-web-proxy/tgweb-install.sh docker install
```

Установка с параметрами:
```bash
sudo /opt/telegram-web-proxy/tgweb-install.sh docker install \
  --web-server caddy \
  --hostname proxy.example.com \
  --email admin@example.com \
  --relay-port 18080 \
  --admin-port 18081 \
  --secret-prefix dd
```

Можно передать собственный секрет:
```bash
sudo /opt/telegram-web-proxy/tgweb-install.sh docker install \
  --web-server caddy --hostname proxy.example.com --email admin@example.com \
  --relay-port 18080 --admin-port 18081 --secret-prefix dd \
  --secret dd0123456789abcdef0123456789abcdef
```

Обслуживание:
```bash
sudo /opt/telegram-web-proxy/tgweb-install.sh docker update
sudo /opt/telegram-web-proxy/tgweb-install.sh docker status
sudo /opt/telegram-web-proxy/tgweb-install.sh docker restart
sudo /opt/telegram-web-proxy/tgweb-install.sh docker logs relay
sudo /opt/telegram-web-proxy/tgweb-install.sh docker backup
sudo /opt/telegram-web-proxy/tgweb-install.sh docker uninstall
sudo /opt/telegram-web-proxy/tgweb-install.sh docker purge
```

`docker uninstall` удаляет контейнеры и сеть, сохраняя конфигурации и volumes. `docker purge` удаляет контейнеры и локальные образы; удаление volumes требует явного `--volumes` и подтверждения.

## Конфигурация и секреты

- `.env` содержит домен, email, relay/admin-порты и параметры MTProxy.
- `docker/config/` содержит конфигурацию relay и token key.
- `docker/profiles/` содержит профили Web Proxy.
- `docker/backend/secret` содержит внутренние секреты backend.
- `docker/private/` и `docker/private-credentials/` содержат приватную авторизацию панели и реквизиты доступа.
- Docker volumes хранят данные панели, TLS, backend и Fail2ban.

Префикс `dd` сохраняется в секрете профиля Web Proxy. Для MTProxy bootstrap записывает тот же секрет без префикса — формат, который ожидает MTProxy. Не публикуй `.env`, `docker/private/`, `docker/private-credentials/`, `docker/backend/secret`, `docker/config/` и резервные копии.

## Nginx

Для чистой установки с Nginx заранее размести сертификаты:

- `docker/nginx/certs/fullchain.pem`
- `docker/nginx/certs/privkey.pem`

Для автоматического TLS выбери Caddy.

## Проверка

Проверь состояние контейнеров и логи:

```bash
sudo /opt/telegram-web-proxy/tgweb-install.sh docker status
sudo /opt/telegram-web-proxy/tgweb-install.sh docker logs relay
sudo /opt/telegram-web-proxy/tgweb-install.sh docker logs caddy
sudo /opt/telegram-web-proxy/tgweb-install.sh docker logs backend
```

HTTP-ответ сайта сам по себе не доказывает работоспособность Web Proxy — обязательно проверь фактическое подключение в Telegram-клиенте.

## Используемые компоненты

- [telegramdesktop/tproxy-server](https://github.com/telegramdesktop/tproxy-server) — relay и Web Proxy.
- [Caddy](https://caddyserver.com/) — TLS и reverse proxy.
- [Nginx](https://nginx.org/) — альтернативный reverse proxy.
- Внутренний backend текущей реализации relay — служебный компонент Web Proxy.
- [Fail2ban](https://github.com/fail2ban/fail2ban) — защита панели и сетевых endpoints.
