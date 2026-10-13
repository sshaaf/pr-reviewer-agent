#!/bin/sh
# Ensure `rgctl discover` always runs under --with-limits (soft RSS + thread cap).
# Spec from RGCTL_WITH_LIMITS: max-mem-mb=<N>,threads=<N>
# (aliases: max-mem|memory-mb , thread|max-thread|max-threads).
# rgctl honors the env var, but the agent/LLM may omit the flag — inject it.
set -eu

RGCTL_BIN="${RGCTL_BIN:-/usr/local/libexec/rgctl}"
LIMITS_SPEC="${RGCTL_WITH_LIMITS:-max-mem-mb=1536,threads=1}"

is_discover=0
has_with_limits=0
seen_subcommand=0
prev=""

for arg in "$@"; do
  if [ "$prev" = "--with-limits" ] || [ "$arg" = "--with-limits" ]; then
    has_with_limits=1
  fi
  case "$arg" in
    --with-limits=*) has_with_limits=1 ;;
  esac

  # First non-option token is the subcommand
  case "$arg" in
    -*)
      prev="$arg"
      continue
      ;;
  esac
  if [ "$seen_subcommand" -eq 0 ]; then
    seen_subcommand=1
    if [ "$arg" = "discover" ]; then
      is_discover=1
    fi
  fi
  prev="$arg"
done

export RGCTL_WITH_LIMITS="${LIMITS_SPEC}"

if [ "$is_discover" -eq 1 ] && [ "$has_with_limits" -eq 0 ]; then
  exec "$RGCTL_BIN" "$@" --with-limits "${LIMITS_SPEC}"
fi

exec "$RGCTL_BIN" "$@"
