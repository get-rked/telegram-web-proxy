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
cp docker/mtproxy/secret.example docker/mtproxy/secret
chmod 600 docker/mtproxy/secret
# Значение в secret должно совпадать с profiles[0].secret.
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

## MTProxy backend

Официальный MTProxy собирается из закреплённого upstream commit
`69f2f083b57bbd94932cb9f4f32155f33e719ff1`. Он запускается отдельным контейнером
в сетевом namespace relay и слушает внутренний порт `2398`; статистика доступна
только внутри namespace на `127.0.0.1:8888/stats`. Порт 2398 не публикуется на
хост. Relay подключает профиль к `127.0.0.1:2398`.

**Клиентский секрет должен быть одинаковым в двух местах:**
- `docker/mtproxy/secret` — 32 hex-символа, один newline допустим;
- `secret` соответствующего профиля в `docker/config/profiles.json`.

Сейчас пример в обоих файлах — тестовое значение. Перед использованием сгенерируйте
свой секрет командой `openssl rand -hex 16` и замените его в обоих файлах.
Автоматическая генерация и синхронизация появятся в bootstrap-этапе.

При первом старте контейнер загружает официальные `proxy-secret` и
`proxy-multi.conf` с Telegram и сохраняет их в volume `mtproxy-data`. Upstream
рекомендует обновлять routing config ежедневно; автоматический refresh пока не
добавлен. MTProxy запускается с одним worker по умолчанию.

Выбрав Caddy или Nginx, добавьте профиль `mtproxy` к команде запуска:

```bash
docker compose --profile caddy --profile mtproxy up -d --build
# либо:
docker compose --profile nginx --profile mtproxy up -d --build
```

Проверка состояния:

```bash
docker compose logs --tail=100 mtproxy
docker compose exec mtproxy curl -fsS http://127.0.0.1:8888/stats
```

## Панель и ограничения текущего этапа

Панель будет доступна по `https://DOMAIN/admin/`. SQLite хранится в именованном томе `panel-data`. Сейчас панель предоставляет просмотр статуса и списка профилей; изменение профилей из UI ещё не реализовано.

Автоматическая генерация и согласование конфигурации/секретов, ежедневное обновление MTProxy routing config, CRUD профилей, безопасный reload, backup/restore, расширенные метрики и миграция существующей установки ещё не реализованы. **Не разворачивайте эту экспериментальную ветку на рабочем прокси.**
