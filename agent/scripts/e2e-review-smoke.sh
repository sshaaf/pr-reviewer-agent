#!/usr/bin/env bash
# E2E smoke: coolstore-weblogic local branch → containerized opencode session → structured review.
#
# Artifacts are written to agent/e2e-runs/<timestamp>-<id>/ :
#   trace.out          step-by-step log (also mirrored to stdout)
#   meta.json          image, model, refs, session id, exit status
#   input.json         skill Input JSON
#   prompt.txt         prompt_async body text
#   session.json       create-session response
#   messages.json      final GET /session/:id/message
#   transcript.md      extracted assistant text
#   docker.log         container logs
#   git-diff.patch     base...HEAD patch
#   git-stat.txt       diff --stat
#   review-paths.json  host-side rgctl review paths (best-effort)
#   IMPACT_REPORT.md   skill-produced impact report (copied from fixture)
#   result.json        pass/fail + section / impact-report checks
#
# OpenCode session API (https://opencode.ai/docs/server):
#   POST /session, POST /session/:id/prompt_async,
#   GET  /session/status, GET /session/:id/message
#
# Required: LITELLM_API_KEY (via env or agent/.env)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AGENT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=load-env.sh
. "${SCRIPT_DIR}/load-env.sh"

IMAGE="${1:-${IMAGE:-pr-reviewer-agent:latest}}"
PASSWORD="${SMOKE_TEST_PASSWORD:-${OPENCODE_SERVER_PASSWORD:-e2e-smoke-secret}}"
CONTAINER_NAME="agent-e2e-${RANDOM}"
HOST_PORT="${E2E_HOST_PORT:-14096}"
BASE_URL="http://127.0.0.1:${HOST_PORT}"
AUTH_USER="opencode"
MAX_WAIT="${E2E_TIMEOUT_SECONDS:-900}"
POLL_INTERVAL="${E2E_POLL_SECONDS:-5}"
COOLSTORE_URL="${COOLSTORE_URL:-https://github.com/sshaaf/coolstore-weblogic.git}"
LITELLM_BASE_URL="${LITELLM_BASE_URL:-https://litemaas.rhoai.rh-aiservices-bu.com/v1}"
LITELLM_MODEL="${LITELLM_MODEL:-Qwen3.6-35B-A3B}"
WORK_ROOT="${E2E_WORK_ROOT:-$(mktemp -d -t coolstore-e2e-XXXXXX)}"
REPO_DIR="${WORK_ROOT}/coolstore-weblogic"
KEEP_WORK="${E2E_KEEP_WORK:-0}"
RUNS_ROOT="${E2E_RUNS_DIR:-${AGENT_DIR}/e2e-runs}"
RUN_ID="$(date +%Y%m%d-%H%M%S)-${RANDOM}"
RUN_DIR="${RUNS_ROOT}/${RUN_ID}"
EXIT_CODE=1

mkdir -p "${RUN_DIR}"
# Capture every subsequent stdout/stderr line into trace.out (and keep console).
exec > >(tee -a "${RUN_DIR}/trace.out") 2>&1

AUTH_HEADER="Authorization: Basic $(printf '%s' "${AUTH_USER}:${PASSWORD}" | base64 | tr -d '\n')"

trace() { printf '[%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }

write_result() {
  local status="$1" reason="${2:-}"
  local impact_ok="${IMPACT_ASSERT_OK:-false}"
  local sections_ok="${SECTIONS_ASSERT_OK:-false}"
  jq -n \
    --arg status "$status" \
    --arg reason "$reason" \
    --arg run_dir "$RUN_DIR" \
    --arg session_id "${SESSION_ID:-}" \
    --arg image "$IMAGE" \
    --arg model "$LITELLM_MODEL" \
    --arg base_url "$LITELLM_BASE_URL" \
    --argjson exit_code "$EXIT_CODE" \
    --argjson sections_ok "$sections_ok" \
    --argjson impact_ok "$impact_ok" \
    '{
      status: $status,
      reason: $reason,
      exit_code: $exit_code,
      run_dir: $run_dir,
      session_id: $session_id,
      image: $image,
      litellm_model: $model,
      litellm_base_url: $base_url,
      checks: {
        four_section_review: $sections_ok,
        impact_report: $impact_ok
      },
      finished_at: (now | todate)
    }' >"${RUN_DIR}/result.json"
}

cleanup() {
  local ec=$?
  EXIT_CODE=$ec
  docker logs "${CONTAINER_NAME}" >"${RUN_DIR}/docker.log" 2>&1 || true
  docker rm -f "${CONTAINER_NAME}" >/dev/null 2>&1 || true
  if [ ! -f "${RUN_DIR}/result.json" ]; then
    if [ "$ec" -eq 0 ]; then
      write_result passed
    else
      write_result failed "exit ${ec}"
    fi
  fi
  if [ "${KEEP_WORK}" != "1" ]; then
    rm -rf "${WORK_ROOT}" 2>/dev/null || true
  else
    trace "Keeping workdir: ${WORK_ROOT}"
    echo "${WORK_ROOT}" >"${RUN_DIR}/work_root.path"
  fi
  trace "Artifacts: ${RUN_DIR}"
  trace "trace.out → ${RUN_DIR}/trace.out"
}
trap cleanup EXIT

die() {
  trace "ERROR: $*"
  write_result failed "$*"
  echo "::error::$*" >&2
  exit 1
}

LLM_PROVIDER="${LLM_PROVIDER:-litellm}"
OPENAI_MODEL="${OPENAI_MODEL:-gpt-4o}"
if [ -n "${OPENCODE_MODEL:-}" ]; then
  _e2e_provider="${OPENCODE_MODEL%%/*}"
elif [ "${LLM_PROVIDER}" = "openai" ]; then
  _e2e_provider="openai"
else
  _e2e_provider="litellm"
fi
case "${_e2e_provider}" in
  openai)
    [ -n "${OPENAI_API_KEY:-}" ] || die "OPENAI_API_KEY is required when LLM_PROVIDER=openai (set in agent/.env)"
    ;;
  *)
    [ -n "${LITELLM_API_KEY:-}" ] || die "LITELLM_API_KEY is required when LLM_PROVIDER=litellm (set in agent/.env)"
    ;;
esac

command -v docker >/dev/null || die "docker is required"
command -v curl >/dev/null || die "curl is required"
command -v jq >/dev/null || die "jq is required"
command -v git >/dev/null || die "git is required"
command -v rgctl >/dev/null || die "rgctl is required on PATH to seed .rgctl-base"

trace "RUN_DIR=${RUN_DIR}"
trace "WORK_ROOT=${WORK_ROOT}"
trace "IMAGE=${IMAGE}"
trace "LLM_PROVIDER=${LLM_PROVIDER} OPENCODE_MODEL=${OPENCODE_MODEL:-}"
trace "LITELLM_BASE_URL=${LITELLM_BASE_URL}"
trace "LITELLM_MODEL=${LITELLM_MODEL}"
trace "OPENAI_MODEL=${OPENAI_MODEL}"

jq -n \
  --arg image "$IMAGE" \
  --arg model "$LITELLM_MODEL" \
  --arg base "$LITELLM_BASE_URL" \
  --arg run_id "$RUN_ID" \
  --arg host_port "$HOST_PORT" \
  '{
    run_id: $run_id,
    started_at: (now | todate),
    image: $image,
    litellm_model: $model,
    litellm_base_url: $base,
    host_port: $host_port
  }' >"${RUN_DIR}/meta.json"

# ── 1. Fixture: clone or reuse ──────────────────────────────────────────────
if [ -n "${COOLSTORE_PATH:-}" ] && [ -d "${COOLSTORE_PATH}/.git" ]; then
  trace "Copying COOLSTORE_PATH=${COOLSTORE_PATH}"
  mkdir -p "${REPO_DIR}"
  git clone --local "${COOLSTORE_PATH}" "${REPO_DIR}"
else
  trace "Cloning ${COOLSTORE_URL}"
  git clone --depth 50 "${COOLSTORE_URL}" "${REPO_DIR}"
fi

cd "${REPO_DIR}"
git fetch origin main 2>/dev/null || git fetch origin master 2>/dev/null || true
DEFAULT_BRANCH="$(git rev-parse --abbrev-ref origin/HEAD 2>/dev/null | sed 's#^origin/##' || true)"
if [ -z "${DEFAULT_BRANCH}" ]; then
  if git show-ref --verify --quiet refs/remotes/origin/main; then
    DEFAULT_BRANCH=main
  else
    DEFAULT_BRANCH=master
  fi
fi
BRANCH="smoke/pr-review-${RANDOM}"
git checkout -B "${BRANCH}" "origin/${DEFAULT_BRANCH}"
trace "Branch ${BRANCH} from origin/${DEFAULT_BRANCH}"

# ── 2. Mutate a service + commit ────────────────────────────────────────────
TARGET="src/main/java/com/redhat/coolstore/service/ShippingService.java"
[ -f "${TARGET}" ] || die "expected ${TARGET} in coolstore fixture"
printf '\n// e2e-smoke marker %s\n' "$(date +%s)" >>"${TARGET}"
git add "${TARGET}"
git -c user.email=e2e@pr-reviewer.local -c user.name='E2E Smoke' \
  -c commit.gpgsign=false commit --no-gpg-sign \
  -m "e2e: touch ShippingService for PR review smoke"
HEAD_SHA="$(git rev-parse HEAD)"
trace "Commit $(git rev-parse --short HEAD) on $(git branch --show-current)"
git diff --stat "origin/${DEFAULT_BRANCH}...HEAD" | tee "${RUN_DIR}/git-stat.txt"
git diff "origin/${DEFAULT_BRANCH}...HEAD" >"${RUN_DIR}/git-diff.patch" || true

# ── 3. Seed base artifact from default branch ───────────────────────────────
if [ ! -f ".rgctl-base/.rgctl/graph.snapshot.bin" ]; then
  trace "Seeding .rgctl-base from origin/${DEFAULT_BRANCH}"
  WT="${WORK_ROOT}/base-wt"
  git worktree add --detach "${WT}" "origin/${DEFAULT_BRANCH}"
  (
    cd "${WT}"
    # Match agent-pod budget (override with RGCTL_WITH_LIMITS).
    LIMITS_SPEC="${RGCTL_WITH_LIMITS:-max-mem-mb=1536,threads=1}"
    rgctl discover . --with-cfg --with-limits "${LIMITS_SPEC}" 2>&1 | tee "${RUN_DIR}/discover-base.log"
  )
  mkdir -p .rgctl-base
  rm -rf .rgctl-base/.rgctl
  cp -a "${WT}/.rgctl" .rgctl-base/
  git worktree remove --force "${WT}"
else
  trace "Reusing existing .rgctl-base"
  echo "reused" >"${RUN_DIR}/discover-base.log"
fi
test -f ".rgctl-base/.rgctl/graph.snapshot.bin" || die "base artifact missing after seed"

# Best-effort host-side review paths for the artifact trail
trace "Host rgctl review paths (best-effort)"
if rgctl -f json review paths \
  --base-artifact "${REPO_DIR}/.rgctl-base" \
  --base-ref "origin/${DEFAULT_BRANCH}" \
  --head-ref HEAD \
  >"${RUN_DIR}/review-paths.json" 2>"${RUN_DIR}/review-paths.err"; then
  trace "review-paths.json written"
else
  trace "WARN: host review paths failed (see review-paths.err); continuing"
fi

# ── 4. Start agent container ────────────────────────────────────────────────
trace "Starting ${IMAGE} as ${CONTAINER_NAME} (port ${HOST_PORT})"
docker run -d --name "${CONTAINER_NAME}" \
  -p "${HOST_PORT}:4096" \
  -v "${REPO_DIR}:/app/repo:rw" \
  -e "OPENCODE_SERVER_PASSWORD=${PASSWORD}" \
  -e "LLM_PROVIDER=${LLM_PROVIDER}" \
  -e "OPENCODE_MODEL=${OPENCODE_MODEL:-}" \
  -e "LITELLM_BASE_URL=${LITELLM_BASE_URL}" \
  -e "LITELLM_API_KEY=${LITELLM_API_KEY:-}" \
  -e "LITELLM_MODEL=${LITELLM_MODEL}" \
  -e "OPENAI_API_KEY=${OPENAI_API_KEY:-}" \
  -e "OPENAI_MODEL=${OPENAI_MODEL}" \
  -e "REPO_PATH=/app/repo" \
  -e "RGCTL_BASE_ARTIFACT=/app/repo/.rgctl-base" \
  -e "RGCTL_WITH_LIMITS=${RGCTL_WITH_LIMITS:-max-mem-mb=1536,threads=1}" \
  "${IMAGE}" >/dev/null

trace "Waiting for /global/health"
deadline=$((SECONDS + 120))
healthy=0
while (( SECONDS < deadline )); do
  if resp="$(curl --max-time 5 -sf -H "${AUTH_HEADER}" "${BASE_URL}/global/health" 2>/dev/null)"; then
    if echo "${resp}" | jq -e '.healthy == true' >/dev/null 2>&1; then
      echo "${resp}" | tee "${RUN_DIR}/health.json"
      trace "Health OK"
      healthy=1
      break
    fi
  fi
  sleep 2
done
(( healthy == 1 )) || die "health check timed out"

# ── 5. Create session + prompt_async ────────────────────────────────────────
INPUT_JSON="$(jq -n \
  --arg repo "${COOLSTORE_URL}" \
  --arg base "origin/${DEFAULT_BRANCH}" \
  --arg head "$HEAD_SHA" \
  '{
    repo_url: $repo,
    pr_number: 0,
    base_ref: $base,
    head_ref: $head,
    github_token: null,
    gitlab_token: null,
    config: {
      upstream_depth: 2,
      downstream_depth: 1,
      fanout: 5,
      max_symbols: 25,
      output_mode: "session",
      skip_post: true
    }
  }')"

if [ -f "${REPO_DIR}/policy.json" ]; then
  INPUT_JSON="$(echo "${INPUT_JSON}" | jq --argjson p "$(cat "${REPO_DIR}/policy.json")" '.policy_json = ($p|tostring)')"
fi
echo "${INPUT_JSON}" | jq . >"${RUN_DIR}/input.json"

PROMPT_TEXT="$(cat <<EOF
Load skill rgctl-pr-reviewer-v2 and execute it.
Repository root is /app/repo (REPO_PATH). Run all git and rgctl commands there.
Do not post to GitHub/GitLab. Use output_mode session / skip_post true.
Keep scratch JSON under /app/repo/.rgctl/ (not /tmp).

First write /app/repo/IMPACT_REPORT.md with these exact headings in order:
# Impact Report
## Overview
## Impact Diagram
(include one fenced mermaid code block under Impact Diagram)
## Change Set
## Changes
## Blast Radius
## Communities
## Policy Findings
## Test Handoff
## Sources

Then write the short structured review markdown in your final reply with these exact headings:
## High-level Summary
## Call-Path & Architecture Impact
## Test Coverage & Regressions
## Line-by-Line Feedback

Input JSON:
${INPUT_JSON}
EOF
)"
printf '%s\n' "${PROMPT_TEXT}" >"${RUN_DIR}/prompt.txt"

trace "POST /session"
SESSION_JSON="$(curl --max-time 30 -sf -H "${AUTH_HEADER}" -H "Content-Type: application/json" \
  -X POST "${BASE_URL}/session" -d '{}')"
echo "${SESSION_JSON}" | jq . >"${RUN_DIR}/session.json"
SESSION_ID="$(echo "${SESSION_JSON}" | jq -r '.id // .session.id // empty')"
[ -n "${SESSION_ID}" ] || die "no session id in: ${SESSION_JSON}"
trace "Session: ${SESSION_ID}"

jq --arg sid "$SESSION_ID" --arg branch "$BRANCH" --arg sha "$HEAD_SHA" --arg base "$DEFAULT_BRANCH" \
  '. + {session_id: $sid, branch: $branch, head_sha: $sha, base_branch: $base}' \
  "${RUN_DIR}/meta.json" >"${RUN_DIR}/meta.json.tmp" && mv "${RUN_DIR}/meta.json.tmp" "${RUN_DIR}/meta.json"

PROMPT_BODY="$(jq -n --arg text "${PROMPT_TEXT}" '{
  agent: "pr-reviewer",
  parts: [{ type: "text", text: $text }]
}')"
printf '%s\n' "${PROMPT_BODY}" >"${RUN_DIR}/prompt_async.body.json"

trace "POST /session/${SESSION_ID}/prompt_async"
HTTP_CODE="$(curl --max-time 60 -s -o "${RUN_DIR}/prompt_async.out" -w '%{http_code}' \
  -H "${AUTH_HEADER}" -H "Content-Type: application/json" \
  -X POST "${BASE_URL}/session/${SESSION_ID}/prompt_async" \
  -d "${PROMPT_BODY}")"
echo "${HTTP_CODE}" >"${RUN_DIR}/prompt_async.http_code"
if [ "${HTTP_CODE}" != "204" ] && [ "${HTTP_CODE}" != "200" ]; then
  cat "${RUN_DIR}/prompt_async.out" >&2
  die "prompt_async failed HTTP ${HTTP_CODE}"
fi

# ── 6. Poll status + messages ───────────────────────────────────────────────
is_busy() {
  local st="$1"
  case "${st}" in
    busy|running|in_progress|pending|compacting|active) return 0 ;;
    *) return 1 ;;
  esac
}

trace "Polling session (timeout ${MAX_WAIT}s)"
: >"${RUN_DIR}/poll.log"
end=$((SECONDS + MAX_WAIT))
TRANSCRIPT=""
MSGS='[]'
while (( SECONDS < end )); do
  STATUS_JSON="$(curl --max-time 10 -sf -H "${AUTH_HEADER}" "${BASE_URL}/session/status" 2>/dev/null || echo '{}')"
  echo "${STATUS_JSON}" >"${RUN_DIR}/session-status.json"
  ST="$(echo "${STATUS_JSON}" | jq -r --arg id "${SESSION_ID}" '.[$id] // .[$id].type // .[$id].status // empty' 2>/dev/null || true)"
  if echo "${STATUS_JSON}" | jq -e --arg id "${SESSION_ID}" '.[$id] | type == "object"' >/dev/null 2>&1; then
    ST="$(echo "${STATUS_JSON}" | jq -r --arg id "${SESSION_ID}" '.[$id].type // .[$id].status // "unknown"')"
  fi

  MSGS="$(curl --max-time 30 -sf -H "${AUTH_HEADER}" "${BASE_URL}/session/${SESSION_ID}/message" 2>/dev/null || echo '[]')"
  echo "${MSGS}" >"${RUN_DIR}/messages.json"
  # Assistant-only text (user prompt also contains the section headings).
  TRANSCRIPT="$(echo "${MSGS}" | jq -r '
    [.[]
      | select((.role // .info.role // "") == "assistant")
      | .parts[]? | select(.type=="text") | .text // empty
    ] | join("\n")
  ' 2>/dev/null || true)"
  printf '%s\n' "${TRANSCRIPT}" >"${RUN_DIR}/transcript.md"

  line="status=${ST:-unknown} transcript_bytes=${#TRANSCRIPT}"
  echo "${line}" >>"${RUN_DIR}/poll.log"
  trace "  … ${line}"

  if [ -n "${TRANSCRIPT}" ] && ! is_busy "${ST}"; then
    if echo "${TRANSCRIPT}" | grep -qi 'High-level Summary' \
      && echo "${TRANSCRIPT}" | grep -qi 'Call-Path' \
      && echo "${TRANSCRIPT}" | grep -qi 'Test Coverage' \
      && echo "${TRANSCRIPT}" | grep -qi 'Line-by-Line' \
      && [ -f "${REPO_DIR}/IMPACT_REPORT.md" ]; then
      trace "Session idle (status=${ST:-unknown}) with required sections + IMPACT_REPORT.md"
      break
    fi
  fi
  sleep "${POLL_INTERVAL}"
done

trace "Transcript ${#TRANSCRIPT} bytes → ${RUN_DIR}/transcript.md"

# ── 7. Assert required sections ─────────────────────────────────────────────
fail=0
SECTIONS_ASSERT_OK=false
IMPACT_ASSERT_OK=false
: >"${RUN_DIR}/assert.txt"
for heading in \
  "High-level Summary" \
  "Call-Path" \
  "Test Coverage" \
  "Line-by-Line"
do
  if echo "${TRANSCRIPT}" | grep -qi "${heading}"; then
    echo "OK: transcript ${heading}" | tee -a "${RUN_DIR}/assert.txt"
  else
    echo "FAIL: transcript ${heading}" | tee -a "${RUN_DIR}/assert.txt"
    fail=1
  fi
done
if [ "${fail}" -eq 0 ]; then
  SECTIONS_ASSERT_OK=true
fi

# ── 8. Persist + assert Impact Report ───────────────────────────────────────
IMPACT_SRC="${REPO_DIR}/IMPACT_REPORT.md"
if [ -f "${IMPACT_SRC}" ]; then
  cp -f "${IMPACT_SRC}" "${RUN_DIR}/IMPACT_REPORT.md"
  trace "Copied IMPACT_REPORT.md → ${RUN_DIR}/IMPACT_REPORT.md"
else
  echo "FAIL: IMPACT_REPORT.md missing at ${IMPACT_SRC}" | tee -a "${RUN_DIR}/assert.txt"
  fail=1
fi

impact_fail=0
if [ -f "${RUN_DIR}/IMPACT_REPORT.md" ]; then
  for needle in \
    "# Impact Report" \
    "## Impact Diagram" \
    "## Changes" \
    "## Blast Radius" \
    "## Communities" \
    "## Test Handoff"
  do
    if grep -Fq "${needle}" "${RUN_DIR}/IMPACT_REPORT.md"; then
      echo "OK: impact ${needle}" | tee -a "${RUN_DIR}/assert.txt"
    else
      echo "FAIL: impact ${needle}" | tee -a "${RUN_DIR}/assert.txt"
      impact_fail=1
      fail=1
    fi
  done
  # Mermaid fence: language tag on its own fence line
  if grep -Eq '^```[[:space:]]*mermaid[[:space:]]*$' "${RUN_DIR}/IMPACT_REPORT.md"; then
    echo "OK: impact mermaid fence" | tee -a "${RUN_DIR}/assert.txt"
  else
    echo "FAIL: impact mermaid fence" | tee -a "${RUN_DIR}/assert.txt"
    impact_fail=1
    fail=1
  fi
  if [ "${impact_fail}" -eq 0 ]; then
    IMPACT_ASSERT_OK=true
  fi
fi

if [ "${fail}" -ne 0 ]; then
  docker logs "${CONTAINER_NAME}" 2>&1 | tee -a "${RUN_DIR}/docker.log" | tail -60
  if [ "${SECTIONS_ASSERT_OK}" != "true" ]; then
    die "structured review sections missing from session transcript"
  fi
  die "Impact Report missing or incomplete (see assert.txt)"
fi

EXIT_CODE=0
write_result passed
trace "E2E review smoke passed."
echo "E2E review smoke passed."
echo "Run artifacts: ${RUN_DIR}"
