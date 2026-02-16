#!/usr/bin/env bash
# detect_env.sh — Detect UAS execution environment tier
set -euo pipefail

HAS_TMUX=0; which tmux >/dev/null 2>&1 && HAS_TMUX=1
HAS_CLI=0; which claude >/dev/null 2>&1 && HAS_CLI=1
HAS_PARALLEL=0; which parallel >/dev/null 2>&1 && HAS_PARALLEL=1
CAN_BG=0; bash -c 'echo ok &' >/dev/null 2>&1 && wait && CAN_BG=1
HAS_XARGS=0; which xargs >/dev/null 2>&1 && HAS_XARGS=1

if [ "$HAS_CLI" = "1" ]; then
  TIER=1
  TIER_NAME="Claude Code CLI (Full)"
elif [ "$HAS_TMUX" = "1" ]; then
  TIER=2
  TIER_NAME="Desktop + tmux"
else
  TIER=3
  TIER_NAME="Desktop Minimal"
fi

cat <<EOF
{
  "tier": $TIER,
  "tier_name": "$TIER_NAME",
  "capabilities": {
    "tmux": $HAS_TMUX,
    "claude_cli": $HAS_CLI,
    "gnu_parallel": $HAS_PARALLEL,
    "background_processes": $CAN_BG,
    "xargs": $HAS_XARGS
  },
  "max_workers": $([ $TIER -eq 1 ] && echo 16 || echo 8),
  "recursive_ai": $([ $HAS_CLI -eq 1 ] && echo true || echo false),
  "session_backend": "$([ $HAS_TMUX -eq 1 ] && echo tmux || echo bg_process)"
}
EOF
