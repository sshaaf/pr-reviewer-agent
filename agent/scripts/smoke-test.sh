#!/usr/bin/env bash
# Smoke-test the pr-reviewer-agent image.
# Verifies: baked config present, rgctl available, skill present, opencode health API returns healthy.
set -euo pipefail

IMAGE="${1:-pr-reviewer-agent:latest}"
PASSWORD="${SMOKE_TEST_PASSWORD:-smoke-secret}"
CONTAINER_NAME="agent-smoke-${RANDOM}"
HEALTH_URL="http://127.0.0.1:4096/global/health"
MAX_WAIT="${SMOKE_TEST_TIMEOUT_SECONDS:-60}"

cleanup() { docker rm -f "${CONTAINER_NAME}" >/dev/null 2>&1 || true; }
trap cleanup EXIT

echo "Verifying baked artifacts in ${IMAGE}..."
docker run --rm --entrypoint sh "${IMAGE}" -c '
  test -f /app/opencode.json || { echo "FAIL: opencode.json missing"; exit 1; }
  test -f /app/.opencode/skills/rgctl-pr-reviewer-v2/SKILL.md || { echo "FAIL: skill missing"; exit 1; }
  rgctl --version || { echo "FAIL: rgctl not on PATH"; exit 1; }
  echo "Static checks passed."
'

echo "Starting container ${CONTAINER_NAME}..."
docker run -d --name "${CONTAINER_NAME}" \
  -e "OPENCODE_SERVER_PASSWORD=${PASSWORD}" \
  -e "ANTHROPIC_API_KEY=dummy-for-smoke" \
  -p 4096:4096 \
  "${IMAGE}" >/dev/null

echo "Waiting up to ${MAX_WAIT}s for ${HEALTH_URL}..."
deadline=$((SECONDS + MAX_WAIT))
healthy=0
while (( SECONDS < deadline )); do
  if response="$(curl -sf -u "opencode:${PASSWORD}" "${HEALTH_URL}" 2>/dev/null)"; then
    if echo "${response}" | grep -q '"healthy"[[:space:]]*:[[:space:]]*true'; then
      echo "Health check passed: ${response}"
      healthy=1
      break
    fi
  fi
  sleep 2
done

(( healthy == 1 )) || { echo "::error::Smoke test timed out"; docker logs "${CONTAINER_NAME}" 2>&1 | tail -30; exit 1; }
echo "Smoke test passed."
