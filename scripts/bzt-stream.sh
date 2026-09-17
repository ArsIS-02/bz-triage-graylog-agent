#!/bin/bash
# bzt-stream.sh — запускает bz_triage с профилями из аргумента и шлёт JSON в Graylog
#
# Usage: bzt-stream.sh "<profiles>" <limit_time>
#
# Особенности:
#   - НЕ используем set -e: пайплайн с nc может вернуть ошибку (broken pipe
#     при большом объёме) — это не должно ломать скрипт.
#   - НЕ используем timeout: на macOS его нет.
#   - Per-profile lock с PID-файлом и автоочисткой stale lock: разные агенты
#     не блокируют друг друга, а зависший запуск не держит lock вечно.
#   - nc -w 180: 3 минуты на отправку, хватает для autoruns.
#
set -uo pipefail

PROFILES="${1:-hostinfo,netconn,processes,sessions,users}"
LIMIT_TIME="${2:-90}"

TRIAGE_BIN="/usr/local/bin/bz_triage"
FILTER_BIN="/usr/local/bin/bzt-filter.pl"
GRAYLOG_HOST="192.168.1.210"
GRAYLOG_PORT="9095"

# Уникальный lock по профилю
PROFILE_TAG=$(echo "$PROFILES" | tr ',' '_' | tr -cd 'a-zA-Z0-9_-')
LOCKDIR="/var/run/bzt.${PROFILE_TAG}.lock"

# Автоочистка stale lock: если процесс-владелец мёртв — снести
if [ -d "$LOCKDIR" ]; then
    PIDFILE="$LOCKDIR/pid"
    if [ -f "$PIDFILE" ]; then
        OWNER_PID=$(cat "$PIDFILE" 2>/dev/null)
        if [ -n "$OWNER_PID" ] && ! kill -0 "$OWNER_PID" 2>/dev/null; then
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] removing stale lock (owner pid $OWNER_PID is dead)"
            rm -rf "$LOCKDIR"
        fi
    else
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] removing stale lock (no pid file)"
        rm -rf "$LOCKDIR"
    fi
fi

if ! mkdir "$LOCKDIR" 2>/dev/null; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] another run is active, skipping"
    exit 0
fi
echo $$ > "$LOCKDIR/pid"

TMPDIR_BZT=$(mktemp -d /tmp/bzt.XXXXXX)

cleanup() {
    set +e
    rm -rf "$TMPDIR_BZT"
    rm -rf "$LOCKDIR"
}
trap cleanup EXIT INT TERM

echo "[$(date '+%Y-%m-%d %H:%M:%S')] start: profiles=$PROFILES limit=${LIMIT_TIME}s"

"$TRIAGE_BIN" \
    -p="$PROFILES" \
    --limit-time="$LIMIT_TIME" \
    --tempdir="$TMPDIR_BZT" \
    --stdout 2>/dev/null \
  | "$FILTER_BIN" \
  | nc -w 180 "$GRAYLOG_HOST" "$GRAYLOG_PORT" || true

echo "[$(date '+%Y-%m-%d %H:%M:%S')] done"
