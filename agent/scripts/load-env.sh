#!/usr/bin/env bash
# Source agent/.env (or repo-root .env) into the current shell. Safe for `set -u`.
# Usage:  SCRIPT_DIR=...; # shellcheck source=load-env.sh
#         . "${SCRIPT_DIR}/load-env.sh"

_load_env_file() {
  local f="$1"
  [ -f "$f" ] || return 0
  echo "[env] Loading ${f}"
  set -a
  # shellcheck disable=SC1090
  . "$f"
  set +a
}

_agent_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
_repo_root="$(cd "${_agent_dir}/.." && pwd)"

# Prefer agent/.env, then repo-root .env. Existing exported vars win (set -a does not override? actually . does override).
# Use: only set from file if currently unset — keep CLI exports authoritative.
_load_env_preserve() {
  local f="$1"
  [ -f "$f" ] || return 0
  echo "[env] Loading ${f}"
  while IFS= read -r line || [ -n "$line" ]; do
    # skip blanks and comments
    case "$line" in
      ''|\#*) continue ;;
    esac
    local key="${line%%=*}"
    local val="${line#*=}"
    key="$(printf '%s' "$key" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    # strip optional surrounding quotes on value
    val="$(printf '%s' "$val" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//;s/^"\(.*\)"$/\1/;s/^'\''\(.*\)'\''$/\1/')"
    [ -n "$key" ] || continue
    if [ -z "${!key+x}" ]; then
      export "$key=$val"
    fi
  done <"$f"
}

_load_env_preserve "${_agent_dir}/.env"
_load_env_preserve "${_repo_root}/.env"

unset -f _load_env_file _load_env_preserve
unset _agent_dir _repo_root
