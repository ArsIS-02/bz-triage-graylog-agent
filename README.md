# bz-triage-graylog-agent

Лёгкий агент на базе [BI.ZONE Triage](https://bi.zone/) для отправки
телеметрии macOS в Graylog потоком.

## Идея

Не пишем свой EDR-агент. Используем `bz_triage` как готовый коллектор
и оборачиваем его в 3 `launchd`-агента с разной частотой и разными
наборами профилей. Данные уходят напрямую в Graylog через `nc`,
без промежуточных шипперов.

## Схема

```text
┌──────────────────┐   JSON Lines      ┌───────────────┐
│ bz_triage        │ ──────────────>   │   Graylog     │
│ + bzt-filter.pl  │  Raw TCP :<порт>  │  Raw/Plaintext│
│ + nc             │                   │  + JSON       │
└──────────────────┘                   │  Extractor    │
                                       └───────────────┘
```

## Три агента на каждом хосте

| Агент | Профили | Интервал | Зачем |
|-------|---------|----------|-------|
| `bzt-activity` | `hostinfo,netconn,processes,sessions,users` | 10 мин | Активность в реальном времени |
| `bzt-persistence` | `hostinfo,autoruns` | 30 мин | Мониторинг persistence-механизмов |
| `bzt-baseline` | `investigation` | раз в сутки, 03:00 | Полный снапшот для forensic |

Подробнее — в [`docs/architecture.md`](docs/architecture.md).

## Расписание по хостам (сдвиг минут)

Чтобы несколько Mac'ов не долбили Graylog одновременно, минуты запуска
разносятся. Пример для трёх хостов:

| Хост | activity | persistence |
|------|----------|-------------|
| **Хост #1** | `:00, :10, :20, :30, :40, :50` | `:05, :35` |
| **Хост #2** | `:02, :12, :22, :32, :42, :52` | `:07, :37` |
| **Хост #3** | `:04, :14, :24, :34, :44, :54` | `:09, :39` |

`baseline` у всех — 03:00. При большем числе хостов сдвиг — по 2 минуты
на каждый следующий.

## Требования

- macOS.
- Root-права.
- `bz_triage`: **arm64** для Apple Silicon, **amd64** для Intel.
- Graylog с Raw/Plaintext TCP Input.

## Установка

### 1. Бинарь

Положить `bz_triage` (правильной архитектуры) в `/usr/local/bin/bz_triage`:

```bash
sudo mkdir -p /usr/local/bin
sudo cp bz_triage-<версия>-darwin-<arm64|amd64> /usr/local/bin/bz_triage
sudo chmod 755 /usr/local/bin/bz_triage
sudo xattr -d com.apple.quarantine /usr/local/bin/bz_triage 2>/dev/null || true
```

### 2. Скрипты

```bash
sudo cp scripts/bzt-stream.sh /usr/local/bin/
sudo cp scripts/bzt-filter.pl /usr/local/bin/
sudo cp scripts/bzt-diagnose.sh /usr/local/bin/
sudo chmod 755 /usr/local/bin/bzt-stream.sh \
               /usr/local/bin/bzt-filter.pl \
               /usr/local/bin/bzt-diagnose.sh
```

### 3. Настройки подключения

Открыть `/usr/local/bin/bzt-stream.sh` и указать адрес Graylog:

```bash
GRAYLOG_HOST="<IP-сервера Graylog>"
GRAYLOG_PORT="<порт-Input'а>"
```

Пример:

```bash
GRAYLOG_HOST="10.0.0.5"
GRAYLOG_PORT="9095"
```

### 4. Plist-ы

```bash
sudo cp scripts/ru.bi.zone.bzt-*.plist /Library/LaunchDaemons/
sudo chown root:wheel /Library/LaunchDaemons/ru.bi.zone.bzt-*.plist
sudo chmod 644 /Library/LaunchDaemons/ru.bi.zone.bzt-*.plist
```

**Важно:** в `scripts/ru.bi.zone.bzt-activity.plist` и
`scripts/ru.bi.zone.bzt-persistence.plist` минуты запуска заданы для
**первого хоста** (`:00/:05`). Для второго и третьего хоста нужно
отредактировать `StartCalendarInterval` по таблице выше.

### 5. Загрузка агентов

```bash
for p in activity persistence baseline; do
    sudo launchctl bootout   system/ru.bi.zone.bzt-${p} 2>/dev/null
    sudo launchctl bootstrap system /Library/LaunchDaemons/ru.bi.zone.bzt-${p}.plist
done

sudo launchctl list | grep bzt
```

### 6. Диагностика

```bash
sudo /usr/local/bin/bzt-diagnose.sh
echo "EXIT=$?"
```

## Диагностика

`bzt-diagnose.sh` проверяет:

- бинарь и скрипты (существование, arch, права);
- три plist-а и их загрузку в `launchd`;
- статус каждого агента (`state`, `runs`, `last exit code`);
- сеть до Graylog;
- логи: последние `start`/`done`, свежесть последнего успеха;
- зависшие процессы `bz_triage`/`bzsenedrcore`;
- залипшие локи и временные каталоги;
- свежие ошибки в `.err`.

Exit code: `0` — всё ок, `1` — предупреждения, `2` — критично.

## Документация

- [`docs/architecture.md`](docs/architecture.md) — почему 3 агента, Calendar vs Interval
- [`docs/fields.md`](docs/fields.md) — какие поля отправляются
- [`docs/graylog-setup.md`](docs/graylog-setup.md) — настройка Graylog (heap, retention, Extractor)
- [`docs/troubleshooting.md`](docs/troubleshooting.md) — все грабли

## Известные грабли (кратко)

- На macOS нет GNU `timeout` — не использовать в скриптах.
- `nc -w 180` вешает скрипт на 3 минуты. Правильно: `nc -G 5 -w 1`.
- `set -e` + `nc` на большом объёме = падение без `done`.
- Локи должны быть per-profile + с автоочисткой по PID.
- `bootstrap` без `kickstart` не активирует таймер `StartInterval` —
  поэтому используем `StartCalendarInterval` + `RunAtLoad=true`.
- `bz_triage` оставляет `edr-data*` в `/tmp` — чистим через `find -mmin +10`.
- В Graylog правильно `http_publish_uri`, а не `publish_uri`.
- Heap Graylog и OpenSearch — минимум 4 ГБ.
- Retention обязателен, иначе диск забьётся за месяц.

Подробно — в [`docs/troubleshooting.md`](docs/troubleshooting.md).

## Лицензия

Скрипты — MIT. `bz_triage` — собственность BI.ZONE.
