# Настройка Graylog

## 1. Создать Input

**System → Inputs → Select input → Raw/Plaintext TCP → Launch new input**

Параметры:

| Параметр | Значение |
|----------|----------|
| Title | `bz_triage TCP` |
| Port | `5555` (или свой) |
| Bind address | `0.0.0.0` |
| TLS | как в вашей инфраструктуре |
| Number of workers | 1–2 |

После создания input'а — `Start` его.

## 2. Добавить JSON Extractor

**System → Inputs → bz_triage TCP → Manage extractors → Add extractor**

- **Type:** JSON
- **Title:** `bz_triage JSON`
- **Key:** оставить пустым (парсить всё сообщение целиком)
- **Condition:** `Always try to extract`
- **Extraction strategy:** `Copy extraction`
- **JSON options:**
  - `try_extract_all`: `true`
  - `flatten`: `false`
  - `list_separator`: `,`

Сохранить. С этого момента все поля верхнего уровня из JSON
станут отдельными полями сообщения в Graylog.

## 3. Date Extractor для EventTime

По умолчанию `EventTime` придёт строкой. Чтобы Graylog понимал её как
дату (для графиков, алертов по времени):

**Manage extractors → Add extractor**

- **Type:** Regular expression
- **Title:** `EventTime date`
- **Field:** `EventTime`
- **Regular expression:** `^(.*)$`
- **Extraction strategy:** `Copy extraction`
- **Condition:** `Only attempt extraction if field exists`
- **Add converter:** `Date`
  - **Format:** `yyyy-MM-dd'T'HH:mm:ss.SSS`
  - **Timezone:** по вашему региону (например, `Europe/Moscow`)

## 4. Pipeline Rule для удаления тяжёлых полей

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

Создать Pipeline, добавить в него правило, привязать к Stream,
куда будут попадать события от `bz_triage`.

## 5. Stream и retention

**Streams → Create stream** — например, `bz_triage`.

Правило:

```text
Field: source
Type: match regular expression
Value: ^MacMiniM2$   # или маска имён ваших хостов
```

Или по другому полю — например, `sensor_cfg_profile = triage`.

Настроить retention:

- **Index Set:** создать отдельный `bz_triage index set`.
- **Rotation:** например, daily или по размеру (10 GB).
- **Retention:** 30–90 дней, в зависимости от политики.

## 6. Проверка

На хосте запустить:

```bash
sudo /usr/local/bin/bzt-stream.sh
```

В Graylog: **Search** → выбрать Stream `bz_triage` → убедиться, что
сообщения появились и поля разложились.
