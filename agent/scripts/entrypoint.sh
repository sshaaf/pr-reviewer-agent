#!/bin/sh
# Start opencode serve. PR review uses rgctl review CLI in-process (no rgctl serve --watch).
set -e

export LITELLM_BASE_URL="${LITELLM_BASE_URL:-https://litemaas.rhoai.rh-aiservices-bu.com/v1}"
export REPO_PATH="${REPO_PATH:-/app/repo}"

# Constrain rgctl discover for small K8s/OpenShift pods (soft RSS + Rayon threads).
# Spec keys: max-mem-mb (aliases: max-mem, memory-mb), threads (aliases: thread, max-thread, max-threads).
# Env alone is honored by rgctl; the /usr/local/bin/rgctl wrapper also injects --with-limits
# so agent/LLM-invoked discover cannot skip limits. Leave headroom under the pod memory limit.
export RGCTL_WITH_LIMITS="${RGCTL_WITH_LIMITS:-max-mem-mb=1536,threads=1}"

# Multi-provider selection:
#   OPENCODE_MODEL=openai/gpt-4o          (full provider/model — highest priority)
#   LLM_PROVIDER=openai|litellm           (default litellm) + OPENAI_MODEL / LITELLM_MODEL
LLM_PROVIDER="${LLM_PROVIDER:-litellm}"
LITELLM_MODEL="${LITELLM_MODEL:-Qwen3.6-35B-A3B}"
OPENAI_MODEL="${OPENAI_MODEL:-gpt-4o}"

# Prefer a writable config under HOME (/tmp) so the active model can be patched at runtime.
CONFIG_SRC="/app/opencode.json"
CONFIG_DST="${HOME:-/tmp}/.config/opencode/opencode.json"
mkdir -p "$(dirname "${CONFIG_DST}")"
cp "${CONFIG_SRC}" "${CONFIG_DST}"

resolve_model() {
  if [ -n "${OPENCODE_MODEL:-}" ]; then
    printf '%s' "${OPENCODE_MODEL}"
    return
  fi
  case "${LLM_PROVIDER}" in
    openai|OpenAI|OPENAI)
      printf 'openai/%s' "${OPENAI_MODEL}"
      ;;
    litellm|LiteLLM|LITELLM|"")
      printf 'litellm/%s' "${LITELLM_MODEL}"
      ;;
    *)
      echo "[entrypoint] ERROR: unknown LLM_PROVIDER=${LLM_PROVIDER} (use litellm|openai or set OPENCODE_MODEL)" >&2
      exit 1
      ;;
  esac
}

ACTIVE_MODEL="$(resolve_model)"
PROVIDER_ID="${ACTIVE_MODEL%%/*}"
MODEL_ID="${ACTIVE_MODEL#*/}"

if [ -z "${PROVIDER_ID}" ] || [ -z "${MODEL_ID}" ] || [ "${PROVIDER_ID}" = "${ACTIVE_MODEL}" ]; then
  echo "[entrypoint] ERROR: model must be provider/model (got: ${ACTIVE_MODEL})" >&2
  exit 1
fi

# Warn when the selected provider has no API key (health smoke can start without one).
case "${PROVIDER_ID}" in
  openai)
    if [ -z "${OPENAI_API_KEY:-}" ]; then
      echo "[entrypoint] WARN: OPENAI_API_KEY unset — reviews using openai will fail auth" >&2
    fi
    ;;
  litellm)
    if [ -z "${LITELLM_API_KEY:-}" ]; then
      echo "[entrypoint] WARN: LITELLM_API_KEY unset — reviews using litellm will fail auth" >&2
    fi
    ;;
esac

if command -v jq >/dev/null 2>&1; then
  tmp="$(mktemp)"
  jq --arg full "${ACTIVE_MODEL}" --arg prov "${PROVIDER_ID}" --arg mid "${MODEL_ID}" '
    .model = $full
    | .agents["pr-reviewer"].model = $full
    | if $prov == "litellm" then
        .provider.litellm.models = {($mid): {"name": $mid}}
      elif $prov == "openai" then
        .provider.openai.models = ((.provider.openai.models // {}) + {($mid): {"name": $mid}})
      else
        .
      end
  ' "${CONFIG_DST}" >"$tmp" && mv "$tmp" "${CONFIG_DST}"
fi

echo "[entrypoint] LLM_PROVIDER=${LLM_PROVIDER} OPENCODE_MODEL=${OPENCODE_MODEL:-} → ${ACTIVE_MODEL}"
echo "[entrypoint] LITELLM_BASE_URL=${LITELLM_BASE_URL}"
echo "[entrypoint] REPO_PATH=${REPO_PATH}"
echo "[entrypoint] RGCTL_WITH_LIMITS=${RGCTL_WITH_LIMITS}"
echo "[entrypoint] Starting opencode serve on 0.0.0.0:4096"
exec opencode serve \
  --hostname 0.0.0.0 \
  --port 4096 \
  --print-logs \
  --log-level INFO
