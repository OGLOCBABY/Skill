#!/usr/bin/env bash
# orchestrate.sh — Coordinator-Worker orchestration engine
# Usage: orchestrate.sh <tasks.jsonl> [--max-workers N] [--hooks hooks.json]
set -euo pipefail

TASKS_FILE="${1:?Usage: orchestrate.sh <tasks.jsonl> [--max-workers N] [--hooks hooks.json]}"
MAX_WORKERS=8
HOOKS_CONFIG=""
WORKDIR=$(mktemp -d /tmp/uas-orch-XXXX)
RESULTS_DIR="$WORKDIR/results"
PIDS_FILE="$WORKDIR/pids"
STATUS_FILE="$WORKDIR/status"
mkdir -p "$RESULTS_DIR"

shift
while [[ $# -gt 0 ]]; do
  case $1 in
    --max-workers) MAX_WORKERS=$2; shift 2;;
    --hooks) HOOKS_CONFIG=$2; shift 2;;
    *) echo "Unknown arg: $1" >&2; exit 1;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

run_hook() {
  local point=$1; local target=${2:-""}
  [ -z "$HOOKS_CONFIG" ] && return 0
  [ -f "$SCRIPT_DIR/run_hooks.sh" ] && bash "$SCRIPT_DIR/run_hooks.sh" "$point" "$target" "$HOOKS_CONFIG"
}

TOTAL=$(wc -l < "$TASKS_FILE")
echo "[UAS] Orchestrating $TOTAL tasks (max $MAX_WORKERS parallel) workspace=$WORKDIR"

run_hook "pre-exec" "$TASKS_FILE"

RUNNING=0
TASK_NUM=0

while IFS= read -r task; do
  TASK_NUM=$((TASK_NUM + 1))
  ID=$(echo "$task" | python3 -c "import sys,json; print(json.load(sys.stdin).get('id','task_$TASK_NUM'))" 2>/dev/null || echo "task_${TASK_NUM}")
  CMD=$(echo "$task" | python3 -c "import sys,json; print(json.load(sys.stdin)['cmd'])")

  while [ $RUNNING -ge $MAX_WORKERS ]; do
    for pidline in $(cat "$PIDS_FILE" 2>/dev/null); do
      pid=${pidline%%:*}
      if ! kill -0 "$pid" 2>/dev/null; then
        wait "$pid" 2>/dev/null || true
        RUNNING=$((RUNNING - 1))
      fi
    done
    [ $RUNNING -ge $MAX_WORKERS ] && sleep 0.5
  done

  echo "[UAS] Dispatching worker $ID ($TASK_NUM/$TOTAL)"
  bash -c "$CMD" > "$RESULTS_DIR/${ID}.out" 2> "$RESULTS_DIR/${ID}.err" &
  WORKER_PID=$!
  echo "${WORKER_PID}:${ID}" >> "$PIDS_FILE"
  RUNNING=$((RUNNING + 1))

done < "$TASKS_FILE"

echo "[UAS] All tasks dispatched. Waiting for completion..."
wait

echo "[UAS] Collecting results..."
PASS=0; FAIL=0
while IFS=: read -r pid id; do
  if [ -s "$RESULTS_DIR/${id}.err" ] && ! [ -s "$RESULTS_DIR/${id}.out" ]; then
    echo "  $id: FAIL"
    echo "$id:FAIL" >> "$STATUS_FILE"
    FAIL=$((FAIL + 1))
    run_hook "on-error" "$RESULTS_DIR/${id}.err"
  else
    echo "  $id: PASS"
    echo "$id:PASS" >> "$STATUS_FILE"
    PASS=$((PASS + 1))
    run_hook "post-exec" "$RESULTS_DIR/${id}.out"
  fi
done < "$PIDS_FILE"

MERGED="$WORKDIR/merged_output.txt"
for f in "$RESULTS_DIR"/*.out; do
  [ -f "$f" ] || continue
  echo "======== $(basename "$f" .out) ========" >> "$MERGED"
  cat "$f" >> "$MERGED"
  echo "" >> "$MERGED"
done

run_hook "on-complete" "$MERGED"

cat <<EOF

[UAS] Orchestration Complete
  Workspace: $WORKDIR
  Total: $TOTAL | Pass: $PASS | Fail: $FAIL
  Merged output: $MERGED
  Individual results: $RESULTS_DIR/
EOF
