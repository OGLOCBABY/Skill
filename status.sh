#!/usr/bin/env bash
# status.sh — Show UAS workspace status
# Usage: status.sh <workspace_dir>
set -euo pipefail

WORKSPACE="${1:?Usage: status.sh <workspace_dir>}"

echo "[UAS] Status for workspace: $WORKSPACE"
echo ""

if [ -f "$WORKSPACE/env.json" ]; then
  echo "Environment:"
  cat "$WORKSPACE/env.json"
  echo ""
fi

echo "Workers:"
for outfile in "$WORKSPACE"/results/*.out 2>/dev/null; do
  [ -f "$outfile" ] || continue
  WID=$(basename "$outfile" .out)
  ERRFILE="$WORKSPACE/results/${WID}.err"
  SIZE=$(wc -c < "$outfile" 2>/dev/null || echo 0)
  if [ -s "$ERRFILE" ]; then
    echo "  $WID: DONE (output: ${SIZE}B, has errors)"
  else
    echo "  $WID: DONE (output: ${SIZE}B)"
  fi
done

if ls "$WORKSPACE"/results/*.out >/dev/null 2>&1; then
  TOTAL=$(ls "$WORKSPACE"/results/*.out 2>/dev/null | wc -l)
  echo ""
  echo "Total workers: $TOTAL"
else
  echo "  (no results yet)"
fi

if [ -f "$WORKSPACE/merged_output.txt" ]; then
  echo ""
  echo "Merged output: $WORKSPACE/merged_output.txt ($(wc -c < "$WORKSPACE/merged_output.txt")B)"
fi
