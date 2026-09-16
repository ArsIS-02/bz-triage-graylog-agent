# BZ Triage → Graylog (lightweight agent)

Используем BI.ZONE Triage как готовый коллектор телеметрии на macOS.
Скрипт-обёртка периодически запускает `bz_triage` и отправляет JSON-поток
напрямую в Graylog через `--dsthost` / `--dstport`.

## Идея

Не пишем свой EDR-агент. Берём подписанный бинарь BI.ZONE Triage,
который уже умеет собирать autoruns, процессы, сеть, пользователей,
подписи и хеши. Оборачиваем его в launchd-демон, который:

1. создаёт временный `outdir` через `mktemp -d`;
2. запускает `bz_triage` с нужными профилями;
3. стримит JSON-записи по TCP в Graylog;
4. удаляет `outdir` через `trap` (даже при падении);
5. следит за размером `outdir` через watchdog.

Graylog принимает поток через **Raw/Plaintext TCP Input** и разбирает
каждую JSON-строку через **JSON Extractor**.

## Схема

```text
┌─────────────┐     JSON Lines      ┌──────────────┐
│ bz_triage   │ ──────────────────> │   Graylog    │
│ (macOS)     │  --dsthost:port     │ Raw TCP +    │
└─────────────┘                     │ JSON Extractor│
       │                            └──────────────┘
       │ --outdir=/tmp/bzt.XXXXXX
       ▼
   временные файлы
   (удаляются trap'ом)
```

## Требования

- macOS (проверено на Mac mini M2, macOS 27.0 beta).
- Root-права для `bz_triage`.
- `bz_triage` версии 1.3.0.1+ (скачать с сайта BI.ZONE).
- Graylog с включённым Raw/Plaintext TCP Input.
- `jq` и `curl` не нужны — отправка идёт самим сенсором.

## Установка

1. Положить бинарь, например, в `/usr/local/bin/bz_triage`.
2. Скопировать `scripts/bzt-stream.sh` в `/usr/local/bin/`.
3. Поправить в скрипте переменные:
   - `TRIAGE_BIN`
   - `GRAYLOG_HOST`
   - `GRAYLOG_PORT`
   - `PROFILES`
   - `OUTDIR_MAX_MB`
4. Скопировать `plist` в `/Library/LaunchDaemons/` и загрузить:
   ```bash
   sudo launchctl load /Library/LaunchDaemons/com.example.bzt-collector.plist
   ```

## Настройка Graylog

1. Создать **Input → Raw/Plaintext TCP** на порту, например `5555`.
2. Добавить **Extractor → JSON**:
   - Key: пусто (парсить всё сообщение).
   - `try_extract_all`: `true`.
3. Для поля `EventTime` добавить **Date Extractor** с форматом
   `yyyy-MM-dd'T'HH:mm:ss.SSS`.
4. (Опционально) Pipeline Rule для удаления `file_content`, если он
   всё-таки попал в поток.

## Набор полей

Обязательные:
`SystemHostname`, `SystemMachineSN`, `event_type`, `event_type_vendor`,
`Action`, `file_path`, `file_name`, `file_sha256`, `file_sig_status`,
`file_sig_ident`, `cmdline`, `EventTime`, `inventory_task_name`,
`inventory_session_id`.

Рекомендуемые:
`dev_os`, `dev_ipv4`, `dev_users`, `file_owner_name`, `file_group_name`,
`cmdline_fingerprint`, `sensor_version`, `rule_name`.

Для сетевых профилей — все `net_*` поля.

**Отфильтровать:** `file_content`, `file_yara_*` (если YARA не нужна),
`file_tgt_*` (опционально).

Подробнее — в `docs/fields.md`.

## Безопасность и диск

- `bz_triage` всегда пишет `outdir` локально, даже при `--dsthost`.
- Без очистки за месяц накопятся десятки гигабайт.
- В скрипте используется `mktemp -d` + `trap cleanup EXIT INT TERM`.
- Watchdog убивает процесс, если `outdir` превысил `OUTDIR_MAX_MB`.

## Статус

- [x] Архитектура определена.
- [x] Черновик обёртки и launchd-plist.
- [x] Набор полей предложен.
- [ ] Проверка `--dsthost` через `nc -l`.
- [ ] Настройка JSON Extractor в Graylog.
- [ ] Прогон на реальном хосте и замер объёма.

## Лицензия

Скрипты — MIT. Сам `bz_triage` — собственность BI.ZONE, см. их лицензию.
