#!/usr/bin/env bash
# orch-loop.sh — Heartbeat watchdog for the orchestrator.
#
# Purpose: keep the orchestrator Claude Code instance alive when it falls
# silent. Runs in its own bare terminal (no Claude, no tmux for itself).
# Reads the public state of the worker and orchestrator tmux sessions; if
# both go IDLE for too long while todo.md still has unchecked items, it
# nudges the orchestrator pane with a "continue" message.
#
# This script does NOT make any task decisions — it only ensures the
# orchestrator wakes up. All actual decisions stay with the LLM.
#
# Required tmux sessions (priority: CLI arg > env var > .orch/orch-loop.env > default):
#   - $ORCH_SESSION   (default: "orch")     — orchestrator Claude pane
#   - $WORKER_SESSION (default: "test_cc")  — worker Claude pane
#
# Required files:
#   - $PROJECT_DIR/.orch/todo.md            — used to detect "all done"
#
# Optional config file:
#   - $PROJECT_DIR/.orch/orch-loop.env      — sourced if present
#                                             (set ORCH_SESSION etc here)
#
# Usage:
#   bash orch-loop.sh /path/to/project [orch_session] [worker_session]
#   # or with env file at $PROJECT_DIR/.orch/orch-loop.env:
#   bash orch-loop.sh /path/to/project
#   # or with shell env:
#   export ORCH_SESSION=mySupervisor WORKER_SESSION=myWorker
#   bash orch-loop.sh /path/to/project
#
# Defaults to PROJECT_DIR=$(pwd), ORCH_SESSION=orch, WORKER_SESSION=test_cc.

set -uo pipefail

PROJECT_DIR="${1:-$(pwd)}"

# Source the project-level config file if present. CLI args still win.
ENV_FILE="$PROJECT_DIR/.orch/orch-loop.env"
if [[ -f "$ENV_FILE" ]]; then
    # shellcheck disable=SC1090
    set -a; source "$ENV_FILE"; set +a
fi

# CLI arg wins; otherwise env var (possibly from env file); otherwise default
ORCH_SESSION="${2:-${ORCH_SESSION:-orch}}"
WORKER_SESSION="${3:-${WORKER_SESSION:-test_cc}}"

ORCH_DIR="$PROJECT_DIR/.orch"
TODO_FILE="$ORCH_DIR/todo.md"
LOG_FILE="$ORCH_DIR/orch-loop.log"
SCRIPTS_DIR="$HOME/.claude/skills/tmux-orchestrator/scripts"

# Tunables (env-overridable)
POLL_INTERVAL="${POLL_INTERVAL:-60}"        # seconds between polls
IDLE_STREAK_THRESHOLD="${IDLE_STREAK_THRESHOLD:-3}"  # both-idle polls before waking
WAKE_COOLDOWN="${WAKE_COOLDOWN:-120}"       # min seconds between wakes
QUIESCE_GRACE="${QUIESCE_GRACE:-180}"       # seconds to wait after all-todos-done before exit

log() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $*"
    echo "$msg" | tee -a "$LOG_FILE" >&2
}

precheck() {
    if [[ ! -d "$ORCH_DIR" ]]; then
        log "FATAL: .orch dir not found at $ORCH_DIR"
        exit 2
    fi
    if [[ ! -f "$TODO_FILE" ]]; then
        log "FATAL: todo.md not found at $TODO_FILE"
        exit 2
    fi
    if [[ ! -x "$SCRIPTS_DIR/orch-status" ]]; then
        log "FATAL: orch-status not found or not executable at $SCRIPTS_DIR/orch-status"
        exit 2
    fi
    if ! tmux has-session -t "$ORCH_SESSION" 2>/dev/null; then
        log "FATAL: orchestrator tmux session '$ORCH_SESSION' not running. Start it with: tmux new -s $ORCH_SESSION && claude"
        exit 2
    fi
    if ! tmux has-session -t "$WORKER_SESSION" 2>/dev/null; then
        log "FATAL: worker tmux session '$WORKER_SESSION' not running. Start it with: tmux new -s $WORKER_SESSION && claude"
        exit 2
    fi
    log "Pre-flight OK. Project=$PROJECT_DIR orch=$ORCH_SESSION worker=$WORKER_SESSION"
}

# Echo "BUSY", "IDLE", "ERROR", or "UNKNOWN"
state_of() {
    "$SCRIPTS_DIR/orch-status" "$1" 2>/dev/null \
      | python3 -c 'import json,sys
try:
    d=json.loads(sys.stdin.read())
    print(d.get("state","UNKNOWN"))
except Exception:
    print("UNKNOWN")'
}

# Count unchecked tasks in todo.md
open_tasks() {
    grep -c '^- \[ \]' "$TODO_FILE" 2>/dev/null || echo 0
}

# Detect dialog on either pane (would block input)
dialog_on() {
    "$SCRIPTS_DIR/orch-status" "$1" 2>/dev/null \
      | python3 -c 'import json,sys
try:
    d=json.loads(sys.stdin.read())
    print("yes" if d.get("dialog_present") else "no")
except Exception:
    print("no")'
}

wake_orch() {
    local now_iso
    now_iso=$(date '+%H:%M')
    local msg="[orch-loop heartbeat $now_iso] 两边 IDLE 持续 ${POLL_INTERVAL}*${IDLE_STREAK_THRESHOLD}s. 请检查 .orch/todo.md 进度，决定下一步并继续。"
    # If the orch pane has a dialog open, dismiss with '0' first.
    if [[ "$(dialog_on "$ORCH_SESSION")" == "yes" ]]; then
        tmux send-keys -t "$ORCH_SESSION" "0"
        sleep 1
    fi
    tmux send-keys -t "$ORCH_SESSION" "$msg"
    sleep 1
    tmux send-keys -t "$ORCH_SESSION" "Enter"
    log "WAKE sent to $ORCH_SESSION"
}

# --- main loop ---
precheck
log "Starting heartbeat loop. POLL=${POLL_INTERVAL}s STREAK=${IDLE_STREAK_THRESHOLD} COOLDOWN=${WAKE_COOLDOWN}s"

idle_streak=0
last_wake_epoch=0
all_done_since=0

while true; do
    orch_state=$(state_of "$ORCH_SESSION")
    worker_state=$(state_of "$WORKER_SESSION")
    open=$(open_tasks)
    now=$(date +%s)

    # Termination: all todos done. Give a grace window in case orch is
    # writing the final summary, then exit.
    if [[ "$open" -eq 0 ]]; then
        if [[ "$all_done_since" -eq 0 ]]; then
            all_done_since=$now
            log "todo.md has no open tasks. Waiting ${QUIESCE_GRACE}s grace before exit."
        fi
        if (( now - all_done_since >= QUIESCE_GRACE )); then
            log "Quiesce grace elapsed. Exiting cleanly."
            exit 0
        fi
        sleep "$POLL_INTERVAL"
        continue
    else
        all_done_since=0
    fi

    # If worker is BUSY, orchestrator is rightfully idle waiting. Skip.
    if [[ "$worker_state" == "BUSY" ]]; then
        idle_streak=0
        log "poll: orch=$orch_state worker=BUSY open=$open — worker working, no action"
        sleep "$POLL_INTERVAL"
        continue
    fi

    # If orch is BUSY, it's actively deciding. Skip.
    if [[ "$orch_state" == "BUSY" ]]; then
        idle_streak=0
        log "poll: orch=BUSY worker=$worker_state open=$open — orch deciding, no action"
        sleep "$POLL_INTERVAL"
        continue
    fi

    # Both IDLE while work remains → suspicious
    idle_streak=$((idle_streak + 1))
    log "poll: orch=$orch_state worker=$worker_state open=$open — both-idle streak=$idle_streak"

    if (( idle_streak >= IDLE_STREAK_THRESHOLD )); then
        if (( now - last_wake_epoch >= WAKE_COOLDOWN )); then
            wake_orch
            last_wake_epoch=$now
            idle_streak=0
        else
            log "WAKE suppressed by cooldown (remaining $(( WAKE_COOLDOWN - (now - last_wake_epoch) ))s)"
        fi
    fi

    sleep "$POLL_INTERVAL"
done
