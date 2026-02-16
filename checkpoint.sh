#!/usr/bin/env bash
# checkpoint.sh — Save, resume, and list UAS workspace checkpoints
# Usage:
#   checkpoint.sh save <workspace> [checkpoint_name]
#   checkpoint.sh resume <checkpoint_name>
#   checkpoint.sh list
set -euo pipefail

ACTION="${1:?Usage: checkpoint.sh <save|resume|list> [args]}"
PERSIST_DIR="/mnt/user-data/outputs/uas_checkpoints"
mkdir -p "$PERSIST_DIR"

case "$ACTION" in
  save)
    WORKSPACE="${2:?Workspace path required}"
    CKPT_NAME="${3:-$(basename "$WORKSPACE")-$(date +%Y%m%dT%H%M%S)}"
    CKPT_FILE="$PERSIST_DIR/${CKPT_NAME}.tar.gz"

    if [ ! -d "$WORKSPACE/.uas" ]; then
      echo "[CHECKPOINT] ERROR: No .uas/ directory in $WORKSPACE" >&2
      exit 1
    fi

    # Save metadata
    cat > "$WORKSPACE/.uas/checkpoint_meta.json" <<METAEOF
{
  "checkpoint_name": "$CKPT_NAME",
  "workspace": "$WORKSPACE",
  "timestamp": "$(date -Iseconds)",
  "hostname": "$(hostname 2>/dev/null || echo unknown)"
}
METAEOF

    # Tar workspace state (tasks, status, results, logs, config)
    tar -czf "$CKPT_FILE" \
      -C "$(dirname "$WORKSPACE")" \
      "$(basename "$WORKSPACE")/.uas" \
      "$(basename "$WORKSPACE")/hooks.json" \
      "$(basename "$WORKSPACE")/env.json" \
      2>/dev/null || true

    SIZE=$(du -sh "$CKPT_FILE" 2>/dev/null | cut -f1 || echo "?")
    echo "[CHECKPOINT] Saved: $CKPT_FILE ($SIZE)"
    ;;

  resume)
    CKPT_NAME="${2:?Checkpoint name required}"
    CKPT_FILE="$PERSIST_DIR/${CKPT_NAME}.tar.gz"

    if [ ! -f "$CKPT_FILE" ]; then
      # Try with pattern match
      CKPT_FILE=$(ls -t "$PERSIST_DIR"/${CKPT_NAME}*.tar.gz 2>/dev/null | head -1)
      if [ -z "$CKPT_FILE" ] || [ ! -f "$CKPT_FILE" ]; then
        echo "[CHECKPOINT] ERROR: No checkpoint found matching '$CKPT_NAME'" >&2
        echo "[CHECKPOINT] Available:" >&2
        ls "$PERSIST_DIR"/*.tar.gz 2>/dev/null | sed 's|.*/||;s|\.tar\.gz||' >&2 || echo "  (none)" >&2
        exit 1
      fi
    fi

    RESTORE_DIR="/tmp"
    tar -xzf "$CKPT_FILE" -C "$RESTORE_DIR"

    # Find restored workspace
    RESTORED=$(tar -tzf "$CKPT_FILE" | head -1 | cut -d/ -f1)
    WORKSPACE="$RESTORE_DIR/$RESTORED"

    # Read checkpoint metadata
    if [ -f "$WORKSPACE/.uas/checkpoint_meta.json" ]; then
      echo "[CHECKPOINT] Restored from: $(python3 -c "
import json
m = json.load(open('$WORKSPACE/.uas/checkpoint_meta.json'))
print(f\"{m['checkpoint_name']} (saved {m['timestamp']})\")
" 2>/dev/null || echo "$CKPT_NAME")"
    fi

    # Analyze task status
    TOTAL=0; DONE=0; PENDING=0; FAILED=0
    for sf in "$WORKSPACE"/.uas/status/*.st 2>/dev/null; do
      [ -f "$sf" ] || continue
      TOTAL=$((TOTAL + 1))
      STATUS=$(cat "$sf")
      case "$STATUS" in
        DONE) DONE=$((DONE + 1)) ;;
        FAILED) FAILED=$((FAILED + 1)) ;;
        *) PENDING=$((PENDING + 1)) ;;
      esac
    done

    cat <<EOF
[CHECKPOINT] Workspace restored: $WORKSPACE
  Tasks: $TOTAL total | $DONE done | $PENDING pending | $FAILED failed
  Next: Re-run orchestrate.sh on the task file — completed tasks will be skipped.
EOF
    ;;

  list)
    echo "[CHECKPOINT] Available checkpoints in $PERSIST_DIR:"
    if ls "$PERSIST_DIR"/*.tar.gz >/dev/null 2>&1; then
      for f in "$PERSIST_DIR"/*.tar.gz; do
        NAME=$(basename "$f" .tar.gz)
        SIZE=$(du -sh "$f" 2>/dev/null | cut -f1 || echo "?")
        MOD=$(date -r "$f" "+%Y-%m-%d %H:%M" 2>/dev/null || stat -c %y "$f" 2>/dev/null | cut -d. -f1 || echo "?")
        echo "  $NAME  ($SIZE, $MOD)"
      done
    else
      echo "  (none)"
    fi
    ;;

  *)
    echo "Unknown action: $ACTION" >&2
    echo "Usage: checkpoint.sh <save|resume|list>" >&2
    exit 1
    ;;
esac
