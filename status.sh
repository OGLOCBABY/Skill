#!/usr/bin/env bash
# status.sh — Enhanced UAS workspace status dashboard
# Usage: status.sh <workspace_dir>
set -euo pipefail

WORKSPACE="${1:?Usage: status.sh <workspace_dir>}"

echo "╔══════════════════════════════════════╗"
echo "║      UAS v2 Status Dashboard         ║"
echo "╚══════════════════════════════════════╝"
echo ""

# Environment
if [ -f "$WORKSPACE/env.json" ]; then
  TIER=$(python3 -c "import json; print(json.load(open('$WORKSPACE/env.json'))['tier_name'])" 2>/dev/null || echo "unknown")
  echo "Environment: $TIER"
  echo ""
fi

# Observer dashboard (if running)
if [ -f "$WORKSPACE/.uas/dashboard.md" ]; then
  echo "── Live Observer Dashboard ──"
  cat "$WORKSPACE/.uas/dashboard.md"
  echo ""
fi

# Task status summary
echo "── Task Status ──"
TOTAL=0; DONE=0; RUNNING=0; PENDING=0; FAILED=0; BLOCKED=0
for sf in "$WORKSPACE"/.uas/status/*.st 2>/dev/null; do
  [ -f "$sf" ] || continue
  TOTAL=$((TOTAL + 1))
  TID=$(basename "$sf" .st)
  STATUS=$(cat "$sf")
  TIME_FILE="$WORKSPACE/.uas/status/${TID}.time"
  ELAPSED=""
  [ -f "$TIME_FILE" ] && ELAPSED=" ($(cat "$TIME_FILE")s)"

  case "$STATUS" in
    DONE)    DONE=$((DONE + 1));    echo "  ✓ $TID: DONE$ELAPSED" ;;
    RUNNING) RUNNING=$((RUNNING + 1)); echo "  ⟳ $TID: RUNNING$ELAPSED" ;;
    FAILED)  FAILED=$((FAILED + 1));  echo "  ✗ $TID: FAILED$ELAPSED" ;;
    BLOCKED) BLOCKED=$((BLOCKED + 1)); echo "  ⊘ $TID: BLOCKED" ;;
    PENDING) PENDING=$((PENDING + 1)); echo "  ○ $TID: PENDING" ;;
    *)       echo "  ? $TID: $STATUS" ;;
  esac
done

if [ $TOTAL -eq 0 ]; then
  echo "  (no tasks tracked)"
fi

echo ""
echo "Summary: $TOTAL total | $DONE done | $RUNNING running | $PENDING pending | $FAILED failed | $BLOCKED blocked"

# Active processes
echo ""
echo "── Active Processes ──"
PROC_COUNT=0
for pidfile in "$WORKSPACE"/.uas/status/*.pid 2>/dev/null; do
  [ -f "$pidfile" ] || continue
  WID=$(basename "$pidfile" .pid)
  PID=$(cat "$pidfile")
  if kill -0 "$PID" 2>/dev/null; then
    echo "  $WID: pid=$PID (alive)"
    PROC_COUNT=$((PROC_COUNT + 1))
  fi
done
[ $PROC_COUNT -eq 0 ] && echo "  (none)"

# Observer status
echo ""
echo "── Observer ──"
if [ -f "$WORKSPACE/.uas/observer.pid" ]; then
  OBS_PID=$(cat "$WORKSPACE/.uas/observer.pid")
  if kill -0 "$OBS_PID" 2>/dev/null; then
    echo "  Running (pid=$OBS_PID)"
  else
    echo "  Stopped (stale pidfile)"
  fi
else
  echo "  Not started"
fi

# Checkpoints
echo ""
echo "── Checkpoints ──"
CKPT_DIR="/mnt/user-data/outputs/uas_checkpoints"
if [ -d "$CKPT_DIR" ] && ls "$CKPT_DIR"/*.tar.gz >/dev/null 2>&1; then
  for f in "$CKPT_DIR"/*.tar.gz; do
    NAME=$(basename "$f" .tar.gz)
    SIZE=$(du -sh "$f" 2>/dev/null | cut -f1 || echo "?")
    echo "  $NAME ($SIZE)"
  done
else
  echo "  (none saved)"
fi

# Failed task details
if [ $FAILED -gt 0 ]; then
  echo ""
  echo "── Failure Details ──"
  for sf in "$WORKSPACE"/.uas/status/*.st 2>/dev/null; do
    [ -f "$sf" ] || continue
    [ "$(cat "$sf")" = "FAILED" ] || continue
    TID=$(basename "$sf" .st)
    ERR_FILE="$WORKSPACE/.uas/results/${TID}.err"
    if [ -f "$ERR_FILE" ] && [ -s "$ERR_FILE" ]; then
      echo "  $TID:"
      tail -5 "$ERR_FILE" | sed 's/^/    /'
    fi
  done
fi

echo ""
echo "Workspace: $WORKSPACE"
