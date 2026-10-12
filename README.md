# sdlc-agents

OpenCode + `rgctl` **PR review agent** for OpenShift, integrated with **in-cluster GitLab**.

## Layout

```
agent/                    Agent image (OpenCode + rgctl + skill)
trigger/                  GitLab webhook trigger image
deploy/openshift/         Kustomize manifests (agent + trigger sidecar pod)
.github/workflows/        Build/push Quay images
```

## Images

| Image | Registry |
|-------|----------|
| Agent | `quay.io/sshaaf/pr-reviewer-agent` |
| Trigger | `quay.io/sshaaf/pr-reviewer-trigger` |

## Local build / smoke

```bash
docker build --platform linux/amd64 -f agent/Dockerfile -t pr-reviewer-agent:latest .
cp agent/.env.example agent/.env   # set LITELLM_API_KEY for e2e
./agent/scripts/smoke-test.sh pr-reviewer-agent:latest
./agent/scripts/e2e-review-smoke.sh pr-reviewer-agent:latest
```

## OpenShift + GitLab

See **[deploy/openshift/README.md](deploy/openshift/README.md)** for Secrets, `GITLAB_URL`, webhook registration, and verify steps.

```bash
oc apply -k deploy/openshift
```

## Skill Input JSON

Documented in `agent/.opencode/skills/rgctl-pr-reviewer-v2/SKILL.md` (includes `project_id`, `gitlab_token`, `gitlab_url` for OpenShift MR reviews).
