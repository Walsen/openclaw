# =============================================================================
# OpenClaw Agent Container for Bedrock AgentCore Runtime
# Multi-stage build: builder (install everything) -> runtime (minimal image)
#
# Based on: github.com/aws-samples/sample-OpenClaw-on-AWS-with-Bedrock
#           enterprise/agent-container/Dockerfile
# Updated:  Latest Python 3.13, Node.js 24 LTS, OpenClaw latest
# =============================================================================

# Stage 1: Builder - install all dependencies and tools
FROM --platform=linux/arm64 python:3.13-slim AS builder

ARG TARGETARCH=arm64

RUN apt-get update && apt-get install -y --no-install-recommends \
    curl unzip git && rm -rf /var/lib/apt/lists/*

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

# Install pnpm globally, then use it for OpenClaw + ClawHub
RUN npm install -g pnpm

# Install OpenClaw and ClawHub CLI globally via pnpm
# Using latest — test IM channels end-to-end if using Telegram/Discord/Slack
RUN pnpm add -g openclaw@latest clawhub@latest

# Install enterprise built-in skills (Layer 1)
# These are available to all tenants with zero cold-start overhead.
# To customize: override SKILLS_PREINSTALL at build time.
ARG SKILLS_PREINSTALL="deep-research-pro self-improving-agent jina-reader skill-vetter"
RUN HOME=/root && mkdir -p /root/.openclaw && \
    for skill in $SKILLS_PREINSTALL; do \
      for attempt in 1 2 3; do \
        clawhub install "$skill" --no-input --force && break; \
        echo "Retry $attempt for $skill..."; sleep 5; \
      done; \
    done; echo "Built-in skills installed: $SKILLS_PREINSTALL"

# Find and copy templates so OpenClaw can find them from any cwd
RUN mkdir -p /app/docs/reference && \
    TEMPLATE_DIR=$(find /root/.local/share/pnpm /usr/lib/node_modules /usr/local/lib/node_modules -path "*/openclaw/docs/reference/templates" -type d 2>/dev/null | head -1) && \
    if [ -n "$TEMPLATE_DIR" ]; then cp -r "$TEMPLATE_DIR" /app/docs/reference/templates; \
    else echo "WARNING: templates not found, creating empty dir" && mkdir -p /app/docs/reference/templates; fi

# Install Python dependencies
COPY requirements.txt /tmp/requirements.txt
RUN pip install --no-cache-dir -r /tmp/requirements.txt

# Pre-warm V8 Compile Cache (Node.js 22+)
# Caches compiled bytecode so openclaw CLI modules load faster at runtime
RUN mkdir -p /app/.compile-cache && \
    NODE_COMPILE_CACHE=/app/.compile-cache OPENCLAW_SKIP_ONBOARDING=1 \
    openclaw agent --help > /dev/null 2>&1 || true

# Stage 2: Runtime - minimal image with only needed artifacts
FROM --platform=linux/arm64 python:3.13-slim

RUN apt-get update && apt-get install -y --no-install-recommends jq curl \
    && rm -rf /var/lib/apt/lists/*

# Install AWS CLI via pip (not binary copy — avoids Python version mismatch)
RUN pip install --no-cache-dir awscli boto3 requests

# Copy Node.js runtime from builder
COPY --from=builder /usr/bin/node /usr/bin/node

# Copy pnpm global store + bin links from builder
COPY --from=builder /root/.local/share/pnpm /root/.local/share/pnpm
ENV PNPM_HOME="/root/.local/share/pnpm"
ENV PATH="$PNPM_HOME:$PATH"

# Re-create openclaw symlink if needed (COPY resolves symlinks, breaking ESM imports)
RUN OPENCLAW_MJS=$(find $PNPM_HOME -name "openclaw.mjs" -path "*/openclaw/*" 2>/dev/null | head -1) && \
    if [ -n "$OPENCLAW_MJS" ]; then ln -sf "$OPENCLAW_MJS" /usr/local/bin/openclaw; fi

# Copy V8 compile cache + templates from builder
COPY --from=builder /app/.compile-cache /app/.compile-cache
COPY --from=builder /app/docs/reference /app/docs/reference

# Copy built-in skills from builder (Layer 1)
# clawhub installs to ~/.openclaw/skills/ directory
COPY --from=builder /root/.openclaw/skills /root/.openclaw/skills

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
