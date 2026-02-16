#!/usr/bin/env bash
# run_hooks.sh — Execute hooks at lifecycle points
# Usage: run_hooks.sh <hook_point> <target_file> [hooks.json]
set -euo pipefail

HOOK_POINT="${1:?Hook point required (pre-exec|post-exec|on-error|on-complete|gate)}"
TARGET="${2:-""}"
CONFIG="${3:-hooks.json}"

if [ ! -f "$CONFIG" ]; then
  exit 0
fi

CMDS=$(python3 -c "
import json, sys
cfg = json.load(open('$CONFIG'))
hooks = cfg.get('hooks', {}).get('$HOOK_POINT', [])
if isinstance(hooks, str):
    hooks = [hooks]
elif isinstance(hooks, dict):
    hooks = [hooks.get('command', '')]
for h in hooks:
    if h: print(h)
" 2>/dev/null)

if [ -z "$CMDS" ]; then
  exit 0
fi

ALL_PASS=0
while IFS= read -r cmd; do
  [ -z "$cmd" ] && continue
  echo "[HOOK:$HOOK_POINT] Running: $cmd $TARGET"
  if bash "$cmd" "$TARGET"; then
    echo "[HOOK:$HOOK_POINT] PASS: $cmd"
  else
    echo "[HOOK:$HOOK_POINT] FAIL: $cmd" >&2
    ALL_PASS=1

    if [ "$HOOK_POINT" = "gate" ]; then
      RETRY_LIMIT=$(python3 -c "
import json
cfg = json.load(open('$CONFIG'))
g = cfg.get('hooks',{}).get('gate',{})
print(g.get('retry_limit', 0) if isinstance(g, dict) else 0)
" 2>/dev/null || echo 0)
      echo "[HOOK:gate] Retry limit: $RETRY_LIMIT"
    fi
  fi
done <<< "$CMDS"

exit $ALL_PASS
