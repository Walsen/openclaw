"""
Enterprise Skill Loader for OpenClaw Multi-Tenant Platform.

Loads skills from S3 based on tenant permissions and injects API keys
from SSM Parameter Store as environment variables.

Three-layer skill architecture (all zero-invasion to OpenClaw):
  Layer 1: Built-in skills (Docker image, always available)
  Layer 2: S3 hot-load skills (scripts, loaded at microVM startup)
  Layer 3: Pre-built skill bundles (tar.gz from S3, loaded at startup)

Usage:
  python skill_loader.py --tenant TENANT_ID --workspace /tmp/workspace \
    --bucket openclaw-tenants-xxx --stack openclaw-multitenancy --region us-east-1

Output:
  - Skills copied to {workspace}/skills/
  - /tmp/skill_env.sh with export KEY=VALUE lines for API key injection
"""

import argparse
import json
import logging
import os
import subprocess
import sys

import boto3
from botocore.exceptions import ClientError

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
logger = logging.getLogger(__name__)


def get_tenant_roles(stack_name, tenant_id, region=None):
    """Get tenant's roles from DynamoDB position/department data."""
    ddb_region = region or os.environ.get("DYNAMODB_REGION", os.environ.get("AWS_REGION", "us-east-1"))
    ddb_table = os.environ.get("DYNAMODB_TABLE", os.environ.get("STACK_NAME", "openclaw"))

    base_id = tenant_id
    parts = base_id.split("__")
    if len(parts) >= 2:
        base_id = parts[1]

    try:
        ddb = boto3.resource("dynamodb", region_name=ddb_region)
        table = ddb.Table(ddb_table)

        resp = table.get_item(Key={"PK": "ORG#acme", "SK": f"EMP#{base_id}"})
        emp = resp.get("Item", {})
        if not emp:
            logger.info("Employee %s not found, using default roles", base_id)
            return ["employee"]

        dept_name = emp.get("departmentName", "")
        role = emp.get("role", "employee")

        roles = [role, "employee"]
        if dept_name:
            dept_lower = dept_name.lower().replace(" & ", "_").replace(" ", "_")
            roles.append(dept_lower)
            DEPT_ALIASES = {
                "engineering": ["engineering", "devops", "qa"],
                "platform team": ["engineering", "devops"],
                "frontend team": ["engineering"],
                "backend team": ["engineering"],
                "qa team": ["engineering", "qa"],
                "enterprise sales": ["sales"],
                "smb sales": ["sales"],
                "customer success": ["csm"],
                "hr & admin": ["hr"],
                "legal & compliance": ["legal"],
                "product": ["product"],
                "finance": ["finance"],
            }
            for alias in DEPT_ALIASES.get(dept_name.lower(), []):
                if alias not in roles:
                    roles.append(alias)

        if role == "admin":
            roles.append("management")

        logger.info("Tenant %s (%s) roles: %s", base_id, dept_name, list(set(roles)))
        return list(set(roles))
    except Exception as e:
        logger.warning("DynamoDB role resolution failed: %s — using default", e)
        return ["employee"]


def load_skill_manifest(skill_dir):
    """Read skill.json manifest from a skill directory."""
    manifest_path = os.path.join(skill_dir, "skill.json")
    if not os.path.isfile(manifest_path):
        return None
    try:
        with open(manifest_path) as f:
            return json.load(f)
    except (json.JSONDecodeError, IOError) as e:
        logger.warning("Failed to read manifest %s: %s", manifest_path, e)
        return None


def is_skill_allowed(manifest, tenant_roles):
    """Check if a skill is allowed for the tenant based on role permissions."""
    if not manifest:
        return True

    permissions = manifest.get("permissions", {})
    allowed_roles = permissions.get("allowedRoles", ["*"])
    blocked_roles = permissions.get("blockedRoles", [])

    for role in tenant_roles:
        if role in blocked_roles:
            logger.info("Skill %s blocked for role %s", manifest.get("name"), role)
            return False

    if "*" in allowed_roles:
        return True
    for role in tenant_roles:
        if role in allowed_roles:
            return True

    logger.info("Skill %s not in allowedRoles for %s", manifest.get("name"), tenant_roles)
    return False


def load_layer2_skills(s3, bucket, stack_name, tenant_id, tenant_roles, workspace):
    """Load Layer 2 skills from S3 (script-level, no npm deps)."""
    skills_dir = os.path.join(workspace, "skills")
    os.makedirs(skills_dir, exist_ok=True)
    loaded = []

    shared_prefix = "_shared/skills/"
    try:
        subprocess.run(
            ["aws", "s3", "sync", f"s3://{bucket}/{shared_prefix}", f"{skills_dir}/_shared_tmp/", "--quiet"],
            capture_output=True,
            text=True,
            timeout=30,
        )
    except Exception as e:
        logger.warning("Failed to sync shared skills: %s", e)
        return loaded

    shared_tmp = os.path.join(skills_dir, "_shared_tmp")
    if os.path.isdir(shared_tmp):
        for skill_name in os.listdir(shared_tmp):
            skill_path = os.path.join(shared_tmp, skill_name)
            if not os.path.isdir(skill_path):
                continue
            manifest = load_skill_manifest(skill_path)
            if is_skill_allowed(manifest, tenant_roles):
                dest = os.path.join(skills_dir, skill_name)
                if not os.path.exists(dest):
                    os.rename(skill_path, dest)
                    loaded.append(skill_name)
                    logger.info("Layer 2 skill loaded: %s", skill_name)
            else:
                logger.info("Layer 2 skill filtered: %s", skill_name)
        subprocess.run(["rm", "-rf", shared_tmp], capture_output=True)

    tenant_prefix = f"{tenant_id}/skills/"
    try:
        subprocess.run(
            ["aws", "s3", "sync", f"s3://{bucket}/{tenant_prefix}", f"{skills_dir}/", "--quiet"],
            capture_output=True,
            text=True,
            timeout=30,
        )
    except Exception as e:
        logger.warning("Failed to sync tenant skills: %s", e)

    return loaded


def load_personal_skills(s3, bucket, tenant_id, workspace, region=None):
    """Load employee's personalSkills from DynamoDB -> pull from S3."""
    ddb_region = region or os.environ.get("DYNAMODB_REGION", os.environ.get("AWS_REGION", "us-east-1"))
    ddb_table = os.environ.get("DYNAMODB_TABLE", os.environ.get("STACK_NAME", "openclaw"))

    base_id = tenant_id
    parts = base_id.split("__")
    if len(parts) >= 2:
        base_id = parts[1]

    try:
        ddb = boto3.resource("dynamodb", region_name=ddb_region)
        table = ddb.Table(ddb_table)
        resp = table.get_item(Key={"PK": "ORG#acme", "SK": f"EMP#{base_id}"})
        emp = resp.get("Item", {})
        personal = emp.get("personalSkills", [])
        if not personal:
            return []
    except Exception as e:
        logger.warning("Failed to read personalSkills: %s", e)
        return []

    skills_dir = os.path.join(workspace, "skills")
    os.makedirs(skills_dir, exist_ok=True)
    loaded = []

    for skill_name in personal:
        dest = os.path.join(skills_dir, skill_name)
        if os.path.exists(dest):
            continue
        try:
            subprocess.run(
                ["aws", "s3", "sync", f"s3://{bucket}/_shared/skills/{skill_name}/", f"{dest}/", "--quiet"],
                capture_output=True,
                text=True,
                timeout=15,
            )
            if os.path.isdir(dest):
                loaded.append(skill_name)
                logger.info("Personal skill loaded: %s", skill_name)
        except Exception as e:
            logger.warning("Failed to load personal skill %s: %s", skill_name, e)

    return loaded


def load_layer3_bundles(s3_client, ssm, bucket, stack_name, workspace):
    """Load Layer 3 pre-built skill bundles from S3."""
    skills_dir = os.path.join(workspace, "skills")
    os.makedirs(skills_dir, exist_ok=True)
    loaded = []

    catalog_path = f"/openclaw/{stack_name}/skill-catalog/"
    try:
        resp = ssm.get_parameters_by_path(Path=catalog_path, Recursive=False)
        params = resp.get("Parameters", [])
    except ClientError:
        logger.info("No skill catalog found at %s", catalog_path)
        return loaded

    for param in params:
        skill_name = param["Name"].split("/")[-1]
        version = param["Value"]
        bundle_key = f"_shared/skill-bundles/skill-{skill_name}-{version}.tar.gz"

        local_tar = f"/tmp/skill-{skill_name}.tar.gz"
        try:
            s3_client.download_file(bucket, bundle_key, local_tar)
            subprocess.run(
                ["tar", "xzf", local_tar, "-C", skills_dir], capture_output=True, text=True, timeout=30, check=True
            )
            os.remove(local_tar)
            loaded.append(f"{skill_name}@{version}")
            logger.info("Layer 3 bundle loaded: %s@%s", skill_name, version)
        except ClientError:
            logger.warning("Bundle not found in S3: %s", bundle_key)
        except subprocess.CalledProcessError as e:
            logger.warning("Failed to extract bundle %s: %s", skill_name, e)
        except Exception as e:
            logger.warning("Failed to load bundle %s: %s", skill_name, e)

    return loaded


def inject_skill_keys(ssm, stack_name, workspace, env_file="/tmp/skill_env.sh"):
    """Read API keys from SSM and write export statements to env file."""
    skills_dir = os.path.join(workspace, "skills")
    env_lines = []
    injected = []

    # Per-skill keys are driven by each skill's manifest, so they need the skills
    # directory. The _global keys below do not — returning early here meant that a
    # workspace without a skills/ dir got no global keys at all (JINA_API_KEY among
    # them), so the loop is skipped rather than the whole function.
    for skill_name in os.listdir(skills_dir) if os.path.isdir(skills_dir) else []:
        skill_path = os.path.join(skills_dir, skill_name)
        if not os.path.isdir(skill_path):
            continue
        manifest = load_skill_manifest(skill_path)
        if not manifest:
            continue

        required_env = manifest.get("requires", {}).get("env", [])
        if not required_env:
            continue

        for env_var in required_env:
            ssm_path = f"/openclaw/{stack_name}/skill-keys/{skill_name}/{env_var}"
            try:
                resp = ssm.get_parameter(Name=ssm_path, WithDecryption=True)
                value = resp["Parameter"]["Value"]
                safe_value = value.replace("'", "'\\''")
                env_lines.append(f"export {env_var}='{safe_value}'")
                injected.append(f"{skill_name}/{env_var}")
                logger.info("Injected key: %s/%s", skill_name, env_var)
            except ClientError:
                logger.warning("Key not found in SSM: %s", ssm_path)

    global_path = f"/openclaw/{stack_name}/skill-keys/_global/"
    try:
        resp = ssm.get_parameters_by_path(Path=global_path, Recursive=False, WithDecryption=True)
        for param in resp.get("Parameters", []):
            env_var = param["Name"].split("/")[-1]
            value = param["Value"]
            safe_value = value.replace("'", "'\\''")
            env_lines.append(f"export {env_var}='{safe_value}'")
            injected.append(f"_global/{env_var}")
            logger.info("Injected global key: %s", env_var)
    except ClientError:
        pass

    # Merge, never truncate. gog_init.py writes GOG_* exports (including the
    # keyring password) to this same file earlier in startup; opening it with "w"
    # silently dropped them, so anything reading skill_env.sh afterwards — the
    # agent subprocess, workspace_assembler — lost the Google Workspace config.
    existing: list[str] = []
    if os.path.isfile(env_file):
        try:
            with open(env_file) as f:
                existing = [ln.rstrip("\n") for ln in f if ln.strip() and not ln.startswith("#")]
        except OSError as e:
            logger.warning("Could not read existing %s: %s", env_file, e)

    def _var_of(line: str) -> str:
        return line[len("export ") :].split("=", 1)[0] if line.startswith("export ") else ""

    fresh_vars = {_var_of(ln) for ln in env_lines}
    # Keep prior exports unless this run supplies a newer value for the same var.
    merged = [ln for ln in existing if _var_of(ln) not in fresh_vars] + env_lines

    with open(env_file, "w") as f:
        f.write("#!/bin/sh\n")
        f.write("# Auto-generated — skill API keys plus any env written by gog_init.py\n")
        for line in merged:
            f.write(line + "\n")

    logger.info(
        "Wrote %d env vars to %s (%d new, %d preserved)",
        len(merged),
        env_file,
        len(env_lines),
        len(merged) - len(env_lines),
    )
    return injected


def main():
    parser = argparse.ArgumentParser(description="Enterprise Skill Loader")
    parser.add_argument("--tenant", required=True, help="Tenant ID")
    parser.add_argument("--workspace", required=True, help="Workspace directory")
    parser.add_argument("--bucket", required=True, help="S3 bucket name")
    parser.add_argument("--stack", required=True, help="Stack name")
    parser.add_argument("--region", default="us-east-1", help="AWS region")
    args = parser.parse_args()

    ssm = boto3.client("ssm", region_name=args.region)
    s3 = boto3.client("s3", region_name=args.region)

    logger.info("=== Skill Loader START tenant=%s ===", args.tenant)

    roles = get_tenant_roles(args.stack, args.tenant, region=args.region)

    l2 = load_layer2_skills(s3, args.bucket, args.stack, args.tenant, roles, args.workspace)
    logger.info("Layer 2 loaded: %s", l2 if l2 else "none")

    personal = load_personal_skills(s3, args.bucket, args.tenant, args.workspace, region=args.region)
    logger.info("Personal skills loaded: %s", personal if personal else "none")

    l3 = load_layer3_bundles(s3, ssm, args.bucket, args.stack, args.workspace)
    logger.info("Layer 3 loaded: %s", l3 if l3 else "none")

    keys = inject_skill_keys(ssm, args.stack, args.workspace)
    logger.info("Keys injected: %d", len(keys))

    skills_dir = os.path.join(args.workspace, "skills")
    total = 0
    if os.path.isdir(skills_dir):
        total = len([d for d in os.listdir(skills_dir) if os.path.isdir(os.path.join(skills_dir, d))])
    logger.info("=== Skill Loader DONE: %d skills available ===", total)


if __name__ == "__main__":
    main()
