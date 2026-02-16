#!/usr/bin/env bash
# init_workspace.sh — Initialize a UAS workspace
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
mkdir -p "$WORKSPACE"/{tasks,results,stages,hooks,logs}

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

cat > "$WORKSPACE/tasks/example.jsonl" <<'TASKEOF'
{"id":"w1","cmd":"echo 'Worker 1 processing...' && sleep 1 && echo 'w1 done'"}
{"id":"w2","cmd":"echo 'Worker 2 processing...' && sleep 1 && echo 'w2 done'"}
{"id":"w3","cmd":"echo 'Worker 3 processing...' && sleep 1 && echo 'w3 done'"}
TASKEOF

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
bash "$SCRIPT_DIR/detect_env.sh" > "$WORKSPACE/env.json" 2>/dev/null || true

cat <<EOF
[UAS] Workspace initialized: $WORKSPACE
  tasks/       — JSONL task definitions
  results/     — Worker outputs
  stages/      — Pipeline stage scripts
  hooks/       — Hook scripts
  logs/        — Execution logs
  hooks.json   — Hook configuration
  env.json     — Environment capabilities

Next steps:
  1. Define tasks in tasks/*.jsonl
  2. Configure hooks in hooks.json
  3. Run: bash scripts/orchestrate.sh $WORKSPACE/tasks/example.jsonl
EOF
