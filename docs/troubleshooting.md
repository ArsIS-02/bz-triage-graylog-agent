# Известные грабли

Всё, что нашли при развёртывании агента на реальных хостах
(Mac mini M2, MacBook Pro M4 Pro, MacBook Pro Intel) и при настройке
Graylog.

## macOS

### `timeout` не существует на macOS

**Симптом:** скрипт падает мгновенно после `start`, в логе нет `done`.

**Причина:** в скрипте используется GNU-утилита `timeout`, которой нет
в macOS по умолчанию. Она есть только в `coreutils` из Homebrew,
и называется `gtimeout`.

**Решение:** не использовать `timeout` в скриптах для macOS.
Если нужен таймаут — реализовывать на уровне `launchd` или через
периодическую проверку PID.

### `set -e` + `nc` = падение без `done`

**Симптом:** `start` в логе есть, `done` нет, `last exit code = 1`.

**Причина:** пайплайн `bz_triage | filter | nc` — если `nc` вернёт
ошибку (broken pipe при большом `autoruns`), `set -e` немедленно
убивает скрипт, не дав ему записать `done` и не отработав trap.

**Решение:**

- Убрать `-e` из `set -euo pipefail` → `set -uo pipefail`.
- Обернуть пайплайн в `( ... ) || true`.

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

### Залипший lock

**Симптом:** `another run is active, skipping` повторяется через
каждые N минут, но данных нет.

**Причина:** процесс был убит SIGKILL, trap не сработал, лок-директория
осталась. `rm -f` её не удаляет (не файл). `rmdir` не работает,
если внутри есть `pid`.

**Решение:** в скрипте — auto-cleanup stale lock по PID:

```bash
if [ -d "$LOCKDIR/pid" ]; then
    OWNER_PID=$(cat "$LOCKDIR/pid")
    kill -0 "$OWNER_PID" 2>/dev/null || rm -rf "$LOCKDIR"
fi
```

Ручная очистка всех локов:

```bash
sudo rm -rf /var/run/bzt.*.lock
```

### Буферизация Perl-фильтра

**Симптом:** данных нет, но `bz_triage` работает, а `nc` завершается
с `EXIT=0`.

**Причина:** Perl копит stdout в буфере. При малом объёме (например
`hostinfo` — одна строка) данные не успевают дойти до `nc`, и он
закрывает соединение раньше.

**Решение:** `$| = 1;` в начале `bzt-filter.pl`.

### `nc` — BSD, а не GNU

На macOS `/usr/bin/nc` — это BSD-версия. Не поддерживает
некоторые GNU-опции (`-N`, `--send-only`). Флаг `-w` работает
и там, и там, поэтому используем его.

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
http_external_uri = http://192.168.1.210:9000/
http_publish_uri = http://192.168.1.210:9000/
```

**Важно:** параметр называется **`http_publish_uri`**, а не `publish_uri`.
С `publish_uri` Graylog его молча игнорирует и берёт первую попавшуюся
сетевую карту (например, Docker bridge `172.18.0.1`).

Проверка, что подхватилось:

```bash
mongo graylog --eval "db.nodes.find().pretty()"
```

В `transport_address` должно быть `http://192.168.1.210:9000/api/`.

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

**Retention.** Если индексов накопилось 50+ по 5 ГБ, поиск и
индексация идут крайне медленно. Настроить:

**System → Indices → Default index set → Edit**

- Rotation strategy: `Index time`
- Rotation period: `P1D`
- Retention strategy: `Delete`
- Max number of indices: `14`

⚠️ При сохранении Graylog **немедленно удалит** лишние индексы.

### `Executing search failed: timeout`

В браузере при поиске. Смотреть `proxied_requests_default_call_timeout`
и `stale_leader_timeout` в `server.conf` (см. выше).

Дополнительно: очистить кэш браузера (`Ctrl+Shift+R`) или открыть
Graylog в режиме инкогнито. Ошибка может быть закэширована.

### Graylog перезапускается и теряет соединение

Проверить `TimeoutStopSec` в systemd:

```bash
sudo systemctl cat graylog-server | grep -i timeout
```

По умолчанию 90 сек — Graylog с 4 ГБ heap не успевает корректно
остановиться, и systemd убивает его SIGKILL. Это оставляет процессы
в неконсистентном состоянии.

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

При копировании блоков конфига легко получить дубли. Проверить:

```bash
sudo grep -n "stale_leader_timeout\|proxied_requests\|elasticsearch_search" \
    /etc/graylog/server/server.conf
```

Должно быть по одной строке на параметр. Если дубли — удалить лишние.

### `opensearch.yml` — `compatibility.override_main_response_version`

Иногда включён по умолчанию (`true`), что заставляет OpenSearch
притворяться Elasticsearch 7.10. Это может вызывать таймауты.
Проверить:

```bash
curl -s "http://localhost:9200/_cluster/settings?include_defaults=true&pretty" \
  | grep override_main_response_version
```

Если `true` — отключить:

```bash
curl -X PUT "http://localhost:9200/_cluster/settings" \
  -H 'Content-Type: application/json' \
  -d '{"persistent":{"compatibility.override_main_response_version":false}}'
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
  | nc -w 30 192.168.1.210 9095
echo "EXIT=$?"
# Ожидаемо: EXIT=0
```

### Что висит в момент проблем

```bash
ps aux | grep -E "bz_triage|bzt-stream|bzt-filter|nc -w" | grep -v grep
```

### Счётчик Input'а в Graylog

**System → Inputs → `Raw/Plaintext TCP/BiZone macOS`** —
колонка `Received messages`. После прогона должна увеличиться.

### Удалить все залипшие локи

```bash
sudo rm -rf /var/run/bzt.*.lock
```

### Проверить статус агента

```bash
sudo launchctl print system/ru.bi.zone.bzt-activity | grep -E "state|pid|last exit"
```

### Хвосты логов

```bash
sudo tail -5 /var/log/bzt-activity.log
sudo tail -5 /var/log/bzt-persistence.log
sudo tail -5 /var/log/bzt-baseline.log
sudo cat /var/log/bzt-activity.err
sudo cat /var/log/bzt-persistence.err
sudo cat /var/log/bzt-baseline.err
```

## Логи

| Агент | log | err |
|-------|-----|-----|
| activity | `/var/log/bzt-activity.log` | `.err` |
| persistence | `/var/log/bzt-persistence.log` | `.err` |
| baseline | `/var/log/bzt-baseline.log` | `.err` |

### Частота реальных запусков

```bash
sudo grep "start:" /var/log/bzt-activity.log | tail -10
```

Разница между соседними строками — реальный интервал.
При `StartInterval=600` должно быть ровно 10 минут (600 сек).

### Считаем пропуски

```bash
sudo grep -c "skipping" /var/log/bzt-activity.log
```

Если больше нуля — интервал слишком маленький для этих профилей,
надо увеличить `StartInterval` или уменьшить набор профилей.

## Полезные команды

### Показать список профилей bz_triage

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

### Проверить разложение полей в Graylog

```bash
echo '{"probe":"'"$(date +%s)"'","host":"test"}' | nc -w 5 192.168.1.210 9095
```

Затем в **Search** за последние 5 минут найти сообщение с `probe`
и убедиться, что поля разложены (не только `message`).
