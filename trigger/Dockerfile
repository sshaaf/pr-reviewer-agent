# GitLab webhook trigger — same toolchain as agent (git + rgctl) + Python.
# Prefer linux/amd64.
ARG RGCTL_VERSION=v0.4.19
ARG RGCTL_REPO=sshaaf/rgctl

FROM ubuntu:24.04

ARG RGCTL_VERSION
ARG RGCTL_REPO
ARG TARGETARCH

USER root

RUN apt-get update \
  && apt-get install -y --no-install-recommends \
       ca-certificates curl tar git python3 \
  && rm -rf /var/lib/apt/lists/* \
  && mkdir -p /app/scripts /workspace \
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
  tar -C /usr/local/bin -xzf /tmp/rgctl.tgz rgctl; \
  chmod +x /usr/local/bin/rgctl; \
  rm -f /tmp/rgctl.tgz; \
  rgctl --version

COPY --chown=1001:0 trigger/app.py /app/trigger/app.py
COPY --chown=1001:0 agent/scripts/review-workspace.sh /app/scripts/review-workspace.sh
RUN chmod +x /app/scripts/review-workspace.sh /app/trigger/app.py

ENV HOME=/tmp
ENV WORKSPACE=/workspace/repo
ENV REVIEW_WORKSPACE_SCRIPT=/app/scripts/review-workspace.sh
ENV LISTEN_PORT=8080
ENV AGENT_URL=http://127.0.0.1:4096

USER 1001
EXPOSE 8080
WORKDIR /app

ENTRYPOINT ["python3", "/app/trigger/app.py"]
