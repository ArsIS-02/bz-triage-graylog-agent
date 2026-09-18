# Настройка Graylog

Пошаговая инструкция для приёма и обработки данных от `bz_triage`.

## 1. Создать Input

**System → Inputs → Select input → Raw/Plaintext TCP → Launch new input**

| Параметр | Значение |
|----------|----------|
| Title | `BiZone macOS` (или любое) |
| Port | `<порт-Input'а>` |
| Bind address | `0.0.0.0` |
| TLS | по инфраструктуре (по умолчанию выкл) |
| Number of workers | 1–2 |

**Важно:** Bind address — именно `0.0.0.0`, не `127.0.0.1`. Иначе
Graylog слушает только localhost, и пакеты с удалённых хостов
приниматься не будут — увидишь `nc -zv` succeeded, но данных в поиске нет.

После создания — **Start** input.

## 2. JSON Extractor

**System → Inputs → BiZone macOS → Manage extractors → Add extractor**

| Поле | Значение |
|------|----------|
| Title | `bz_triage JSON` |
| Type | `JSON` |
| Key | *(оставь пустым — парсить всё сообщение)* |
| Condition | `Always try to extract` |
| Extraction strategy | `Copy extraction` |
| **JSON options:** | |
| `try_extract_all` | ✅ включить |
| `flatten` | ⬜ выключить |
| `list_separator` | `,` |

Save.

С этого момента **новые** сообщения будут разложены на поля:
`event_type`, `SystemHostname`, `file_path` и т. д. Старые
(проиндексированные до этого) останутся одной строкой в `message`.

## 3. Heap JVM

На сервере с 16 ГБ RAM — минимум **4 ГБ** на каждый Java-процесс.

**OpenSearch** (`/etc/opensearch/jvm.options`):

```
-Xms4g
-Xmx4g
```

**Graylog** (`/etc/graylog/server/jvm.options`):

```
-Xms4g
-Xmx4g
```

Меньше — получишь `ChunkedBulkIndexer Failed to index` и медленный
поиск. После изменения — перезапустить соответствующий сервис:

```bash
sudo systemctl restart opensearch
sudo systemctl restart graylog-server
```

## 4. `server.conf` — критичные параметры

`/etc/graylog/server/server.conf`:

```ini
http_bind_address = 0.0.0.0:9000
http_external_uri = http://<IP-сервера Graylog>:9000/
http_publish_uri = http://<IP-сервера Graylog>:9000/

# Увеличенные таймауты при нагрузке
stale_leader_timeout = 2000
proxied_requests_default_call_timeout = 30s
elasticsearch_search_timeout = 1m
elasticsearch_request_timeout = 1m
```

**Критично:**

- **`http_publish_uri`**, а не `publish_uri`. С `publish_uri` Graylog
  его молча игнорирует и публикует себя по первой попавшейся
  сетевой карте (например, Docker bridge `172.18.0.1`). После этого
  поиск в вебе падает с `Node ... cannot be found among active nodes`.
- **`stale_leader_timeout = 2000`** — миллисекунды. Дефолт 1000 мс
  мал при нагрузке.
- **`proxied_requests_default_call_timeout = 30s`** — дефолт 1000 мс.
  При большой нагрузке Graylog не успевает ответить сам себе
  за секунду.

После правок — перезапустить:

```bash
sudo systemctl restart graylog-server
```

Проверить, что `http_publish_uri` подхватился:

```bash
mongo graylog --eval "db.nodes.find().pretty()"
```

В `transport_address` должно быть `http://<IP-сервера Graylog>:9000/api/`.

## 5. systemd timeout

По умолчанию `TimeoutStopSec=90`. Graylog с 4 ГБ heap не успевает
корректно остановиться за это время, и systemd убивает его SIGKILL —
это оставляет систему в неконсистентном состоянии (метрики Input'ов
«залипают»).

Создать override:

```bash
sudo mkdir -p /etc/systemd/system/graylog-server.service.d
sudo tee /etc/systemd/system/graylog-server.service.d/timeout.conf > /dev/null <<'EOF'
[Service]
TimeoutStopSec=120
TimeoutStartSec=300
EOF
sudo systemctl daemon-reload
```

## 6. Retention (обязательно!)

**System → Indices → Default index set → Edit**

| Параметр | Значение |
|----------|----------|
| Rotation strategy | `Index time` |
| Rotation period | `P1D` |
| Retention strategy | `Delete` |
| Max number of indices | `14` (или больше) |

⚠️ **При сохранении Graylog немедленно удалит индексы, не попадающие
под лимит.** Если нужно сохранить историю — сначала экспорт.

**Оценка потока** для одного хоста с нашей схемой:

| Источник | Объём | Частота | Итого/сутки |
|----------|-------|---------|-------------|
| activity | ~3 МБ | 144 раза | ~430 МБ |
| persistence | ~1.5 МБ | 48 раз | ~70 МБ |
| baseline | ~15 МБ | 1 раз | ~15 МБ |
| **на один хост** | | | **~515 МБ** |
| **на 3 хоста** | | | **~1.5 ГБ/сутки** |

Без retention диск забьётся за 1–2 месяца.

## 7. Index template для больших числовых полей (опционально)

Если в логах появляются ошибки вида:

```
failed to parse field [traceID] of type [long]
Preview of field's value: '9223373162136731652'
```

или

```
Limit of total fields [1000] has been exceeded
```

— создать override-шаблон:

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

Применится к **новым** индексам. Для текущего — ротировать:
**System → Indices → Default index set → Maintenance → Rotate active write index**.

## 8. Pipeline для удаления тяжёлых полей (опционально)

Если фильтр на хосте не отработал — на всякий случай:

**System → Pipelines → Manage rules → Create rule**

```text
rule "drop heavy fields"
when
    has_field("file_content") ||
    has_field("file_yara_scope") ||
    has_field("file_yara_status")
then
    remove_field("file_content");
    remove_field("file_yara_scope");
    remove_field("file_yara_status");
end
```

Создать pipeline, добавить правило, привязать к Stream, куда
попадают bz_triage события.

## 9. Stream

**Streams → Create stream** — например, `BiZone macOS`.

Правило:

```
Field: gl2_source_input
Type: match exactly
Value: <ID твоего Input'а>
```

Или по содержимому:

```
Field: message
Type: contains
Value: "event_log_source":"InventoryNG"
```

## 10. Проверка

Отправить тестовое сообщение:

```bash
echo '{"test":"hello","host":"test","ts":"'"$(date -u +%FT%TZ)"'"}' \
  | nc -G 5 -w 1 <IP-сервера Graylog> <порт-Input'а>
```

**Search → Last 5 minutes** → найти `test: hello`.

**Если сообщения нет:**

- Input не `Running` → `System → Inputs`, проверить статус.
- Порт не тот → сравнить с `GRAYLOG_PORT` в `bzt-stream.sh`.
- Firewall на сервере → `nc -zv <IP-сервера Graylog> <порт>` с клиента.

**Если сообщение есть, но поля не разложены:**

- Extractor не настроен → шаг 2.
- `try_extract_all` не включён.
- Старое сообщение (до настройки Extractor) → Extractor применяется
  только к новым.

**Если сообщение есть, поля разложены, но поиск тормозит:**

- Retention не настроен → шаг 6.
- Heap маленький → шаг 3.
- Таймауты дефолтные → шаг 4.
- Слишком много параллельных поисков (открытый браузер с авто-refresh,
  event processors) → закрыть браузер, отключить лишние event definitions.

**Если Input в статусе `FAILED` с ошибкой `A metric named ... already exists`:**

- Жёсткий рестарт Graylog → метрики Input'ов остались в реестре.
- Решение: удалить Input и создать заново (с новым ID), либо
  `systemctl stop` → пауза → `pkill -9 -f graylog.jar` → `systemctl start`.

## 11. Проверка индексации

Ошибки индексации видны в **System → Overview → Indexer failures**.

Общие причины:

| Ошибка | Решение |
|--------|---------|
| `Failed to parse field [traceID] of type [long]` | Index template (шаг 7) |
| `Limit of total fields [1000] has been exceeded` | Index template (шаг 7) |
| `index [...] blocked by: [FORBIDDEN/8/index write (api)]` | Снять read-only блок (см. troubleshooting) |
| `primary shard is not active` | Индекс повреждён после жёсткого рестарта — удалить и ротировать |

Подробно — в [`troubleshooting.md`](troubleshooting.md).
