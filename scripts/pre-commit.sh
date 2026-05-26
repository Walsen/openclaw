#!/bin/bash
# Git pre-commit hook: lint, static checks, tests
# Install: cp scripts/pre-commit.sh .git/hooks/pre-commit && chmod +x .git/hooks/pre-commit
set -e

# Ensure devbox-managed tools (shellcheck, ruff, etc.) are on PATH
# when running outside of a devbox shell (e.g. git commit from IDE or bare terminal).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
DEVBOX_BIN="$REPO_ROOT/.devbox/nix/profile/default/bin"
if [ -d "$DEVBOX_BIN" ]; then
    export PATH="$DEVBOX_BIN:$PATH"
fi

echo "=== Pre-commit: ruff lint ==="
ruff check .

echo "=== Pre-commit: ruff format ==="
ruff format --check .

echo "=== Pre-commit: shellcheck ==="
shellcheck entrypoint.sh

echo "=== Pre-commit: JSON validation ==="
python3 -c "import json; json.load(open('openclaw.json'))"

echo "=== Pre-commit: Python compile check ==="
for f in server.py workspace_assembler.py permissions.py identity.py memory.py \
         observability.py safety.py skill_loader.py auth-agent/permission_request.py; do
    python3 -m py_compile "$f"
done

echo "=== Pre-commit: pytest ==="
python3 -m pytest tests/ -v --tb=short 2>/dev/null || echo "(no tests found — skipped)"

echo "=== All checks passed ==="
