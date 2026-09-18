#!/bin/bash
# bzt-stream.sh — запускает bz_triage с профилями из аргумента и шлёт JSON в Graylog
#
# Usage: bzt-stream.sh "<profiles>" <limit_time>
#
# Особенности:
#   - НЕ используем set -e: пайплайн с nc может вернуть ошибку (broken pipe).
#   - НЕ используем timeout: на macOS его нет.
#   - Per-profile lock с PID-файлом и автоочисткой stale lock.
#   - nc -G 5 -w 1: правильные таймауты для macOS BSD nc.
#   - cleanup чистит за собой временные каталоги bz_triage (edr-data*, bzt.*).
set -uo pipefail

PROFILES="${1:-hostinfo,netconn,processes,sessions,users}"
LIMIT_TIME="${2:-90}"

TRIAGE_BIN="/usr/local/bin/bz_triage"
FILTER_BIN="/usr/local/bin/bzt-filter.pl"
GRAYLOG_HOST="192.168.1.210"
GRAYLOG_PORT="9095"

PROFILE_TAG=$(echo "$PROFILES" | tr ',' '_' | tr -cd 'a-zA-Z0-9_-')
LOCKDIR="/var/run/bzt.${PROFILE_TAG}.lock"

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
    find /tmp -maxdepth 1 -name "edr-data*" -type d -mmin +10 -exec rm -rf {} \; 2>/dev/null
    find /tmp -maxdepth 1 -name "bzt.*"    -type d -mmin +10 -exec rm -rf {} \; 2>/dev/null
}
trap cleanup EXIT INT TERM

echo "[$(date '+%Y-%m-%d %H:%M:%S')] start: profiles=$PROFILES limit=${LIMIT_TIME}s"

"$TRIAGE_BIN" \
    -p="$PROFILES" \
    --limit-time="$LIMIT_TIME" \
    --tempdir="$TMPDIR_BZT" \
    --stdout 2>/dev/null \
  | "$FILTER_BIN" \
  | nc -G 5 -w 1 "$GRAYLOG_HOST" "$GRAYLOG_PORT" || true

echo "[$(date '+%Y-%m-%d %H:%M:%S')] done"
