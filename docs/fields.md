# Набор полей

`bz_triage` шлёт JSON Lines — каждая запись отдельной строкой.
После настройки JSON Extractor в Graylog (см.
[`graylog-setup.md`](graylog-setup.md)) все поля верхнего уровня
становятся отдельными полями сообщения.

Ниже — рекомендованный минимум и что фильтруется на хосте.

## Что фильтруется на хосте (`bzt-filter.pl`)

Эти поля удаляются **до** отправки в Graylog — они либо огромные,
либо не нужны для анализа:

| Поле | Почему удаляем |
|------|----------------|
| `file_content` | Первые байты бинарника, сотни байт на запись |
| `file_yara_scope` | Мусор, если YARA не используется |
| `file_yara_status` | То же |
| `file_yara_matches` | То же |

Если фильтрация не сработала — на стороне Graylog можно добить
Pipeline Rule (см. `graylog-setup.md`, п.7).

## Обязательные поля

Нужны для идентификации хоста и события.

| Поле | Назначение |
|------|------------|
| `SystemHostname` | Имя хоста |
| `SystemMachineSN` | Серийный номер |
| `dev_os` | Строка версии ОС (например, `macOS 27.0 arm64`) |
| `dev_os_type` | `darwin`, `linux` |
| `dev_ipv4` | IP-адрес |
| `dev_users` | Список пользователей (например, `501(igor)`) |
| `event_type` | Тип события (`HostInfo`, `AsepInfo`, `UserLogonInfo`) |
| `event_type_vendor` | Вендорский тип (`EndpointState`, `AutorunLaunchDaemonFound`) |
| `Action` | Действие (дублирует `event_type_vendor` в части профилей) |
| `EventTime` | Время события в ISO 8601 |
| `inventory_task_name` | Название задачи (профиль) |
| `inventory_session_id` | ID сессии (группирует события одного запуска) |
| `ServiceVersion` | Версия сенсора |

## Файловые объекты (autoruns, fileperm, keydirsinfo)

| Поле | Назначение |
|------|------------|
| `file_path` | Полный путь |
| `file_name` | Имя файла |
| `file_size` | Размер |
| `file_type` | `File`, `Link`, `Directory` |
| `file_sha256` | SHA-256 хеш |
| `file_md5` | MD5 хеш |
| `file_signed` | `true` / `false` |
| `file_sig` | Строка подписи (например, `Software Signing`) |
| `file_sig_status` | `Good`, `Unsigned`, `Error` |
| `file_sig_ident` | Идентификатор подписи |
| `file_sig_ca` | CA подписи |
| `file_owner_name` | Владелец |
| `file_group_name` | Группа |
| `file_owner_id` | UID владельца |
| `file_group_id` | GID группы |
| `file_exists` | Файл реально существует по пути |
| `file_crtime` | Время создания |
| `file_mtime` | Время модификации |
| `file_atime` | Время доступа |
| `file_inode` | Inode |
| `cmdline` | Командная строка запуска |
| `file_sig_cdhash` | CDHash подписи (для macOS) |

## Процессы (processes)

| Поле | Назначение |
|------|------------|
| `proc_name` | Имя процесса |
| `proc_path` | Путь к бинарнику |
| `proc_pid` | PID |
| `proc_ppid` | PPID |
| `proc_user` | Пользователь |
| `proc_cmdline` | Командная строка |
| `proc_sha256` | Хеш бинарника |
| `proc_sig_status` | Статус подписи |

(точные имена полей — из JSON `processes` на конкретной версии сенсора)

## Сетевые соединения (netconn, networks)

| Поле | Назначение |
|------|------------|
| `net_protocol` | `TCP` / `UDP` |
| `net_local_ip` | Локальный IP |
| `net_local_port` | Локальный порт |
| `net_remote_ip` | Удалённый IP |
| `net_remote_port` | Удалённый порт |
| `net_state` | `LISTEN`, `ESTABLISHED` |
| `net_pid` | PID процесса |
| `net_process_name` | Имя процесса |

Точные названия полей зависят от версии сенсора — см. реальный JSON.

## Пользователи и сессии (users, sessions, logonhist)

| Поле | Назначение |
|------|------------|
| `user_name` | Имя пользователя |
| `user_id` | UID |
| `user_home` | Домашняя директория |
| `user_shell` | Shell |
| `user_groups` | Группы |
| `session_user` | Пользователь сессии |
| `session_tty` | TTY |
| `session_login_time` | Время логина |
| `session_remote_host` | Откуда логинился |

## Autoruns (autoruns)

Особый набор — `asep_*` поля:

| Поле | Назначение |
|------|------------|
| `asep_type` | `LaunchAgent`, `LaunchDaemon`, `BashEntry`, `CronJob`, ... |
| `asep_file_path` | Путь к plist/скрипту |
| `asep_file_name` | Имя |
| `asep_file_sha256` | Хеш |
| `asep_file_sig_status` | Статус подписи |
| `asep_file_owner_name` | Владелец |
| `asep_file_group_name` | Группа |
| `asep_file_exists` | Файл существует |
| `cmdline` | Что запускается |

## Служебные поля для мониторинга агента

| Поле | Зачем |
|------|-------|
| `sensor_install_time` | Время установки сенсора |
| `sensor_install_age` | Возраст установки (сек) |
| `sensor_version` | Версия сенсора |
| `sensor_cfg_profile` | `triage` |
| `sensor_cfg_profile_id` | ID профиля |
| `sensor_cfg_version` | Версия конфига |
| `dev_boot_time` | Время загрузки хоста |
| `dev_uptime` | Аптайм (сек) |
| `dev_install_age` | Возраст ОС (сек) |
| `customer_id` | ID заказчика (если мультитенант) |
| `SystemAgentID` | ID агента (`standalone-run` для локального) |
| `EventRulesVersion` | Версия правил |

## Замечания по типам

- `EventTime` — строка ISO 8601 **без таймзоны**
  (например, `2026-09-17T11:38:30.354`). В Graylog настрой
  Date Extractor с форматом `yyyy-MM-dd'T'HH:mm:ss.SSS`.
  Если не настроить — поле останется строкой, по нему не
  построить графики и алерты по времени.
- `event_utc_time` — то же в UTC, удобно для точного сравнения
  между хостами в разных TZ.
- Числовые поля (`file_size`, `dev_uptime`, `EventID`) —
  Graylog сохранит как числа.
- Логические (`file_exists`, `file_signed`) — как boolean.

## Ссылки

- [`graylog-setup.md`](graylog-setup.md) — как настроить Extractor.
- [`troubleshooting.md`](troubleshooting.md) — если поля не разложились.
