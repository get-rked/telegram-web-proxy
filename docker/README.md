# Docker deployment — экспериментальная ветка

Это первый этап Docker-native архитектуры: сборка закреплённой версии Telegram Desktop relay из исходников, панель в отдельном непривилегированном контейнере, SQLite для журнала аудита и Caddy как TLS reverse proxy.

**Это пока не полная замена установщику.** Контейнер MTProxy, генерация конфигурации и секретов при первом запуске, изменение профилей из UI, резервное копирование, метрики и миграция существующей установки ещё не реализованы. Не разворачивайте этот этап на рабочем прокси.

Подготовка:

```bash
cp .env.example .env
# Укажите DOMAIN, ACME_EMAIL и PANEL_PASSWORD (не менее 16 символов).
mkdir -p docker/config
cp docker/config/config.example.json docker/config/config.json
cp docker/config/profiles.example.json docker/config/profiles.json
# Замените hostname, секрет и backend на реальные значения.
```

Запуск после реализации полного набора сервисов:

```bash
docker compose config
docker compose build
docker compose up -d
docker compose logs -f
```

Панель будет доступна по `https://DOMAIN/admin/`. SQLite хранится в именованном томе `panel-data`. Конфиги прокси монтируются в панель только для чтения. Docker socket и host network не используются.
