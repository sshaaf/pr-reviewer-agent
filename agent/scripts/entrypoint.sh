#!/bin/sh
# Start opencode serve. PR review uses rgctl review CLI in-process (no rgctl serve --watch).
set -e

export LITELLM_BASE_URL="${LITELLM_BASE_URL:-https://litemaas.rhoai.rh-aiservices-bu.com/v1}"
export REPO_PATH="${REPO_PATH:-/app/repo}"

# Constrain rgctl discover (and any CLI that honors RGCTL_WITH_LIMITS) for small
# Kubernetes / OpenShift agent pods. Leave headroom under the typical 2Gi limit
# for OpenCode + the OS. Override via RGCTL_WITH_LIMITS in the pod env.
# Spec: max-mem-mb=<N>,threads=<N>  (see: rgctl discover --help --with-limits)
export RGCTL_WITH_LIMITS="${RGCTL_WITH_LIMITS:-max-mem-mb=1536,threads=1}"

# Prefer a writable config under HOME (/tmp) so LITELLM_MODEL can be patched at runtime.
CONFIG_SRC="/app/opencode.json"
CONFIG_DST="${HOME:-/tmp}/.config/opencode/opencode.json"
mkdir -p "$(dirname "${CONFIG_DST}")"
cp "${CONFIG_SRC}" "${CONFIG_DST}"

if [ -n "${LITELLM_MODEL:-}" ] && command -v jq >/dev/null 2>&1; then
  tmp="$(mktemp)"
  jq --arg m "$LITELLM_MODEL" '
    .model = ("litellm/" + $m)
    | .agents["pr-reviewer"].model = ("litellm/" + $m)
    | .provider.litellm.models = {($m): {"name": $m}}
  ' "${CONFIG_DST}" >"$tmp" && mv "$tmp" "${CONFIG_DST}"
  echo "[entrypoint] Using LITELLM_MODEL=${LITELLM_MODEL}"
fi

echo "[entrypoint] LITELLM_BASE_URL=${LITELLM_BASE_URL}"
echo "[entrypoint] REPO_PATH=${REPO_PATH}"
echo "[entrypoint] RGCTL_WITH_LIMITS=${RGCTL_WITH_LIMITS}"
echo "[entrypoint] Starting opencode serve on 0.0.0.0:4096"
exec opencode serve \
  --hostname 0.0.0.0 \
  --port 4096 \
  --print-logs \
  --log-level INFO
