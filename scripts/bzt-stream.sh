#!/bin/bash
#
# bzt-stream.sh — обёртка вокруг bz_triage для потоковой отправки в Graylog.
#
# Что делает:
#   1. Создаёт уникальный временный outdir через mktemp -d.
#   2. Запускает bz_triage с указанными профилями.
#   3. Параллельно следит за размером outdir (watchdog).
#   4. По завершении (в т.ч. при падении) удаляет outdir через trap.
#
# Требует root-прав (bz_triage собирает данные из системных путей).
#
set -euo pipefail

# ─── Настройки ───────────────────────────────────────────────────────────────
TRIAGE_BIN="/usr/local/bin/bz_triage"
GRAYLOG_HOST="graylog.example.org"
GRAYLOG_PORT="5555"
PROFILES="investigation"
LIMIT_TIME=180
OUTDIR_MAX_MB=2048

# ─── Служебные переменные ────────────────────────────────────────────────────
OUTDIR=""
TRIAGE_PID=""
WATCHDOG_PID=""

cleanup() {
    set +e
    if [ -n "$WATCHDOG_PID" ]; then
        kill "$WATCHDOG_PID" 2>/dev/null
    fi
    if [ -n "$TRIAGE_PID" ]; then
        wait "$TRIAGE_PID" 2>/dev/null
    fi
    sleep 1
    if [ -n "$OUTDIR" ] && [ -d "$OUTDIR" ]; then
        rm -rf "$OUTDIR"
    fi
}
trap cleanup EXIT INT TERM

# ─── Основной запуск ─────────────────────────────────────────────────────────
OUTDIR=$(mktemp -d /tmp/bzt.XXXXXX)

"$TRIAGE_BIN" \
    -p="$PROFILES" \
    --limit-time="$LIMIT_TIME" \
    --outdir="$OUTDIR" \
    --dsthost="$GRAYLOG_HOST" \
    --dstport="$GRAYLOG_PORT" \
    >/dev/null 2>&1 &
TRIAGE_PID=$!

# ─── Watchdog на размер outdir ───────────────────────────────────────────────
(
    while kill -0 "$TRIAGE_PID" 2>/dev/null; do
        SIZE=$(du -sm "$OUTDIR" 2>/dev/null | awk '{print $1}')
        if [ "${SIZE:-0}" -gt "$OUTDIR_MAX_MB" ]; then
            echo "[watchdog] outdir > ${OUTDIR_MAX_MB} МБ, kill bz_triage" >&2
            kill -TERM "$TRIAGE_PID" 2>/dev/null
            break
        fi
        sleep 10
    done
) &
WATCHDOG_PID=$!

# ─── Ожидание завершения ─────────────────────────────────────────────────────
wait "$TRIAGE_PID" || true
