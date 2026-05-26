# =============================================================================
# OpenClaw Agent Container for Bedrock AgentCore Runtime
# Single-stage build: Node.js + Python in one image.
#
# Why not multi-stage for Node/pnpm?
# pnpm uses hardlinks and symlinks in its content-addressable store. Docker's
# COPY --from resolves symlinks into regular files and cannot preserve hardlinks
# across filesystem boundaries, which breaks ESM module resolution entirely.
# The only correct approach is to install pnpm and all Node packages directly
# in the final image, using a BuildKit cache mount to keep builds fast.
#
# Based on: github.com/aws-samples/sample-OpenClaw-on-AWS-with-Bedrock
#           enterprise/agent-container/Dockerfile
# Updated:  Latest Python 3.13, Node.js 24 LTS, OpenClaw latest
# =============================================================================

FROM python:3.13-slim

ARG TARGETARCH=arm64

RUN apt-get update && apt-get install -y --no-install-recommends \
    curl unzip git jq && rm -rf /var/lib/apt/lists/*

# Install AWS CLI v2 (architecture-aware)
RUN if [ "$TARGETARCH" = "arm64" ] || [ "$(uname -m)" = "aarch64" ]; then \
        curl -sL "https://awscli.amazonaws.com/awscli-exe-linux-aarch64.zip" -o "/tmp/awscli.zip"; \
    else \
        curl -sL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "/tmp/awscli.zip"; \
    fi && unzip -q /tmp/awscli.zip -d /tmp && /tmp/aws/install \
    && rm -rf /tmp/aws /tmp/awscli.zip

# Install Node.js 24 LTS (required by OpenClaw)
RUN curl -fsSL https://deb.nodesource.com/setup_24.x | bash - \
    && apt-get install -y nodejs && rm -rf /var/lib/apt/lists/*

# Install Python dependencies
COPY requirements.txt /tmp/requirements.txt
RUN pip install --no-cache-dir awscli boto3 requests && \
    pip install --no-cache-dir -r /tmp/requirements.txt

# Install pnpm + OpenClaw + ClawHub.
# Using a BuildKit cache mount so the pnpm store persists across builds —
# packages are only re-downloaded when versions change, not on every build.
# pnpm is installed and runs entirely within this single filesystem layer,
# so hardlinks and symlinks are preserved correctly.
ENV PNPM_HOME="/root/.local/share/pnpm"
ENV PATH="$PNPM_HOME:$PATH"
RUN --mount=type=cache,id=pnpm-store,target=/root/.local/share/pnpm/store \
    npm install -g pnpm && \
    mkdir -p "$PNPM_HOME" && \
    pnpm config set global-bin-dir "$PNPM_HOME" && \
    pnpm add -g openclaw@latest clawhub@latest

# Install gogcli — Google Workspace CLI (Go binary, not on npm)
# Downloads the pre-built binary from GitHub Releases, architecture-aware.
ARG GOGCLI_VERSION="0.19.0"
RUN ARCH=$(uname -m) && \
    if [ "$ARCH" = "aarch64" ] || [ "$ARCH" = "arm64" ]; then GOARCH="arm64"; else GOARCH="amd64"; fi && \
    curl -fsSL "https://github.com/openclaw/gogcli/releases/download/v${GOGCLI_VERSION}/gogcli_${GOGCLI_VERSION}_linux_${GOARCH}.tar.gz" \
        -o /tmp/gogcli.tar.gz && \
    tar -xzf /tmp/gogcli.tar.gz -C /usr/local/bin gog && \
    chmod +x /usr/local/bin/gog && \
    rm /tmp/gogcli.tar.gz && \
    gog --version

# Install enterprise built-in skills (Layer 1)
# These are available to all tenants with zero cold-start overhead.
# To customize: override SKILLS_PREINSTALL at build time.
# gog is included by default — Google credentials are injected at runtime
# via GOG_ACCOUNT_* env vars set by `just setup-google` in the infra repo.
ARG SKILLS_PREINSTALL="deep-research-pro self-improving-agent jina-reader skill-vetter gog"
RUN HOME=/root && mkdir -p /root/.openclaw/skills && \
    for skill in $SKILLS_PREINSTALL; do \
      for attempt in 1 2 3; do \
        clawhub install "$skill" --no-input --force && break; \
        echo "Retry $attempt for $skill..."; sleep 5; \
      done; \
    done && \
    # clawhub may install to /skills or ~/.openclaw/skills depending on version — consolidate
    if [ -d /skills ] && [ "$(ls -A /skills 2>/dev/null)" ]; then \
        cp -r /skills/. /root/.openclaw/skills/; \
    fi && \
    echo "Built-in skills installed: $SKILLS_PREINSTALL" && \
    ls /root/.openclaw/skills/ 2>/dev/null || echo "(no skills in ~/.openclaw/skills)"

# Find and copy templates so OpenClaw can find them from any cwd
RUN mkdir -p /app/docs/reference && \
    TEMPLATE_DIR=$(find /root/.local/share/pnpm /usr/lib/node_modules /usr/local/lib/node_modules -path "*/openclaw/docs/reference/templates" -type d 2>/dev/null | head -1) && \
    if [ -n "$TEMPLATE_DIR" ]; then cp -r "$TEMPLATE_DIR" /app/docs/reference/templates; \
    else echo "WARNING: templates not found, creating empty dir" && mkdir -p /app/docs/reference/templates; fi

# Pre-warm V8 Compile Cache (Node.js 22+)
# Caches compiled bytecode so openclaw CLI modules load faster at runtime
RUN mkdir -p /app/.compile-cache && \
    NODE_COMPILE_CACHE=/app/.compile-cache OPENCLAW_SKIP_ONBOARDING=1 \
    openclaw agent --help > /dev/null 2>&1 || true

WORKDIR /app

# Copy Agent Container application files
COPY server.py .
COPY entrypoint.sh .
COPY openclaw.json .
COPY permissions.py .
COPY identity.py .
COPY memory.py .
COPY observability.py .
COPY safety.py .
COPY skill_loader.py .
COPY workspace_assembler.py .
COPY gog_init.py .

# Copy auth-agent module
RUN mkdir -p /app/auth-agent
COPY auth-agent/permission_request.py /app/auth-agent/permission_request.py
COPY auth-agent/__init__.py /app/auth-agent/__init__.py

# Create directories
RUN mkdir -p /tmp/openclaw/sessions /tmp/workspace /root/.openclaw

# Make entrypoint executable
RUN chmod +x /app/entrypoint.sh

ENV OPENCLAW_SKIP_ONBOARDING=1
ENV PORT=8080

EXPOSE 8080

# Build: docker build --platform linux/arm64 -t openclaw-agent:latest .
ENTRYPOINT ["/app/entrypoint.sh"]
