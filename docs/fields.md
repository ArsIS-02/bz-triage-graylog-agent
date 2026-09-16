# Набор полей для отправки в Graylog

`bz_triage` шлёт JSON Lines — каждая запись отдельной строкой. Все поля,
которые остались в JSON, попадут в Graylog через Raw TCP Input и JSON
Extractor.

Ниже — рекомендованный минимум и что лучше отфильтровать.

## Обязательные поля

Эти поля нужны для идентификации хоста, события и объекта.

| Поле | Назначение |
|------|------------|
| `SystemHostname` | Имя хоста |
| `SystemMachineSN` | Серийный номер (на случай дублирования имён) |
| `event_type` | Тип события (например, `HostInfo`, `AsepInfo`) |
| `event_type_vendor` | Вендорский тип события |
| `Action` | Действие (дублирует `event_type_vendor` в некоторых профилях) |
| `file_path` | Полный путь к файлу |
| `file_name` | Имя файла |
| `file_sha256` | SHA-256 хеш |
| `file_sig_status` | Статус подписи: `Good`, `Unsigned`, `Error` |
| `file_sig_ident` | Идентификатор подписи |
| `cmdline` | Командная строка запуска |
| `EventTime` | Время события в ISO 8601 |
| `inventory_task_name` | Название задачи инвентаризации (профиль) |
| `inventory_session_id` | ID сессии (группирует события одного запуска) |

## Рекомендуемые поля

| Поле | Назначение |
|------|------------|
| `dev_os` | Строка версии ОС (например, `macOS 27.0 arm64 #27.0.0`) |
| `dev_os_type` | Тип ОС (`darwin`, `linux`, ...) |
| `dev_ipv4` | IP-адрес хоста |
| `dev_users` | Список пользователей (например, `501(igor)`) |
| `file_owner_name` | Владелец файла |
| `file_group_name` | Группа файла |
| `cmdline_fingerprint` | Хеш командной строки (для группировки) |
| `sensor_version` | Версия сенсора (важно после обновлений) |
| `rule_name` | Имя правила, сгенерировавшего событие |
| `EventRulesVersion` | Версия правил на момент сбора |

## Для сетевых профилей

Отправлять все `net_*` поля, какие есть. Типичные:

- `net_protocol` — `TCP` / `UDP`
- `net_local_ip`, `net_local_port`
- `net_remote_ip`, `net_remote_port`
- `net_state` — `LISTEN`, `ESTABLISHED`, ...
- `net_pid`, `net_process_name`
- `net_remote_hostname`

## Что отфильтровать

| Поле | Почему |
|------|--------|
| `file_content` | Первые байты бинарника — сотни байт на запись, быстро забьёт индекс |
| `file_yara_scope`, `file_yara_status`, `file_yara_matches` | Если YARA не используется — мусор |
| `file_tgt_*` | Атрибуты symlink-целей, редко нужны для триажа |

Если фильтрация на хосте невозможна — удаляйте эти поля в Graylog
Pipeline Rule:

```text
rule "drop heavy fields"
when
    has_field("file_content")
then
    remove_field("file_content");
    remove_field("file_yara_scope");
    remove_field("file_yara_status");
    remove_field("file_yara_matches");
end
```

## Служебные поля для мониторинга агента

| Поле | Зачем |
|------|-------|
| `sensor_install_time` | Время установки сенсора |
| `sensor_install_age` | Возраст установки в секундах |
| `dev_boot_time` | Время загрузки хоста |
| `dev_uptime` | Аптайм в секундах |
| `customer_id` | Если один Graylog на несколько заказчиков |
| `SystemAgentID` | Различать стенды и режимы запуска |

## Замечания по типам

- `EventTime` — строка ISO 8601 с локальной таймзоной
  (например, `2026-09-16T13:20:56.118`). В Graylog настройте Date
  Extractor с форматом `yyyy-MM-dd'T'HH:mm:ss.SSS`.
- Если Graylog ругается на таймзону — используйте `event_utc_time`,
  если он есть в записи.
