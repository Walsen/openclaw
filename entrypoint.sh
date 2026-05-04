#!/bin/bash
# =============================================================================
# Agent Container Entrypoint
# Design: OpenClaw Gateway starts first (port 18789) for native session management.
# server.py starts immediately for health check. S3 workspace assembled on first request.
# openclaw agent CLI connects to Gateway → proper memory compaction and session state.
# =============================================================================
set -uo pipefail  # removed -e: server.py must start even if early commands fail

TENANT_ID="${SESSION_ID:-${sessionId:-unknown}}"
S3_BUCKET="${S3_BUCKET:-openclaw-tenants-000000000000}"
WORKSPACE="/root/.openclaw/workspace"
SYNC_INTERVAL="${SYNC_INTERVAL:-60}"
STACK_NAME="${STACK_NAME:-dev}"
AWS_REGION="${AWS_REGION:-us-east-1}"

# Extract base employee ID from Tenant Router's tenant_id format
# Format: channel__employee_id__hash (e.g., port__emp-w5__c60c15e6c2ed12bf585)
# We use the base employee ID for S3 workspace paths so data persists across sessions
BASE_TENANT_ID="$TENANT_ID"
if echo "$TENANT_ID" | grep -q '__'; then
    # Split by __ and take the middle segment (employee ID)
    BASE_TENANT_ID=$(echo "$TENANT_ID" | awk -F'__' '{print $2}')
    if [ -z "$BASE_TENANT_ID" ]; then
        BASE_TENANT_ID="$TENANT_ID"
    fi
fi
S3_BASE="s3://${S3_BUCKET}/${BASE_TENANT_ID}"

echo "[entrypoint] START tenant=${TENANT_ID} base=${BASE_TENANT_ID} bucket=${S3_BUCKET}"

# =============================================================================
# LOCAL_DEV mode: skip all S3/DynamoDB/SSM calls, use local workspace only
# =============================================================================
if [ "${LOCAL_DEV:-}" = "true" ]; then
    echo "[entrypoint] LOCAL_DEV mode — skipping S3/DynamoDB/SSM, using local workspace"
    mkdir -p "$WORKSPACE" "$WORKSPACE/memory" "$WORKSPACE/skills" "$WORKSPACE/output"
    ln -sfn "$WORKSPACE" /tmp/workspace
    echo "${TENANT_ID}" > /tmp/tenant_id
    echo "${BASE_TENANT_ID}" > /tmp/base_tenant_id

    # Write openclaw.json
    OPENCLAW_CONFIG_DIR="$HOME/.openclaw"
    mkdir -p "$OPENCLAW_CONFIG_DIR"
    sed -e "s|\${AWS_REGION}|${AWS_REGION}|g" \
        -e "s|\${BEDROCK_MODEL_ID}|${BEDROCK_MODEL_ID:-global.anthropic.claude-sonnet-4-6}|g" \
        /app/openclaw.json > "$OPENCLAW_CONFIG_DIR/openclaw.json"

    # Write a minimal SOUL.md so OpenClaw has an identity
    if [ ! -f "$WORKSPACE/SOUL.md" ]; then
        cat > "$WORKSPACE/SOUL.md" <<'EOF'
# Local Dev Agent

You are a helpful AI assistant running locally via OpenClaw on Amazon Bedrock.
You have access to web search, file operations, shell, and code execution tools.
EOF
    fi

    export NODE_COMPILE_CACHE=/app/.compile-cache
    export NODE_OPTIONS="${NODE_OPTIONS:+$NODE_OPTIONS }--dns-result-order=ipv4first"
    export OPENCLAW_WORKSPACE="$WORKSPACE"
    export OPENCLAW_SKIP_ONBOARDING=1
    export OPENCLAW_SKIP_CRON=1

    openclaw gateway --port 18789 > /tmp/openclaw-gateway.log 2>&1 &
    GATEWAY_PID=$!
    echo "[entrypoint] Gateway PID=${GATEWAY_PID}"

    for i in $(seq 1 30); do
        if curl -sf --connect-timeout 1 http://127.0.0.1:18789/__openclaw/control-ui-config.json >/dev/null 2>&1; then
            echo "[entrypoint] Gateway ready (${i}s)"
            break
        fi
        sleep 1
    done

    python /app/server.py &
    SERVER_PID=$!
    echo "[entrypoint] server.py PID=${SERVER_PID}"

    trap 'kill "$GATEWAY_PID" "$SERVER_PID" 2>/dev/null; wait "$SERVER_PID" 2>/dev/null; echo "[entrypoint] LOCAL_DEV shutdown complete"; exit 0' SIGTERM SIGINT
    wait "$SERVER_PID" || true
    exit 0
fi

# =============================================================================
# Step 0: Node.js runtime optimizations (before any openclaw invocation)
# =============================================================================

# V8 Compile Cache (Node.js 22+) — pre-warmed at Docker build time
if [ -d /app/.compile-cache ]; then
    export NODE_COMPILE_CACHE=/app/.compile-cache
    echo "[entrypoint] V8 compile cache enabled"
fi

# Force IPv4 for Node.js VPC compatibility
# Node.js 22+ Happy Eyeballs tries IPv6 first, times out in VPC without IPv6
export NODE_OPTIONS="${NODE_OPTIONS:+$NODE_OPTIONS }--dns-result-order=ipv4first"

# EFS workspace detection:
# If EFS is mounted at /mnt/efs (EFS_ENABLED env var set by task definition),
# use /mnt/efs/{BASE_TENANT_ID}/workspace/ as the persistent workspace.
# On first start (empty EFS dir), bootstrap from S3. No watchdog needed.
EFS_MODE=false
if [ "${EFS_ENABLED:-}" = "true" ] && [ -d "/mnt/efs" ]; then
    EFS_WORKSPACE="/mnt/efs/${BASE_TENANT_ID}/workspace"
    mkdir -p "$EFS_WORKSPACE" "$EFS_WORKSPACE/memory" "$EFS_WORKSPACE/skills"
    WORKSPACE="$EFS_WORKSPACE"
    export OPENCLAW_WORKSPACE="$WORKSPACE"
    EFS_MODE=true
    echo "[entrypoint] EFS mode: workspace=${WORKSPACE}"

    # Bootstrap from S3 if this employee's EFS directory is empty (first start)
    if [ -z "$(ls -A "$EFS_WORKSPACE" 2>/dev/null)" ]; then
        echo "[entrypoint] EFS workspace empty — bootstrapping from S3..."
        aws s3 sync "${S3_BASE}/workspace/" "$EFS_WORKSPACE/" \
            --quiet --region "$AWS_REGION" 2>/dev/null || true
        echo "[entrypoint] EFS bootstrap complete"
    fi
else
    # Standard mode: use default workspace path, watchdog will sync to S3
    mkdir -p "$WORKSPACE" "$WORKSPACE/memory" "$WORKSPACE/skills"
fi

# Clean output/ directory on every cold start.
rm -rf "$WORKSPACE/output" 2>/dev/null
mkdir -p "$WORKSPACE/output"

# Symlink for backward compat (skill_loader, watchdog sync)
ln -sfn "$WORKSPACE" /tmp/workspace
echo "$TENANT_ID" > /tmp/tenant_id
echo "$BASE_TENANT_ID" > /tmp/base_tenant_id

# =============================================================================
# Step 0.5: Write openclaw.json config (substitute env vars)
# =============================================================================
OPENCLAW_CONFIG_DIR="$HOME/.openclaw"
mkdir -p "$OPENCLAW_CONFIG_DIR"

# Generate a random gateway token for this container instance
GATEWAY_TOKEN=$(head -c 24 /dev/urandom | od -An -tx1 | tr -d ' \n')
export OPENCLAW_GATEWAY_TOKEN="$GATEWAY_TOKEN"

sed -e "s|\${AWS_REGION}|${AWS_REGION}|g" \
    -e "s|\${BEDROCK_MODEL_ID}|${BEDROCK_MODEL_ID:-global.anthropic.claude-sonnet-4-6}|g" \
    /app/openclaw.json > "$OPENCLAW_CONFIG_DIR/openclaw.json"
echo "[entrypoint] openclaw.json written to $OPENCLAW_CONFIG_DIR/openclaw.json"

# Store gateway token in SSM so admin console proxy can authenticate
if [ -n "${SHARED_AGENT_ID:-}" ]; then
    aws ssm put-parameter \
        --name "/openclaw/${STACK_NAME}/always-on/${SHARED_AGENT_ID}/gateway-token" \
        --value "$GATEWAY_TOKEN" --type "SecureString" --overwrite \
        --region "$AWS_REGION" 2>/dev/null \
        && echo "[entrypoint] Gateway token stored in SSM for ${SHARED_AGENT_ID}" \
        || echo "[entrypoint] WARNING: Gateway token SSM write failed"
fi

# =============================================================================
# Step 0.55: Synchronous workspace assembly for always-on containers
# =============================================================================
if [ "$EFS_MODE" = "true" ] || [ -n "${SHARED_AGENT_ID:-}" ]; then
    aws s3 sync "${S3_BASE}/workspace/" "$WORKSPACE/" \
        --quiet --region "$AWS_REGION" 2>/dev/null || true
    if [ -f "/app/workspace_assembler.py" ] && [ "$BASE_TENANT_ID" != "unknown" ]; then
        timeout 25 python3 /app/workspace_assembler.py \
            --tenant "$TENANT_ID" \
            --workspace "$WORKSPACE" \
            --bucket "$S3_BUCKET" \
            --stack "$STACK_NAME" \
            --region "$AWS_REGION" 2>&1 | head -5 \
            && echo "[entrypoint] Pre-Gateway workspace assembly complete" \
            || echo "[entrypoint] Pre-Gateway assembly timed out (non-fatal)"
    fi
fi

# =============================================================================
# Step 0.6: Inject IM bot tokens into openclaw.json (for always-on direct IM)
# =============================================================================
if [ -n "${TELEGRAM_BOT_TOKEN:-}" ] || [ -n "${DISCORD_BOT_TOKEN:-}" ]; then
    python3 -c "
import json, os, sys

config_path = os.path.expanduser('~/.openclaw/openclaw.json')
with open(config_path) as f:
    c = json.load(f)

c.setdefault('channels', {})

tg_token = os.environ.get('TELEGRAM_BOT_TOKEN', '')
if tg_token:
    c['channels'].setdefault('telegram', {})
    c['channels']['telegram']['botToken'] = tg_token
    c['channels']['telegram'].setdefault('accounts', {}).setdefault('default', {})['botToken'] = tg_token
    print('[entrypoint] Telegram bot token injected')

dc_token = os.environ.get('DISCORD_BOT_TOKEN', '')
if dc_token:
    c['channels'].setdefault('discord', {})
    c['channels']['discord']['token'] = dc_token
    print('[entrypoint] Discord bot token injected')

with open(config_path, 'w') as f:
    json.dump(c, f, indent=2)
" 2>&1 || echo "[entrypoint] Bot token injection failed (non-fatal)"
fi

# =============================================================================
# Step 0.6.1: Auto-connect IM channels from DynamoDB credentials (Fargate)
# =============================================================================
if [ "$EFS_MODE" = "true" ] && [ "$BASE_TENANT_ID" != "unknown" ]; then
    python3 -c "
import json, os, subprocess, sys
try:
    import boto3
    ddb_region = os.environ.get('DYNAMODB_REGION', os.environ.get('AWS_REGION', 'us-east-1'))
    ddb_table = os.environ.get('DYNAMODB_TABLE', os.environ.get('STACK_NAME', 'openclaw'))
    emp_id = '$BASE_TENANT_ID'
    ddb = boto3.resource('dynamodb', region_name=ddb_region)
    table = ddb.Table(ddb_table)
    resp = table.get_item(Key={'PK': 'ORG#acme', 'SK': f'EMP#{emp_id}'})
    creds = resp.get('Item', {}).get('imCredentials', {})
    if not creds:
        print('[entrypoint] No IM credentials in DynamoDB for ' + emp_id)
        sys.exit(0)
    openclaw = '/usr/local/bin/openclaw'
    env = os.environ.copy()
    env['HOME'] = os.environ.get('HOME', '/root')
    env['PATH'] = '/usr/local/bin:/usr/bin:/bin:' + env.get('PATH', '')
    for channel, data in creds.items():
        if not data or not isinstance(data, dict):
            continue
        cmd = [openclaw, 'channels', 'add', '--channel', channel]
        for k, v in data.items():
            if k in ('connectedAt',):
                continue
            flag = '--' + k.replace('_', '-')
            if k == 'appId': flag = '--app-id'
            elif k == 'appSecret': flag = '--app-secret'
            elif k == 'botToken': flag = '--bot-token'
            elif k == 'appToken': flag = '--app-token'
            cmd.extend([flag, str(v)])
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=15, env=env)
        if r.returncode == 0:
            print(f'[entrypoint] IM auto-connect: {channel} OK')
        else:
            print(f'[entrypoint] IM auto-connect: {channel} FAILED ({r.stderr[:100]})')
except Exception as e:
    print(f'[entrypoint] IM auto-connect failed (non-fatal): {e}')
" 2>&1
fi

# =============================================================================
# Step 1: Start server.py IMMEDIATELY — health check must respond in seconds
# AgentCore health-checks /ping right after container start. server.py must be
# up before the Gateway wait loop, not after.
# =============================================================================
export OPENCLAW_WORKSPACE="$WORKSPACE"
export OPENCLAW_SKIP_ONBOARDING=1
export OPENCLAW_SKIP_CRON=1  # Disable built-in cron — EventBridge handles scheduling

# Pre-inject AWS credentials so the Node.js openclaw CLI can find them.
# The CLI doesn't reliably pick up IAM role credentials from the container
# environment (AWS_CONTAINER_CREDENTIALS_RELATIVE_URI). We resolve them via
# Python/boto3 and export as explicit env vars that Node.js AWS SDK always reads.
python3 -c "
import boto3, os, sys
try:
    creds = boto3.Session().get_credentials()
    if creds:
        frozen = creds.get_frozen_credentials()
        print(f'export AWS_ACCESS_KEY_ID={frozen.access_key}')
        print(f'export AWS_SECRET_ACCESS_KEY={frozen.secret_key}')
        if frozen.token:
            print(f'export AWS_SESSION_TOKEN={frozen.token}')
        print(f'export AWS_DEFAULT_REGION={os.environ.get(\"AWS_REGION\", \"us-east-1\")}')
        sys.stderr.write(\"[entrypoint] AWS credentials pre-injected for Node.js\n\")
except Exception as e:
    sys.stderr.write(f'[entrypoint] WARNING: Could not pre-inject credentials: {e}\n')
" > /tmp/aws_creds.sh 2>&1 || true
# shellcheck source=/dev/null
[ -f /tmp/aws_creds.sh ] && . /tmp/aws_creds.sh || true

python /app/server.py &
SERVER_PID=$!
echo "[entrypoint] server.py PID=${SERVER_PID}"

# Wait briefly for server.py to bind to port 8080
for i in $(seq 1 10); do
    if curl -sf --connect-timeout 1 http://127.0.0.1:8080/ping >/dev/null 2>&1; then
        echo "[entrypoint] server.py ready on port 8080 (${i}s)"
        break
    fi
    sleep 1
done

# =============================================================================
# Step 0.7: Start OpenClaw Gateway — native session management + memory
# (started AFTER server.py so health check passes immediately)
# =============================================================================
openclaw gateway --port 18789 > /tmp/openclaw-gateway.log 2>&1 &
GATEWAY_PID=$!
echo "[entrypoint] OpenClaw Gateway PID=${GATEWAY_PID}"

# Wait for Gateway to start
if [ "$EFS_MODE" = "true" ]; then
    GATEWAY_WAIT=5
    echo "[entrypoint] Fargate mode: waiting ${GATEWAY_WAIT}s for Gateway (non-blocking)"
else
    GATEWAY_WAIT=30
    echo "[entrypoint] AgentCore mode: waiting ${GATEWAY_WAIT}s for Gateway"
fi

GATEWAY_READY=false
for i in $(seq 1 $GATEWAY_WAIT); do
    if curl -sf --connect-timeout 1 http://127.0.0.1:18789/__openclaw/control-ui-config.json >/dev/null 2>&1; then
        echo "[entrypoint] Gateway ready on port 18789 (${i}s)"
        GATEWAY_READY=true
        break
    fi
    sleep 1
done
if [ "$GATEWAY_READY" = "false" ]; then
    if [ "$EFS_MODE" = "true" ]; then
        echo "[entrypoint] Gateway still starting (Fargate: will be ready for next request)"
    else
        echo "[entrypoint] WARNING: Gateway not ready after ${GATEWAY_WAIT}s (tools may be unavailable)"
    fi
fi

# Auto-pair Control UI and store dashboard URL token in SSM
_AGENT_SSM_ID="${SHARED_AGENT_ID:-}"
if [ -z "$_AGENT_SSM_ID" ] && [ "$EFS_MODE" = "true" ]; then
    _AGENT_SSM_ID=$(echo "$TENANT_ID" | sed -n 's/personal__//p')
    if [ -n "$_AGENT_SSM_ID" ]; then
        _LOOKED_UP=$(aws ssm get-parameter --name "/openclaw/${STACK_NAME}/tenants/${_AGENT_SSM_ID}/always-on-agent" \
            --query Parameter.Value --output text --region "$AWS_REGION" 2>/dev/null || true)
        [ -n "$_LOOKED_UP" ] && _AGENT_SSM_ID="$_LOOKED_UP"
    fi
fi
if [ "$GATEWAY_READY" = "true" ] && [ -n "$_AGENT_SSM_ID" ]; then
    DASHBOARD_OUTPUT=$(timeout 10 openclaw dashboard --no-open 2>&1 || true)
    DASHBOARD_TOKEN=$(echo "$DASHBOARD_OUTPUT" | sed -n 's/.*#token=\([a-f0-9]*\).*/\1/p' | head -1)
    if [ -n "$DASHBOARD_TOKEN" ]; then
        aws ssm put-parameter \
            --name "/openclaw/${STACK_NAME}/always-on/${_AGENT_SSM_ID}/dashboard-token" \
            --value "$DASHBOARD_TOKEN" --type "String" --overwrite \
            --region "$AWS_REGION" 2>/dev/null \
            && echo "[entrypoint] Dashboard pairing token stored in SSM" \
            || echo "[entrypoint] WARNING: Dashboard token SSM write failed"
    else
        echo "[entrypoint] No dashboard token extracted (non-fatal)"
    fi
fi

# (server.py already started above before Gateway wait)

# =============================================================================
# Step 2: S3 sync in background (non-blocking)
# =============================================================================
(
    echo "[bg] Pulling workspace from S3..."
    aws s3 sync "${S3_BASE}/workspace/" "$WORKSPACE/" --exclude "output/*" --quiet 2>/dev/null || true

    if [ -n "${SHARED_AGENT_ID:-}" ]; then
        echo "$SHARED_AGENT_ID" > "$WORKSPACE/.shared_agent"
        echo "[bg] Shared agent detected: $SHARED_AGENT_ID"
    fi

    TENANT_POSITION=""

    # Initialize SOUL.md for new tenants
    if [ ! -f "$WORKSPACE/SOUL.md" ]; then
        aws s3 cp "s3://${S3_BUCKET}/_shared/templates/default.md" "$WORKSPACE/SOUL.md" \
            --quiet 2>/dev/null || echo "You are a helpful AI assistant." > "$WORKSPACE/SOUL.md"
    fi

    # Workspace Assembler: Merge three-layer SOUL (Global + Position + Personal)
    if [ "$TENANT_ID" != "unknown" ]; then
        echo "[bg] Assembling three-layer workspace..."
        python /app/workspace_assembler.py \
            --tenant "$TENANT_ID" \
            --workspace "$WORKSPACE" \
            --bucket "$S3_BUCKET" \
            --stack "$STACK_NAME" \
            --region "$AWS_REGION" \
            --position "${TENANT_POSITION:-}" 2>&1 || echo "[bg] workspace_assembler.py failed (non-fatal)"
    else
        echo "[bg] Skipping workspace assembly (tenant=unknown, will assemble on first request)"
    fi

    # Skill Loader: Layer 2 (S3 hot-load) + Layer 3 (pre-built bundles)
    echo "[bg] Loading enterprise skills..."
    python /app/skill_loader.py \
        --tenant "$TENANT_ID" \
        --workspace "$WORKSPACE" \
        --bucket "$S3_BUCKET" \
        --stack "$STACK_NAME" \
        --region "$AWS_REGION" 2>&1 || echo "[bg] skill_loader.py failed (non-fatal)"

    if [ -f /tmp/skill_env.sh ]; then
        # shellcheck source=/dev/null
        . /tmp/skill_env.sh
        echo "[bg] Skill API keys loaded"
    fi

    echo "[bg] Workspace + skills ready"
    echo "WORKSPACE_READY" > /tmp/workspace_status

    # Watchdog: sync workspace back to S3
    if [ "$EFS_MODE" = "true" ]; then
        echo "[watchdog] EFS mode active — skipping S3 sync loop"
        while true; do sleep 3600; done
    else
        while true; do
            sleep "$SYNC_INTERVAL"
            CURRENT_BASE=$(cat /tmp/base_tenant_id 2>/dev/null || echo "$BASE_TENANT_ID")
            if [ "$CURRENT_BASE" != "unknown" ] && [ -n "$CURRENT_BASE" ]; then
                SYNC_TARGET="s3://${S3_BUCKET}/${CURRENT_BASE}/workspace/"
                if aws s3 sync "$WORKSPACE/" "$SYNC_TARGET" \
                    --exclude "node_modules/*" --exclude "skills/_shared/*" --exclude "skills/*" \
                    --exclude "SOUL.md" --exclude "AGENTS.md" --exclude "TOOLS.md" \
                    --exclude "IDENTITY.md" --exclude "SESSION_CONTEXT.md" --exclude "CHANNELS.md" \
                    --exclude ".personal_soul_backup.md" \
                    --exclude "knowledge/*" \
                    --size-only --region "$AWS_REGION" \
                    --quiet 2>/dev/null; then
                    echo "[watchdog] Synced to ${SYNC_TARGET}"
                fi
            fi
            if [ -f "$WORKSPACE/.shared_agent" ]; then
                SHARED_ID=$(cat "$WORKSPACE/.shared_agent")
                aws s3 sync "$WORKSPACE/memory/" "s3://${S3_BUCKET}/_shared/memory/${SHARED_ID}/" \
                    --quiet 2>/dev/null || true
                aws s3 cp "$WORKSPACE/MEMORY.md" "s3://${S3_BUCKET}/_shared/memory/${SHARED_ID}/MEMORY.md" \
                    --quiet 2>/dev/null || true
            fi
        done
    fi
) &
BG_PID=$!
echo "[entrypoint] Background sync PID=${BG_PID}"

# =============================================================================
# Step 3: Graceful shutdown
# =============================================================================
cleanup() {
    echo "[entrypoint] SIGTERM — flushing workspace"

    # Deregister SSM endpoint
    if [ -n "${SHARED_AGENT_ID:-}" ]; then
        aws ssm delete-parameter \
            --name "/openclaw/${STACK_NAME}/always-on/${SHARED_AGENT_ID}/endpoint" \
            --region "$AWS_REGION" 2>/dev/null || true
        echo "[entrypoint] SSM endpoint deregistered for ${SHARED_AGENT_ID}"
    fi
    if [ -n "${FARGATE_TIER:-}" ]; then
        aws ssm delete-parameter \
            --name "/openclaw/${STACK_NAME}/fargate/tier-${FARGATE_TIER}/endpoint" \
            --region "$AWS_REGION" 2>/dev/null || true
        echo "[entrypoint] Fargate tier endpoint deregistered: tier-${FARGATE_TIER}"
    fi

    # Stop server first — no new requests during shutdown
    kill "$SERVER_PID" 2>/dev/null || true

    # Signal Gateway to shut down gracefully and WAIT for memory write
    kill -SIGTERM "$GATEWAY_PID" 2>/dev/null || true
    for i in $(seq 1 15); do
        kill -0 "$GATEWAY_PID" 2>/dev/null || break
        sleep 1
    done
    kill -9 "$GATEWAY_PID" 2>/dev/null || true

    # Stop background watchdog
    kill "$BG_PID" 2>/dev/null || true
    wait "$SERVER_PID" 2>/dev/null || true

    # Persist workspace to S3
    FINAL_BASE=$(cat /tmp/base_tenant_id 2>/dev/null || echo "$BASE_TENANT_ID")
    if [ "$FINAL_BASE" != "unknown" ] && [ -n "$FINAL_BASE" ]; then
        SYNC_TARGET="s3://${S3_BUCKET}/${FINAL_BASE}/workspace/"

        if [ "$EFS_MODE" = "true" ]; then
            echo "[entrypoint] EFS → S3 cross-mode snapshot..."
            timeout 15 aws s3 sync "$WORKSPACE/memory/" "${SYNC_TARGET}memory/" \
                --region "$AWS_REGION" --quiet 2>/dev/null || true
            timeout 10 aws s3 cp "$WORKSPACE/MEMORY.md" "${SYNC_TARGET}MEMORY.md" \
                --region "$AWS_REGION" --quiet 2>/dev/null || true
            timeout 10 aws s3 cp "$WORKSPACE/HEARTBEAT.md" "${SYNC_TARGET}HEARTBEAT.md" \
                --region "$AWS_REGION" --quiet 2>/dev/null || true
        else
            aws s3 sync "$WORKSPACE/memory/" "${SYNC_TARGET}memory/" \
                --region "$AWS_REGION" --quiet 2>/dev/null || true
            aws s3 cp "$WORKSPACE/MEMORY.md" "${SYNC_TARGET}MEMORY.md" \
                --region "$AWS_REGION" --quiet 2>/dev/null || true
            aws s3 sync "$WORKSPACE/" "$SYNC_TARGET" \
                --exclude "node_modules/*" --exclude "skills/_shared/*" --exclude "skills/*" \
                --exclude "SOUL.md" --exclude "AGENTS.md" --exclude "TOOLS.md" \
                --exclude "IDENTITY.md" --exclude ".personal_soul_backup.md" \
                --exclude "knowledge/*" \
                --size-only --region "$AWS_REGION" \
                --quiet 2>/dev/null || true
        fi
        echo "[entrypoint] Workspace persisted to ${SYNC_TARGET}"
    fi
    echo "[entrypoint] Done"
    exit 0
}
trap cleanup SIGTERM SIGINT

# Register ECS Fargate task endpoint in SSM once server is healthy
if [ -n "${SHARED_AGENT_ID:-}" ] && [ -n "${ECS_CONTAINER_METADATA_URI_V4:-}" ]; then
(
    for i in $(seq 1 15); do
        if curl -sf "http://localhost:8080/ping" >/dev/null 2>&1; then break; fi
        sleep 1
    done
    TASK_IP=""
    for META_URL in "${ECS_CONTAINER_METADATA_URI_V4}/task" "${ECS_CONTAINER_METADATA_URI_V4}"; do
        TASK_IP=$(curl -sf "$META_URL" 2>/dev/null \
            | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    for c in data.get('Containers', [data]):
        for n in c.get('Networks', []):
            addrs = n.get('IPv4Addresses', [])
            if addrs:
                print(addrs[0])
                sys.exit(0)
    print('')
except Exception:
    print('')
" 2>/dev/null || echo "")
        if [ -n "$TASK_IP" ]; then break; fi
    done
    if [ -n "$TASK_IP" ]; then
        ENDPOINT="http://${TASK_IP}:8080"
        aws ssm put-parameter \
            --name "/openclaw/${STACK_NAME}/always-on/${SHARED_AGENT_ID}/endpoint" \
            --value "$ENDPOINT" --type "String" --overwrite \
            --region "$AWS_REGION" 2>/dev/null \
            && echo "[entrypoint] ECS endpoint registered: $ENDPOINT" \
            || echo "[entrypoint] WARNING: SSM endpoint registration failed"
        if [ -n "${FARGATE_TIER:-}" ]; then
            aws ssm put-parameter \
                --name "/openclaw/${STACK_NAME}/fargate/tier-${FARGATE_TIER}/endpoint" \
                --value "$ENDPOINT" --type "String" --overwrite \
                --region "$AWS_REGION" 2>/dev/null \
                && echo "[entrypoint] Fargate tier endpoint registered: tier-${FARGATE_TIER} → $ENDPOINT" \
                || echo "[entrypoint] WARNING: Fargate tier endpoint registration failed"
        fi
    else
        echo "[entrypoint] WARNING: Could not determine ECS task IP"
    fi
) &
fi

echo "[entrypoint] Waiting..."
wait "$SERVER_PID" || true
