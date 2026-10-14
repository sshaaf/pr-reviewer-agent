#!/usr/bin/env bash
# Prepare a git workspace for an MR/PR review (clone/fetch + base artifact).
# Used by OpenShift GitLab or GitHub App triggers (same pod or Job).
set -euo pipefail

REPO_URL="${REPO_URL:?REPO_URL required}"
TARGET_BRANCH="${TARGET_BRANCH:?TARGET_BRANCH required}"
SOURCE_BRANCH="${SOURCE_BRANCH:?SOURCE_BRANCH required}"
HEAD_SHA="${HEAD_SHA:-}"
WORKSPACE="${WORKSPACE:-/workspace/repo}"
# Soft RSS (~90% warn / ~95% abort) + Rayon thread cap for discover/CFG.
# Keys: max-mem-mb|max-mem|memory-mb , threads|thread|max-thread|max-threads
export RGCTL_WITH_LIMITS="${RGCTL_WITH_LIMITS:-max-mem-mb=1536,threads=1}"
LIMITS_SPEC="${RGCTL_WITH_LIMITS}"
# Prefer in-cluster GitLab Service for clone (pods often cannot use the external Route auth UX).
GITLAB_URL="${GITLAB_URL:-}"
GITLAB_TOKEN="${GITLAB_TOKEN:-}"
GITHUB_TOKEN="${GITHUB_TOKEN:-}"
# Auto-detect: github if GITHUB_TOKEN set (and no gitlab), else gitlab
if [ -n "${VCS_PROVIDER:-}" ]; then
  :
elif [ -n "${GITHUB_TOKEN}" ] && [ -z "${GITLAB_TOKEN}" ]; then
  VCS_PROVIDER=github
elif [[ "${REPO_URL}" == *github.com* ]] && [ -n "${GITHUB_TOKEN}" ]; then
  VCS_PROVIDER=github
else
  VCS_PROVIDER=gitlab
fi

log() { printf '[review-workspace] %s\n' "$*"; }

urlencode() {
  python3 -c 'import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1], safe=""))' "$1"
}

# Clean transport URL (no credentials). Prefer GITLAB_URL + path from REPO_URL.
transport_url() {
  if [ "${VCS_PROVIDER}" = "gitlab" ] && [ -n "${GITLAB_URL}" ]; then
    local path
    path="${REPO_URL#*://}"
    path="/${path#*/}"
    printf '%s%s' "${GITLAB_URL%/}" "${path}"
    return
  fi
  printf '%s' "${REPO_URL}"
}

# Authenticated clone/fetch URL. Keep until all network git ops finish.
auth_url() {
  local transport token_enc proto rest
  transport="$(transport_url)"
  if [ "${VCS_PROVIDER}" = "github" ]; then
    [ -n "${GITHUB_TOKEN}" ] || { log "ERROR: GITHUB_TOKEN required for github provider"; exit 1; }
    token_enc="$(urlencode "${GITHUB_TOKEN}")"
    if [[ "${transport}" =~ ^https?:// ]]; then
      proto="${transport%%://*}"
      rest="${transport#*://}"
      printf '%s://x-access-token:%s@%s' "${proto}" "${token_enc}" "${rest}"
      return
    fi
    printf '%s' "${transport}"
    return
  fi
  [ -n "${GITLAB_TOKEN}" ] || { log "ERROR: GITLAB_TOKEN required for gitlab provider"; exit 1; }
  token_enc="$(urlencode "${GITLAB_TOKEN}")"
  if [[ "${transport}" =~ ^https?:// ]]; then
    proto="${transport%%://*}"
    rest="${transport#*://}"
    printf '%s://oauth2:%s@%s' "${proto}" "${token_enc}" "${rest}"
    return
  fi
  printf '%s' "${transport}"
}

export GIT_TERMINAL_PROMPT=0
export GIT_ASKPASS=/bin/true

TRANSPORT="$(transport_url)"
CLONE_URL="$(auth_url)"

rm -rf "${WORKSPACE}"
mkdir -p "$(dirname "${WORKSPACE}")"

log "Cloning ${REPO_URL} (via ${TRANSPORT}) → ${WORKSPACE}"
git clone --depth 50 "${CLONE_URL}" "${WORKSPACE}"
cd "${WORKSPACE}"
# Keep authenticated remote until fetch/worktree network ops complete
git remote set-url origin "${CLONE_URL}"

git fetch origin "${TARGET_BRANCH}" "${SOURCE_BRANCH}" 2>/dev/null \
  || git fetch origin "${TARGET_BRANCH}"

if [ -n "${HEAD_SHA}" ]; then
  git checkout -f "${HEAD_SHA}"
else
  git checkout -f "origin/${SOURCE_BRANCH}" 2>/dev/null \
    || git checkout -f "${SOURCE_BRANCH}"
fi

BASE_REF="origin/${TARGET_BRANCH}"
if ! git rev-parse --verify "${BASE_REF}" >/dev/null 2>&1; then
  BASE_REF="${TARGET_BRANCH}"
fi

if [ ! -f ".rgctl-base/.rgctl/graph.snapshot.bin" ]; then
  log "Seeding .rgctl-base from ${BASE_REF} (limits=${LIMITS_SPEC})"
  WT="$(mktemp -d /tmp/rgctl-base-XXXXXX)"
  git worktree add --detach "${WT}" "${BASE_REF}"
  (
    cd "${WT}"
    rgctl discover . --with-cfg --with-limits "${LIMITS_SPEC}"
  )
  mkdir -p .rgctl-base
  rm -rf .rgctl-base/.rgctl
  cp -a "${WT}/.rgctl" .rgctl-base/
  git worktree remove --force "${WT}" || rm -rf "${WT}"
fi

test -f ".rgctl-base/.rgctl/graph.snapshot.bin" \
  || { log "ERROR: base artifact missing"; exit 1; }

# Scrub token from .git/config before handing workspace to the agent
git remote set-url origin "${REPO_URL}"

HEAD_REF="$(git rev-parse HEAD)"
META_DIR="$(dirname "${WORKSPACE}")"
mkdir -p "${META_DIR}"
printf '%s\n' "${BASE_REF}" > "${META_DIR}/base_ref"
printf '%s\n' "${HEAD_REF}" > "${META_DIR}/head_ref"

# Materialize repo-owned policy for the skill (Input policy_json may also be set by trigger).
POLICY_RESOLVED=""
if [ -f "${WORKSPACE}/.rgctl/policy.json" ]; then
  POLICY_RESOLVED="${WORKSPACE}/.rgctl/policy.json"
elif [ -f "${WORKSPACE}/policy.json" ]; then
  mkdir -p "${WORKSPACE}/.rgctl"
  cp -f "${WORKSPACE}/policy.json" "${WORKSPACE}/.rgctl/policy.json"
  POLICY_RESOLVED="${WORKSPACE}/.rgctl/policy.json"
fi
if [ -n "${POLICY_RESOLVED}" ]; then
  printf '%s\n' "${POLICY_RESOLVED}" > "${META_DIR}/policy_path"
  log "Policy ready at ${POLICY_RESOLVED}"
else
  rm -f "${META_DIR}/policy_path"
  log "No repo policy.json (review check will be skipped unless Input policy_json is set)"
fi

log "Ready base_ref=${BASE_REF} head_ref=${HEAD_REF}"
