# pr-reviewer-agent

Container image: OpenCode serve + `rgctl` + `rgctl-pr-reviewer-v2` skill.

PR review uses the **`rgctl review`** CLI (base artifact + `review paths` / `review check`). There is no `rgctl serve --watch` companion.

## LLM providers (LiteLLM + OpenAI)

OpenCode ships with two providers in `opencode.json`: **LiteLLM** (OpenAI-compatible proxy) and **OpenAI** (native). Pick one at runtime:

| Variable | Default | Description |
|----------|---------|-------------|
| `LLM_PROVIDER` | `litellm` | `litellm` or `openai` |
| `OPENCODE_MODEL` | — | Full `provider/model` override (e.g. `openai/gpt-4o`). Wins over `LLM_PROVIDER` |
| `LITELLM_BASE_URL` | `https://litemaas.rhoai.rh-aiservices-bu.com/v1` | LiteLLM `/v1` root |
| `LITELLM_API_KEY` | — | Required when using litellm |
| `LITELLM_MODEL` | `Qwen3.6-35B-A3B` | Model id under the litellm provider |
| `OPENAI_API_KEY` | — | Required when using openai |
| `OPENAI_MODEL` | `gpt-4o` | Model id under the openai provider |

```bash
# LiteLLM (default)
export LLM_PROVIDER=litellm
export LITELLM_API_KEY='<proxy-key>'

# OpenAI
export LLM_PROVIDER=openai
export OPENAI_API_KEY='sk-...'
export OPENAI_MODEL=gpt-4o
# or: export OPENCODE_MODEL=openai/gpt-4o
```

Pass these into the container (`-e` / Compose / Secret). Do not bake keys into the image.

## Other env

| Variable | Default | Description |
|----------|---------|-------------|
| `OPENCODE_SERVER_PASSWORD` | — | HTTP basic auth password (user `opencode`) |
| `REPO_PATH` | `/app/repo` | Git checkout the skill should operate on |
| `RGCTL_WITH_LIMITS` | `max-mem-mb=1536,threads=1` | Passed to every `rgctl discover --with-limits`. Keys: `max-mem-mb` (aliases `max-mem`, `memory-mb`) soft RSS — warn ~90%, abort ~95%; `threads` (aliases `thread`, `max-thread`, `max-threads`) caps discover/CFG Rayon workers. Keep `max-mem-mb` below the pod memory limit with headroom for OpenCode. The image wraps `rgctl` so discover cannot skip limits. |

Kubernetes agent pods default to **2 CPU / 2Gi** (OpenShift smoke uses **3Gi** + `max-mem-mb=2048`). Raise pod memory and `RGCTL_WITH_LIMITS` together if discover aborts near the soft tripwire.

OpenShift + in-cluster GitLab deploy: see [deploy/openshift/README.md](../deploy/openshift/README.md).

## Smoke tests

Config file (gitignored): copy the example and fill in the key:

```bash
cp agent/.env.example agent/.env
# edit agent/.env → set LITELLM_API_KEY=...
```

Both `smoke-test.sh` and `e2e-review-smoke.sh` load `agent/.env` (then repo-root `.env`) via `scripts/load-env.sh`. Shell-exported vars take precedence.

```bash
# Health only (LLM key optional)
./agent/scripts/smoke-test.sh pr-reviewer-agent:latest

# Full coolstore e2e (requires LITELLM_API_KEY in agent/.env or the environment)
./agent/scripts/e2e-review-smoke.sh pr-reviewer-agent:latest
```

Each e2e run writes a folder under `agent/e2e-runs/<timestamp>-<id>/` (gitignored):

| File | Contents |
|------|----------|
| `trace.out` | Timestamped step log (mirrors console) |
| `transcript.md` | Final assistant review text |
| `messages.json` | Raw OpenCode session messages |
| `input.json` / `prompt.txt` | Skill input and prompt |
| `review-paths.json` | Host-side `rgctl review paths` (best-effort) |
| `docker.log` | Agent container logs |
| `git-diff.patch` / `git-stat.txt` | Fixture delta |
| `result.json` / `assert.txt` | Pass/fail + section checks |
