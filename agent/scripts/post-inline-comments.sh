#!/usr/bin/env bash
# Post line-level review findings as inline diff comments (GitLab Changes tab / GitHub Files tab).
#
# Input JSON (.rgctl/line-comments.json by default):
# {
#   "provider": "gitlab"|"github",
#   "gitlab_url": "http://gitlab.../  (API root, no /api/v4)",
#   "gitlab_token": "...",
#   "project_id": 1,
#   "pr_number": 1,
#   "github_token": "...",
#   "repo_url": "https://github.com/org/repo.git",
#   "items": [
#     {"path":"src/Foo.java","new_line":22,"body":"...","section":"4","severity":"yellow"},
#     {"path":"src/Foo.java","old_line":10,"body":"...","section":"3","severity":"red"}
#   ]
# }
# severity (optional): green|yellow|red → prefixes 🟢|🟡|🔴 on the posted body.
#
# Env overrides: LINE_COMMENTS_JSON, GITLAB_TOKEN, GITHUB_TOKEN, GITLAB_URL
set -euo pipefail

JSON_PATH="${LINE_COMMENTS_JSON:-${1:-.rgctl/line-comments.json}}"
test -f "${JSON_PATH}" || { echo "[inline-comments] missing ${JSON_PATH}" >&2; exit 1; }
command -v jq >/dev/null || { echo "[inline-comments] jq required" >&2; exit 1; }
command -v curl >/dev/null || { echo "[inline-comments] curl required" >&2; exit 1; }

log() { printf '[inline-comments] %s\n' "$*"; }

PROVIDER="$(jq -r '.provider // empty' "${JSON_PATH}")"
PR_NUMBER="$(jq -r '.pr_number // empty' "${JSON_PATH}")"
PROJECT_ID="$(jq -r '.project_id // empty' "${JSON_PATH}")"
REPO_URL="$(jq -r '.repo_url // empty' "${JSON_PATH}")"
ITEM_COUNT="$(jq '.items | length' "${JSON_PATH}")"

if [ "${ITEM_COUNT}" = "0" ] || [ "${ITEM_COUNT}" = "null" ]; then
  log "no items — nothing to post"
  exit 0
fi

# Infer provider
if [ -z "${PROVIDER}" ]; then
  if [ -n "$(jq -r '.gitlab_token // empty' "${JSON_PATH}")" ] || [ -n "${GITLAB_TOKEN:-}" ]; then
    PROVIDER=gitlab
  elif [ -n "$(jq -r '.github_token // empty' "${JSON_PATH}")" ] || [ -n "${GITHUB_TOKEN:-}" ]; then
    PROVIDER=github
  else
    log "ERROR: cannot infer provider (need gitlab_token or github_token)"
    exit 1
  fi
fi

post_gitlab() {
  local token url api
  token="$(jq -r '.gitlab_token // empty' "${JSON_PATH}")"
  token="${token:-${GITLAB_TOKEN:-}}"
  url="$(jq -r '.gitlab_url // empty' "${JSON_PATH}")"
  url="${url:-${GITLAB_URL:-}}"
  [ -n "${token}" ] || { log "ERROR: gitlab_token required"; exit 1; }
  [ -n "${PROJECT_ID}" ] || { log "ERROR: project_id required"; exit 1; }
  [ -n "${PR_NUMBER}" ] || { log "ERROR: pr_number required"; exit 1; }

  if [ -z "${url}" ] && [ -n "${REPO_URL}" ]; then
    # Derive from repo_url: https://host/group/proj.git → https://host
    url="$(printf '%s' "${REPO_URL}" | sed -E 's#^(https?://[^/]+)/.*#\1#')"
  fi
  url="${url%/}"
  api="${url}/api/v4"

  # Fetch diff_refs for position SHAs
  local mr
  mr="$(curl -skS --header "PRIVATE-TOKEN: ${token}" \
    "${api}/projects/${PROJECT_ID}/merge_requests/${PR_NUMBER}")"
  local base_sha head_sha start_sha
  base_sha="$(printf '%s' "${mr}" | jq -r '.diff_refs.base_sha // empty')"
  head_sha="$(printf '%s' "${mr}" | jq -r '.diff_refs.head_sha // empty')"
  start_sha="$(printf '%s' "${mr}" | jq -r '.diff_refs.start_sha // empty')"
  [ -n "${base_sha}" ] && [ -n "${head_sha}" ] && [ -n "${start_sha}" ] \
    || { log "ERROR: MR diff_refs incomplete"; exit 1; }

  log "GitLab MR !${PR_NUMBER} project=${PROJECT_ID} items=${ITEM_COUNT} head=${head_sha:0:8}"

  local i path new_line old_line body section payload code
  i=0
  while [ "${i}" -lt "${ITEM_COUNT}" ]; do
    path="$(jq -r --argjson i "${i}" '.items[$i].path // empty' "${JSON_PATH}")"
    new_line="$(jq -r --argjson i "${i}" '.items[$i].new_line // empty' "${JSON_PATH}")"
    old_line="$(jq -r --argjson i "${i}" '.items[$i].old_line // empty' "${JSON_PATH}")"
    body="$(jq -r --argjson i "${i}" '.items[$i].body // empty' "${JSON_PATH}")"
    section="$(jq -r --argjson i "${i}" '.items[$i].section // "4"' "${JSON_PATH}")"
    severity="$(jq -r --argjson i "${i}" '.items[$i].severity // empty' "${JSON_PATH}" | tr '[:upper:]' '[:lower:]')"
    i=$((i + 1))

    [ -n "${path}" ] && [ -n "${body}" ] || { log "skip item $((i)): missing path/body"; continue; }
    if [ -z "${new_line}" ] && [ -z "${old_line}" ]; then
      log "skip ${path}: need new_line or old_line"
      continue
    fi

    chip=""
    case "${severity}" in
      green) chip="🟢 " ;;
      yellow) chip="🟡 " ;;
      red) chip="🔴 " ;;
    esac
    # Prefix severity chip + section tag for Changes-tab context
    body="${chip}**§${section}** ${body}"

    payload="$(jq -n \
      --arg body "${body}" \
      --arg base "${base_sha}" \
      --arg head "${head_sha}" \
      --arg start "${start_sha}" \
      --arg path "${path}" \
      --arg new_line "${new_line}" \
      --arg old_line "${old_line}" \
      '
      {
        body: $body,
        position: {
          base_sha: $base,
          head_sha: $head,
          start_sha: $start,
          position_type: "text",
          old_path: $path,
          new_path: $path
        }
      }
      | if $new_line != "" then .position.new_line = ($new_line|tonumber) else . end
      | if $old_line != "" then .position.old_line = ($old_line|tonumber) else . end
      ')"

    code="$(curl -skS -o /tmp/inline-gl-resp.json -w '%{http_code}' \
      --request POST \
      --header "PRIVATE-TOKEN: ${token}" \
      --header "CONTENT-TYPE: application/json" \
      --data "${payload}" \
      "${api}/projects/${PROJECT_ID}/merge_requests/${PR_NUMBER}/discussions")"
    if [ "${code}" = "200" ] || [ "${code}" = "201" ]; then
      log "OK ${path}:${new_line:-~${old_line}} (HTTP ${code})"
    else
      log "FAIL ${path}:${new_line:-~${old_line}} HTTP ${code}: $(head -c 300 /tmp/inline-gl-resp.json)"
    fi
  done
}

post_github() {
  local token owner repo
  token="$(jq -r '.github_token // empty' "${JSON_PATH}")"
  token="${token:-${GITHUB_TOKEN:-}}"
  [ -n "${token}" ] || { log "ERROR: github_token required"; exit 1; }
  [ -n "${PR_NUMBER}" ] || { log "ERROR: pr_number required"; exit 1; }

  # Parse owner/repo from repo_url
  owner="$(printf '%s' "${REPO_URL}" | sed -E 's#.*github.com[:/]([^/]+)/([^/.]+)(\.git)?$#\1#')"
  repo="$(printf '%s' "${REPO_URL}" | sed -E 's#.*github.com[:/]([^/]+)/([^/.]+)(\.git)?$#\2#')"
  [ -n "${owner}" ] && [ -n "${repo}" ] || { log "ERROR: cannot parse owner/repo from ${REPO_URL}"; exit 1; }

  local head_sha
  head_sha="$(curl -skS --header "Authorization: Bearer ${token}" \
    --header "Accept: application/vnd.github+json" \
    "https://api.github.com/repos/${owner}/${repo}/pulls/${PR_NUMBER}" \
    | jq -r '.head.sha // empty')"
  [ -n "${head_sha}" ] || { log "ERROR: cannot resolve PR head sha"; exit 1; }

  log "GitHub PR #${PR_NUMBER} ${owner}/${repo} items=${ITEM_COUNT} head=${head_sha:0:8}"

  local i path new_line old_line body section side line payload code
  i=0
  while [ "${i}" -lt "${ITEM_COUNT}" ]; do
    path="$(jq -r --argjson i "${i}" '.items[$i].path // empty' "${JSON_PATH}")"
    new_line="$(jq -r --argjson i "${i}" '.items[$i].new_line // empty' "${JSON_PATH}")"
    old_line="$(jq -r --argjson i "${i}" '.items[$i].old_line // empty' "${JSON_PATH}")"
    body="$(jq -r --argjson i "${i}" '.items[$i].body // empty' "${JSON_PATH}")"
    section="$(jq -r --argjson i "${i}" '.items[$i].section // "4"' "${JSON_PATH}")"
    severity="$(jq -r --argjson i "${i}" '.items[$i].severity // empty' "${JSON_PATH}" | tr '[:upper:]' '[:lower:]')"
    i=$((i + 1))

    [ -n "${path}" ] && [ -n "${body}" ] || continue
    if [ -n "${new_line}" ]; then
      side=RIGHT
      line="${new_line}"
    elif [ -n "${old_line}" ]; then
      side=LEFT
      line="${old_line}"
    else
      log "skip ${path}: need new_line or old_line"
      continue
    fi

    chip=""
    case "${severity}" in
      green) chip="🟢 " ;;
      yellow) chip="🟡 " ;;
      red) chip="🔴 " ;;
    esac
    body="${chip}**§${section}** ${body}"
    payload="$(jq -n \
      --arg body "${body}" \
      --arg commit "${head_sha}" \
      --arg path "${path}" \
      --argjson line "${line}" \
      --arg side "${side}" \
      '{body:$body, commit_id:$commit, path:$path, line:$line, side:$side}')"

    code="$(curl -skS -o /tmp/inline-gh-resp.json -w '%{http_code}' \
      --request POST \
      --header "Authorization: Bearer ${token}" \
      --header "Accept: application/vnd.github+json" \
      --header "CONTENT-TYPE: application/json" \
      --data "${payload}" \
      "https://api.github.com/repos/${owner}/${repo}/pulls/${PR_NUMBER}/comments")"
    if [ "${code}" = "200" ] || [ "${code}" = "201" ]; then
      log "OK ${path}:${line} (${side}) HTTP ${code}"
    else
      log "FAIL ${path}:${line} HTTP ${code}: $(head -c 300 /tmp/inline-gh-resp.json)"
    fi
  done
}

case "${PROVIDER}" in
  gitlab) post_gitlab ;;
  github) post_github ;;
  *) log "ERROR: unknown provider ${PROVIDER}"; exit 1 ;;
esac

log "done"
