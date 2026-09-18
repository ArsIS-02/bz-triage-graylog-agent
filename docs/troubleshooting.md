# Известные грабли

Всё, что мы встретили при развёртывании агента на реальных хостах
и при настройке Graylog.

## macOS

### `timeout` не существует на macOS

**Симптом:** скрипт падает мгновенно после `start`, в логе нет `done`.

**Причина:** в скрипте используется GNU-утилита `timeout`, которой нет
в macOS по умолчанию. Есть только в `coreutils` из Homebrew, и
называется `gtimeout`.

**Решение:** не использовать `timeout` в скриптах для macOS.

### `set -e` + `nc` = падение без `done`

**Симптом:** `start` в логе есть, `done` нет, `last exit code = 1`.

**Причина:** пайплайн `bz_triage | filter | nc` — если `nc` вернёт
ошибку (broken pipe при большом `autoruns`), `set -e` немедленно
убивает скрипт, не дав ему записать `done` и не отработав trap.

**Решение:**

- Убрать `-e` из `set -euo pipefail` → `set -uo pipefail`.
- Обернуть пайплайн в `( ... ) || true`.

### `nc -w 180` вешает скрипт на 3 минуты

**Симптом:** `start` в логе, потом тишина 180 секунд, потом `done`.
Или вообще никогда — если больше 180 сек.

**Причина:** BSD `nc` на macOS после закрытия stdin **не завершается
сразу**, а ждёт `-w` секунд простоя. `-w 180` = 3 минуты ожидания.

**Решение:** `nc -G 5 -w 1` — `-G` таймаут на connect, `-w 1` короткий
idle timeout. Соединение закроется через 1 секунду после EOF.

Проверка, что флаг есть:

```bash
grep "nc -G" /usr/local/bin/bzt-stream.sh
```

### `nc: invalid tcp adaptive write timeout value`

**Симптом:** `nc` ругается при `-w 180` и `-N`.

**Причина:** `-N` в BSD `nc` — не «закрыть после EOF», а **количество
проб для генерации таймаута**, требует числовой аргумент. Плюс лимит
на `-w` — порядка 100 секунд.

**Решение:** не использовать `-N`. Использовать `-G 5 -w 1`.

### `bzt-filter.pl` спотыкается на не-объектах

**Симптом** в `.err`:

```
Can't use string ("55737") as a HASH ref while "strict refs" in use
```

**Причина:** `bz_triage` иногда отдаёт в потоке не JSON-объект, а строку
или число. `delete $data->{...}` падает на строке.

**Решение:** в фильтре добавить проверку:

```perl
next unless ref($data) eq 'HASH';
```

### Буферизация Perl-фильтра

**Симптом:** данных нет, но `bz_triage` работает, а `nc` завершается
с `EXIT=0`.

**Причина:** Perl копит stdout в буфере. При малом объёме (например
`hostinfo` — одна строка) данные не успевают дойти до `nc`, и он
закрывает соединение раньше.

**Решение:** `$| = 1;` в начале `bzt-filter.pl`.

### Залипший lock

**Симптом:** `another run is active, skipping` повторяется через
каждые N минут, но данных нет.

**Причина:** процесс был убит SIGKILL, trap не сработал, лок-директория
осталась. `rm -f` её не удаляет (не файл). `rmdir` не работает,
если внутри есть `pid`.

**Решение:**

- Lock должен быть **per-profile**: `/var/run/bzt.<profiles>.lock`,
  чтобы разные агенты не блокировали друг друга.
- В лок пишется `pid` владельца. При старте проверяем — жив ли он.
- Если мёртв — сносим лок через `rm -rf`.

Ручная очистка всех локов:

```bash
sudo rm -rf /var/run/bzt.*.lock
```

### `bootstrap` без `kickstart` не активирует таймер `StartInterval`

**Симптом:** после `launchctl bootout` + `bootstrap` агент загружен,
но `runs = 0`, `last exit = (never exited)`, `job state = uninitialized`.

**Причина:** `launchd` не активирует `StartInterval` пока агент не
запустится хотя бы раз. С `RunAtLoad = false` получается замкнутый круг:
таймер ждёт первого запуска, первый запуск ждёт таймера.

**Решение:**

- Использовать **`StartCalendarInterval`** вместо `StartInterval` —
  он не требует активации через kickstart.
- Добавить **`RunAtLoad = true`** — при каждой загрузке Mac или
  `bootstrap` агент запускается сразу и активирует свой таймер.
- Если уже залипло — `launchctl kickstart system/<label>` вручную.

### `StartInterval` не догоняет пропуски после сна

**Симптом:** ноутбук после пробуждения не отправляет логи сразу, а
ждёт следующего интервала. Если он спал 5 часов, данные за эти часы
теряются.

**Причина:** `StartInterval` отсчитывается от предыдущего запуска и
пропущенные окна не «догоняет».

**Решение:** использовать `StartCalendarInterval` — он запускает
задачу сразу после пробуждения, если её время прошло.

### `bz_triage` оставляет `edr-data*` в `/tmp`

**Симптом:** `/tmp` забивается каталогами `edr-data<числа>` по 1 МБ.
Растёт ~200 МБ/сутки (при трёх агентах).

**Причина:** `bz_triage` создаёт временные файлы **в дополнение**
к нашему `--tempdir`. Trap их не удаляет.

**Решение:** в `cleanup()` скрипта `bzt-stream.sh`:

```bash
find /tmp -maxdepth 1 -name "edr-data*" -type d -mmin +10 -exec rm -rf {} \; 2>/dev/null
find /tmp -maxdepth 1 -name "bzt.*"    -type d -mmin +10 -exec rm -rf {} \; 2>/dev/null
```

`-mmin +10` — не трогает свежие, только старше 10 минут.

### Другие залипшие каталоги `/tmp/bzt.*`

**Симптом:** в `/tmp` лежат каталоги `bzt.XXXXXX` (создаются нашим
скриптом через `mktemp -d`), не удаляются.

**Причина:** процесс убит SIGKILL → trap не сработал.

**Решение:** та же автоочистка, что и для `edr-data*` (см. выше).
Ручная:

```bash
sudo rm -rf /tmp/bzt.*
```

### `nc` — BSD, а не GNU

На macOS `/usr/bin/nc` — это BSD-версия. Не поддерживает некоторые
GNU-опции (`-N`, `--send-only`). Флаг `-w` работает, но с оговорками —
см. выше.

### `xattr` блокирует запуск скачанного бинаря

**Симптом:** `zsh: bad CPU type in executable` или
`Operation not permitted` при запуске `bz_triage`.

**Причина:** macOS ставит карантинный флаг на всё, что скачано из
интернета.

**Решение:**

```bash
sudo xattr -d com.apple.quarantine /usr/local/bin/bz_triage
```

## Graylog

### `Node ... cannot be found among active nodes`

Это **не** ошибка в node_id. Это Graylog не может проксировать запрос
к самому себе по адресу, который у него в `transport_address`.

**Шаг 1.** Проверить, что в `server.conf` правильно указано:

```ini
http_bind_address = 0.0.0.0:9000
http_external_uri = http://<IP-сервера Graylog>:9000/
http_publish_uri = http://<IP-сервера Graylog>:9000/
```

**Важно:** параметр называется **`http_publish_uri`**, а не `publish_uri`.
С `publish_uri` Graylog его молча игнорирует и берёт первую попавшуюся
сетевую карту (например, Docker bridge `172.18.0.1`).

Проверка, что подхватилось:

```bash
mongo graylog --eval "db.nodes.find().pretty()"
```

В `transport_address` должно быть `http://<IP-сервера Graylog>:9000/api/`.

**Шаг 2.** Если адрес уже правильный, но ошибка осталась — увеличить
таймауты в `server.conf`:

```ini
stale_leader_timeout = 2000
proxied_requests_default_call_timeout = 30s
elasticsearch_search_timeout = 1m
elasticsearch_request_timeout = 1m
```

Затем:

```bash
sudo systemctl restart graylog-server
```

### `ChunkedBulkIndexer Failed to index`

Graylog принимает сообщения, но OpenSearch не может их записать.
Обычно из-за нехватки heap или отсутствия retention.

**Heap.** Проверить:

```bash
grep -E "Xms|Xmx" /etc/opensearch/jvm.options
grep -E "Xms|Xmx" /etc/graylog/server/jvm.options
```

Минимум 4 ГБ для обоих на сервере с 16 ГБ RAM.

**Retention.** Если индексов накопилось 20+ по 5 ГБ, поиск и
индексация идут крайне медленно. Настроить:

**System → Indices → Default index set → Edit**

- Rotation strategy: `Index time`
- Rotation period: `P1D`
- Retention strategy: `Delete`
- Max number of indices: `14`

⚠️ При сохранении Graylog **немедленно удалит** лишние индексы.

**`traceID` не влезает в `long`.** Если в ошибке видишь:

```
failed to parse field [traceID] of type [long]
Preview of field's value: '9223373162136731652'
```

Значение больше `Long.MAX_VALUE`. Решение — переопределить mapping
через шаблон:

```bash
curl -X PUT "http://localhost:9200/_index_template/custom-overrides" \
  -H 'Content-Type: application/json' -d '{
    "index_patterns": ["graylog_*"],
    "priority": 500,
    "template": {
      "settings": {"index.mapping.total_fields.limit": 5000},
      "mappings": {
        "dynamic_templates": [{
          "traceID_as_keyword": {
            "match": "traceID",
            "mapping": {"type": "keyword"}
          }
        }]
      }
    }
  }'
```

Применится к **новым** индексам. Для текущего — ротировать индекс
(`System → Indices → Rotate active write index`).

**`Limit of total fields [1000] has been exceeded`.** Та же причина —
много разных полей от разных источников. Решение — тот же шаблон
с `index.mapping.total_fields.limit: 5000`.

### `index [graylog_NNN] blocked by: [FORBIDDEN/8/index write (api)]`

Индекс переведён в read-only.

**Причина:** чаще всего — сработала дисковая защита OpenSearch
(flood-stage) при заполнении диска. Или индекс помечен как read-only
вручную после сбоя.

**Решение — снять блок:**

```bash
curl -X PUT "http://localhost:9200/graylog_NNN/_settings" \
  -H 'Content-Type: application/json' \
  -d '{"index.blocks.read_only_allow_delete": null}'
```

**Если блокировка возвращается** — искать причину:

```bash
# Свободное место
df -h /

# Настройки watermark
curl -s "http://localhost:9200/_cluster/settings?include_defaults=true&pretty" \
  | grep -i watermark
```

Если диск > 90% — чистить (retention, удаление старых индексов).

### `Executing search failed: timeout`

В браузере при поиске. Смотреть `proxied_requests_default_call_timeout`
и `stale_leader_timeout` в `server.conf` (см. выше).

Дополнительно — очистить кэш браузера (`Ctrl+Shift+R`).

### Graylog перезапускается и теряет соединение

Проверить `TimeoutStopSec` в systemd:

```bash
sudo systemctl cat graylog-server | grep -i timeout
```

По умолчанию 90 сек — Graylog с 4 ГБ heap не успевает корректно
остановиться, и systemd убивает его SIGKILL. Это оставляет систему
в неконсистентном состоянии (метрики Input'ов «залипают»).

**Решение:**

```bash
sudo mkdir -p /etc/systemd/system/graylog-server.service.d
sudo tee /etc/systemd/system/graylog-server.service.d/timeout.conf > /dev/null <<'EOF'
[Service]
TimeoutStopSec=120
TimeoutStartSec=300
EOF
sudo systemctl daemon-reload
```

### Дубли параметров в `server.conf`

При копировании блоков легко получить дубли. Проверить:

```bash
sudo grep -n "stale_leader_timeout\|proxied_requests\|elasticsearch_search" \
    /etc/graylog/server/server.conf
```

Должно быть по одной строке на параметр.

### Input `FAILED`: `A metric named ... already exists`

**Симптом:** Input не запускается. В логе:

```
Startup failed on 0.0.0.0:<порт>. A metric named
org.graylog2.inputs.<тип>.<input-id>.workers.executor-service.tasks.completed
already exists.
```

**Причина:** после жёсткого рестарта Graylog (SIGKILL) Input не успел
корректно выгрузиться, а его метрики остались в реестре. При следующем
старте — конфликт.

**Решение:**

1. Остановить Input.
2. Если не помогло — удалить Input и создать заново (с новым ID
   метрики не конфликтуют).
3. Если и это не помогло — `sudo systemctl stop graylog-server`,
   пауза 15 секунд, `sudo pkill -9 -f graylog.jar`, `systemctl start`.

**Профилактика:** не использовать `systemctl restart` после
`TimeoutStopSec`-таймаута. Всегда `stop` → пауза → `start`.

### `Unrecognized field "tags"` после отката версии

**Симптом:** после downgrade с 7.2.x до 7.1.x появляется ошибка:

```
Unrecognized field "tags" (class ...AutoValue_EventDto$Builder),
not marked as ignorable
```

**Причина:** в 7.2.0 добавили поле `tags` в event definitions и в
event DTO. Старая версия его не понимает.

**Решение:** либо вернуться на 7.2.x, либо удалить поле из MongoDB:

```bash
mongo graylog --eval 'db.event_definitions.updateMany({}, {$unset: {tags: ""}})'
mongo graylog --eval 'db.event_notifications.updateMany({}, {$unset: {tags: ""}})'
```

⚠️ **Graylog официально не поддерживает downgrade.** Миграции схемы
не откатываются. Если откатились — ждите подобных проблем с другими
коллекциями.

### `proxied_requests_default_call_timeout` не помогает

При высокой нагрузке Graylog может не успевать ответить сам себе за
30 секунд. Тогда ищем причину нагрузки:

```bash
curl -s "http://localhost:9200/_cat/thread_pool?v&h=node_name,name,active,queue,rejected,completed"
uptime
```

Если `search queue` растёт — **закрой браузер с Graylog** (автообновление
поиска каждые 2 секунды бьёт по всем индексам) или отключи event
processors:

```bash
mongo graylog --eval 'db.event_definitions.updateMany({}, {$set: {state: "DISABLED"}})'
```

## Диагностика

### Быстрая проверка пайплайна

```bash
# Отдельно bz_triage
sudo /usr/local/bin/bz_triage -p hostinfo --limit-time=60 --stdout 2>/dev/null | wc -c
# Ожидаемо: ~1400 байт

# Плюс фильтр
sudo /usr/local/bin/bz_triage -p hostinfo --limit-time=60 --stdout 2>/dev/null \
  | /usr/local/bin/bzt-filter.pl | wc -c
# Ожидаемо: ~1400 байт

# Плюс nc
sudo /usr/local/bin/bz_triage -p hostinfo --limit-time=60 --stdout 2>/dev/null \
  | /usr/local/bin/bzt-filter.pl \
  | nc -G 5 -w 1 <IP-сервера Graylog> <порт>
echo "EXIT=$?"
# Ожидаемо: EXIT=0
```

### Полный диагностический скрипт

`sudo /usr/local/bin/bzt-diagnose.sh` — проверяет всё сразу, exit code
`0/1/2`. См. `README.md`.

### Что висит в момент проблем

```bash
ps aux | grep -E "bz_triage|bzt-stream|bzt-filter|nc -w|bzsenedrcore" | grep -v grep
```

Убить всё зависшее:

```bash
sudo pkill -9 -f bzsenedrcore
sudo pkill -9 -f "bz_triage -p"
sudo pkill -9 -f bzt-filter
sudo pkill -9 -f "nc -"
sudo rm -rf /var/run/bzt.*.lock /tmp/bzt.* /tmp/edr-data*
```

### Счётчик Input'а в Graylog

**System → Inputs** — колонка `Received messages`. После прогона
должна увеличиться.

### Логи агентов

| Агент | log | err |
|-------|-----|-----|
| activity | `/var/log/bzt-activity.log` | `.err` |
| persistence | `/var/log/bzt-persistence.log` | `.err` |
| baseline | `/var/log/bzt-baseline.log` | `.err` |

Свежие ошибки:

```bash
sudo tail -30 /var/log/bzt-activity.err
sudo tail -30 /var/log/bzt-persistence.err
sudo tail -30 /var/log/bzt-baseline.err
```

### Реальная частота запусков

```bash
sudo grep "start:" /var/log/bzt-activity.log | tail -10
```

Разница между соседними строками — реальный интервал. При
`StartCalendarInterval` должны совпадать с заданными минутами.

### Считаем пропуски

```bash
sudo grep -c "skipping" /var/log/bzt-activity.log
```

Должно быть 0. Если больше — интервал слишком мал для этих профилей.

### Статус конкретного агента в launchd

```bash
sudo launchctl print system/ru.bi.zone.bzt-activity \
  | grep -E "state|runs|last exit|run interval"
```

`runs = 0` и `last exit = (never exited)` — агент загружен, но
не сработал. Причина — `bootstrap` без `kickstart` (см. выше).

### Показать список профилей `bz_triage`

```bash
sudo /usr/local/bin/bz_triage -p list
```

### Замерить время каждого профиля

```bash
for p in hostinfo netconn processes sessions users autoruns; do
    echo "=== $p ==="
    /usr/bin/time -p sudo /usr/local/bin/bz_triage -p $p --limit-time=30 --stdout 2>/dev/null | wc -c
done
```

### Удалить залипшие локи и временные файлы

```bash
sudo rm -rf /var/run/bzt.*.lock
sudo rm -rf /tmp/bzt.*
sudo rm -rf /tmp/edr-data*
```

## Изменение частоты

Если нужно ускорить или замедлить сбор, редактируй plist и перезагружай:

```bash
sudo nano /Library/LaunchDaemons/ru.bi.zone.bzt-activity.plist
# Изменить StartCalendarInterval

sudo launchctl bootout   system/ru.bi.zone.bzt-activity 2>/dev/null
sudo launchctl bootstrap system /Library/LaunchDaemons/ru.bi.zone.bzt-activity.plist
```

**Правило:** интервал между запусками должен быть в 2–3 раза больше
времени сбора. Для `hostinfo,netconn,processes,sessions,users`
(~20 сек) 10 минут — с запасом.
