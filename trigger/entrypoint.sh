#!/usr/bin/env bash
# Select GitLab or GitHub App trigger process.
# Dual-provider (both /hooks/gitlab and /hooks/github in one process) is out of scope —
# set TRIGGER_PROVIDER to exactly one of: gitlab | github.
set -euo pipefail
PROVIDER="${TRIGGER_PROVIDER:-gitlab}"
export PYTHONPATH="/app/trigger${PYTHONPATH:+:$PYTHONPATH}"
case "${PROVIDER}" in
  github|gh)
    exec python3 /app/trigger/github_app.py
    ;;
  gitlab|gl|*)
    exec python3 /app/trigger/app.py
    ;;
esac
