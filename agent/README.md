# pr-reviewer-agent

Container image: OpenCode serve + `rgctl` + `rgctl-pr-reviewer-v2` skill.

PR review uses the **`rgctl review`** CLI (base artifact + `review paths` / `review check`). There is no `rgctl serve --watch` companion.

## LLM (LiteLLM / OpenAI-compatible)

OpenCode is configured for an OpenAI-compatible `/v1/chat/completions` endpoint.

| Variable | Required | Default | Description |
|----------|----------|---------|-------------|
| `LITELLM_BASE_URL` | yes (set by entrypoint default) | `https://litemaas.rhoai.rh-aiservices-bu.com/v1` | OpenAI-compatible API root |
| `LITELLM_API_KEY` | **yes** for real reviews | — | Bearer token for the proxy |
| `LITELLM_MODEL` | no | `Qwen3.6-35B-A3B` | Model id; must exist under `provider.litellm.models` in `opencode.json` when overridden at build/config time |

Example (same shape as curl to LiteLLM):

```bash
export LITELLM_BASE_URL=https://litemaas.rhoai.rh-aiservices-bu.com/v1
export LITELLM_API_KEY='<your-key>'
# model used by opencode.json: litellm/Qwen3.6-35B-A3B
```

Pass these into the container (`-e` / Compose / your orchestrator). Do not bake keys into the image.

## Other env

| Variable | Default | Description |
|----------|---------|-------------|
| `OPENCODE_SERVER_PASSWORD` | — | HTTP basic auth password (user `opencode`) |
| `REPO_PATH` | `/app/repo` | Git checkout the skill should operate on |
| `RGCTL_WITH_LIMITS` | `max-mem-mb=1536,threads=1` | Soft RSS + thread cap for `rgctl discover` (and skill `--with-limits`). Keep `max-mem-mb` below the pod memory limit with headroom for OpenCode |

Kubernetes agent pods default to **2 CPU / 2Gi**. The skill also uses modest review budgets (`fanout=5`, `max_symbols=25`). Raise memory limits and `RGCTL_WITH_LIMITS` together if indexing large repos aborts near the soft memory tripwire (~95% of `max-mem-mb`).

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
