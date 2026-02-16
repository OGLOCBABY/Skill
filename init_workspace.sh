#!/usr/bin/env bash
# init_workspace.sh — Initialize a UAS v2 workspace with .uas/ structure
# Usage: init_workspace.sh <workspace_name> [--dir path]
set -euo pipefail

NAME="${1:?Usage: init_workspace.sh <n> [--dir path]}"
BASE_DIR="/tmp"
shift
while [[ $# -gt 0 ]]; do
  case $1 in
    --dir) BASE_DIR=$2; shift 2;;
    *) shift;;
  esac
done

WORKSPACE="$BASE_DIR/uas-${NAME}"
mkdir -p "$WORKSPACE"/.uas/{tasks,results,status,checkpoints,logs}

# Default hooks configuration
cat > "$WORKSPACE/hooks.json" <<'HOOKEOF'
{
  "hooks": {
    "pre-exec": [],
    "post-exec": [],
    "on-error": [],
    "on-complete": [],
    "gate": {
      "command": "",
      "pass_exit_code": 0,
      "retry_limit": 2
    }
  }
}
HOOKEOF

# Example task file with dependencies
cat > "$WORKSPACE/.uas/tasks/example.jsonl" <<'TASKEOF'
{"id":"setup","cmd":"echo 'Setting up environment...' && sleep 1 && echo 'setup done'","deps":[],"priority":10,"timeout":60,"desc":"Initialize environment"}
{"id":"build","cmd":"echo 'Building project...' && sleep 2 && echo 'build done'","deps":["setup"],"priority":8,"timeout":120,"desc":"Compile project"}
{"id":"lint","cmd":"echo 'Running linter...' && sleep 1 && echo '0 issues'","deps":["setup"],"priority":5,"timeout":60,"desc":"Static analysis"}
{"id":"test","cmd":"echo 'Running tests...' && sleep 2 && echo '15/15 passed'","deps":["build"],"priority":7,"timeout":180,"desc":"Unit tests"}
{"id":"report","cmd":"echo 'Generating report...' && sleep 1 && echo 'All checks passed'","deps":["test","lint"],"priority":3,"timeout":60,"desc":"Final report"}
TASKEOF

# Detect environment
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
if [ -f "$SCRIPT_DIR/detect_env.sh" ]; then
  bash "$SCRIPT_DIR/detect_env.sh" > "$WORKSPACE/env.json" 2>/dev/null || true
fi

cat <<EOF
[UAS] Workspace initialized: $WORKSPACE
  .uas/tasks/      — JSONL task definitions (with deps, priority, timeout)
  .uas/results/    — Worker outputs
  .uas/status/     — Per-worker state tracking
  .uas/logs/       — Execution logs and observer output
  .uas/checkpoints/ — Local checkpoint metadata
  hooks.json       — Hook configuration
  env.json         — Environment capabilities

Example DAG (setup → build → test, setup → lint, test+lint → report):
  Run: bash scripts/orchestrate.sh $WORKSPACE/.uas/tasks/example.jsonl --workspace $WORKSPACE
EOF
