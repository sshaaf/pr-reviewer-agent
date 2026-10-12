#!/usr/bin/env bash
# Prepare a git workspace for an MR review (clone/fetch + base artifact).
# Used by the OpenShift GitLab trigger (same pod or Job).
set -euo pipefail

REPO_URL="${REPO_URL:?REPO_URL required}"
GITLAB_TOKEN="${GITLAB_TOKEN:?GITLAB_TOKEN required}"
TARGET_BRANCH="${TARGET_BRANCH:?TARGET_BRANCH required}"
SOURCE_BRANCH="${SOURCE_BRANCH:?SOURCE_BRANCH required}"
HEAD_SHA="${HEAD_SHA:-}"
WORKSPACE="${WORKSPACE:-/workspace/repo}"
LIMITS_SPEC="${RGCTL_WITH_LIMITS:-max-mem-mb=1536,threads=1}"
# Prefer in-cluster GitLab Service for clone (pods often cannot use the external Route auth UX).
GITLAB_URL="${GITLAB_URL:-}"

log() { printf '[review-workspace] %s\n' "$*"; }

urlencode() {
  python3 -c 'import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1], safe=""))' "$1"
}

# Clean transport URL (no credentials). Prefer GITLAB_URL + path from REPO_URL.
transport_url() {
  if [ -n "${GITLAB_URL}" ]; then
    local path
    path="${REPO_URL#*://}"
    path="/${path#*/}"
    printf '%s%s' "${GITLAB_URL%/}" "${path}"
    return
  fi
  printf '%s' "${REPO_URL}"
}

# Authenticated clone/fetch URL (oauth2 PAT). Keep until all network git ops finish.
auth_url() {
  local transport token_enc proto rest
  transport="$(transport_url)"
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
log "Ready base_ref=${BASE_REF} head_ref=${HEAD_REF}"
