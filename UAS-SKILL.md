---
name: ultra-agent-swarm
description: >
  Activate CLI-tier orchestration capabilities in Claude Desktop chat.
  Enables recursive task decomposition with parallel worker processes,
  tmux/background session management, hook-based validation loops,
  and Unix pipeline automation. Use this skill whenever the user needs
  multi-step automation, parallel execution, self-correcting workflows,
  persistent background tasks, or any task that benefits from spawning
  multiple coordinated processes. Also trigger when user says "swarm",
  "orchestrate", "parallel", "pipeline", "hook", "background task",
  "multi-agent", "tmux", "session", or asks to "run X while doing Y".
---

# Ultra Agent Swarm (UAS)

CLI-tier orchestration for Claude Desktop. This skill bridges the capability
gap between Claude Code CLI and Claude Desktop by implementing recursive
orchestration, session management, hook systems, and pipeline automation
using the bash tools available in the Desktop container environment.

## Environment Detection (Run First)

Before any orchestration task, detect the execution environment to select
the right strategy. Run `scripts/detect_env.sh` or execute inline:

```bash
# Detect environment capabilities
HAS_TMUX=$(which tmux 2>/dev/null && echo 1 || echo 0)
HAS_CLAUDE_CLI=$(which claude 2>/dev/null && echo 1 || echo 0)
HAS_PARALLEL=$(which parallel 2>/dev/null && echo 1 || echo 0)
CAN_BG=$(bash -c 'echo ok &' 2>/dev/null && wait && echo 1 || echo 0)
echo "ENV: tmux=$HAS_TMUX cli=$HAS_CLAUDE_CLI parallel=$HAS_PARALLEL bg=$CAN_BG"
```

**Environment tiers:**
- **Tier 1 (Claude Code CLI)**: Full recursive spawning, native tmux, hooks via git/shell
- **Tier 2 (Desktop + tmux)**: tmux sessions, background processes, shell hooks
- **Tier 3 (Desktop minimal)**: Background processes, xargs parallelism, shell hooks

The skill auto-adapts. All patterns below include tier-specific implementations.

---

## 1. Recursive Orchestration

Decompose complex tasks into a coordinator + multiple workers that execute
in parallel, with results aggregated back to the coordinator.

### Pattern: Coordinator-Worker

```
┌─────────────┐
│ COORDINATOR  │  ← Decomposes task, dispatches, aggregates
└──────┬──────┘
       │ spawn N workers
  ┌────┼────┐
  ▼    ▼    ▼
┌───┐┌───┐┌───┐
│W1 ││W2 ││W3 │  ← Each worker: isolated task, writes to own output file
└─┬─┘└─┬─┘└─┬─┘
  │    │    │
  ▼    ▼    ▼
  results/w1 results/w2 results/w3
       │
  ┌────┴────┐
  │AGGREGATE │  ← Coordinator merges all results
  └─────────┘
```

### Implementation

Use `scripts/orchestrate.sh` for the full pattern. Core logic:

```bash
WORKDIR=$(mktemp -d /tmp/uas-XXXX)
TASK_FILE="$WORKDIR/tasks.jsonl"  # one JSON task per line
RESULTS_DIR="$WORKDIR/results"
mkdir -p "$RESULTS_DIR"

# --- DECOMPOSE: write subtasks ---
# Each line: {"id":"w1","cmd":"...","args":"..."}

# --- DISPATCH: launch workers in parallel ---
while IFS= read -r task; do
  id=$(echo "$task" | python3 -c "import sys,json; print(json.load(sys.stdin)['id'])")
  cmd=$(echo "$task" | python3 -c "import sys,json; print(json.load(sys.stdin)['cmd'])")
  # Launch worker in background, redirect output
  bash -c "$cmd" > "$RESULTS_DIR/$id.out" 2> "$RESULTS_DIR/$id.err" &
done < "$TASK_FILE"

# --- WAIT: all workers complete ---
wait

# --- AGGREGATE: merge results ---
for f in "$RESULTS_DIR"/*.out; do
  echo "=== $(basename $f .out) ==="
  cat "$f"
done > "$WORKDIR/merged_result.txt"
```

**Tier 1 enhancement** (Claude Code CLI): Replace `bash -c "$cmd"` with
`claude -p "$cmd" --output-format text` to spawn actual Claude instances
as workers, enabling recursive AI reasoning chains.

### Self-Iterating Pattern

For tasks requiring self-review and correction:

```bash
MAX_ITERATIONS=3
ITERATION=0
STATUS="needs_work"

while [ "$STATUS" != "pass" ] && [ $ITERATION -lt $MAX_ITERATIONS ]; do
  # Execute task
  bash -c "$TASK_CMD" > "$WORKDIR/output_v${ITERATION}.txt" 2>&1

  # Run validation hook (see Section 3)
  STATUS=$(bash scripts/validate_hook.sh "$WORKDIR/output_v${ITERATION}.txt")

  if [ "$STATUS" != "pass" ]; then
    # Feed error back as input to next iteration
    TASK_CMD="$ORIGINAL_CMD --fix-errors $(cat $WORKDIR/output_v${ITERATION}.err)"
  fi
  ITERATION=$((ITERATION + 1))
done
```

---

## 2. Session Management

Persistent, concurrent task execution with context isolation.

### Tier 1/2: tmux Sessions

```bash
# Create named session for a workstream
tmux new-session -d -s "uas-main"
tmux new-window -t "uas-main" -n "worker1"
tmux new-window -t "uas-main" -n "worker2"

# Dispatch commands to isolated windows
tmux send-keys -t "uas-main:worker1" "python3 analyze.py data1.csv > /tmp/r1.txt" Enter
tmux send-keys -t "uas-main:worker2" "python3 analyze.py data2.csv > /tmp/r2.txt" Enter

# Monitor from coordinator window
tmux send-keys -t "uas-main:0" "tail -f /tmp/r1.txt /tmp/r2.txt" Enter

# Capture output programmatically
tmux capture-pane -t "uas-main:worker1" -p > /tmp/worker1_transcript.txt
```

Session lifecycle management via `scripts/session_manager.sh`:
- `init <name> <num_workers>` — create session with N worker windows
- `dispatch <name> <worker> <cmd>` — send command to specific worker
- `status <name>` — check all worker states
- `collect <name> <output_dir>` — gather all worker outputs
- `teardown <name>` — clean up session

### Tier 3: Background Process Manager (tmux fallback)

When tmux is unavailable, use PID-tracked background processes:

```bash
# scripts/bg_manager.sh handles this automatically
PIDFILE="/tmp/uas-pids-$$"

# Launch tracked background processes
launch_worker() {
  local id=$1; shift
  "$@" > "/tmp/uas-out-$id" 2> "/tmp/uas-err-$id" &
  echo "$!:$id" >> "$PIDFILE"
}

# Wait for all workers
wait_all() {
  while IFS=: read -r pid id; do
    wait "$pid"
    echo "$id:$?" >> "/tmp/uas-status-$$"
  done < "$PIDFILE"
}

# Check which workers are still running
status_all() {
  while IFS=: read -r pid id; do
    if kill -0 "$pid" 2>/dev/null; then
      echo "$id: RUNNING (pid=$pid)"
    else
      echo "$id: DONE"
    fi
  done < "$PIDFILE"
}
```

---

## 3. Hook System

Deterministic validation and auto-correction loops.

### Hook Types

| Hook Point   | Trigger                        | Purpose                           |
|-------------|-------------------------------|-----------------------------------|
| pre-exec    | Before worker starts          | Validate inputs, check deps       |
| post-exec   | After worker completes        | Lint, test, validate output       |
| on-error    | Worker exits non-zero         | Auto-retry, escalate, log         |
| on-complete | All workers done              | Aggregate, report, cleanup        |
| gate        | Between pipeline stages       | Quality gate — block or pass      |

### Hook Configuration

Create `hooks.json` in your workspace:

```json
{
  "hooks": {
    "pre-exec": ["scripts/check_deps.sh"],
    "post-exec": [
      "scripts/lint_output.sh",
      "scripts/run_tests.sh"
    ],
    "on-error": ["scripts/auto_fix.sh"],
    "gate": {
      "command": "scripts/quality_gate.sh",
      "pass_exit_code": 0,
      "retry_limit": 2
    }
  }
}
```

### Hook Runner

`scripts/run_hooks.sh` executes hooks at each lifecycle point:

```bash
run_hooks() {
  local hook_point=$1
  local target_file=$2
  local hooks_config=${3:-"hooks.json"}

  # Extract hook commands for this point
  local cmds=$(python3 -c "
import json, sys
cfg = json.load(open('$hooks_config'))
hooks = cfg.get('hooks',{}).get('$hook_point',[])
if isinstance(hooks, dict): hooks = [hooks.get('command','')]
for h in hooks: print(h)
")

  local all_pass=0
  while IFS= read -r cmd; do
    [ -z "$cmd" ] && continue
    if ! bash "$cmd" "$target_file"; then
      echo "HOOK FAILED: $hook_point/$cmd on $target_file" >&2
      all_pass=1
    fi
  done <<< "$cmds"
  return $all_pass
}
```

### Auto-Correction Loop (Hook + Orchestration Combined)

```bash
# Full self-correcting execution cycle
execute_with_hooks() {
  local cmd=$1
  local output=$2
  local max_retries=${3:-3}
  local attempt=0

  run_hooks "pre-exec" ""

  while [ $attempt -lt $max_retries ]; do
    bash -c "$cmd" > "$output" 2> "${output}.err"
    exit_code=$?

    if [ $exit_code -ne 0 ]; then
      run_hooks "on-error" "${output}.err"
      attempt=$((attempt + 1))
      continue
    fi

    if run_hooks "post-exec" "$output"; then
      run_hooks "on-complete" "$output"
      return 0
    fi

    # Post-exec hook failed — auto-fix and retry
    run_hooks "on-error" "$output"
    attempt=$((attempt + 1))
  done

  echo "FAILED after $max_retries attempts" >&2
  return 1
}
```

---

## 4. Pipeline Automation

Unix pipe-style chaining of processing stages with gate hooks between them.

### Linear Pipeline

```bash
# scripts/pipeline.sh — stage-based execution
STAGES=("stage1.sh" "stage2.sh" "stage3.sh")
PIPE_DIR=$(mktemp -d /tmp/uas-pipe-XXXX)

prev_output=""
for i in "${!STAGES[@]}"; do
  stage="${STAGES[$i]}"
  stage_out="$PIPE_DIR/stage_${i}.out"

  # Gate hook between stages
  if [ -n "$prev_output" ]; then
    if ! run_hooks "gate" "$prev_output"; then
      echo "Pipeline halted at gate before stage $i" >&2
      exit 1
    fi
  fi

  # Execute stage with previous output as input
  if [ -n "$prev_output" ]; then
    bash "$stage" < "$prev_output" > "$stage_out" 2> "$PIPE_DIR/stage_${i}.err"
  else
    bash "$stage" > "$stage_out" 2> "$PIPE_DIR/stage_${i}.err"
  fi

  if [ $? -ne 0 ]; then
    run_hooks "on-error" "$PIPE_DIR/stage_${i}.err"
    exit 1
  fi

  prev_output="$stage_out"
done

# Final output
cat "$prev_output"
```

### Fan-Out / Fan-In Pipeline

For stages that can run in parallel:

```
Input → [Split] → Worker1 ─┐
                  Worker2 ─┤→ [Merge] → Output
                  Worker3 ─┘
```

Use the orchestrator from Section 1 as the fan-out/fan-in mechanism.
Split input via `split` or custom logic, dispatch to workers, aggregate.

---

## 5. Workflow Templates

Read `references/workflow-templates.md` for ready-to-use templates:

- **Code Review Swarm** — parallel lint + test + security scan with merged report
- **Research Pipeline** — search → extract → analyze → synthesize
- **Data Processing** — split CSV → parallel transform → merge
- **Build & Validate** — compile → test → hook-gate → deploy
- **Document Generation** — outline → parallel section writing → merge → review hook

---

## 6. Operational Commands

Quick-reference for common operations:

| Action                     | Command                                           |
|---------------------------|---------------------------------------------------|
| Initialize workspace       | `bash scripts/init_workspace.sh <name>`           |
| Detect environment         | `bash scripts/detect_env.sh`                      |
| Launch orchestration       | `bash scripts/orchestrate.sh <tasks.jsonl>`       |
| Manage sessions            | `bash scripts/session_manager.sh <action> <args>` |
| Run with hooks             | `bash scripts/run_with_hooks.sh <cmd> <output>`   |
| Execute pipeline           | `bash scripts/pipeline.sh <stages_dir>`           |
| Status dashboard           | `bash scripts/status.sh <workspace>`              |

---

## Constraints & Limitations

- **Desktop container resets between conversations** — all state is ephemeral.
  For persistence across sessions, write final outputs to `/mnt/user-data/outputs/`
  or user's filesystem via MCP.
- **No native Claude-spawns-Claude in Desktop** — recursive AI reasoning requires
  Tier 1 (Claude Code CLI). Desktop tier simulates via bash process parallelism.
- **tmux may need installation** — if unavailable, the skill auto-falls back to
  background process management. Functionality is equivalent; monitoring is less rich.
- **Container resource limits** — don't spawn more than 8-10 parallel workers
  in Desktop container to avoid OOM or throttling.
