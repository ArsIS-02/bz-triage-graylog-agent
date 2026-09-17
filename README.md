# bz-triage-graylog-agent

Лёгкий агент на базе [BI.ZONE Triage](https://bi.zone/) для отправки
телеметрии macOS в Graylog потоком.

## Идея

Не пишем свой EDR-агент. Используем `bz_triage` как готовый коллектор
и оборачиваем его в 3 `launchd`-агента с разной частотой и разными
наборами профилей. Данные уходят напрямую в Graylog через `nc -w`,
без промежуточных шипперов.

## Схема

```text
┌──────────────────┐   JSON Lines   ┌───────────────┐
│ bz_triage        │ ────────────>  │   Graylog     │
│ + bzt-filter.pl  │  Raw TCP :9095 │  Raw/Plaintext│
│ + nc             │                │  + JSON       │
└──────────────────┘                │  Extractor    │
                                    └───────────────┘
```

## Три агента на каждом хосте

| Агент | Профили | Интервал | Зачем |
|-------|---------|----------|-------|
| `bzt-activity` | `hostinfo,netconn,processes,sessions,users` | 600 сек (10 мин) | Активность в реальном времени |
| `bzt-persistence` | `hostinfo,autoruns` | 1800 сек (30 мин) | Мониторинг persistence-механизмов |
| `bzt-baseline` | `investigation` | раз в сутки, 03:00 | Полный снапшот для forensic |

Почему именно так — см. [`docs/architecture.md`](docs/architecture.md).

## Требования

- macOS (проверено на Mac mini M2, MacBook Pro M4 Pro, MacBook Pro Intel).
- Root-права.
- `bz_triage` **arm64** для Apple Silicon, **amd64** для Intel.
- Graylog с Raw/Plaintext TCP Input на 9095.

## Установка

1. Положить бинарь `bz_triage` (правильной архитектуры) в `/usr/local/bin/bz_triage`.
2. Скопировать скрипты:

   ```bash
   sudo cp scripts/bzt-stream.sh /usr/local/bin/
   sudo cp scripts/bzt-filter.pl /usr/local/bin/
   sudo chmod 755 /usr/local/bin/bzt-stream.sh /usr/local/bin/bzt-filter.pl
   ```

3. Поправить `GRAYLOG_HOST` и `GRAYLOG_PORT` в `/usr/local/bin/bzt-stream.sh`.

4. Установить три plist-а:

   ```bash
   sudo cp scripts/ru.bi.zone.bzt-*.plist /Library/LaunchDaemons/
   sudo chown root:wheel /Library/LaunchDaemons/ru.bi.zone.bzt-*.plist
   sudo chmod 644 /Library/LaunchDaemons/ru.bi.zone.bzt-*.plist
   ```

5. Загрузить:

   ```bash
   for p in activity persistence baseline; do
       sudo launchctl bootstrap system /Library/LaunchDaemons/ru.bi.zone.bzt-${p}.plist
   done
   sudo launchctl list | grep bzt
   ```

6. Форс-запуск для проверки:

   ```bash
   sudo launchctl kickstart -k system/ru.bi.zone.bzt-activity
   sudo launchctl kickstart -k system/ru.bi.zone.bzt-persistence
   sleep 90
   sudo tail -3 /var/log/bzt-activity.log
   sudo tail -3 /var/log/bzt-persistence.log
   ```

## Документация

- [`docs/architecture.md`](docs/architecture.md) — почему 3 агента
- [`docs/fields.md`](docs/fields.md) — какие поля отправляются
- [`docs/graylog-setup.md`](docs/graylog-setup.md) — настройка Graylog
- [`docs/troubleshooting.md`](docs/troubleshooting.md) — все грабли

## Известные грабли (кратко)

- `timeout` отсутствует на macOS — не использовать в скриптах.
- `set -e` + `nc` на большом объёме = падение без `done`.
- Локи должны быть per-profile + с автоочисткой по PID.
- В Graylog правильно `http_publish_uri`, а не `publish_uri`.
- Heap Graylog и OpenSearch — минимум 4 ГБ.
- Retention обязателен, иначе диск забьётся за месяц.

Подробно — в [`docs/troubleshooting.md`](docs/troubleshooting.md).

## Лицензия

Скрипты — MIT. `bz_triage` — собственность BI.ZONE.
