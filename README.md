# OpenClaw Agent Container for Amazon Bedrock AgentCore

[![CI](https://github.com/Walsen/openclaw/actions/workflows/ci.yml/badge.svg)](https://github.com/Walsen/openclaw/actions/workflows/ci.yml)
[![Docker Hub](https://img.shields.io/docker/v/ffactory/openclaw?label=Docker%20Hub)](https://hub.docker.com/r/ffactory/openclaw)

Docker image that runs [OpenClaw](https://openclaw.ai) inside an [Amazon Bedrock AgentCore Runtime](https://docs.aws.amazon.com/bedrock-agentcore/latest/devguide/what-is-bedrock-agentcore.html) microVM.

Based on [aws-samples/sample-OpenClaw-on-AWS-with-Bedrock/enterprise/agent-container](https://github.com/aws-samples/sample-OpenClaw-on-AWS-with-Bedrock/tree/main/enterprise/agent-container), updated to latest dependencies and extended with local development support.

## What This Repo Does

This repo builds **only the Docker image**. The container:

- Runs OpenClaw inside an AgentCore Firecracker microVM (ARM64)
- Implements the AgentCore HTTP contract on port 8080 (`/ping`, `/invocations`)
- Manages per-tenant workspace assembly — 3-layer SOUL merge (Global → Position → Personal)
- Handles S3 workspace sync, skill loading, permission enforcement, and Bedrock Guardrails
- Calls Amazon Bedrock for LLM inference via ConverseStream API

For the full infrastructure (CDK stacks, Router Lambda, DynamoDB, etc.) see:
- [sample-host-openclaw-on-amazon-bedrock-agentcore](https://github.com/aws-samples/sample-host-openclaw-on-amazon-bedrock-agentcore) — CDK + AgentCore Starter Toolkit deployment
- [sample-OpenClaw-on-AWS-with-Bedrock](https://github.com/aws-samples/sample-OpenClaw-on-AWS-with-Bedrock) — Full enterprise platform

## Dependency Versions

| Dependency | Original | This Repo |
|---|---|---|
| Python | 3.12-slim | 3.13-slim |
| Node.js | 22.x | 24.x LTS |
| Package manager | npm | pnpm |
| OpenClaw | 2026.3.24 (pinned) | `2026.6.33` (pinned) |
| Bedrock provider plugin | n/a (was built in) | `@openclaw/amazon-bedrock-provider@2026.6.33` |
| ClawHub | `@latest` | `0.23.1` (pinned) |
| gogcli | n/a | `0.34.1` |
| AWS CLI | v1 (pip) | v2 (official installer) |
| boto3 | >=1.34.0 | >=1.38.0 |
| requests | >=2.31.0 | >=2.32.0 |

> **OpenClaw and the Bedrock provider plugin must be bumped together.** From
> `2026.6.x` the Bedrock provider is a separate package and openclaw core carries
> no AWS SDK, so upgrading openclaw alone leaves the agent unable to reach a model.
> Both versions are `Dockerfile` build args; the build fails if the plugin does not
> register. See [docs/SKILLS.md](docs/SKILLS.md).

---

## Quick Start — Local Development

Run the full agent locally against real Bedrock. No LocalStack, no mocks.

**Prerequisites:** AWS credentials in `~/.aws` with Bedrock model access enabled.

```bash
# Enter the dev environment (installs all tools via Nix)
devbox shell

# Start the container
just up
```

Or without devbox:

```bash
docker compose up
```

**Test it:**

```bash
# Health check
curl http://localhost:8080/ping

# Chat
curl -s -X POST http://localhost:8080/invocations \
  -H "Content-Type: application/json" \
  -d '{"message": "What is the capital of France?"}' | jq -r .response
```

**OpenClaw Gateway UI** — open `http://localhost:18789` for the full web interface.

### What LOCAL_DEV mode does

`docker-compose.yml` sets `LOCAL_DEV=true`, which:

- Skips all S3 / DynamoDB / SSM calls
- Grants full tool access: `shell`, `file`, `code_execution`, `web_search`, `browser`
- Uses a named Docker volume for persistent SQLite memory across restarts
- Writes a minimal `SOUL.md` on first start

**Reset memory:**
```bash
just reset-memory
# or: docker compose down -v
```

### Configuration

Copy `local.env.example` to `local.env` to override defaults:

```bash
cp local.env.example local.env
# edit AWS_REGION, AWS_PROFILE, BEDROCK_MODEL_ID, SESSION_ID
docker compose --env-file local.env up
```

---

## Dev Environment (devbox)

This repo uses [devbox](https://www.jetify.com/devbox) for a reproducible dev environment. All tools are pinned via Nix — no system installs needed.

```bash
# Install devbox (one-time)
curl -fsSL https://get.jetify.com/devbox | bash

# Enter the environment
devbox shell
```

Tools provided:

| Tool | Purpose |
|---|---|
| `python` 3.14 | Runtime for server.py and scripts |
| `uv` | Fast Python package manager |
| `ruff` | Linter and formatter |
| `nodejs_24` | Required by OpenClaw |
| `pnpm` | Node package manager |
| `shellcheck` | Shell script linter |
| `just` | Task runner |
| `docker` | Container builds |
| `awscli2` | AWS CLI for ECR push and local testing |
| `jq` / `yq` | JSON/YAML processing |

### direnv integration

If you have [direnv](https://direnv.net) installed, the `.envrc` file activates the devbox environment automatically when you `cd` into the repo:

```bash
direnv allow
```

---

## Task Runner (just)

```bash
just --list        # show all recipes
just up            # start local dev container
just down          # stop container
just logs          # tail container logs
just reset-memory  # wipe conversation history
just build         # build ARM64 image locally
just lint          # ruff + shellcheck
just fmt           # auto-format Python
just compile       # syntax-check all .py files
just test          # run pytest
just check         # full pre-commit check
just ping          # health check running container
just chat "hello"  # send a message
just ui            # open Gateway UI in browser
just push-ecr      # push to ECR (needs AWS_ACCOUNT + AWS_REGION)
```

---

## Building the Image

```bash
# Build for ARM64 (required by AgentCore Runtime)
docker build --platform linux/arm64 -t ffactory/openclaw:latest .

# Custom pre-installed skills — always scoped AND version-pinned
docker build --platform linux/arm64 \
  --build-arg SKILLS_PREINSTALL="@parags/deep-research-pro@1.0.2" \
  -t ffactory/openclaw:latest .
```

### Build arguments

| ARG | Default | Description |
|---|---|---|
| `TARGETARCH` | injected by BuildKit | Target architecture — do not give this a default |
| `OPENCLAW_VERSION` | `2026.6.33` | Must match `BEDROCK_PROVIDER_VERSION` |
| `BEDROCK_PROVIDER_VERSION` | `2026.6.33` | `@openclaw/amazon-bedrock-provider`; peer-depends on openclaw |
| `GOGCLI_VERSION` | `0.34.1` | Google Workspace CLI binary |
| `SKILLS_PREINSTALL` | see [docs/SKILLS.md](docs/SKILLS.md) | Scoped, version-pinned ClawHub skills |
| `SKILLS_STRICT` | `1` | Fail the build if a requested skill is missing |

**What the agent can do, and how to drive it** — what each baked skill and plugin
does, how to add or remove them, how to vet a new one, and how to install a paid
Jina Reader API key: **[docs/SKILLS.md](docs/SKILLS.md)**.

---

## Workspace files: generated vs persisted

The workspace mixes two kinds of file, and confusing them is the usual cause of
"the agent forgot what I told it".

**Generated on every session start** by `workspace_assembler.py`, from S3 and
DynamoDB. Edits to these are discarded, and they are excluded from the S3 sync
because re-uploading a derived file would be pointless churn:

| File | Built from |
|---|---|
| `SOUL.md` | `_shared/soul/global/` + `_shared/soul/positions/<pos>/` + `PERSONAL_SOUL.md`, plus the runtime context block |
| `AGENTS.md` | global + position `AGENTS.md` |
| `TOOLS.md` | global `TOOLS.md` |
| `IDENTITY.md` | the employee's DynamoDB `EMP#` record |
| `SESSION_CONTEXT.md` | session type (employee / playground / twin / admin) |
| `CHANNELS.md` | the employee's IM channel pairings |
| `knowledge/` | assigned knowledge bases (`CONFIG#kb-assignments`) |

**Persisted to S3** — the real state, synced by the watchdog and on shutdown:

| Path | Purpose |
|---|---|
| `PERSONAL_SOUL.md` | **the personal layer** — the writable source of the agent's standing instructions |
| `MEMORY.md`, `memory/` | long-term memory |
| `.learnings/` | self-improvement log (see [docs/SKILLS.md](docs/SKILLS.md)) |
| `output/` | files produced for the employee |

So to change an agent's standing behaviour durably, edit **`PERSONAL_SOUL.md`**,
not `SOUL.md`. The agent is now told this explicitly in its context block; before
that it would edit `SOUL.md`, watch the change take effect for the rest of the
session, and lose it at the next start with no error logged anywhere.

Company-wide and per-position instructions are deliberately not writable from the
container: they live in S3 under `_shared/soul/` and are managed through the Admin
Console.

### Push to ECR

```bash
export AWS_ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
export AWS_REGION=us-west-2
just push-ecr
```

---

## Project Structure

```
├── Dockerfile                  # Multi-stage ARM64 build (builder → runtime)
├── entrypoint.sh               # Startup: Gateway → server.py → S3 sync → watchdog
├── server.py                   # AgentCore HTTP contract (/ping, /invocations)
├── openclaw.json               # OpenClaw config template (env var substitution)
├── requirements.txt            # Python runtime deps
├── permissions.py              # Per-tenant tool allowlists (DynamoDB / LOCAL_DEV)
├── identity.py                 # In-memory approval token store
├── memory.py                   # AgentCore Memory cloud persistence
├── observability.py            # Structured CloudWatch logging
├── safety.py                   # Prompt injection defense + input validation
├── skill_loader.py             # 3-layer skill loading (image / S3 / bundles)
├── workspace_assembler.py      # 3-layer SOUL merge (Global / Position / Personal)
├── auth-agent/
│   ├── __init__.py
│   └── permission_request.py   # PermissionRequest dataclass
├── docker-compose.yml          # Local dev setup (LOCAL_DEV=true)
├── local.env.example           # Local config template
├── Justfile                    # Task runner recipes
├── devbox.json                 # Reproducible dev environment (Nix)
├── pyproject.toml              # Python project config (ruff, pytest, uv)
├── ruff.toml                   # Linter config
└── scripts/
    └── pre-commit.sh           # Git pre-commit hook
```

---

## Environment Variables

### Runtime (AgentCore / CDK)

| Variable | Default | Description |
|---|---|---|
| `SESSION_ID` | `unknown` | Tenant / session identifier |
| `S3_BUCKET` | **required** (no default) | Workspace S3 bucket, e.g. `openclaw-workspaces-<account>-<region>`. Startup fails with exit 78 if unset, unless `LOCAL_DEV=true` |
| `STACK_NAME` | `dev` | CloudFormation stack name |
| `AWS_REGION` | `us-east-1` | AWS region |
| `BEDROCK_MODEL_ID` | `global.anthropic.claude-sonnet-4-6` | Bedrock model ID |
| `GUARDRAIL_ID` | (empty) | Bedrock Guardrail ID — omit to disable |
| `GUARDRAIL_VERSION` | `DRAFT` | Guardrail version |
| `DYNAMODB_TABLE` | (from STACK_NAME) | DynamoDB table name |
| `PORT` | `8080` | HTTP server port |

### Local development

| Variable | Default | Description |
|---|---|---|
| `LOCAL_DEV` | `false` | Set `true` to skip all S3/DynamoDB/SSM and grant full tool access |
| `AWS_PROFILE` | `default` | AWS credentials profile |

---

## Tool Capabilities & Permissions

Each tenant gets a per-tenant tool allowlist. In production the allowlist comes
from DynamoDB (resolved by `permissions.py`); in `LOCAL_DEV` mode it's the full
local profile. `server.py` and the prompt builders use the allowlist to scope
what the agent may do and to compute the blocked-tool list.

| Capability | What it grants |
|---|---|
| `web_search` | Web search |
| `shell` | Arbitrary shell command execution |
| `gog` | Google Workspace (Gmail / Drive / Calendar) via the `gog` CLI — **without** general `shell` |
| `browser` | Headless browser automation |
| `file` / `file_write` | Read / write files in the workspace |
| `code_execution` | Run code |

`load_extension` and `eval` are **always blocked**, regardless of allowlist.

### Google Workspace (`gog`)

The `gog` capability lets a tenant run Gmail, Drive, and Calendar actions —
reading mail, saving files to Drive, moving or trashing email, managing calendar
events — through the `gog` CLI. It is gated as its own capability (separate from
`shell`) so a tenant can be granted Workspace access **without** being able to run
arbitrary commands (least privilege).

- **Grant it** by adding `"gog"` to a position's `toolAllowlist` in the DynamoDB
  app table (e.g. `toolAllowlist: ["web_search", "gog"]`).
- **Credentials** (`GOG_*` env, including `GOG_KEYRING_PASSWORD`, and the OAuth
  refresh tokens) are injected into the runtime by the infra repo's
  `scripts/cli.py`, not baked into this image. Multiple Google accounts are
  supported; the agent picks the default unless another is named.
- **OAuth setup and account management** (consent flow, scopes, adding accounts)
  live in [`Walsen/openclaw-agentcore-crew`](https://github.com/Walsen/openclaw-agentcore-crew)
  — see its README "Google Workspace Integration" section.

When a tenant has `gog` but not `shell`, the system prompt scopes shell guidance
to `gog` commands only, advertises the available Gmail/Drive commands, and
requires confirmation before destructive actions (e.g. trashing email).

## CI/CD

**CI** (`.github/workflows/ci.yml`) — every push and PR:
1. Lint — ruff check + format, shellcheck, JSON validation
2. Test — `py_compile` on all Python files, pytest
3. Build — ARM64 Docker image (no push), GHA layer cache

**Publish** (`.github/workflows/publish.yml`) — PR merge to `main`:
- Builds and pushes to [`ffactory/openclaw`](https://hub.docker.com/r/ffactory/openclaw) on Docker Hub
- Tags: `latest`, short git SHA, date (`YYYYMMDD`)

Required repository secrets: `DOCKERHUB_USERNAME`, `DOCKERHUB_TOKEN`

---

## Git Hooks

Install the pre-commit hook to run lint + compile + tests before every commit:

```bash
just install-hooks
```

The hook runs: ruff lint → ruff format check → shellcheck → JSON validation → py_compile → pytest.

---

## License

MIT-0. See [LICENSE](LICENSE).
