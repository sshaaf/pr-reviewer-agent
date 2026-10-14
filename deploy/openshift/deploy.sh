#!/usr/bin/env bash
# Apply pr-reviewer OpenShift manifests with the standard sizing profile.
#
# Profile (every overlay inherits from base):
#   agent + trigger limits: 4 CPU / 4Gi (requests 500m / 1Gi)
#   RGCTL_WITH_LIMITS:      max-mem-mb=3072,threads=4
#
# Usage:
#   ./deploy/openshift/deploy.sh              # default (base → ns pr-reviewer)
#   ./deploy/openshift/deploy.sh smoke        # overlays/smoke
#   ./deploy/openshift/deploy.sh github       # overlays/github
#   ./deploy/openshift/deploy.sh --dry-run smoke
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OPENSHIFT_DIR="$(cd "$(dirname "$0")" && pwd)"

EXPECTED_RGCTL="max-mem-mb=3072,threads=4"
EXPECTED_MEM_LIMIT="4Gi"
EXPECTED_CPU_LIMIT="4"

DRY_RUN=0
OVERLAY="base"

usage() {
  sed -n '2,16p' "$0" | sed -n '/^#/p' | sed 's/^# \{0,1\}//'
  exit "${1:-0}"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage 0 ;;
    --dry-run) DRY_RUN=1; shift ;;
    base|smoke|github) OVERLAY="$1"; shift ;;
    *) echo "unknown arg: $1" >&2; usage 1 ;;
  esac
done

case "$OVERLAY" in
  base)   KUSTOMIZE_DIR="$OPENSHIFT_DIR" ;;
  smoke)  KUSTOMIZE_DIR="$OPENSHIFT_DIR/overlays/smoke" ;;
  github) KUSTOMIZE_DIR="$OPENSHIFT_DIR/overlays/github" ;;
esac

echo "[deploy] overlay=${OVERLAY} dir=${KUSTOMIZE_DIR}"
echo "[deploy] profile: ${EXPECTED_CPU_LIMIT} CPU / ${EXPECTED_MEM_LIMIT}, RGCTL_WITH_LIMITS=${EXPECTED_RGCTL}"

# Fail fast if base drifted away from the standard profile.
CM_LIMITS="$(grep -E '^\s*RGCTL_WITH_LIMITS:' "$OPENSHIFT_DIR/base/configmap.yaml" | head -1 | sed -E 's/.*"([^"]+)".*/\1/')"
if [[ "$CM_LIMITS" != "$EXPECTED_RGCTL" ]]; then
  echo "[deploy] ERROR: base/configmap.yaml RGCTL_WITH_LIMITS='${CM_LIMITS}' != '${EXPECTED_RGCTL}'" >&2
  exit 1
fi
if ! grep -q "memory: ${EXPECTED_MEM_LIMIT}" "$OPENSHIFT_DIR/base/deployment.yaml"; then
  echo "[deploy] ERROR: base/deployment.yaml missing memory limit ${EXPECTED_MEM_LIMIT}" >&2
  exit 1
fi
if ! grep -q "cpu: \"${EXPECTED_CPU_LIMIT}\"" "$OPENSHIFT_DIR/base/deployment.yaml"; then
  echo "[deploy] ERROR: base/deployment.yaml missing cpu limit ${EXPECTED_CPU_LIMIT}" >&2
  exit 1
fi

if [[ "$DRY_RUN" -eq 1 ]]; then
  if command -v kubectl >/dev/null 2>&1; then
    kubectl kustomize "$KUSTOMIZE_DIR"
  else
    oc kustomize "$KUSTOMIZE_DIR"
  fi
  echo "[deploy] dry-run ok"
  exit 0
fi

command -v oc >/dev/null || { echo "[deploy] ERROR: oc required" >&2; exit 1; }

oc apply -k "$KUSTOMIZE_DIR"

# Namespace: kustomization field, else Deployment metadata.namespace, else default.
NS="$(awk '/^namespace:/{print $2; exit}' "$KUSTOMIZE_DIR/kustomization.yaml" 2>/dev/null || true)"
if [[ -z "${NS}" ]]; then
  NS="$(oc kustomize "$KUSTOMIZE_DIR" | awk '/^kind: Deployment$/{d=1} d && /^  namespace:/{print $2; exit}')"
fi
NS="${NS:-pr-reviewer}"

echo "[deploy] waiting for rollout in ns=${NS}"
oc -n "$NS" rollout status deploy/pr-reviewer --timeout=180s

LIVE_RGCTL="$(oc -n "$NS" exec deploy/pr-reviewer -c trigger -- printenv RGCTL_WITH_LIMITS)"
if [[ "$LIVE_RGCTL" != "$EXPECTED_RGCTL" ]]; then
  echo "[deploy] ERROR: live RGCTL_WITH_LIMITS='${LIVE_RGCTL}' != '${EXPECTED_RGCTL}'" >&2
  echo "[deploy] hint: remove a stale env override: oc -n ${NS} set env deploy/pr-reviewer -c trigger RGCTL_WITH_LIMITS-" >&2
  exit 1
fi

oc -n "$NS" get deploy pr-reviewer -o json | python3 -c "
import json,sys
expected_mem='${EXPECTED_MEM_LIMIT}'
expected_cpu='${EXPECTED_CPU_LIMIT}'
d=json.load(sys.stdin)
bad=[]
for c in d['spec']['template']['spec']['containers']:
    lim=(c.get('resources') or {}).get('limits') or {}
    if lim.get('memory') != expected_mem or str(lim.get('cpu')) != expected_cpu:
        bad.append((c['name'], lim))
if bad:
    print('[deploy] ERROR: container limits not on profile:', bad, file=sys.stderr)
    sys.exit(1)
print('[deploy] verified: all containers limits cpu=%s memory=%s' % (expected_cpu, expected_mem))
"

echo "[deploy] ok overlay=${OVERLAY} ns=${NS} RGCTL_WITH_LIMITS=${LIVE_RGCTL}"
