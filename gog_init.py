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

This script writes the credential files that gogcli expects so it can
authenticate without an interactive OAuth flow inside the container.
gogcli stores credentials in ~/.config/gog/accounts/<email>.json
"""

import json
import logging
import os
import subprocess
import sys
from pathlib import Path

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger("gog_init")

GOG_CONFIG_DIR = Path(os.environ.get("HOME", "/root")) / ".config" / "gog" / "accounts"
GOG_BIN = "/usr/local/bin/gog"


def safe_key(email: str) -> str:
    """Convert email to the env var safe key used by the infra repo."""
    return email.upper().replace("@", "_AT_").replace(".", "_")


def get_account_env(email: str, field: str) -> str:
    safe = safe_key(email)
    return os.environ.get(f"GOG_ACCOUNT_{safe}_{field}", "")


def write_credential_file(email: str) -> bool:
    """Write a gogcli credential JSON for one account. Returns True on success."""
    client_id = get_account_env(email, "CLIENT_ID")
    client_secret = get_account_env(email, "CLIENT_SECRET")
    refresh_token = get_account_env(email, "REFRESH_TOKEN")
    scopes_raw = get_account_env(email, "SCOPES")
    label = get_account_env(email, "LABEL") or email.split("@")[0]

    if not all([client_id, client_secret, refresh_token]):
        log.warning("Skipping %s — missing CLIENT_ID, CLIENT_SECRET, or REFRESH_TOKEN", email)
        return False

    scopes = [s.strip() for s in scopes_raw.split(",") if s.strip()] if scopes_raw else []

    # gogcli credential file format
    cred = {
        "account": email,
        "label": label,
        "client_id": client_id,
        "client_secret": client_secret,
        "refresh_token": refresh_token,
        "scopes": scopes,
        # access_token is intentionally omitted — gogcli will fetch one on first use
        "token_type": "Bearer",
    }

    GOG_CONFIG_DIR.mkdir(parents=True, exist_ok=True)
    cred_path = GOG_CONFIG_DIR / f"{email}.json"
    cred_path.write_text(json.dumps(cred, indent=2))
    cred_path.chmod(0o600)
    log.info("Wrote credential file: %s (label=%s, scopes=%d)", cred_path, label, len(scopes))
    return True


def set_default_account(email: str) -> None:
    """Write the gogcli default account config."""
    config_dir = Path(os.environ.get("HOME", "/root")) / ".config" / "gog"
    config_dir.mkdir(parents=True, exist_ok=True)
    config_path = config_dir / "config.json"
    config = {}
    if config_path.exists():
        try:
            config = json.loads(config_path.read_text())
        except Exception:
            pass
    config["default_account"] = email
    config_path.write_text(json.dumps(config, indent=2))
    log.info("Default gog account set to: %s", email)


def verify_gog_binary() -> bool:
    """Check that the gog binary is available."""
    if not Path(GOG_BIN).exists():
        # Try PATH fallback
        result = subprocess.run(["which", "gog"], capture_output=True, text=True)
        if result.returncode != 0:
            log.error("gog binary not found at %s and not on PATH", GOG_BIN)
            return False
    return True


def main() -> None:
    accounts_raw = os.environ.get("GOG_ACCOUNTS", "").strip()
    if not accounts_raw:
        log.info("GOG_ACCOUNTS not set — nothing to initialize")
        return

    if not verify_gog_binary():
        log.warning("gog binary missing — skipping credential initialization")
        return

    accounts = [a.strip() for a in accounts_raw.split(",") if a.strip()]
    default_account = os.environ.get("GOG_DEFAULT_ACCOUNT", accounts[0] if accounts else "")

    log.info("Initializing gog credentials for %d account(s): %s", len(accounts), ", ".join(accounts))

    initialized = []
    for email in accounts:
        if write_credential_file(email):
            initialized.append(email)

    if not initialized:
        log.warning("No accounts successfully initialized")
        return

    # Set default account
    if default_account in initialized:
        set_default_account(default_account)
    elif initialized:
        set_default_account(initialized[0])

    # Write a skill_env.sh fragment so server.py picks up GOG_DEFAULT_ACCOUNT
    # for the openclaw subprocess environment
    skill_env_path = Path("/tmp/skill_env.sh")
    lines = []
    if skill_env_path.exists():
        lines = skill_env_path.read_text().splitlines()

    gog_lines = [
        f"export GOG_ACCOUNTS='{accounts_raw}'",
        f"export GOG_DEFAULT_ACCOUNT='{default_account}'",
        f"export GOG_CONFIG_DIR='{GOG_CONFIG_DIR.parent}'",
    ]
    # Append only lines not already present
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
        default_account,
    )


if __name__ == "__main__":
    try:
        main()
    except Exception as e:
        log.error("gog_init failed: %s", e)
        sys.exit(1)
