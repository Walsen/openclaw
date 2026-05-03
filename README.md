# OpenClaw Agent Container for Amazon Bedrock AgentCore

Build the OpenClaw Docker image for deployment on [Amazon Bedrock AgentCore Runtime](https://docs.aws.amazon.com/bedrock/latest/userguide/agentcore.html).

Based on [aws-samples/sample-OpenClaw-on-AWS-with-Bedrock/enterprise/agent-container](https://github.com/aws-samples/sample-OpenClaw-on-AWS-with-Bedrock/tree/main/enterprise/agent-container), updated to use latest dependency versions.

## What This Repo Does

This repo contains **only** the Docker image build for the OpenClaw agent container. The container:

- Runs OpenClaw inside an AgentCore microVM (ARM64 Firecracker)
- Exposes an HTTP server on port 8080 implementing the AgentCore contract (`/ping`, `/invocations`)
- Manages per-tenant workspace assembly (3-layer SOUL merge: Global → Position → Personal)
- Handles S3 workspace sync, skill loading, permission enforcement, and guardrails
- Connects to Amazon Bedrock for LLM inference via ConverseStream API

For the full infrastructure (CDK stacks, Router Lambda, DynamoDB, etc.), see:
- [sample-host-openclaw-on-amazon-bedrock-agentcore](https://github.com/aws-samples/sample-host-openclaw-on-amazon-bedrock-agentcore) — CDK deployment with AgentCore Starter Toolkit
- [sample-OpenClaw-on-AWS-with-Bedrock](https://github.com/aws-samples/sample-OpenClaw-on-AWS-with-Bedrock) — Full enterprise platform

## Version Updates

| Dependency | Original | This Repo |
|---|---|---|
| Python | 3.12-slim | 3.13-slim |
| Node.js | 22.x | 24.x (LTS) |
| OpenClaw | 2026.3.24 (pinned) | latest (via pnpm) |
| ClawHub | latest | latest (via pnpm) |
| boto3 | >=1.34.0 | >=1.38.0 |
| requests | >=2.31.0 | >=2.32.0 |

> **Note:** The original repo pinned OpenClaw to `2026.3.24` due to a breaking change in `2026.3.28` affecting IM channel integration. The latest version (`2026.5.2`) may have resolved this. Test IM channels end-to-end after building.

## Prerequisites

- Docker with ARM64 support (Docker Desktop with buildx, or native ARM64 host)
- AWS CLI v2 configured
- An ECR repository to push the image to

## Build

```bash
# Build for ARM64 (required by AgentCore Runtime)
docker build --platform linux/arm64 -t openclaw-agent:latest .

# Tag and push to ECR
AWS_ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
AWS_REGION=us-west-2

aws ecr get-login-password --region $AWS_REGION | \
  docker login --username AWS --password-stdin \
  $AWS_ACCOUNT.dkr.ecr.$AWS_REGION.amazonaws.com

docker tag openclaw-agent:latest \
  $AWS_ACCOUNT.dkr.ecr.$AWS_REGION.amazonaws.com/openclaw-agent:latest

docker push \
  $AWS_ACCOUNT.dkr.ecr.$AWS_REGION.amazonaws.com/openclaw-agent:latest
```

## Build Arguments

| ARG | Default | Description |
|---|---|---|
| `TARGETARCH` | `arm64` | Target architecture |
| `SKILLS_PREINSTALL` | `deep-research-pro self-improving-agent jina-reader skill-vetter` | ClawHub skills to bake into the image |

```bash
# Custom skills
docker build --platform linux/arm64 \
  --build-arg SKILLS_PREINSTALL="deep-research-pro jina-reader" \
  -t openclaw-agent:latest .
```

## Project Structure

```
├── Dockerfile              # Multi-stage build (builder → runtime)
├── entrypoint.sh           # Container startup (Gateway, server.py, S3 sync)
├── server.py               # HTTP server implementing AgentCore contract
├── openclaw.json           # OpenClaw config template (env var substitution)
├── requirements.txt        # Python dependencies
├── permissions.py          # Per-tenant permission profiles (DynamoDB)
├── identity.py             # Approval token issuance/validation
├── memory.py               # AgentCore Memory persistence layer
├── observability.py        # Structured logging for CloudWatch
├── safety.py               # Input validation, prompt injection defense
├── skill_loader.py         # 3-layer skill loading (Docker/S3/bundles)
├── workspace_assembler.py  # 3-layer SOUL merge (Global/Position/Personal)
└── auth-agent/
    ├── __init__.py
    └── permission_request.py  # PermissionRequest dataclass
```

## Environment Variables

The container expects these environment variables at runtime (set by AgentCore/CDK):

| Variable | Default | Description |
|---|---|---|
| `SESSION_ID` | `unknown` | Tenant/session identifier |
| `S3_BUCKET` | `openclaw-tenants-000000000000` | Workspace S3 bucket |
| `STACK_NAME` | `dev` | CloudFormation stack name |
| `AWS_REGION` | `us-east-1` | AWS region |
| `BEDROCK_MODEL_ID` | `global.anthropic.claude-sonnet-4-6` | Bedrock model ID |
| `GUARDRAIL_ID` | (empty) | Bedrock Guardrail ID (optional) |
| `GUARDRAIL_VERSION` | `DRAFT` | Guardrail version |
| `DYNAMODB_TABLE` | (from STACK_NAME) | DynamoDB table name |
| `PORT` | `8080` | HTTP server port |

## License

MIT-0. See [LICENSE](LICENSE).

## Local Development

Run the container locally against real Bedrock — no LocalStack or mock services needed.

**Prerequisites:** AWS credentials with Bedrock access (`~/.aws/credentials`), and Bedrock model access enabled in your account.

```bash
# Copy and edit the env template (optional — defaults work for most setups)
cp local.env.example local.env

# Start
docker compose up

# Or with a specific model
BEDROCK_MODEL_ID=global.anthropic.claude-haiku-4-5-20251001-v1:0 docker compose up
```

**Test it:**

```bash
# Health check
curl http://localhost:8080/ping

# Send a message
curl -X POST http://localhost:8080/invocations \
  -H "Content-Type: application/json" \
  -d '{"message": "What is the capital of France?"}'
```

**OpenClaw Gateway UI** is available at `http://localhost:18789` — full web interface for chatting with the agent directly.

**What `LOCAL_DEV=true` does:**
- Skips all S3/DynamoDB/SSM calls
- Grants full tool access (shell, file, code_execution, web_search, browser)
- Uses a named Docker volume (`openclaw-workspace`) for persistent SQLite memory across restarts
- Writes a minimal `SOUL.md` on first start

**What still works:**
- Full OpenClaw agent loop via Bedrock ConverseStream
- All built-in tools and baked-in ClawHub skills
- Persistent conversation memory (Docker volume survives `docker compose down`)
- OpenClaw Gateway web UI on port 18789

**Reset memory:**
```bash
docker volume rm openclaw_openclaw-workspace
```



Two GitHub Actions workflows:

**CI** (`.github/workflows/ci.yml`) — runs on every push and PR:
- Lint: ruff check + format, shellcheck on entrypoint.sh, JSON validation
- Test: Python syntax compilation, pytest
- Build: ARM64 Docker image build (no push) with GHA cache

**Publish** (`.github/workflows/publish.yml`) — runs on PR merge to `main`:
- Builds and pushes to `ffactory/openclaw` on Docker Hub
- Tags: `latest`, git SHA, date (`YYYYMMDD`)

Required repository secrets:
- `DOCKERHUB_USERNAME` — Docker Hub username
- `DOCKERHUB_TOKEN` — Docker Hub access token
