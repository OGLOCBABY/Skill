#!/usr/bin/env bash
# orchestrate.sh — DAG-aware coordinator-worker orchestration engine
# Usage: orchestrate.sh <tasks.jsonl> [--max-workers N] [--hooks hooks.json]
#        [--checkpoint] [--observe] [--workspace dir]
set -euo pipefail

TASKS_FILE="${1:?Usage: orchestrate.sh <tasks.jsonl> [flags]}"
MAX_WORKERS=8
HOOKS_CONFIG=""
DO_CHECKPOINT=0
DO_OBSERVE=0
WORKSPACE=""

shift
while [[ $# -gt 0 ]]; do
  case $1 in
    --max-workers) MAX_WORKERS=$2; shift 2;;
    --hooks) HOOKS_CONFIG=$2; shift 2;;
    --checkpoint) DO_CHECKPOINT=1; shift;;
    --observe) DO_OBSERVE=1; shift;;
    --workspace) WORKSPACE=$2; shift 2;;
    *) echo "Unknown arg: $1" >&2; exit 1;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Setup workspace
if [ -z "$WORKSPACE" ]; then
  WORKSPACE=$(mktemp -d /tmp/uas-orch-XXXX)
fi
mkdir -p "$WORKSPACE/.uas"/{tasks,results,status,logs,checkpoints}

# Copy task file into workspace
cp "$TASKS_FILE" "$WORKSPACE/.uas/tasks/main.jsonl"

run_hook() {
  local point=$1; local target=${2:-""}
  [ -z "$HOOKS_CONFIG" ] && return 0
  [ -f "$SCRIPT_DIR/run_hooks.sh" ] && bash "$SCRIPT_DIR/run_hooks.sh" "$point" "$target" "$HOOKS_CONFIG"
}

# Check for resumed checkpoint — skip completed tasks
check_already_done() {
  local tid=$1
  local sf="$WORKSPACE/.uas/status/${tid}.st"
  [ -f "$sf" ] && [ "$(cat "$sf")" = "DONE" ] && return 0
  return 1
}

TOTAL=$(wc -l < "$TASKS_FILE" | tr -d ' ')
echo "[UAS] Orchestrating $TOTAL tasks (max $MAX_WORKERS parallel)"
echo "[UAS] Workspace: $WORKSPACE"

# --- DAG SCHEDULING ---
HAS_PYTHON3=0; which python3 >/dev/null 2>&1 && HAS_PYTHON3=1

if [ "$HAS_PYTHON3" = "1" ] && [ -f "$SCRIPT_DIR/dag_scheduler.py" ]; then
  echo "[UAS] Running DAG scheduler..."
  SCHEDULE=$(python3 "$SCRIPT_DIR/dag_scheduler.py" "$TASKS_FILE")

  ERRORS=$(echo "$SCHEDULE" | python3 -c "import sys,json; errs=json.load(sys.stdin).get('errors',[]); [print(e) for e in errs]" 2>/dev/null)
  if [ -n "$ERRORS" ]; then
    echo "[UAS] Scheduler warnings:" >&2
    echo "$ERRORS" >&2
  fi

  NUM_WAVES=$(echo "$SCHEDULE" | python3 -c "import sys,json; print(json.load(sys.stdin)['total_waves'])")
  echo "[UAS] Scheduled into $NUM_WAVES waves"
else
  echo "[UAS] No python3 or dag_scheduler.py — falling back to flat parallel dispatch"
  # Build single-wave schedule from raw JSONL
  SCHEDULE=$(python3 -c "
import json, sys
tasks = []
for line in open('$TASKS_FILE'):
    line = line.strip()
    if not line: continue
    t = json.loads(line)
    tasks.append({'id':t['id'],'cmd':t['cmd'],'priority':t.get('priority',5),'timeout':t.get('timeout',300),'retry':t.get('retry',1),'desc':t.get('desc','')})
print(json.dumps({'waves':[{'wave':0,'tasks':tasks}],'total_tasks':len(tasks),'total_waves':1,'errors':[]}))
" 2>/dev/null || echo '{"waves":[],"total_waves":0,"errors":["Failed to parse tasks"]}')
  NUM_WAVES=1
fi

# --- START OBSERVER ---
OBSERVER_PID=""
if [ "$DO_OBSERVE" = "1" ] && [ -f "$SCRIPT_DIR/observer.sh" ]; then
  bash "$SCRIPT_DIR/observer.sh" "$WORKSPACE" &
  OBSERVER_PID=$!
  echo "[UAS] Observer started (pid=$OBSERVER_PID)"
fi

# --- PRE-EXEC HOOKS ---
run_hook "pre-exec" "$TASKS_FILE"

# --- EXECUTE WAVES ---
TOTAL_PASS=0
TOTAL_FAIL=0
TOTAL_SKIP=0

for WAVE_IDX in $(seq 0 $((NUM_WAVES - 1))); do
  WAVE_TASKS=$(echo "$SCHEDULE" | python3 -c "
import sys, json
waves = json.load(sys.stdin)['waves']
for w in waves:
    if w['wave'] == $WAVE_IDX:
        for t in w['tasks']:
            print(json.dumps(t))
")

  WAVE_SIZE=$(echo "$WAVE_TASKS" | grep -c . || echo 0)
  echo ""
  echo "[UAS] === Wave $WAVE_IDX ($WAVE_SIZE tasks) ==="

  PIDS_FILE="$WORKSPACE/.uas/logs/wave${WAVE_IDX}_pids"
  RUNNING=0

  while IFS= read -r task_json; do
    [ -z "$task_json" ] && continue
    TID=$(echo "$task_json" | python3 -c "import sys,json; print(json.load(sys.stdin)['id'])")
    CMD=$(echo "$task_json" | python3 -c "import sys,json; print(json.load(sys.stdin)['cmd'])")
    TIMEOUT=$(echo "$task_json" | python3 -c "import sys,json; print(json.load(sys.stdin).get('timeout',300))")
    RETRY_MAX=$(echo "$task_json" | python3 -c "import sys,json; print(json.load(sys.stdin).get('retry',1))")

    # Skip if already completed (checkpoint resume)
    if check_already_done "$TID"; then
      echo "  $TID: SKIP (already done)"
      TOTAL_SKIP=$((TOTAL_SKIP + 1))
      continue
    fi

    # Throttle: wait for slot
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

    echo "  $TID: DISPATCHING"
    echo "RUNNING" > "$WORKSPACE/.uas/status/${TID}.st"
    echo "$(date +%s)" > "$WORKSPACE/.uas/status/${TID}.start"

    # Execute with timeout
    (
      timeout "$TIMEOUT" bash -c "$CMD" \
        > "$WORKSPACE/.uas/results/${TID}.out" \
        2> "$WORKSPACE/.uas/results/${TID}.err"
      echo $? > "$WORKSPACE/.uas/status/${TID}.exit"
    ) &
    WORKER_PID=$!
    echo "${WORKER_PID}:${TID}" >> "$PIDS_FILE"
    echo "$WORKER_PID" > "$WORKSPACE/.uas/status/${TID}.pid"
    RUNNING=$((RUNNING + 1))

  done <<< "$WAVE_TASKS"

  # Wait for wave completion
  echo "[UAS] Waiting for wave $WAVE_IDX to complete..."
  if [ -f "$PIDS_FILE" ]; then
    while IFS=: read -r pid tid; do
      wait "$pid" 2>/dev/null || true
    done < "$PIDS_FILE"
  fi

  # Evaluate wave results
  echo "[UAS] Wave $WAVE_IDX results:"
  WAVE_PASS=0; WAVE_FAIL=0
  if [ -f "$PIDS_FILE" ]; then
    while IFS=: read -r pid tid; do
      EXIT_CODE=$(cat "$WORKSPACE/.uas/status/${tid}.exit" 2>/dev/null || echo "1")
      ELAPSED=$(( $(date +%s) - $(cat "$WORKSPACE/.uas/status/${tid}.start" 2>/dev/null || echo "$(date +%s)") ))
      echo "$ELAPSED" > "$WORKSPACE/.uas/status/${tid}.time"

      if [ "$EXIT_CODE" = "0" ]; then
        # Run post-exec hooks
        if run_hook "post-exec" "$WORKSPACE/.uas/results/${tid}.out" 2>/dev/null; then
          echo "DONE" > "$WORKSPACE/.uas/status/${tid}.st"
          echo "  $tid: PASS (${ELAPSED}s)"
          WAVE_PASS=$((WAVE_PASS + 1))
        else
          echo "FAILED" > "$WORKSPACE/.uas/status/${tid}.st"
          echo "  $tid: HOOK_FAIL (${ELAPSED}s)"
          run_hook "on-error" "$WORKSPACE/.uas/results/${tid}.out" 2>/dev/null || true
          WAVE_FAIL=$((WAVE_FAIL + 1))
        fi
      else
        echo "FAILED" > "$WORKSPACE/.uas/status/${tid}.st"
        echo "  $tid: FAIL exit=$EXIT_CODE (${ELAPSED}s)"
        run_hook "on-error" "$WORKSPACE/.uas/results/${tid}.err" 2>/dev/null || true
        WAVE_FAIL=$((WAVE_FAIL + 1))
      fi
    done < "$PIDS_FILE"
  fi

  TOTAL_PASS=$((TOTAL_PASS + WAVE_PASS))
  TOTAL_FAIL=$((TOTAL_FAIL + WAVE_FAIL))

  # Checkpoint after wave
  if [ "$DO_CHECKPOINT" = "1" ] && [ -f "$SCRIPT_DIR/checkpoint.sh" ]; then
    bash "$SCRIPT_DIR/checkpoint.sh" save "$WORKSPACE" "$(basename "$WORKSPACE")-wave${WAVE_IDX}" 2>/dev/null || true
  fi

  # Block downstream waves if any task in this wave failed with dependents
  if [ $WAVE_FAIL -gt 0 ]; then
    echo "[UAS] WARNING: $WAVE_FAIL failures in wave $WAVE_IDX — downstream dependent tasks may be blocked"
  fi
done

# --- AGGREGATE RESULTS ---
MERGED="$WORKSPACE/.uas/results/merged_output.txt"
for f in "$WORKSPACE"/.uas/results/*.out; do
  [ -f "$f" ] || continue
  BASENAME=$(basename "$f" .out)
  echo "======== $BASENAME ========" >> "$MERGED"
  cat "$f" >> "$MERGED"
  echo "" >> "$MERGED"
done

# --- ON-COMPLETE HOOKS ---
run_hook "on-complete" "$MERGED"

# --- STOP OBSERVER ---
if [ -n "$OBSERVER_PID" ]; then
  kill "$OBSERVER_PID" 2>/dev/null || true
fi

# --- FINAL CHECKPOINT ---
if [ "$DO_CHECKPOINT" = "1" ] && [ -f "$SCRIPT_DIR/checkpoint.sh" ]; then
  bash "$SCRIPT_DIR/checkpoint.sh" save "$WORKSPACE" "$(basename "$WORKSPACE")-final" 2>/dev/null || true
fi

cat <<EOF

[UAS] Orchestration Complete
  Workspace: $WORKSPACE
  Total: $TOTAL | Pass: $TOTAL_PASS | Fail: $TOTAL_FAIL | Skipped: $TOTAL_SKIP
  Waves: $NUM_WAVES
  Merged output: $MERGED
  Individual results: $WORKSPACE/.uas/results/
EOF
