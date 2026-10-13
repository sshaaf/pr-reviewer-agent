#!/usr/bin/env bash
# Resolve active rgctl policy for a repo workspace.
# Prints absolute path to materialized ${REPO}/.rgctl/policy.json, or exits 1 if none.
# Order: POLICY_JSON_FILE env → existing .rgctl/policy.json → root policy.json
set -euo pipefail

REPO_PATH="${1:-${REPO_PATH:-.}}"
REPO_PATH="$(cd "${REPO_PATH}" && pwd)"
DEST="${REPO_PATH}/.rgctl/policy.json"

if [ -n "${POLICY_JSON_FILE:-}" ] && [ -f "${POLICY_JSON_FILE}" ]; then
  mkdir -p "${REPO_PATH}/.rgctl"
  cp -f "${POLICY_JSON_FILE}" "${DEST}"
  printf '%s\n' "${DEST}"
  exit 0
fi

if [ -f "${DEST}" ]; then
  printf '%s\n' "${DEST}"
  exit 0
fi

if [ -f "${REPO_PATH}/policy.json" ]; then
  mkdir -p "${REPO_PATH}/.rgctl"
  cp -f "${REPO_PATH}/policy.json" "${DEST}"
  printf '%s\n' "${DEST}"
  exit 0
fi

exit 1
