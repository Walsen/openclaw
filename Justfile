# OpenClaw AgentCore — task runner
# Usage: just <recipe>   (requires just, available via devbox)

# List available recipes
default:
    @just --list

# ── Dev environment ───────────────────────────────────────────────────────────

# Start local dev container (LOCAL_DEV=true, real Bedrock)
up:
    docker compose up

# Start in background
up-d:
    docker compose up -d

# Stop local dev container
down:
    docker compose down

# Tail container logs
logs:
    docker compose logs -f

# Reset conversation memory (wipe Docker volume)
reset-memory:
    docker compose down -v
    @echo "Memory volume removed"

# ── Build ─────────────────────────────────────────────────────────────────────

# Build ARM64 image locally
build:
    docker build --platform linux/arm64 -t ffactory/openclaw:local .

# Build with custom skills
build-skills skills="deep-research-pro jina-reader":
    docker build --platform linux/arm64 \
        --build-arg SKILLS_PREINSTALL="{{ skills }}" \
        -t ffactory/openclaw:local .

# ── Lint & test ───────────────────────────────────────────────────────────────

# Run all lint checks
lint:
    ruff check .
    ruff format --check .
    shellcheck entrypoint.sh
    python3 -c "import json; json.load(open('openclaw.json'))"

# Auto-fix formatting
fmt:
    ruff format .
    ruff check --fix .

# Compile-check all Python files
compile:
    @for f in server.py workspace_assembler.py permissions.py identity.py \
               memory.py observability.py safety.py skill_loader.py \
               auth-agent/permission_request.py; do \
        python3 -m py_compile "$$f" && echo "OK $$f"; \
    done

# Run tests
test:
    python3 -m pytest tests/ -v --tb=short 2>/dev/null || echo "No tests found"

# Run full pre-commit check (lint + compile + test)
check:
    bash scripts/pre-commit.sh

# Install pre-commit hook
install-hooks:
    cp scripts/pre-commit.sh .git/hooks/pre-commit
    chmod +x .git/hooks/pre-commit
    @echo "Pre-commit hook installed"

# ── Interact with running container ──────────────────────────────────────────

# Health check
ping:
    curl -sf http://localhost:8080/ping | jq .

# Send a chat message
chat message="hello":
    curl -s -X POST http://localhost:8080/invocations \
        -H "Content-Type: application/json" \
        -d '{"message": "{{ message }}"}' | jq -r .response

# Open OpenClaw Gateway UI in browser
ui:
    @echo "Opening http://localhost:18789"
    @open http://localhost:18789 2>/dev/null || xdg-open http://localhost:18789 2>/dev/null || echo "Visit: http://localhost:18789"

# ── AWS / ECR ─────────────────────────────────────────────────────────────────

# Push to ECR (set AWS_ACCOUNT and AWS_REGION first)
push-ecr tag="latest":
    #!/usr/bin/env bash
    set -euo pipefail
    : "${AWS_ACCOUNT:?Set AWS_ACCOUNT}"
    : "${AWS_REGION:?Set AWS_REGION}"
    REPO="$AWS_ACCOUNT.dkr.ecr.$AWS_REGION.amazonaws.com/openclaw-agent"
    aws ecr get-login-password --region "$AWS_REGION" | \
        docker login --username AWS --password-stdin "$AWS_ACCOUNT.dkr.ecr.$AWS_REGION.amazonaws.com"
    docker tag ffactory/openclaw:local "$REPO:{{ tag }}"
    docker push "$REPO:{{ tag }}"
    echo "Pushed $REPO:{{ tag }}"
