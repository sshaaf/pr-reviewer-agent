# Coolstore seed (policy + architecture)

Copy these files into a coolstore (or demo) GitLab project so OpenShift MR reviews exercise policy + doc applicability:

| File | Role |
|------|------|
| `policy.json` | `rgctl review check` / `pr-check` policy (`max_impact_nodes: 12`, temporal scope) |
| `docs/architecture.md` | Human guidelines the skill may cite (soft; not auto-RED) |

```bash
cp policy.json /path/to/coolstore/
mkdir -p /path/to/coolstore/docs
cp docs/architecture.md /path/to/coolstore/docs/
```

E2E smoke overlays this seed automatically when cloning coolstore.
