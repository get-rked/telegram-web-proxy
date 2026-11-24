# Docker deployment — экспериментальная ветка

Это экспериментальная Docker-native архитектура: закреплённая версия Telegram relay, отдельная панель управления, SQLite для аудита и выбираемый reverse proxy.

**Reverse proxy можно выбрать:**
- **Caddy** — автоматическое получение и продление TLS-сертификатов Let's Encrypt.
- **Nginx** — отдельная конфигурация для TLS-сертификата, который вы заранее размещаете на хосте.

Запускайте только один reverse proxy одновременно: оба используют опубликованные relay порты 80 и 443.

## Подготовка

```bash
cp .env.example .env
# Укажите DOMAIN, ACME_EMAIL и PANEL_PASSWORD (не менее 16 символов).
mkdir -p docker/config
cp docker/config/config.example.json docker/config/config.json
cp docker/config/profiles.example.json docker/config/profiles.json
# Замените hostname, секрет и backend на реальные значения.
```

## Вариант 1: Caddy (автоматический TLS)

DNS-запись домена должна указывать на сервер, а входящие TCP-порты 80 и 443 должны быть доступны.

```bash
docker compose --profile caddy config
docker compose --profile caddy build
docker compose --profile caddy up -d
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
docker compose --profile nginx config
docker compose --profile nginx build
docker compose --profile nginx up -d
docker compose logs -f nginx
```

Nginx перенаправляет HTTP на HTTPS, обслуживает панель по `/admin` и передаёт остальные запросы relay. Автоматическое получение/обновление сертификатов для Nginx пока не входит в эту конфигурацию — обновляйте файлы сертификата на хосте и перезапускайте Nginx после обновления:

```bash
docker compose --profile nginx restart nginx
```

## Панель и ограничения текущего этапа

Панель будет доступна по `https://DOMAIN/admin/`. SQLite хранится в именованном томе `panel-data`. Сейчас панель предоставляет просмотр статуса и списка профилей; изменение профилей из UI ещё не реализовано.

Контейнер MTProxy, автоматическая генерация конфигурации/секретов, CRUD профилей, безопасный reload, backup/restore, расширенные метрики и миграция существующей установки ещё не реализованы. **Не разворачивайте эту экспериментальную ветку на рабочем прокси.**
