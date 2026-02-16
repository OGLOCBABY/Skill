#!/usr/bin/env bash
# pipeline.sh — Stage-based pipeline with gate hooks
# Usage: pipeline.sh <stages_dir> [--hooks hooks.json] [--input input_file]
set -euo pipefail

STAGES_DIR="${1:?Usage: pipeline.sh <stages_dir> [--hooks hooks.json] [--input file]}"
HOOKS_CONFIG=""
INPUT_FILE=""
PIPE_DIR=$(mktemp -d /tmp/uas-pipe-XXXX)
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

shift
while [[ $# -gt 0 ]]; do
  case $1 in
    --hooks) HOOKS_CONFIG=$2; shift 2;;
    --input) INPUT_FILE=$2; shift 2;;
    *) shift;;
  esac
done

run_hook() {
  local point=$1; local target=${2:-""}
  [ -z "$HOOKS_CONFIG" ] && return 0
  bash "$SCRIPT_DIR/run_hooks.sh" "$point" "$target" "$HOOKS_CONFIG"
}

mapfile -t STAGES < <(find "$STAGES_DIR" -maxdepth 1 -name "*.sh" -type f | sort)

if [ ${#STAGES[@]} -eq 0 ]; then
  echo "[UAS] No stages found in $STAGES_DIR" >&2
  exit 1
fi

echo "[UAS] Pipeline: ${#STAGES[@]} stages | workspace=$PIPE_DIR"

PREV_OUTPUT="$INPUT_FILE"
for i in "${!STAGES[@]}"; do
  STAGE="${STAGES[$i]}"
  STAGE_NAME=$(basename "$STAGE" .sh)
  STAGE_OUT="$PIPE_DIR/${STAGE_NAME}.out"
  STAGE_ERR="$PIPE_DIR/${STAGE_NAME}.err"

  if [ -n "$PREV_OUTPUT" ] && [ "$i" -gt 0 ]; then
    echo "[UAS] Gate check before stage $STAGE_NAME..."
    if ! run_hook "gate" "$PREV_OUTPUT"; then
      echo "[UAS] Pipeline HALTED at gate before $STAGE_NAME" >&2
      echo "[UAS] Last good output: $PREV_OUTPUT"
      exit 1
    fi
  fi

  echo "[UAS] Stage $((i+1))/${#STAGES[@]}: $STAGE_NAME"
  run_hook "pre-exec" "$STAGE"

  if [ -n "$PREV_OUTPUT" ] && [ -f "$PREV_OUTPUT" ]; then
    bash "$STAGE" < "$PREV_OUTPUT" > "$STAGE_OUT" 2> "$STAGE_ERR"
  else
    bash "$STAGE" > "$STAGE_OUT" 2> "$STAGE_ERR"
  fi

  EXIT_CODE=$?
  if [ $EXIT_CODE -ne 0 ]; then
    echo "[UAS] Stage $STAGE_NAME FAILED (exit=$EXIT_CODE)" >&2
    cat "$STAGE_ERR" >&2
    run_hook "on-error" "$STAGE_ERR"
    exit 1
  fi

  run_hook "post-exec" "$STAGE_OUT"
  PREV_OUTPUT="$STAGE_OUT"
  echo "[UAS] Stage $STAGE_NAME complete → $STAGE_OUT"
done

run_hook "on-complete" "$PREV_OUTPUT"

echo ""
echo "[UAS] Pipeline complete. Final output: $PREV_OUTPUT"
echo "[UAS] All stage outputs: $PIPE_DIR/"