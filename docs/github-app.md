# GitHub App review ingress (read-only)

GitHub App webhook path for the same `rgctl-pr-reviewer-v2` skill used on GitLab. **Auto-review** on PR events plus **`@mention`** commands. Write-back is comments / review comments / optional Checks only — **no** push or open-fix-PR in v1.

GitLab path: [`deploy/openshift/README.md`](../deploy/openshift/README.md). Demo narrative: [`docs/demo-runbook.md`](demo-runbook.md).

---

## 1. Create the GitHub App

GitHub → Settings → Developer settings → **GitHub Apps** → New.

### Permissions (v1)

| Permission | Access |
|------------|--------|
| Repository permissions → **Contents** | **Read-only** |
| **Pull requests** | Read and write |
| **Issues** | Read and write |
| **Checks** | Read and write |
| **Metadata** | Read-only |

Do **not** grant Contents: Write until a future “fix PR” change.

### Subscribe to events

- `Pull request`
- `Issue comment`
- `Pull request review comment`

### Webhook

- URL: `https://<trigger-route-host>/hooks/github`
- Secret: generate a strong value → `GITHUB_WEBHOOK_SECRET`
- Content type: `application/json`

### Identity

- After create: note **App ID** → `GITHUB_APP_ID`
- Generate **private key** (PEM) → `GITHUB_APP_PRIVATE_KEY`
- Bot username / slug (e.g. `rgctl-bot[bot]` login without `[bot]` for mentions, or the App slug) → `GITHUB_BOT_SLUG`  
  Mentions match `@<GITHUB_BOT_SLUG>` (case-insensitive). Example: slug `rgctl-bot` → `@rgctl-bot`.

Install the App on pilot repositories (or the org).

---

## 2. Secrets

```bash
NS=pr-reviewer   # or pr-reviewer-smoke / github overlay NS

# PEM may be multi-line — use --from-file for the key
oc -n "$NS" create secret generic pr-reviewer-github-app \
  --from-literal=GITHUB_APP_ID='123456' \
  --from-literal=GITHUB_WEBHOOK_SECRET='...' \
  --from-literal=GITHUB_BOT_SLUG='rgctl-bot' \
  --from-file=GITHUB_APP_PRIVATE_KEY=./github-app.pem
```

Also keep existing agent secrets (`OPENCODE_SERVER_PASSWORD`, LLM keys). GitLab keys may be empty when running GitHub-only.

See [`deploy/openshift/secret-example.yaml`](../deploy/openshift/secret-example.yaml) for field names.

---

## 3. Deploy trigger in GitHub mode

Trigger image entrypoint selects provider via `TRIGGER_PROVIDER=github` (overlay) or run:

```bash
TRIGGER_PROVIDER=github python3 /app/trigger/github_app.py
```

OpenShift: apply the github overlay (standard **4 CPU / 4Gi** + `RGCTL_WITH_LIMITS=max-mem-mb=3072,threads=4` profile):

```bash
./deploy/openshift/deploy.sh github
```

That sets `TRIGGER_PROVIDER=github` and pulls env from `pr-reviewer-github-app` (+ shared config/LLM secrets).

Webhook path: **`POST /hooks/github`** (health: `GET /healthz`).

```bash
oc -n "$NS" get route pr-reviewer-trigger
# → https://<host>/hooks/github
```

---

## 4. Behavior

| Event | Behavior |
|-------|----------|
| `pull_request` opened / synchronize / reopened / ready_for_review | Full review if **not draft** |
| Draft `opened` | Skipped until `ready_for_review` |
| `@bot` / `@bot review` on PR | Full review |
| `@bot explain …` / clear question | Short in-thread reply (no fix PR) |
| `@bot fix` / implement | Soft refuse (read-only) |
| `@bot` on a non-PR issue | No fabricated PR review; short message |

Debounce + single in-flight review match the GitLab trigger (shared workspace).

---

## 5. Live smoke checklist

1. Install App on a test repo; confirm webhook deliveries (green) to `/hooks/github`.
2. Open a non-draft PR → Verdict issue comment + Files tab review comments; optional Check.
3. Comment `@<slug> review` → second review run (debounce permitting).
4. Comment `@<slug> please fix` → refusal reply; no new branch/PR.
5. Open a **draft** PR → no auto-review until marked ready.

Unit coverage (no App required): `python3 -m unittest trigger/test_github_app.py`.

---

## 6. Later: fix PRs

Grant Contents: Write (or a second App), add an explicit `@bot fix` path that pushes a branch and opens a PR. Keep review App read-only when possible.
