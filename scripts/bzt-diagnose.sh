#!/bin/bash
#
# bzt-diagnose.sh — диагностика агента bz_triage → Graylog на macOS.
#
# Проверяет:
#   - бинарь bz_triage (существование, arch, права)
#   - скрипты bzt-stream.sh, bzt-filter.pl
#   - plist-ы launchd и статус агентов (activity/persistence/baseline)
#   - сеть до Graylog (TCP)
#   - логи: последние start/done/skipping и время последнего успеха
#   - зависшие процессы bz_triage/bzsenedrcore
#   - залипшие локи и временные каталоги
#   - свежие ошибки в .err
#
# Exit code:
#   0 — всё ок
#   1 — есть предупреждения
#   2 — есть критические проблемы
#
# Запускать от root:
#   sudo /usr/local/bin/bzt-diagnose.sh
#
set -uo pipefail

# ─── Настройки ───────────────────────────────────────────────────────────────
LOOKBACK_LINES=60        # сколько последних строк лога анализировать
STUCK_THRESHOLD_SEC=300  # start без done дольше — считаем зависанием
ERR_FRESH_SEC=3600       # .err свежее этого (сек) считаем «недавней ошибкой»

# ─── Цвета ───────────────────────────────────────────────────────────────────
if [ -t 1 ]; then
    RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[0;33m'
    BLUE=$'\033[0;34m'; BOLD=$'\033[1m'; NC=$'\033[0m'
else
    RED=''; GREEN=''; YELLOW=''; BLUE=''; BOLD=''; NC=''
fi

WARN_COUNT=0
CRIT_COUNT=0

ok()   { printf "  ${GREEN}✓${NC} %s\n" "$*"; }
warn() { printf "  ${YELLOW}⚠${NC} %s\n" "$*"; WARN_COUNT=$((WARN_COUNT+1)); }
fail() { printf "  ${RED}✗${NC} %s\n" "$*"; CRIT_COUNT=$((CRIT_COUNT+1)); }
info() { printf "    %s\n" "$*"; }
hdr()  { printf "\n${BOLD}${BLUE}== %s ==${NC}\n" "$*"; }

# ─── Root check ──────────────────────────────────────────────────────────────
if [ "$(id -u)" -ne 0 ]; then
    echo "Запусти от root: sudo $0" >&2
    exit 1
fi

# ─── Шапка ───────────────────────────────────────────────────────────────────
printf "${BOLD}bz_triage диагностика${NC}\n"
printf "Хост:  %s\n" "$(hostname)"
printf "Дата:  %s\n" "$(date '+%Y-%m-%d %H:%M:%S %Z')"
printf "Arch:  %s\n" "$(uname -m)"

# ─── 1. Бинарь ───────────────────────────────────────────────────────────────
hdr "Бинарь bz_triage"
BIN="/usr/local/bin/bz_triage"
if [ ! -f "$BIN" ]; then
    fail "$BIN не найден"
else
    ARCH=$(file "$BIN" | sed -E 's/.*executable //' | tr -d ' ')
    SIZE=$(du -h "$BIN" | awk '{print $1}')
    HOST_ARCH=$(uname -m)
    case "$HOST_ARCH" in
        arm64)  EXPECTED="arm64" ;;
        x86_64) EXPECTED="x86_64" ;;
        *)      EXPECTED="" ;;
    esac
    ok "$BIN, $SIZE, arch=$ARCH"
    if [ -n "$EXPECTED" ] && [ "$ARCH" != "$EXPECTED" ]; then
        fail "архитектура $ARCH не совпадает с хостом ($HOST_ARCH)"
    fi
    [ -x "$BIN" ] || fail "$BIN не исполняемый"
fi

# ─── 2. Скрипты ──────────────────────────────────────────────────────────────
hdr "Скрипты-обёртки"
for f in /usr/local/bin/bzt-stream.sh /usr/local/bin/bzt-filter.pl; do
    if [ ! -f "$f" ]; then
        fail "$f не найден"
    elif [ ! -x "$f" ]; then
        fail "$f не исполняемый"
    else
        ok "$f ($(stat -f%z "$f") байт)"
    fi
done

# ─── 3. Настройки скрипта ────────────────────────────────────────────────────
hdr "Настройки GRAYLOG в bzt-stream.sh"
GRAYLOG_HOST=$(grep -E '^GRAYLOG_HOST=' /usr/local/bin/bzt-stream.sh 2>/dev/null | head -1 | cut -d'"' -f2)
GRAYLOG_PORT=$(grep -E '^GRAYLOG_PORT=' /usr/local/bin/bzt-stream.sh 2>/dev/null | head -1 | cut -d'"' -f2)
NC_LINE=$(grep -E 'nc\s' /usr/local/bin/bzt-stream.sh 2>/dev/null | grep -v '^#' | head -1)
info "GRAYLOG_HOST=$GRAYLOG_HOST"
info "GRAYLOG_PORT=$GRAYLOG_PORT"
if [ -z "$GRAYLOG_HOST" ] || [ -z "$GRAYLOG_PORT" ]; then
    fail "не прочитать GRAYLOG_HOST/PORT"
else
    ok "адрес Graylog задан"
fi
if echo "$NC_LINE" | grep -q "nc -G"; then
    ok "nc с -G (правильный таймаут)"
else
    warn "nc без -G — на macOS может висеть. Ожидается: nc -G 5 -w 1 ..."
    info "Текущая строка: $NC_LINE"
fi

# ─── 4. plist-ы ──────────────────────────────────────────────────────────────
hdr "launchd plist-ы"
for p in activity persistence baseline; do
    PLIST="/Library/LaunchDaemons/ru.bi.zone.bzt-${p}.plist"
    if [ ! -f "$PLIST" ]; then
        fail "$PLIST не найден"
    elif ! plutil -lint "$PLIST" >/dev/null 2>&1; then
        fail "$PLIST невалидный"
    else
        ok "$PLIST"
    fi
done

# ─── 5. launchd статус ───────────────────────────────────────────────────────
hdr "launchd статус агентов"
for p in activity persistence baseline; do
    LABEL="ru.bi.zone.bzt-${p}"
    LINE=$(launchctl list 2>/dev/null | grep -w "$LABEL" | head -1)
    if [ -z "$LINE" ]; then
        fail "$LABEL не загружен в launchd"
        continue
    fi
    PID=$(echo "$LINE" | awk '{print $1}')
    EXIT=$(echo "$LINE" | awk '{print $2}')
    if [ "$PID" = "-" ]; then
        if [ "$EXIT" = "0" ]; then
            ok "$LABEL: idle (last exit 0)"
        else
            warn "$LABEL: idle, last exit=$EXIT"
        fi
    else
        ok "$LABEL: running, pid=$PID, last exit=$EXIT"
    fi
done

# ─── 6. Сеть до Graylog ──────────────────────────────────────────────────────
hdr "Сеть до Graylog"
if [ -n "$GRAYLOG_HOST" ] && [ -n "$GRAYLOG_PORT" ]; then
    if nc -z -G 5 "$GRAYLOG_HOST" "$GRAYLOG_PORT" 2>/dev/null; then
        ok "TCP $GRAYLOG_HOST:$GRAYLOG_PORT доступен"
    else
        fail "TCP $GRAYLOG_HOST:$GRAYLOG_PORT недоступен"
    fi
fi

# ─── 7. Анализ логов ─────────────────────────────────────────────────────────
analyze_log() {
    local logfile="$1"
    local label="$2"
    hdr "Лог $label"

    if [ ! -f "$logfile" ]; then
        warn "$logfile не найден"
        return
    fi

    local recent
    recent=$(tail -n "$LOOKBACK_LINES" "$logfile" 2>/dev/null)
    if [ -z "$recent" ]; then
        info "лог пуст"
        return
    fi

    local starts dones skips
    starts=$(echo "$recent" | grep -c "start:" || true)
    dones=$(echo "$recent" | grep -c "done" || true)
    skips=$(echo "$recent" | grep -c "skipping" || true)
    info "за последние $LOOKBACK_LINES строк: start=$starts, done=$dones, skipping=$skips"

    local last_start_line last_start_ts
    last_start_line=$(echo "$recent" | grep "start:" | tail -1)
    if [ -z "$last_start_line" ]; then
        warn "нет записей 'start:' в логе"
    else
        last_start_ts=$(echo "$last_start_line" | sed -nE 's/^\[([0-9-]+ [0-9:]+)\].*/\1/p')
        info "последний start: $last_start_ts"

        # Проверим, есть ли done после последнего start
        local after_start
        after_start=$(grep -A 3 "$last_start_line" "$logfile" 2>/dev/null | grep -c "done" || true)
        if [ "$after_start" -gt 0 ]; then
            ok "последний start завершился done"
        else
            local start_epoch now_epoch delta
            start_epoch=$(date -j -f "%Y-%m-%d %H:%M:%S" "$last_start_ts" +%s 2>/dev/null)
            now_epoch=$(date +%s)
            if [ -n "$start_epoch" ]; then
                delta=$((now_epoch - start_epoch))
                if [ "$delta" -gt "$STUCK_THRESHOLD_SEC" ]; then
                    fail "start без done, прошло ${delta}с (>${STUCK_THRESHOLD_SEC}с — зависание?)"
                else
                    info "start без done, прошло ${delta}с (возможно, ещё идёт)"
                fi
            fi
        fi
    fi

    info "последние 5 строк:"
    echo "$recent" | tail -5 | sed 's/^/      /'
}

analyze_log "/var/log/bzt-activity.log"    "activity"
analyze_log "/var/log/bzt-persistence.log" "persistence"
analyze_log "/var/log/bzt-baseline.log"    "baseline"

# ─── 8. Зависшие процессы ────────────────────────────────────────────────────
hdr "Зависшие процессы bz_triage/bzsenedrcore"
STUCK=$(ps aux | grep -E "bz_triage|bzsenedrcore" | grep -v grep || true)
if [ -z "$STUCK" ]; then
    ok "нет процессов bz_triage/bzsenedrcore"
else
    warn "найдены процессы:"
    echo "$STUCK" | awk '{printf "      pid=%s cpu=%s rss=%s %s %s\n", $2, $3, $4, $11, $12}' | head -10
fi

# ─── 9. Локи ─────────────────────────────────────────────────────────────────
hdr "Локи /var/run/bzt.*.lock"
LOCKS=$(ls -d /var/run/bzt*.lock 2>/dev/null || true)
if [ -z "$LOCKS" ]; then
    ok "нет залипших локов"
else
    warn "найдены локи:"
    for l in $LOCKS; do
        local_pid=""
        [ -f "$l/pid" ] && local_pid=$(cat "$l/pid" 2>/dev/null)
        echo "      $l (pid=$local_pid)"
    done
fi

# ─── 10. Временные каталоги ──────────────────────────────────────────────────
hdr "Временные каталоги /tmp/bzt.*"
TMPDIRS=$(ls -d /tmp/bzt.* 2>/dev/null || true)
if [ -z "$TMPDIRS" ]; then
    ok "нет временных каталогов"
else
    warn "есть каталоги (должны удаляться trap-ом):"
    for d in $TMPDIRS; do
        SZ=$(du -sh "$d" 2>/dev/null | awk '{print $1}')
        echo "      $d ($SZ)"
    done
fi

# ─── 11. Свежие ошибки в .err ────────────────────────────────────────────────
hdr "Свежие ошибки в .err"
NOW=$(date +%s)
for p in activity persistence baseline; do
    ERRFILE="/var/log/bzt-${p}.err"
    [ -f "$ERRFILE" ] || continue
    SIZE=$(stat -f%z "$ERRFILE" 2>/dev/null || echo 0)
    if [ "$SIZE" -eq 0 ]; then
        ok "$ERRFILE пуст"
        continue
    fi
    MTIME=$(stat -f%m "$ERRFILE" 2>/dev/null || echo 0)
    AGE=$((NOW - MTIME))
    if [ "$AGE" -lt "$ERR_FRESH_SEC" ]; then
        warn "$ERRFILE изменялся $((AGE/60)) мин назад, размер=$SIZE"
        info "последние 3 строки:"
        tail -3 "$ERRFILE" | sed 's/^/      /'
    else
        info "$ERRFILE: старые записи ($((AGE/3600))ч назад), размер=$SIZE"
    fi
done

# ─── Сводка ──────────────────────────────────────────────────────────────────
hdr "Итог"
if [ "$CRIT_COUNT" -eq 0 ] && [ "$WARN_COUNT" -eq 0 ]; then
    printf "${GREEN}${BOLD}Всё в порядке${NC}\n"
    exit 0
elif [ "$CRIT_COUNT" -eq 0 ]; then
    printf "${YELLOW}${BOLD}Предупреждений: %d${NC}\n" "$WARN_COUNT"
    exit 1
else
    printf "${RED}${BOLD}Критических: %d, предупреждений: %d${NC}\n" "$CRIT_COUNT" "$WARN_COUNT"
    exit 2
fi
