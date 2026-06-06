"""gog_init.py — Initialize gogcli credentials from environment variables.

Called by entrypoint.sh (Step 0.6.5) when GOG_ACCOUNTS is set.

The infra repo's `just setup-google` stores OAuth credentials in AWS Secrets
Manager and `just deploy-phase2` injects them as container env vars:

  GOG_ACCOUNTS                          comma-separated account emails
  GOG_DEFAULT_ACCOUNT                   default account email
  GOG_ACCOUNT_<SAFE>_CLIENT_ID          OAuth client ID
  GOG_ACCOUNT_<SAFE>_CLIENT_SECRET      OAuth client secret
  GOG_ACCOUNT_<SAFE>_REFRESH_TOKEN      OAuth refresh token
  GOG_ACCOUNT_<SAFE>_SCOPES             comma-separated scope URLs
  GOG_ACCOUNT_<SAFE>_LABEL              human label (personal, work, …)

where SAFE = email.upper().replace('@', '_AT_').replace('.', '_')

How gogcli actually stores credentials (verified against gogcli v0.19.0):

  * The OAuth *client* (client_id/client_secret) is stored via
    `gog auth credentials set <file|->`, which writes
    $GOG_HOME/data/credentials.json and (by default) puts the client_secret
    in the keyring.
  * The *refresh token* is stored in the keyring, NOT in a plain JSON file.
    It is imported non-interactively with `gog auth import --email <e>
    --refresh-token-env <VAR>`.
  * In a container there is no OS keyring, so the encrypted *file* keyring
    backend must be used. This REQUIRES two env vars to be set on every
    process that runs `gog` (this script AND the agent subprocess):
        GOG_KEYRING_BACKEND=file
        GOG_KEYRING_PASSWORD=<non-empty secret>

This script drives the real `gog` binary rather than hand-writing files,
so it stays correct across gogcli releases.
"""

import logging
import os
import shutil
import subprocess
import sys
from pathlib import Path

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger("gog_init")


def find_gog() -> str:
    """Return the path to the gog binary, or '' if not found."""
    for candidate in ("/usr/local/bin/gog", "gog"):
        resolved = (
            shutil.which(candidate) if "/" not in candidate else (candidate if Path(candidate).exists() else None)
        )
        if resolved:
            return resolved
    return ""


def safe_key(email: str) -> str:
    """Convert email to the env-var-safe key used by the infra repo."""
    return email.upper().replace("@", "_AT_").replace(".", "_")


def get_account_env(email: str, field: str) -> str:
    return os.environ.get(f"GOG_ACCOUNT_{safe_key(email)}_{field}", "")


def run_gog(gog_bin: str, args: list[str], env: dict, stdin: str | None = None) -> subprocess.CompletedProcess:
    """Run a gog subcommand with --no-input and return the completed process."""
    cmd = [gog_bin, *args, "--no-input"]
    return subprocess.run(
        cmd,
        input=stdin,
        capture_output=True,
        text=True,
        env=env,
        timeout=30,
    )


def build_client_json(client_id: str, client_secret: str) -> str:
    """Build a Google 'installed app' OAuth client JSON that gog can ingest."""
    import json

    return json.dumps(
        {
            "installed": {
                "client_id": client_id,
                "client_secret": client_secret,
                "auth_uri": "https://accounts.google.com/o/oauth2/auth",
                "token_uri": "https://oauth2.googleapis.com/token",
                "redirect_uris": ["http://localhost"],
            }
        }
    )


def init_account(gog_bin: str, email: str, env: dict, default_client_set: bool) -> tuple[bool, bool]:
    """Initialize one account. Returns (success, client_was_set)."""
    client_id = get_account_env(email, "CLIENT_ID")
    client_secret = get_account_env(email, "CLIENT_SECRET")
    refresh_token = get_account_env(email, "REFRESH_TOKEN")

    if not all([client_id, client_secret, refresh_token]):
        log.warning("Skipping %s — missing CLIENT_ID, CLIENT_SECRET, or REFRESH_TOKEN", email)
        return False, default_client_set

    # 1. Store the OAuth client once (the 'default' client is shared across
    #    accounts that use the same Cloud project). Re-running is harmless.
    if not default_client_set:
        client_json = build_client_json(client_id, client_secret)
        result = run_gog(gog_bin, ["auth", "credentials", "set", "-"], env, stdin=client_json)
        if result.returncode != 0:
            log.error("Failed to store OAuth client for %s: %s", email, result.stderr.strip())
            return False, default_client_set
        log.info("Stored OAuth client (default) for %s", email)
        default_client_set = True

    # 2. Import the refresh token into the keyring non-interactively.
    #    Pass the token via a private env var so it never appears in argv.
    import_env = dict(env)
    import_env["GOG_IMPORT_RT"] = refresh_token
    args = ["auth", "import", f"--email={email}", "--refresh-token-env=GOG_IMPORT_RT"]
    # The account's SCOPES env var holds full scope URLs; gog's --services
    # expects service names, and the flag is informational only, so we omit it
    # to avoid mismatches.
    result = run_gog(gog_bin, args, import_env)
    if result.returncode != 0:
        log.error("Failed to import refresh token for %s: %s", email, result.stderr.strip())
        return False, default_client_set
    log.info("Imported refresh token for %s", email)
    return True, default_client_set


def main() -> None:
    accounts_raw = os.environ.get("GOG_ACCOUNTS", "").strip()
    if not accounts_raw:
        log.info("GOG_ACCOUNTS not set — nothing to initialize")
        return

    gog_bin = find_gog()
    if not gog_bin:
        log.warning("gog binary not found — skipping credential initialization")
        return

    # The file keyring backend is mandatory in a headless container.
    keyring_backend = os.environ.get("GOG_KEYRING_BACKEND", "")
    keyring_password = os.environ.get("GOG_KEYRING_PASSWORD", "")
    if keyring_backend != "file" or not keyring_password:
        log.error(
            "GOG_KEYRING_BACKEND must be 'file' and GOG_KEYRING_PASSWORD must be set "
            "(got backend=%r, password_set=%s). gog cannot store credentials without "
            "a writable keyring. Set these in entrypoint.sh before running gog_init.py.",
            keyring_backend,
            bool(keyring_password),
        )
        return

    # Build a clean environment for the gog subprocesses, inheriting GOG_HOME /
    # keyring config from the parent.
    env = dict(os.environ)

    accounts = [a.strip() for a in accounts_raw.split(",") if a.strip()]
    default_account = os.environ.get("GOG_DEFAULT_ACCOUNT", accounts[0] if accounts else "")

    log.info("Initializing gog credentials for %d account(s): %s", len(accounts), ", ".join(accounts))

    initialized: list[str] = []
    client_set = False
    for email in accounts:
        ok, client_set = init_account(gog_bin, email, env, client_set)
        if ok:
            initialized.append(email)

    if not initialized:
        log.warning("No accounts successfully initialized")
        return

    # 3. Record the default account. gog reserves the literal alias name
    #    "default", so use the config setting instead of an alias when the
    #    chosen default is the first/only account (already the implicit default).
    chosen_default = default_account if default_account in initialized else initialized[0]
    if chosen_default != initialized[0]:
        result = run_gog(gog_bin, ["auth", "alias", "set", "primary", chosen_default], env)
        if result.returncode == 0:
            log.info("Default gog account alias 'primary' -> %s", chosen_default)
        else:
            log.warning("Could not set default alias: %s", result.stderr.strip())
    else:
        log.info("Default gog account: %s (implicit)", chosen_default)

    # 4. Run a non-fatal health check so failures are visible in logs.
    doctor = run_gog(gog_bin, ["auth", "doctor", "--check"], env)
    log.info("gog auth doctor output:\n%s", (doctor.stdout or doctor.stderr).strip())

    # 5. Write a skill_env.sh fragment so server.py / the agent subprocess pick
    #    up the gog env (accounts, default, and—critically—the keyring vars).
    skill_env_path = Path("/tmp/skill_env.sh")
    lines = skill_env_path.read_text().splitlines() if skill_env_path.exists() else []
    gog_lines = [
        f"export GOG_ACCOUNTS='{accounts_raw}'",
        f"export GOG_DEFAULT_ACCOUNT='{chosen_default}'",
        f"export GOG_KEYRING_BACKEND='{keyring_backend}'",
        f"export GOG_KEYRING_PASSWORD='{keyring_password}'",
    ]
    gog_home = os.environ.get("GOG_HOME", "")
    if gog_home:
        gog_lines.append(f"export GOG_HOME='{gog_home}'")
    existing = set(lines)
    for line in gog_lines:
        if line not in existing:
            lines.append(line)
    skill_env_path.write_text("\n".join(lines) + "\n")
    log.info("Updated /tmp/skill_env.sh with gog env vars")

    log.info(
        "gog initialization complete: %d/%d accounts ready, default=%s",
        len(initialized),
        len(accounts),
        chosen_default,
    )


if __name__ == "__main__":
    try:
        main()
    except Exception as e:
        log.error("gog_init failed: %s", e)
        sys.exit(1)
