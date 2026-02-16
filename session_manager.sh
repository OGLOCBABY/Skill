#!/usr/bin/env bash
# session_manager.sh — Manage worker sessions (tmux or bg fallback)
# Usage: session_manager.sh <action> <session_name> [args...]
set -euo pipefail

ACTION="${1:?Usage: session_manager.sh <init|dispatch|status|collect|teardown> <n> [args]}"
SESSION="${2:?Session name required}"
shift 2

HAS_TMUX=0; which tmux >/dev/null 2>&1 && HAS_TMUX=1
SESSION_DIR="/tmp/uas-session-${SESSION}"

case "$ACTION" in
  init)
    NUM_WORKERS=${1:-4}
    mkdir -p "$SESSION_DIR"/{outputs,pids}
    echo "$NUM_WORKERS" > "$SESSION_DIR/num_workers"

    if [ "$HAS_TMUX" = "1" ]; then
      tmux new-session -d -s "$SESSION" -n "coord"
      for i in $(seq 1 "$NUM_WORKERS"); do
        tmux new-window -t "$SESSION" -n "w${i}"
      done
      echo "[UAS] tmux session '$SESSION' created with $NUM_WORKERS workers"
    else
      echo "{}" > "$SESSION_DIR/pids/registry.json"
      echo "[UAS] bg-process session '$SESSION' created with $NUM_WORKERS slots"
    fi
    ;;

  dispatch)
    WORKER=${1:?Worker ID required}
    CMD=${2:?Command required}

    if [ "$HAS_TMUX" = "1" ]; then
      tmux send-keys -t "${SESSION}:${WORKER}" "$CMD > $SESSION_DIR/outputs/${WORKER}.out 2> $SESSION_DIR/outputs/${WORKER}.err" Enter
      echo "[UAS] Dispatched to tmux ${SESSION}:${WORKER}"
    else
      bash -c "$CMD" > "$SESSION_DIR/outputs/${WORKER}.out" 2> "$SESSION_DIR/outputs/${WORKER}.err" &
      PID=$!
      echo "$PID" > "$SESSION_DIR/pids/${WORKER}.pid"
      echo "[UAS] Dispatched bg process pid=$PID for worker $WORKER"
    fi
    ;;

  status)
    echo "[UAS] Session: $SESSION"
    if [ "$HAS_TMUX" = "1" ]; then
      tmux list-windows -t "$SESSION" 2>/dev/null | while read -r line; do
        echo "  $line"
      done
    else
      for pidfile in "$SESSION_DIR"/pids/*.pid; do
        [ -f "$pidfile" ] || continue
        WID=$(basename "$pidfile" .pid)
        PID=$(cat "$pidfile")
        if kill -0 "$PID" 2>/dev/null; then
          echo "  $WID: RUNNING (pid=$PID)"
        else
          if [ -s "$SESSION_DIR/outputs/${WID}.err" ]; then
            echo "  $WID: DONE (has errors)"
          else
            echo "  $WID: DONE (ok)"
          fi
        fi
      done
    fi
    ;;

  collect)
    OUTPUT_DIR=${1:-"$SESSION_DIR/collected"}
    mkdir -p "$OUTPUT_DIR"
    cp "$SESSION_DIR"/outputs/*.out "$OUTPUT_DIR/" 2>/dev/null || true
    echo "[UAS] Outputs collected to $OUTPUT_DIR"
    ls -la "$OUTPUT_DIR"
    ;;

  teardown)
    if [ "$HAS_TMUX" = "1" ]; then
      tmux kill-session -t "$SESSION" 2>/dev/null || true
    else
      for pidfile in "$SESSION_DIR"/pids/*.pid; do
        [ -f "$pidfile" ] || continue
        PID=$(cat "$pidfile")
        kill "$PID" 2>/dev/null || true
      done
    fi
    rm -rf "$SESSION_DIR"
    echo "[UAS] Session '$SESSION' terminated and cleaned up"
    ;;

  *)
    echo "Unknown action: $ACTION" >&2
    echo "Actions: init, dispatch, status, collect, teardown" >&2
    exit 1
    ;;
esac