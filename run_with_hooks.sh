#!/usr/bin/env bash
# run_with_hooks.sh — Execute a command with full hook lifecycle, auto-retry,
#                     and error classification
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

# Error classification — parse stderr to determine retry strategy
classify_error() {
  local errfile=$1
  [ ! -f "$errfile" ] || [ ! -s "$errfile" ] && echo "UNKNOWN" && return

  local content
  content=$(cat "$errfile" 2>/dev/null || echo "")

  # Timeout / killed
  if echo "$content" | grep -qi "timeout\|killed\|signal 9\|signal 15\|timed out"; then
    echo "TIMEOUT"
    return
  fi

  # Permission errors
  if echo "$content" | grep -qi "permission denied\|EACCES\|Operation not permitted"; then
    echo "PERMISSION"
    return
  fi

  # Missing dependencies / files
  if echo "$content" | grep -qi "No such file\|not found\|command not found\|ModuleNotFoundError\|ImportError"; then
    echo "MISSING_DEP"
    return
  fi

  # Code / syntax errors
  if echo "$content" | grep -qi "SyntaxError\|TypeError\|NameError\|ValueError\|IndentationError\|ReferenceError"; then
    echo "CODE_ERROR"
    return
  fi

  # Resource exhaustion
  if echo "$content" | grep -qi "OOM\|Cannot allocate\|out of memory\|MemoryError\|ENOMEM\|disk full\|No space"; then
    echo "RESOURCE"
    return
  fi

  # Network errors
  if echo "$content" | grep -qi "Connection refused\|ECONNREFUSED\|Network unreachable\|DNS\|ETIMEDOUT"; then
    echo "NETWORK"
    return
  fi

  echo "UNKNOWN"
}

# Determine if error class is retryable and what adjustment to make
should_retry() {
  local err_class=$1
  case "$err_class" in
    TIMEOUT)     echo "yes:extend_timeout" ;;
    PERMISSION)  echo "no:escalate" ;;
    MISSING_DEP) echo "yes:check_deps" ;;
    CODE_ERROR)  echo "yes:with_context" ;;
    RESOURCE)    echo "yes:reduce_load" ;;
    NETWORK)     echo "yes:wait_retry" ;;
    UNKNOWN)     echo "yes:generic" ;;
  esac
}

ATTEMPT=0
TIMEOUT_MULT=1

run_hook "pre-exec" ""

while [ $ATTEMPT -lt $MAX_RETRIES ]; do
  ATTEMPT=$((ATTEMPT + 1))
  echo "[UAS] Attempt $ATTEMPT/$MAX_RETRIES: $CMD"

  # Execute
  EFFECTIVE_CMD="$CMD"
  bash -c "$EFFECTIVE_CMD" > "$OUTPUT" 2> "${OUTPUT}.err"
  EXIT_CODE=$?

  if [ $EXIT_CODE -ne 0 ]; then
    ERR_CLASS=$(classify_error "${OUTPUT}.err")
    RETRY_DECISION=$(should_retry "$ERR_CLASS")
    RETRYABLE=${RETRY_DECISION%%:*}
    STRATEGY=${RETRY_DECISION##*:}

    echo "[UAS] Failed (exit=$EXIT_CODE) — Error class: $ERR_CLASS — Strategy: $STRATEGY"

    if [ "$RETRYABLE" = "no" ]; then
      echo "[UAS] Non-retryable error ($ERR_CLASS). Stopping." >&2
      run_hook "on-error" "${OUTPUT}.err"
      exit 1
    fi

    # Apply strategy adjustments
    case "$STRATEGY" in
      extend_timeout)
        TIMEOUT_MULT=$((TIMEOUT_MULT * 2))
        echo "[UAS] Extended timeout multiplier to ${TIMEOUT_MULT}x"
        ;;
      wait_retry)
        echo "[UAS] Network error — waiting 5s before retry"
        sleep 5
        ;;
      *)
        # Generic retry — run on-error hook which may auto-fix
        ;;
    esac

    run_hook "on-error" "${OUTPUT}.err"
    continue
  fi

  # Success — run post-exec validation
  if run_hook "post-exec" "$OUTPUT"; then
    echo "[UAS] All hooks passed on attempt $ATTEMPT"
    run_hook "on-complete" "$OUTPUT"
    exit 0
  fi

  echo "[UAS] Post-exec hook failed, retrying..." >&2
  run_hook "on-error" "$OUTPUT"
done

echo "[UAS] FAILED after $MAX_RETRIES attempts" >&2
echo "[UAS] Last error class: $(classify_error "${OUTPUT}.err")" >&2
echo "[UAS] Error output: $(tail -5 "${OUTPUT}.err" 2>/dev/null)" >&2
exit 1
