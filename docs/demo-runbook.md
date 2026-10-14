# Demo runbook — OpenShift + GitLab MR reviewer

Audience: workshop facilitators and SAs presenting the agent live.  
Ops install details stay in [`deploy/openshift/README.md`](../deploy/openshift/README.md). Skill format details stay in [`agent/.opencode/skills/rgctl-pr-reviewer-v2/SKILL.md`](../agent/.opencode/skills/rgctl-pr-reviewer-v2/SKILL.md).

**GitHub App** (auto + `@mention`, read-only): see [`docs/github-app.md`](github-app.md) — separate from this GitLab smoke path.

---

## 1. Story (30 seconds)

This agent reviews **GitLab merge requests** on OpenShift: webhook → clone → `rgctl` call-graph under a memory budget → OpenCode skill → **Verdict** (GREEN / YELLOW / RED) plus a short four-section note, **Changes-tab** line comments, and a machine-readable **`IMPACT_REPORT.md`**.

It is **advisory** (not a merge gate). It is **not** a full CI suite or security scanner — it answers “what does this diff touch in the call graph, and what should humans check before merge?”

---

## 2. Before demo day (prerequisites)

Complete this checklist **before** anyone joins the call.

### OpenShift

- [ ] `oc` logged into a cluster with rights to create namespace `pr-reviewer-smoke` (or equivalent)
- [ ] Can pull `quay.io/sshaaf/pr-reviewer-agent:latest` (or mirror + ImageStream)
- [ ] Quota for one reviewer pod: **4 CPU / 4Gi** per container (agent + trigger), requests 500m / 1Gi — see base Deployment / `deploy/openshift/deploy.sh`
- [ ] Optional: SCC / anyuid notes only if restricted SCC blocks the pod; prefer default restricted-v2 if it works

### GitLab (in-cluster)

- [ ] GitLab Service DNS reachable from the reviewer namespace (smoke default: `http://gitlab.gitlab.svc`)
- [ ] **`allow_local_requests_from_web_hooks_and_services`** enabled (Admin → Settings → Network → Outbound requests) so webhooks to `*.svc` / cluster DNS work
- [ ] Project or group token: **`api` + `read_repository`**
- [ ] Demo project imported (e.g. coolstore / coolstore-weblogic) with permission to open MRs
- [ ] Prefer **in-cluster webhook URL** to the trigger Service (not the public Route) for smoke demos

### LLM

- [ ] LiteLLM base URL + API key + model **or** OpenAI key + model
- [ ] Model that can tool-call for a **15–30 minute** session
- [ ] Demo default: LiteLLM; keep OpenAI ready as a reliability fallback (`LLM_PROVIDER=openai`)

### Network / images

- [ ] GitLab Sidekiq can reach the trigger Service on port 8080
- [ ] If Quay is private or blocked: build/push trigger (and agent) into the OpenShift integrated registry / ImageStream used by the smoke overlay

### Timing honesty

| Slot length | Plan |
|-------------|------|
| **≤10 min** | Pre-warm: run one review earlier the same day, or show a completed MR + replay logs. Cold coolstore discover alone can eat the slot. |
| **15–25 min** | Cold path is OK for coolstore-sized repos if the push happens early. |
| **30+ min** | Full narrative + optional IMPACT_REPORT deep-dive. |

---

## 3. Golden path install (smoke)

Canonical topology: namespace **`pr-reviewer-smoke`**, overlay **`deploy/openshift/overlays/smoke`**, GitLab URL **`http://gitlab.gitlab.svc`**, webhook to the **in-cluster Service**.

### 3.1 Namespace and secrets

```bash
NS=pr-reviewer-smoke
oc create namespace "$NS" 2>/dev/null || true

oc -n "$NS" create secret generic pr-reviewer-secrets \
  --from-literal=LLM_PROVIDER='litellm' \
  --from-literal=LITELLM_API_KEY='...' \
  --from-literal=LITELLM_BASE_URL='https://litemaas.example.com/v1' \
  --from-literal=LITELLM_MODEL='Qwen3.6-35B-A3B' \
  --from-literal=OPENAI_API_KEY='' \
  --from-literal=OPENAI_MODEL='gpt-4o' \
  --from-literal=OPENCODE_SERVER_PASSWORD='pick-a-strong-password' \
  --from-literal=GITLAB_TOKEN='glpat-...' \
  --from-literal=GITLAB_WEBHOOK_SECRET='shared-webhook-secret'
```

For OpenAI-first demos, set `LLM_PROVIDER=openai` and a real `OPENAI_API_KEY` (LiteLLM keys may be empty). See [`deploy/openshift/secret-example.yaml`](../deploy/openshift/secret-example.yaml).

### 3.2 Images

Smoke remaps the **trigger** image to the OpenShift integrated registry:

`image-registry.openshift-image-registry.svc:5000/pr-reviewer-smoke/pr-reviewer-trigger:latest`

Ensure that ImageStream/tag exists (binary build or `oc import-image` / mirror from Quay). The **agent** image remains `quay.io/sshaaf/pr-reviewer-agent:latest` unless you patch it.

```bash
# Example: build trigger into the smoke namespace (from repo root)
oc -n "$NS" new-build --name=pr-reviewer-trigger --binary --strategy=docker 2>/dev/null || true
oc -n "$NS" start-build pr-reviewer-trigger --from-dir=. --follow
```

(Adjust if your cluster already has a working ImageStream from a prior demo.)

### 3.3 Apply overlay

```bash
./deploy/openshift/deploy.sh smoke
# (applies overlays/smoke and verifies 4 CPU / 4Gi + RGCTL_WITH_LIMITS=max-mem-mb=3072,threads=4)
```

Confirm smoke ConfigMap `GITLAB_URL` is `http://gitlab.gitlab.svc` (or patch to your GitLab Service host/port).

### 3.4 Health checks

```bash
oc -n pr-reviewer-smoke get pods -l app.kubernetes.io/name=pr-reviewer

oc -n pr-reviewer-smoke exec deploy/pr-reviewer -c trigger -- \
  curl -sf http://127.0.0.1:8080/healthz

PASS=$(oc -n pr-reviewer-smoke get secret pr-reviewer-secrets \
  -o jsonpath='{.data.OPENCODE_SERVER_PASSWORD}' | base64 -d)
oc -n pr-reviewer-smoke exec deploy/pr-reviewer -c trigger -- \
  curl -sf -u "opencode:${PASS}" http://127.0.0.1:4096/global/health

oc -n pr-reviewer-smoke exec deploy/pr-reviewer -c agent -- printenv RGCTL_WITH_LIMITS
# expect: max-mem-mb=3072,threads=4 (or your override)
```

### 3.5 Register webhook (in-cluster)

```bash
# Prefer ClusterIP Service DNS from GitLab's network namespace
oc -n pr-reviewer-smoke get svc pr-reviewer-trigger
# URL shape: http://pr-reviewer-trigger.pr-reviewer-smoke.svc:8080/hooks/gitlab
```

In the GitLab **demo project** → Settings → Webhooks:

| Field | Value |
|-------|--------|
| URL | `http://pr-reviewer-trigger.pr-reviewer-smoke.svc:8080/hooks/gitlab` |
| Secret token | same as `GITLAB_WEBHOOK_SECRET` |
| Trigger | Merge request events |

Use **Test → Merge request events** once; expect HTTP 2xx and a line in trigger logs.

Public Route (`oc -n pr-reviewer-smoke get route pr-reviewer-trigger` → `https://…/hooks/gitlab`) is optional and often flakier for in-cluster GitLab.

### 3.6 Demo project / MR seed

- Import or mirror coolstore (or your fixture) into GitLab.
- Ensure the project has root **`policy.json`**, **`REVIEW.md`**, and **`AGENTS.md`** (copy from [`agent/fixtures/coolstore-seed/`](../agent/fixtures/coolstore-seed/) if missing). The trigger auto-loads repo policy into the skill.
- Open an MR with a **small, reviewable** change (e.g. tweak `ShippingService` shipping calc) so §3/§4 can cite real `path:line` in the diff.
- Optional pre-warm: push once before the audience joins so `.rgctl-base` discover cost is partly paid (workspace is `emptyDir` — a pod restart clears it; still validates webhook + LLM).
- **Policy RED demo:** widen shipping/cart coupling so blast impact exceeds `max_impact_nodes` (12 in the seed), or temporarily lower that limit in `policy.json` on the branch.

---

## 4. Live script (timed)

Assumes coolstore-sized repo, **cold** discover. Adjust narration if pre-warmed.

```
T+0:00   MR Overview — “no review yet” (or show an old note you’re about to supersede)
T+0:30   Push a small ShippingService (or similar) commit / click Update MR
T+1:00   Terminal: oc logs -f deploy/pr-reviewer -c trigger
         Call out: webhook → clone → rgctl discover --with-limits
T+1–10   Narrate: “building base call graph under a memory budget (RGCTL_WITH_LIMITS)”
         Don’t apologize for the wait — this is the product differentiator
T+10–20  Brief agent logs (oc logs -f … -c agent); LLM tool loop
         Keep eyes on the MR tab — don’t debug OpenCode live
T+20     MR note appears:
           Verdict 🟢/🟡/🔴 at top → §§1–4 → Guidelines at bottom
T+21     Changes tab: inline discussions on §3/§4 lines
T+22     Optional: show IMPACT_REPORT.md from the pod (see below)
```

**Commands to keep ready:**

```bash
NS=pr-reviewer-smoke
oc -n "$NS" logs -f deploy/pr-reviewer -c trigger
oc -n "$NS" logs -f deploy/pr-reviewer -c agent

# After review completes:
oc -n "$NS" exec deploy/pr-reviewer -c agent -- \
  ls -la /workspace/repo/IMPACT_REPORT.md
oc -n "$NS" exec deploy/pr-reviewer -c agent -- \
  head -n 40 /workspace/repo/IMPACT_REPORT.md
```

Debounce: ConfigMap `DEBOUNCE_SECONDS` defaults to **60** — rapid pushes may coalesce.

---

## 5. What “good” looks like

Use this as the on-screen checklist:

| Surface | Expect |
|---------|--------|
| **MR note — Verdict** | `## Verdict: 🟡 YELLOW — …` (emoji **and** the word GREEN / YELLOW / RED) |
| **§§1–4** | High-level Summary → Call-Path & Architecture → Test Coverage → Line-by-Line (`path:line` bullets) |
| **Guidelines** | Concerns / Blockers / Open questions / What’s fine (Blockers non-empty if RED); may cite `REVIEW.md` / `AGENTS.md` |
| **Policy Findings** | IMPACT / note must **not** say “No policy configured” when `policy.json` is in the repo |
| **Changes tab** | Inline discussions for concrete §3/§4 findings on lines **in the MR diff** |
| **Workspace** | `/workspace/repo/IMPACT_REPORT.md` with matching `## Verdict` + Mermaid + blast/communities/test handoff |

Teaching moment: the agent should **not** invent blast edges outside evidence from `rgctl` / the git diff (e.g. don’t sell vendored JS noise as architecture impact).

Verdict ladder (advisory): RED = policy new/regression, security/auth/PII/payment, clear break; else YELLOW = hot-path behavior / weak tests / ambiguity; else GREEN. Full rules: skill doc.

---

## 6. Recovery (demo day)

| Symptom | Likely cause | Fast fix |
|---------|--------------|----------|
| No trigger logs on push | Webhook URL wrong; secret mismatch; GitLab blocks local requests | Re-test webhook; enable `allow_local_requests_from_web_hooks_and_services`; use `http://pr-reviewer-trigger.pr-reviewer-smoke.svc:8080/hooks/gitlab` |
| Clone / auth errors | Bad `GITLAB_TOKEN` or URL | Token `api`+`read_repository`; ConfigMap `GITLAB_URL` matches in-cluster API |
| Discover abort / OOM | Soft RSS tripwire or cgroup kill | Confirm `RGCTL_WITH_LIMITS=max-mem-mb=3072,threads=4`; raise pod memory **and** `max-mem-mb` together; smaller fixture if needed |
| Pod ImagePullBackOff | Quay / ImageStream lag | `oc -n pr-reviewer-smoke get is,bc`; rebuild trigger; check agent pull secret |
| Long silence after discover | LLM latency / tool loop | Switch to OpenAI for the room; show agent logs; don’t restart mid-review unless stuck >30 min |
| MR note but no Changes comments | Lines not in diff; helper skip | Findings must use **new-file** line numbers in the MR diff; re-push a clearer line-level change |
| Stale / no new note | Debounce or review lock | Wait `DEBOUNCE_SECONDS`; only one review at a time (serialized lock) |
| Cluster API blip | Control plane transient | Re-`oc login`; check pod still Running; re-test webhook |

**Audience-safe fallback:** open a **pre-completed MR** with Verdict + inlines, walk the note structure, then optionally trigger a second small push if time remains.

---

## 7. Appendix

### Base overlay (non-smoke)

```bash
./deploy/openshift/deploy.sh   # namespace pr-reviewer, Quay images as in base
```

Use when you are not on the smoke ImageStream path. Still prefer in-cluster webhook URLs.

### Switching LLM mid-demo

```bash
# Recreate secret with LLM_PROVIDER=openai and OPENAI_API_KEY, then:
oc -n pr-reviewer-smoke rollout restart deploy/pr-reviewer
```

Or set `OPENCODE_MODEL=openai/gpt-4o` in the secret (overrides provider selection).

### Resource defaults (smoke inherits base)

- Agent / trigger limits: **4 CPU / 4Gi**
- `RGCTL_WITH_LIMITS`: `max-mem-mb=3072,threads=4`
- Reviews serialized in the trigger (shared `/workspace`)

### Related docs

| Doc | Role |
|-----|------|
| [`deploy/openshift/README.md`](../deploy/openshift/README.md) | Secrets, apply, verify |
| [`README.md`](../README.md) | Product overview |
| [`agent/.opencode/skills/rgctl-pr-reviewer-v2/SKILL.md`](../agent/.opencode/skills/rgctl-pr-reviewer-v2/SKILL.md) | Verdict / Guidelines / inline contract |
