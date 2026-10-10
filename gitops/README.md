# pr-reviewer GitOps

This folder contains everything needed to install and configure the PR Reviewer platform via Argo CD on OpenShift.

## Structure

```
gitops/
├── install/                  # Argo CD Application — installs the Helm chart (sync wave 1)
│   ├── argocd-app-install.yaml
│   └── overlays/
│       ├── dev/values.yaml   # dev cluster overrides
│       └── prod/values.yaml  # prod cluster overrides
│
└── config/                   # Argo CD Application — Day 2 config (sync wave 2)
    ├── argocd-app-config.yaml
    ├── users.yaml            # declarative user list
    ├── repos.yaml            # declarative repo list
    ├── configmap-seed.yaml   # wraps users.yaml + repos.yaml + seed script
    └── job-seed.yaml         # PostSync Job — calls REST API idempotently
```

## Bootstrap (first install)

### 1. Apply the Argo CD Applications

```bash
oc apply -f gitops/install/argocd-app-install.yaml
oc apply -f gitops/config/argocd-app-config.yaml
```

Argo CD syncs wave 1 (Helm chart) before wave 2 (seed Job).

### 2. Retrieve the admin password

```bash
oc get secret pr-reviewer-admin -n pr-reviewer \
  -o jsonpath='{.data.password}' | base64 -d
echo
```

Log in at `https://<route-hostname>/login` with the email from `values.yaml` (`admin.email`) and the password above.

### 3. Register a GitHub/GitLab App (admin UI or API)

Before repos in `repos.yaml` can be provisioned, the referenced App (e.g. `github-acme`) must be registered by an admin:

```bash
curl -s -u admin@pr-reviewer.local:<password> \
  -X POST https://<route>/api/v1/apps \
  -H "Content-Type: application/json" \
  -d '{
    "name": "github-acme",
    "provider": "github",
    "appId": "123456",
    "privateKey": "-----BEGIN RSA PRIVATE KEY-----\n...",
    "webhookSecret": "your-webhook-secret"
  }'
```

### 4. Set the GitHub/GitLab webhook URL

In your GitHub App settings, set the webhook URL to:

```
https://<route-hostname>/api/v1/webhooks/github
```

For GitLab, set the webhook URL to:

```
https://<route-hostname>/api/v1/webhooks/gitlab
```

## Day 2: Adding users and repos

Edit `gitops/config/users.yaml` and/or `gitops/config/repos.yaml`, then commit and push. Argo CD detects the change, syncs the ConfigMap, and runs the seed Job. The Job is idempotent — existing users and repos are unaffected.

```bash
# Add a user
echo "  - email: newuser@acme.com\n    role: user" >> gitops/config/users.yaml
git add gitops/config/ && git commit -m "feat: add newuser" && git push
# Argo CD syncs → seed Job runs → user created
```

## Monitoring

```bash
# Watch seed Job logs
oc logs -n pr-reviewer -l job-name=pr-reviewer-seed -f

# Check repo indexing status
oc get pods -n pr-reviewer -l app=pr-reviewer-discover

# View per-repo agent pods
oc get pods -n pr-reviewer -l app=pr-reviewer-agent
```
