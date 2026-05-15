#!/bin/bash
# HASH256 GPU Miner — universal launcher.
#
# Activates the project's .venv and runs miner.py with logs.
# Used by every supervisor option (screen, tmux, cron, pm2, systemd) so
# the actual launch command stays identical regardless of how it is
# invoked.
#
# Usage:
#   ./run-miner.sh                 # foreground, full logging
#   ./run-miner.sh --no-log        # foreground, stdout only
#   ./run-miner.sh -- --batch-size 33554432   # extra args to miner.py
#
# Environment overrides:
#   HASH256_LOG=/path/to/log       # default: <dir>/miner.log
#   HASH256_PYTHON=python3         # override interpreter
#   HASH256_LOCK=/path/to/lock     # default: <dir>/.miner.lock

set -Eeuo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$DIR"

LOG_FILE="${HASH256_LOG:-$DIR/miner.log}"
LOCK_FILE="${HASH256_LOCK:-$DIR/.miner.lock}"
PYTHON_BIN="${HASH256_PYTHON:-}"

# ─── arg parsing ───────────────────────────────────────────────────────
WANT_LOG=1
EXTRA_ARGS=()
while [ $# -gt 0 ]; do
    case "$1" in
        --no-log) WANT_LOG=0 ;;
        --) shift; EXTRA_ARGS=("$@"); break ;;
        *) EXTRA_ARGS+=("$1") ;;
    esac
    shift
done

# ─── pick interpreter ──────────────────────────────────────────────────
if [ -z "$PYTHON_BIN" ]; then
    if [ -x "$DIR/.venv/bin/python" ]; then
        PYTHON_BIN="$DIR/.venv/bin/python"
    elif command -v python3 >/dev/null 2>&1; then
        PYTHON_BIN="$(command -v python3)"
    else
        echo "[run-miner] ERROR: no Python found (neither .venv nor python3)" >&2
        exit 1
    fi
fi

# ─── single-instance guard (best effort; uses flock if available) ──────
acquire_lock() {
    if command -v flock >/dev/null 2>&1; then
        exec 9>"$LOCK_FILE"
        if ! flock -n 9; then
            echo "[run-miner] another miner instance is already running (lock: $LOCK_FILE)" >&2
            exit 1
        fi
    else
        # Fallback: stale-PID check
        if [ -f "$LOCK_FILE" ]; then
            old_pid=$(cat "$LOCK_FILE" 2>/dev/null || echo "")
            if [ -n "$old_pid" ] && kill -0 "$old_pid" 2>/dev/null; then
                echo "[run-miner] miner already running (pid $old_pid)" >&2
                exit 1
            fi
        fi
        echo "$$" > "$LOCK_FILE"
        trap 'rm -f "$LOCK_FILE"' EXIT
    fi
}

acquire_lock

# ─── banner ────────────────────────────────────────────────────────────
echo "[run-miner] starting at $(date '+%Y-%m-%d %H:%M:%S %z')"
echo "[run-miner] dir=$DIR"
echo "[run-miner] python=$PYTHON_BIN"
[ "$WANT_LOG" = "1" ] && echo "[run-miner] log=$LOG_FILE"
echo "[run-miner] args=${EXTRA_ARGS[*]:-<none>}"

# ─── run ───────────────────────────────────────────────────────────────
if [ "$WANT_LOG" = "1" ]; then
    exec "$PYTHON_BIN" -u miner.py "${EXTRA_ARGS[@]}" 2>&1 | tee -a "$LOG_FILE"
else
    exec "$PYTHON_BIN" -u miner.py "${EXTRA_ARGS[@]}"
fi
