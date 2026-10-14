# Coolstore seed (policy + review guidance)

Copy these files into a coolstore (or demo) project so MR/PR reviews exercise policy + soft doc applicability:

| File | Role |
|------|------|
| `policy.json` | `rgctl review check` / `pr-check` policy (`max_impact_nodes: 12`, temporal scope) |
| `REVIEW.md` | Human review guidelines the skill may cite (soft; not auto-RED) |
| `AGENTS.md` | Short agent-oriented notes (soft; not auto-RED) |

```bash
cp policy.json REVIEW.md AGENTS.md /path/to/coolstore/
```

E2E smoke overlays this seed automatically when cloning coolstore.
