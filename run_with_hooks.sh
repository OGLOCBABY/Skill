#!/usr/bin/env bash
# run_with_hooks.sh — Execute a command with full hook lifecycle + auto-retry
# Usage: run_with_hooks.sh <cmd> <output_file> [--hooks hooks.json] [--retries N]
set -euo pipefail

CMD="${1:?Usage: run_with_hooks.sh <cmd> <output_file> [--hooks hooks.json] [--retries N]}"
OUTPUT="${2:?Output file path required}"
HOOKS_CONFIG="hooks.json"
MAX_RETRIES=3
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

shift 2
while [[ $# -gt 0 ]]; do
  case $1 in
    --hooks) HOOKS_CONFIG=$2; shift 2;;
    --retries) MAX_RETRIES=$2; shift 2;;
    *) shift;;
  esac
done

run_hook() {
  [ -f "$HOOKS_CONFIG" ] || return 0
  bash "$SCRIPT_DIR/run_hooks.sh" "$1" "${2:-}" "$HOOKS_CONFIG"
}

ATTEMPT=0
run_hook "pre-exec" ""

while [ $ATTEMPT -lt $MAX_RETRIES ]; do
  ATTEMPT=$((ATTEMPT + 1))
  echo "[UAS] Attempt $ATTEMPT/$MAX_RETRIES: $CMD"

  bash -c "$CMD" > "$OUTPUT" 2> "${OUTPUT}.err"
  EXIT_CODE=$?

  if [ $EXIT_CODE -ne 0 ]; then
    echo "[UAS] Command failed (exit=$EXIT_CODE)" >&2
    run_hook "on-error" "${OUTPUT}.err"
    continue
  fi

  if run_hook "post-exec" "$OUTPUT"; then
    echo "[UAS] All hooks passed on attempt $ATTEMPT"
    run_hook "on-complete" "$OUTPUT"
    exit 0
  fi

  echo "[UAS] Post-exec hook failed, retrying..." >&2
  run_hook "on-error" "$OUTPUT"
done

echo "[UAS] FAILED after $MAX_RETRIES attempts" >&2
exit 1
