#!/bin/sh
# Start rgctl serve --watch as a background companion process, then start opencode serve.
# Both processes share the graph DB at /app/rgctl-db.
set -e

REPO_PATH="${REPO_PATH:-/app/repo}"
RGCTL_DB="${RGCTL_DB:-/app/rgctl-db}"

echo "[entrypoint] Starting rgctl serve --watch on ${REPO_PATH}"
rgctl serve \
  --watch \
  --no-pipeline \
  --query-only \
  --repo "${REPO_PATH}" \
  --db "${RGCTL_DB}" \
  --host 127.0.0.1 \
  --port 8080 &

RGCTL_PID=$!
echo "[entrypoint] rgctl serve --watch started (pid ${RGCTL_PID})"

echo "[entrypoint] Starting opencode serve on 0.0.0.0:4096"
exec opencode serve \
  --hostname 0.0.0.0 \
  --port 4096 \
  --print-logs \
  --log-level INFO
