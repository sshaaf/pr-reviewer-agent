# Webhook trigger (GitLab or GitHub App) — git + rgctl + Python.
# Prefer linux/amd64.
# TRIGGER_PROVIDER=gitlab|github selects entrypoint.
ARG RGCTL_VERSION=v0.4.19
ARG RGCTL_REPO=sshaaf/rgctl

FROM ubuntu:24.04

ARG RGCTL_VERSION
ARG RGCTL_REPO
ARG TARGETARCH

USER root

RUN apt-get update \
  && apt-get install -y --no-install-recommends \
       ca-certificates curl tar git python3 openssl \
  && rm -rf /var/lib/apt/lists/* \
  && mkdir -p /app/scripts /app/trigger /workspace \
  && chown -R 1001:0 /app /workspace \
  && chmod -R g+rwX /app /workspace \
  && chmod 1777 /tmp

RUN set -e; \
  case "${TARGETARCH}" in \
    amd64|x86_64) RGCTL_TRIPLE="x86_64-unknown-linux-gnu" ;; \
    *) echo "Build with --platform linux/amd64"; exit 1 ;; \
  esac; \
  VER="${RGCTL_VERSION#v}"; \
  URL="https://github.com/${RGCTL_REPO}/releases/download/${RGCTL_VERSION}/rgctl-${VER}-${RGCTL_TRIPLE}.tar.gz"; \
  curl -fsSL -o /tmp/rgctl.tgz "${URL}"; \
  mkdir -p /usr/local/libexec; \
  tar -C /usr/local/libexec -xzf /tmp/rgctl.tgz rgctl; \
  chmod +x /usr/local/libexec/rgctl; \
  rm -f /tmp/rgctl.tgz; \
  /usr/local/libexec/rgctl --version

COPY --chown=1001:0 trigger/app.py /app/trigger/app.py
COPY --chown=1001:0 trigger/github_app.py /app/trigger/github_app.py
COPY --chown=1001:0 trigger/github_auth.py /app/trigger/github_auth.py
COPY --chown=1001:0 trigger/mention_intents.py /app/trigger/mention_intents.py
COPY --chown=1001:0 trigger/github_intents.py /app/trigger/github_intents.py
COPY --chown=1001:0 trigger/entrypoint.sh /app/trigger/entrypoint.sh
COPY --chown=1001:0 agent/scripts/review-workspace.sh /app/scripts/review-workspace.sh
COPY --chown=1001:0 agent/scripts/post-inline-comments.sh /app/scripts/post-inline-comments.sh
COPY --chown=1001:0 agent/scripts/resolve-policy.sh /app/scripts/resolve-policy.sh
COPY --chown=1001:0 agent/scripts/rgctl-wrapper.sh /usr/local/bin/rgctl
RUN chmod +x /app/scripts/review-workspace.sh /app/scripts/post-inline-comments.sh \
      /app/scripts/resolve-policy.sh \
      /app/trigger/entrypoint.sh \
      /app/trigger/app.py /app/trigger/github_app.py /usr/local/bin/rgctl \
  && rgctl --version

ENV HOME=/tmp
ENV WORKSPACE=/workspace/repo
ENV REVIEW_WORKSPACE_SCRIPT=/app/scripts/review-workspace.sh
ENV LISTEN_PORT=8080
ENV AGENT_URL=http://127.0.0.1:4096
ENV TRIGGER_PROVIDER=gitlab
ENV PYTHONPATH=/app/trigger
# Soft RSS + Rayon thread cap for discover (override via ConfigMap/Secret).
ENV RGCTL_WITH_LIMITS=max-mem-mb=1536,threads=1

USER 1001
EXPOSE 8080
WORKDIR /app

ENTRYPOINT ["/app/trigger/entrypoint.sh"]
