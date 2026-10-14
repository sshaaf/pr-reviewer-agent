# OpenShift: pr-reviewer-agent + GitLab trigger

Runs OpenCode (`pr-reviewer-agent`) and a GitLab MR webhook trigger as **two containers in one pod**, sharing an `emptyDir` workspace at `/workspace`.

**Live demos / workshops:** follow **[docs/demo-runbook.md](../../docs/demo-runbook.md)** (smoke overlay, timed script, recovery). This README is the ops install sheet.

**GitHub App** (auto-review + `@mention`, read-only): **[docs/github-app.md](../../docs/github-app.md)** and overlay `deploy/openshift/overlays/github` (`TRIGGER_PROVIDER=github`, webhook `POST /hooks/github`).

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
  --from-literal=GITLAB_BOT_USERNAME='rgctl-bot' \
  --from-literal=GITLAB_WEBHOOK_SECRET='shared-webhook-secret'
```

Set `LLM_PROVIDER=openai` (or `OPENCODE_MODEL=openai/gpt-4o`) to use OpenAI instead of LiteLLM. Unused provider keys may be empty.

### Named GitLab bot (required for UX parity)

Do **not** use an administrator PAT. Create a dedicated identity (preferred: **service account** + PAT when your GitLab edition supports it; otherwise a dedicated user) with username e.g. `rgctl-bot`:

1. Create `rgctl-bot` and add it to each demo project (Developer or Maintainer).
2. Mint a personal/project-scoped token with **`api`** + **`read_repository`**.
3. Set `GITLAB_TOKEN` to that token and `GITLAB_BOT_USERNAME=rgctl-bot` (ConfigMap default is also `rgctl-bot`).
4. Review notes and `@rgctl-bot` replies will appear as that user.

Mentions: `@rgctl-bot`, `@rgctl-bot review`, `@rgctl-bot explain …`, `@rgctl-bot fix` (soft refuse). WIP/draft MRs skip auto-review; an explicit `@rgctl-bot review` still runs.

## 2. Point at in-cluster GitLab

Edit `configmap.yaml` (or patch after apply):

```yaml
GITLAB_URL: "http://gitlab-webservice-default.gitlab.svc:8181"
```

Use your GitLab Operator/Helm Service name and port (`oc -n gitlab get svc`).

## 3. Apply

Standard sizing profile (baked into `base/`, enforced by `deploy.sh`):

| Setting | Value |
|---------|--------|
| agent + trigger limits | **4 CPU / 4Gi** (requests 500m / 1Gi) |
| `RGCTL_WITH_LIMITS` | **`max-mem-mb=3072,threads=4`** |

```bash
# Preferred — applies overlay and verifies the profile on the live pod
./deploy/openshift/deploy.sh              # base → ns pr-reviewer
./deploy/openshift/deploy.sh smoke        # overlays/smoke
./deploy/openshift/deploy.sh github       # overlays/github
./deploy/openshift/deploy.sh --dry-run smoke

# Equivalent manual apply (profile still comes from base manifests)
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
| Trigger | **Merge request events** and **Comments** |

If GitLab cannot reach the public Route, use an in-cluster URL from a GitLab sidekiq/network policy perspective, or expose the trigger Service via a hostname GitLab can resolve.

**Verify bot UX:** open a non-WIP MR → note author is `@rgctl-bot`; comment `@rgctl-bot explain …` → short reply; `@rgctl-bot fix` → read-only refuse.

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

If the cloned repo has root `policy.json` or `.rgctl/policy.json`, the trigger loads it into Input `policy_json` and the skill runs `rgctl review check --bisect` (Policy Findings in the Impact Report). `REVIEW.md` and `AGENTS.md` (repo root or `docs/`) are consulted for soft Guidelines Concerns only.

```bash
oc -n pr-reviewer logs -f deploy/pr-reviewer -c trigger
oc -n pr-reviewer logs -f deploy/pr-reviewer -c agent
```

## Resource notes

Defaults in base manifests: agent/trigger **4 CPU / 4Gi**, `RGCTL_WITH_LIMITS=max-mem-mb=3072,threads=4` (`max-mem-mb` soft RSS + `threads` Rayon cap on every `rgctl discover`). Keep `max-mem-mb` under the container limit with headroom; raise both together for larger repos. Reviews are **serialized** in the trigger (one lock) to avoid clobbering the shared workspace.

## Optional agent Route

Uncomment `route-agent.yaml` in `kustomization.yaml` only for debugging OpenCode externally.
