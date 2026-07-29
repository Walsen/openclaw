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

# No default: BuildKit injects the real target arch here. Hardcoding arm64 as a
# default wins over the injected value, which silently installed the aarch64 AWS
# CLI into linux/amd64 builds (the CI Trivy image), leaving `aws` unrunnable.
ARG TARGETARCH

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
# Do NOT add `awscli` here: that is AWS CLI v1, and pip's console script would
# overwrite the /usr/local/bin/aws symlink created by the v2 installer above,
# silently downgrading every `aws` call in entrypoint.sh to v1 while leaving the
# v2 install as dead weight. boto3/requests come from requirements.txt.
COPY requirements.txt /tmp/requirements.txt
RUN pip install --no-cache-dir -r /tmp/requirements.txt

# Install pnpm + OpenClaw + ClawHub.
# Using a BuildKit cache mount so the pnpm store persists across builds —
# packages are only re-downloaded when versions change, not on every build.
# pnpm is installed and runs entirely within this single filesystem layer,
# so hardlinks and symlinks are preserved correctly.
ENV PNPM_HOME="/root/.local/share/pnpm"
ENV PATH="$PNPM_HOME:$PATH"

# Install openclaw and clawhub via npm (not pnpm) to avoid pnpm v11 virtual
# store layout issues where dependency links break at runtime.
# pnpm is still installed for clawhub skill installs later.
#
# VERSION PAIRING — read before bumping either number.
# Up to 2026.5.7 the Bedrock provider lived inside openclaw itself. From
# 2026.6.x it is a separate plugin package, @openclaw/amazon-bedrock-provider,
# which carries the AWS SDK and @smithy/node-http-handler as direct deps (the
# missing dep that used to surface as "LLM request failed"). openclaw core no
# longer depends on any AWS SDK, so installing openclaw ALONE leaves Bedrock
# unregistered. The two must be installed together and kept on the same
# version — the plugin declares `peerDependencies: openclaw >= 2026.6.33`.
#
# 2026.6.33 is the `extended-stable` tag, chosen over `latest` (2026.7.1-2)
# because 2026.7.x also narrows the supported Node range.
#
# clawhub is pinned too: it fetches the built-in skills below at build time, so
# leaving it floating on @latest means two builds of the same commit can produce
# different images.
ARG OPENCLAW_VERSION=2026.6.33
ARG BEDROCK_PROVIDER_VERSION=2026.6.33
RUN npm install -g pnpm "openclaw@${OPENCLAW_VERSION}" clawhub@0.23.1 && \
    pnpm config set global-bin-dir "$PNPM_HOME"

# Install the Bedrock provider plugin. Without this the gateway starts fine but
# every turn fails, because `bedrock-converse-stream` is never registered.
# `openclaw plugins install` takes no --no-input flag (unlike clawhub); it is
# non-interactive already.
RUN HOME=/root openclaw plugins install \
        "npm:@openclaw/amazon-bedrock-provider@${BEDROCK_PROVIDER_VERSION}" --force && \
    HOME=/root openclaw plugins list 2>&1 | grep -qi "amazon-bedrock" && \
    echo "[plugins] amazon-bedrock provider registered" || \
    (echo "FATAL: amazon-bedrock provider plugin did not register" && exit 1)

# Install gogcli — Google Workspace CLI (Go binary, not on npm)
# Downloads the pre-built binary from GitHub Releases, architecture-aware.
# 0.34.1 verified against gog_init.py's exact command surface: `auth credentials
# set -`, `auth import --email --refresh-token-env`, `auth alias set`,
# `auth doctor --check`, and the GOG_KEYRING_BACKEND=file env contract.
ARG GOGCLI_VERSION="0.34.1"
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
# Note: gog (gogcli) is installed as a binary above — not via clawhub.
# gog_init.py handles credential setup at container startup.
#
# Use SCOPED skill names (@publisher/slug). Bare slugs are ambiguous on ClawHub
# now that several publishers own the same slug, and `clawhub install <slug>`
# exits non-zero listing the candidates. Retrying an ambiguous name can never
# succeed, so the old loop burned ~30s per skill and the build still exited 0 —
# shipping an image with the skills silently absent.
#
# Entries take the form @publisher/slug[@version]; pin the version so a rebuild
# of the same commit cannot pull different skill content. No ClawHub account is
# needed for search/inspect/install — only `clawhub scan` and publishing require
# a token.
#
# SKILLS_STRICT=1 turns "a requested skill is missing" into a build failure, so a
# skill can never again go silently absent. Every entry below is scoped AND
# version-pinned, which is what makes that safe.
#   @parags/deep-research-pro     original (created 2026-02), 35k downloads, scan CLEAN
#   @ericsantos/jina-reader       sole owner of the slug, 8.8k downloads, scan CLEAN
#   @pskoett/self-improving-agent 470k downloads, OpenClaw-native, ships tests
# See docs/SKILLS.md for what each one does and how to drive it.
ARG SKILLS_PREINSTALL="@parags/deep-research-pro@1.0.2 @ericsantos/jina-reader@0.0.2 @pskoett/self-improving-agent@4.0.1"
ARG SKILLS_STRICT=1
# Hook packs shipped inside a skill are not registered by installing the skill.
# They are installed as plugins (`openclaw hooks install` is deprecated in favour
# of `openclaw plugins install`). Registering the pack is static, so it happens
# here at build time; ENABLING it happens in entrypoint.sh, because the runtime
# config is regenerated from /app/openclaw.json on every start and would discard a
# build-time enable.
ARG SKILL_HOOK_PACKS="@pskoett/self-improving-agent/hooks/openclaw"
RUN HOME=/root && mkdir -p /root/.openclaw/skills && \
    for entry in $SKILLS_PREINSTALL; do \
      pkg="$entry"; ver=""; \
      # Split a trailing @<version>. The leading @ of a scope is not a version,
      # so only match when a version digit follows the final @.
      case "$entry" in *[a-zA-Z0-9]@[0-9]*) pkg="${entry%@*}"; ver="${entry##*@}" ;; esac; \
      set -- --workdir /root/.openclaw --dir skills install "$pkg" --no-input --force; \
      [ -n "$ver" ] && set -- "$@" --version "$ver"; \
      for attempt in 1 2 3; do \
        out=$(clawhub "$@" 2>&1) && { echo "$out"; break; }; \
        echo "$out"; \
        # An ambiguous slug or an unknown skill will never resolve on retry.
        case "$out" in \
          *"multiple skills"*|*"not found"*) echo "[skills] '$entry' is not resolvable — skipping retries"; break ;; \
        esac; \
        echo "[skills] retry $attempt for $entry..."; sleep 5; \
      done; \
    done; \
    # Older clawhub versions install to /skills — consolidate if that happened.
    if [ -d /skills ] && [ "$(ls -A /skills 2>/dev/null)" ]; then \
        cp -r /skills/. /root/.openclaw/skills/; \
    fi; \
    missing=""; \
    for entry in $SKILLS_PREINSTALL; do \
      pkg="${entry%@[0-9]*}"; slug="${pkg##*/}"; \
      # Scoped installs land in skills/@publisher/<slug>, unscoped in skills/<slug>.
      [ -n "$(find /root/.openclaw/skills -maxdepth 2 -type d -name "$slug" 2>/dev/null)" ] \
        || missing="$missing $slug"; \
    done; \
    echo "[skills] installed:$(find /root/.openclaw/skills -maxdepth 3 -name SKILL.md -printf ' %h\n' 2>/dev/null | sed 's|.*/skills/||' | tr '\n' ' ')"; \
    if [ -n "$missing" ]; then \
      echo "[skills] WARNING: requested but NOT installed:$missing"; \
      if [ "$SKILLS_STRICT" = "1" ]; then echo "[skills] SKILLS_STRICT=1 — failing build"; exit 1; fi; \
    fi

# Register hook packs bundled inside the installed skills.
RUN for pack in $SKILL_HOOK_PACKS; do \
      dir="/root/.openclaw/skills/$pack"; \
      if [ -d "$dir" ]; then \
        HOME=/root openclaw plugins install "$dir" --force 2>&1 | tail -2; \
      else \
        echo "[hooks] pack path not found: $dir"; \
        if [ "$SKILLS_STRICT" = "1" ]; then exit 1; fi; \
      fi; \
    done && \
    HOME=/root openclaw hooks list 2>&1 | grep -qi "self-improvement" && \
    echo "[hooks] self-improvement hook pack registered" || \
    (echo "FATAL: hook pack did not register" && exit 1)

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

# AWS CLI v2 introduced a client-side pager that v1 never had. entrypoint.sh
# discards stderr on its aws calls, so a pager stalling on a non-TTY would look
# like a silent sync failure. Disable it explicitly.
ENV AWS_PAGER=""

EXPOSE 8080

# Build: docker build --platform linux/arm64 -t openclaw-agent:latest .
ENTRYPOINT ["/app/entrypoint.sh"]
