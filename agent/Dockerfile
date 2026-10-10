# pr-reviewer-agent: opencode + rgctl + rgctl-pr-reviewer-v2 skill
#
# Build from repo root:
#   docker build -f agent/Dockerfile -t pr-reviewer-agent:latest .
#
# OpenShift runs as an arbitrary UID in group 0.
# All writable paths are owned 1001:0 with g+rwX.
FROM ghcr.io/anomalyco/opencode:latest

USER root

# Install system dependencies and rgctl
ARG RGCTL_VERSION=latest
ARG TARGETARCH

RUN apk add --no-cache git openssh-client ca-certificates curl tar gcompat jq \
  && ARCH="$(uname -m)" \
  && case "${ARCH}" in \
       x86_64)  RGCTL_ARCH="x86_64-unknown-linux-musl" ;; \
       aarch64) RGCTL_ARCH="aarch64-unknown-linux-musl" ;; \
       *) echo "unsupported arch ${ARCH}"; exit 1 ;; \
     esac \
  && if [ "${RGCTL_VERSION}" = "latest" ]; then \
       RGCTL_URL="$(curl -sf https://api.github.com/repos/reachability-graph/rgctl/releases/latest \
         | jq -r --arg arch "${RGCTL_ARCH}" '.assets[] | select(.name | test($arch)) | .browser_download_url')"; \
     else \
       RGCTL_URL="https://github.com/reachability-graph/rgctl/releases/download/${RGCTL_VERSION}/rgctl-${RGCTL_ARCH}.tar.gz"; \
     fi \
  && curl -fsSL -o /tmp/rgctl.tar.gz "${RGCTL_URL}" \
  && tar -C /usr/local/bin -xzf /tmp/rgctl.tar.gz rgctl \
  && rm -f /tmp/rgctl.tar.gz \
  && rgctl --version \
  && mkdir -p /app/rgctl-db /app/repo /tmp/opencode/log \
  && chown -R 1001:0 /app /tmp/opencode \
  && chmod -R g+rwX /app /tmp/opencode \
  && chmod 1777 /tmp

WORKDIR /app

# Bake in opencode config, skills, and entrypoint
COPY --chown=1001:0 agent/opencode.json /app/opencode.json
COPY --chown=1001:0 agent/.opencode /app/.opencode
COPY --chown=1001:0 agent/scripts/entrypoint.sh /app/scripts/entrypoint.sh
RUN chmod +x /app/scripts/entrypoint.sh

EXPOSE 4096

ENV OPENCODE_HOSTNAME=0.0.0.0
ENV OPENCODE_PORT=4096
ENV HOME=/tmp
ENV XDG_DATA_HOME=/tmp
ENV XDG_CACHE_HOME=/tmp
ENV XDG_CONFIG_HOME=/tmp
ENV RGCTL_DB=/app/rgctl-db

# Secrets (LLM keys, VCS tokens, OPENCODE_SERVER_PASSWORD) at runtime via K8s Secrets.
USER 1001

ENTRYPOINT ["/app/scripts/entrypoint.sh"]
