#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
CONFIG=$(mktemp)
trap 'rm -f "$CONFIG"' EXIT
cat > "$CONFIG" <<'EOF'
APP_DIR=/srv/not-production
BUCKET=test-bucket
REGION=nyc3
PREFIX=compose-recovery
RESTORE_ENV=test
TIMESTAMP=2026-09-02T00-00-00Z
RESTORE_DIR=/tmp/compose-recovery-test
AGE_IDENTITY=/tmp/not-needed-for-dry-run
EOF
"$ROOT/scripts/restore-compose-app.sh" "$CONFIG" | grep -F "Dry run: would download"
