# pr-reviewer-agent: opencode + rgctl + rgctl-pr-reviewer-v2 skill
#
# Prefer linux/amd64 (published rgctl linux-gnu + OpenCode glibc tarball):
#   docker build --platform linux/amd64 -f agent/Dockerfile -t pr-reviewer-agent:latest .
#
# OpenShift runs as an arbitrary UID in group 0.

ARG RGCTL_VERSION=v0.4.19
ARG RGCTL_REPO=sshaaf/rgctl
ARG OPENCODE_VERSION=v1.19.0

FROM ubuntu:24.04

ARG RGCTL_VERSION
ARG RGCTL_REPO
ARG OPENCODE_VERSION
ARG TARGETARCH

USER root

RUN apt-get update \
  && apt-get install -y --no-install-recommends \
       ca-certificates curl tar git openssh-client jq \
  && rm -rf /var/lib/apt/lists/* \
  && mkdir -p /app/rgctl-db /app/repo /tmp/opencode/log \
  && chown -R 1001:0 /app /tmp/opencode \
  && chmod -R g+rwX /app /tmp/opencode \
  && chmod 1777 /tmp

# OpenCode glibc build (do NOT copy from Alpine musl image)
RUN set -e; \
  case "${TARGETARCH}" in \
    amd64|x86_64) OC_ASSET="opencode-linux-x64.tar.gz" ;; \
    arm64|aarch64) OC_ASSET="opencode-linux-arm64.tar.gz" ;; \
    *) echo "unsupported TARGETARCH=${TARGETARCH}"; exit 1 ;; \
  esac; \
  URL="https://github.com/anomalyco/opencode/releases/download/${OPENCODE_VERSION}/${OC_ASSET}"; \
  echo "Downloading ${URL}"; \
  curl -fsSL -o /tmp/opencode.tgz "${URL}"; \
  tar -C /usr/local/bin -xzf /tmp/opencode.tgz opencode; \
  chmod +x /usr/local/bin/opencode; \
  rm -f /tmp/opencode.tgz; \
  opencode --version

# rgctl linux-gnu (amd64 published; arm64 not published yet — require amd64 builds)
RUN set -e; \
  case "${TARGETARCH}" in \
    amd64|x86_64) RGCTL_TRIPLE="x86_64-unknown-linux-gnu" ;; \
    *) echo "No published rgctl linux-gnu for TARGETARCH=${TARGETARCH}. Build with --platform linux/amd64."; exit 1 ;; \
  esac; \
  VER="${RGCTL_VERSION#v}"; \
  URL="https://github.com/${RGCTL_REPO}/releases/download/${RGCTL_VERSION}/rgctl-${VER}-${RGCTL_TRIPLE}.tar.gz"; \
  echo "Downloading ${URL}"; \
  curl -fsSL -o /tmp/rgctl.tgz "${URL}"; \
  tar -C /usr/local/bin -xzf /tmp/rgctl.tgz rgctl; \
  chmod +x /usr/local/bin/rgctl; \
  rm -f /tmp/rgctl.tgz; \
  rgctl --version

WORKDIR /app

COPY --chown=1001:0 agent/opencode.json /app/opencode.json
COPY --chown=1001:0 agent/.opencode /app/.opencode
COPY --chown=1001:0 agent/scripts/entrypoint.sh /app/scripts/entrypoint.sh
COPY --chown=1001:0 agent/scripts/review-workspace.sh /app/scripts/review-workspace.sh
RUN chmod +x /app/scripts/entrypoint.sh /app/scripts/review-workspace.sh

EXPOSE 4096

ENV OPENCODE_HOSTNAME=0.0.0.0
ENV OPENCODE_PORT=4096
ENV HOME=/tmp
ENV XDG_DATA_HOME=/tmp
ENV XDG_CACHE_HOME=/tmp
ENV XDG_CONFIG_HOME=/tmp
ENV RGCTL_DB=/app/rgctl-db
ENV LITELLM_BASE_URL=https://litemaas.rhoai.rh-aiservices-bu.com/v1
# Default for constrained K8s/OpenShift agent pods (override at runtime).
ENV RGCTL_WITH_LIMITS=max-mem-mb=1536,threads=1

USER 1001

ENTRYPOINT ["/app/scripts/entrypoint.sh"]
