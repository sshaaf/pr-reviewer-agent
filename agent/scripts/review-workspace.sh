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

log() { printf '[review-workspace] %s\n' "$*"; }

# Authenticated HTTPS clone URL (GitLab project access token as oauth2 user).
auth_url() {
  local url="$1"
  if [[ "${url}" =~ ^https?:// ]]; then
    local proto rest
    proto="${url%%://*}"
    rest="${url#*://}"
    printf '%s://oauth2:%s@%s' "${proto}" "${GITLAB_TOKEN}" "${rest}"
  else
    printf '%s' "${url}"
  fi
}

rm -rf "${WORKSPACE}"
mkdir -p "$(dirname "${WORKSPACE}")"
CLONE_URL="$(auth_url "${REPO_URL}")"

log "Cloning ${REPO_URL} → ${WORKSPACE}"
git clone --depth 50 "${CLONE_URL}" "${WORKSPACE}"
cd "${WORKSPACE}"
# Scrub token from remote URL in the worktree
git remote set-url origin "${REPO_URL}"

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

HEAD_REF="$(git rev-parse HEAD)"
META_DIR="$(dirname "${WORKSPACE}")"
mkdir -p "${META_DIR}"
printf '%s\n' "${BASE_REF}" > "${META_DIR}/base_ref"
printf '%s\n' "${HEAD_REF}" > "${META_DIR}/head_ref"
log "Ready base_ref=${BASE_REF} head_ref=${HEAD_REF}"
