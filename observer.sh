#!/usr/bin/env bash
# observer.sh — Active health monitor for UAS workers
# Usage: observer.sh <workspace> [--interval 15] [--stall 120] [--kill 180]
# Run in background: bash scripts/observer.sh /tmp/uas-myproject &
set -euo pipefail

WORKSPACE="${1:?Usage: observer.sh <workspace> [--interval N] [--stall N] [--kill N]}"
POLL_INTERVAL=15
STALL_THRESHOLD=120
KILL_THRESHOLD=180
DASHBOARD="$WORKSPACE/.uas/dashboard.md"
LOGFILE="$WORKSPACE/.uas/logs/observer.log"

shift
while [[ $# -gt 0 ]]; do
  case $1 in
    --interval) POLL_INTERVAL=$2; shift 2;;
    --stall) STALL_THRESHOLD=$2; shift 2;;
    --kill) KILL_THRESHOLD=$2; shift 2;;
    *) shift;;
  esac
done

mkdir -p "$(dirname "$DASHBOARD")" "$(dirname "$LOGFILE")"

log() { echo "[$(date +%H:%M:%S)] $*" >> "$LOGFILE"; }

log "Observer started: interval=${POLL_INTERVAL}s stall=${STALL_THRESHOLD}s kill=${KILL_THRESHOLD}s"

# Write PID for cleanup
echo $$ > "$WORKSPACE/.uas/observer.pid"

cleanup() {
  log "Observer shutting down"
  rm -f "$WORKSPACE/.uas/observer.pid"
  exit 0
}
trap cleanup EXIT INT TERM

while true; do
  NOW=$(date +%s)
  ACTIVE=0; DONE=0; FAILED=0; STALLED=0; QUEUED=0
  TABLE=""

  # Scan PID files (from orchestrator)
  for pidfile in "$WORKSPACE"/.uas/status/*.pid 2>/dev/null; do
    [ -f "$pidfile" ] || continue
    WID=$(basename "$pidfile" .pid)
    PID=$(cat "$pidfile" 2>/dev/null || echo "0")
    STATUS_FILE="$WORKSPACE/.uas/status/${WID}.st"
    OUT_FILE="$WORKSPACE/.uas/results/${WID}.out"
    STATUS=$(cat "$STATUS_FILE" 2>/dev/null || echo "UNKNOWN")

    if [ "$STATUS" = "DONE" ] || [ "$STATUS" = "FAILED" ]; then
      [ "$STATUS" = "DONE" ] && DONE=$((DONE + 1)) || FAILED=$((FAILED + 1))
      RUNTIME=$(cat "$WORKSPACE/.uas/status/${WID}.time" 2>/dev/null || echo "?")
      LAST_OUT=$(tail -1 "$OUT_FILE" 2>/dev/null | head -c 40 || echo "—")
      TABLE="${TABLE}| ${WID} | ${STATUS} | ${RUNTIME}s | ${LAST_OUT} |\n"
      continue
    fi

    # Check if process is alive
    if ! kill -0 "$PID" 2>/dev/null; then
      # Process dead but not marked — mark as failed
      echo "FAILED" > "$STATUS_FILE"
      FAILED=$((FAILED + 1))
      log "Worker $WID (pid=$PID) died unexpectedly"
      TABLE="${TABLE}| ${WID} | CRASHED | — | (process died) |\n"
      continue
    fi

    # Process alive — check for stall
    ACTIVE=$((ACTIVE + 1))
    if [ -f "$OUT_FILE" ]; then
      MTIME=$(stat -c %Y "$OUT_FILE" 2>/dev/null || stat -f %m "$OUT_FILE" 2>/dev/null || echo "$NOW")
      AGE=$((NOW - MTIME))
    else
      # No output file yet — use PID file creation time
      MTIME=$(stat -c %Y "$pidfile" 2>/dev/null || stat -f %m "$pidfile" 2>/dev/null || echo "$NOW")
      AGE=$((NOW - MTIME))
    fi

    START_TIME=$(cat "$WORKSPACE/.uas/status/${WID}.start" 2>/dev/null || echo "$NOW")
    RUNTIME=$((NOW - START_TIME))
    LAST_OUT=$(tail -1 "$OUT_FILE" 2>/dev/null | head -c 40 || echo "(waiting)")

    if [ "$AGE" -ge "$KILL_THRESHOLD" ]; then
      log "KILL: Worker $WID stalled ${AGE}s — terminating pid=$PID"
      kill -9 "$PID" 2>/dev/null || true
      echo "FAILED" > "$STATUS_FILE"
      FAILED=$((FAILED + 1))
      ACTIVE=$((ACTIVE - 1))
      TABLE="${TABLE}| ${WID} | KILLED | ${RUNTIME}s | (stalled ${AGE}s) |\n"
    elif [ "$AGE" -ge "$STALL_THRESHOLD" ]; then
      STALLED=$((STALLED + 1))
      log "STALL: Worker $WID no output for ${AGE}s"
      TABLE="${TABLE}| ${WID} | **STALL** | ${RUNTIME}s | ${LAST_OUT} |\n"
    else
      TABLE="${TABLE}| ${WID} | RUNNING | ${RUNTIME}s | ${LAST_OUT} |\n"
    fi
  done

  # Count queued tasks (status PENDING)
  for sf in "$WORKSPACE"/.uas/status/*.st 2>/dev/null; do
    [ -f "$sf" ] || continue
    [ "$(cat "$sf")" = "PENDING" ] && QUEUED=$((QUEUED + 1))
  done

  # Write dashboard
  cat > "$DASHBOARD" <<DASHEOF
## UAS Dashboard — $(date "+%Y-%m-%dT%H:%M:%S")
| Worker | Status | Runtime | Last Output |
|--------|--------|---------|-------------|
$(echo -e "$TABLE")
Active: ${ACTIVE} | Queued: ${QUEUED} | Done: ${DONE} | Failed: ${FAILED} | Stalled: ${STALLED}
DASHEOF

  # Exit if nothing left to monitor
  TOTAL_ALIVE=$((ACTIVE + QUEUED))
  if [ "$TOTAL_ALIVE" -eq 0 ] && [ $((DONE + FAILED)) -gt 0 ]; then
    log "All workers finished. Observer exiting."
    break
  fi

  sleep "$POLL_INTERVAL"
done
