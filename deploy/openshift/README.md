# OpenShift: pr-reviewer-agent + GitLab trigger

Runs OpenCode (`pr-reviewer-agent`) and a GitLab MR webhook trigger as **two containers in one pod**, sharing an `emptyDir` workspace at `/workspace`.

**Live demos / workshops:** follow **[docs/demo-runbook.md](../../docs/demo-runbook.md)** (smoke overlay, timed script, recovery). This README is the ops install sheet.

```
GitLab (on OpenShift) --webhook--> Route --> trigger:8080
                                              | clone + rgctl discover
                                              | prompt_async --> agent:4096 (localhost)
                                              v
                                         MR note via GitLab API
```

## Images

| Image | Build |
|-------|--------|
| `quay.io/sshaaf/pr-reviewer-agent` | `docker build --platform linux/amd64 -f agent/Dockerfile -t quay.io/sshaaf/pr-reviewer-agent:latest .` |
| `quay.io/sshaaf/pr-reviewer-trigger` | `docker build --platform linux/amd64 -f trigger/Dockerfile -t quay.io/sshaaf/pr-reviewer-trigger:latest .` |

## 1. Secrets

```bash
oc create namespace pr-reviewer 2>/dev/null || true

oc -n pr-reviewer create secret generic pr-reviewer-secrets \
  --from-literal=LLM_PROVIDER='litellm' \
  --from-literal=LITELLM_API_KEY='...' \
  --from-literal=LITELLM_BASE_URL='https://litemaas.example.com/v1' \
  --from-literal=LITELLM_MODEL='Qwen3.6-35B-A3B' \
  --from-literal=OPENAI_API_KEY='sk-...' \
  --from-literal=OPENAI_MODEL='gpt-4o' \
  --from-literal=OPENCODE_SERVER_PASSWORD='pick-a-strong-password' \
  --from-literal=GITLAB_TOKEN='glpat-...' \
  --from-literal=GITLAB_WEBHOOK_SECRET='shared-webhook-secret'
```

Set `LLM_PROVIDER=openai` (or `OPENCODE_MODEL=openai/gpt-4o`) to use OpenAI instead of LiteLLM. Unused provider keys may be empty.

`GITLAB_TOKEN` needs `api` + `read_repository` on target projects (project or group access token).

## 2. Point at in-cluster GitLab

Edit `configmap.yaml` (or patch after apply):

```yaml
GITLAB_URL: "http://gitlab-webservice-default.gitlab.svc:8181"
```

Use your GitLab Operator/Helm Service name and port (`oc -n gitlab get svc`).

## 3. Apply

```bash
# Dry-run (no cluster required for client-side validate if using kustomize)
kubectl kustomize deploy/openshift

oc apply -k deploy/openshift
oc -n pr-reviewer rollout status deploy/pr-reviewer
```

## 4. Register GitLab webhook

```bash
oc -n pr-reviewer get route pr-reviewer-trigger
# URL: https://<host>/hooks/gitlab
```

In the GitLab project → **Settings → Webhooks**:

| Field | Value |
|-------|--------|
| URL | `https://<trigger-route-host>/hooks/gitlab` |
| Secret token | same as `GITLAB_WEBHOOK_SECRET` |
| Trigger | Merge request events |

If GitLab cannot reach the public Route, use an in-cluster URL from a GitLab sidekiq/network policy perspective, or expose the trigger Service via a hostname GitLab can resolve.

## 5. Smoke / verify

```bash
# Pod ready?
oc -n pr-reviewer get pods -l app.kubernetes.io/name=pr-reviewer

# Trigger health
oc -n pr-reviewer exec deploy/pr-reviewer -c trigger -- \
  curl -sf http://127.0.0.1:8080/healthz

# Agent health (basic auth)
PASS=$(oc -n pr-reviewer get secret pr-reviewer-secrets -o jsonpath='{.data.OPENCODE_SERVER_PASSWORD}' | base64 -d)
oc -n pr-reviewer exec deploy/pr-reviewer -c trigger -- \
  curl -sf -u "opencode:${PASS}" http://127.0.0.1:4096/global/health

# Limits env
oc -n pr-reviewer exec deploy/pr-reviewer -c agent -- printenv RGCTL_WITH_LIMITS
```

**End-to-end:** open or update an MR on a watched project → trigger logs show clone/discover/`prompt_async` → MR gains a notes comment with the four-section review; workspace contains `IMPACT_REPORT.md` under `/workspace/repo`.

```bash
oc -n pr-reviewer logs -f deploy/pr-reviewer -c trigger
oc -n pr-reviewer logs -f deploy/pr-reviewer -c agent
```

## Resource notes

Defaults in base manifests: agent/trigger **2 CPU / 3Gi**, `RGCTL_WITH_LIMITS=max-mem-mb=2048,threads=1` (`max-mem-mb` soft RSS + `threads` Rayon cap on every `rgctl discover`). Raise pod memory and the spec together for large repos. Reviews are **serialized** in the trigger (one lock) to avoid clobbering the shared workspace.

## Optional agent Route

Uncomment `route-agent.yaml` in `kustomization.yaml` only for debugging OpenCode externally.
