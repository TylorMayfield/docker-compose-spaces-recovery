#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
TEMP_DIR=$(mktemp -d)
trap 'rm -rf "$TEMP_DIR"' EXIT
mkdir -p "$TEMP_DIR/mock-bin" "$TEMP_DIR/payload/config" "$TEMP_DIR/payload/volumes" "$TEMP_DIR/volume-data"
printf 'test configuration\n' > "$TEMP_DIR/payload/config/compose.yml"
printf 'known record\n' > "$TEMP_DIR/volume-data/record.txt"
tar -C "$TEMP_DIR/volume-data" -czf "$TEMP_DIR/payload/volumes/app_data.tar.gz" .
printf 'postgres dump fixture\n' > "$TEMP_DIR/payload/postgres.dump"
tar -C "$TEMP_DIR/payload" -czf "$TEMP_DIR/recovery.tar.gz" config volumes postgres.dump
printf 'timestamp=2026-09-02T00-00-00Z\narchive=2026-09-02T00-00-00Z.tar.gz.age\n' > "$TEMP_DIR/recovery.manifest"
printf 'test identity\n' > "$TEMP_DIR/recovery-key.txt"

cat > "$TEMP_DIR/mock-bin/aws" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "$3" == *.manifest ]]; then
  cp "$MOCK_MANIFEST" "$4"
else
  cp "$MOCK_ARCHIVE" "$4"
fi
EOF
cat > "$TEMP_DIR/mock-bin/age" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
while [[ "$1" != "-o" ]]; do shift; done
output=$2
input=${@: -1}
cp "$input" "$output"
EOF
cat > "$TEMP_DIR/mock-bin/docker" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$MOCK_DOCKER_LOG"
if [[ "$1 $2" == "volume inspect" ]]; then exit 1; fi
exit 0
EOF
chmod 700 "$TEMP_DIR/mock-bin/aws" "$TEMP_DIR/mock-bin/age" "$TEMP_DIR/mock-bin/docker"

cat > "$TEMP_DIR/restore.env" <<EOF
APP_DIR=/srv/not-production
BUCKET=test-bucket
REGION=nyc3
PREFIX=compose-recovery
AWS_ACCESS_KEY_ID=test-key
AWS_SECRET_ACCESS_KEY=test-secret
RESTORE_ENV=test
TIMESTAMP=2026-09-02T00-00-00Z
RESTORE_DIR=$TEMP_DIR/restored
AGE_IDENTITY=$TEMP_DIR/recovery-key.txt
RESTORE_VOLUME_PREFIX=recovered
RESTORE_POSTGRES_CONTAINER=fresh-postgres
RESTORE_POSTGRES_DATABASE=app
RESTORE_POSTGRES_USER=app
EOF

if PATH="$TEMP_DIR/mock-bin:$PATH" \
  MOCK_ARCHIVE="$TEMP_DIR/recovery.tar.gz" \
  MOCK_MANIFEST="$TEMP_DIR/recovery.manifest" \
  MOCK_DOCKER_LOG="$TEMP_DIR/docker.log" \
  "$ROOT/scripts/restore-compose-app.sh" --apply "$TEMP_DIR/restore.env" >"$TEMP_DIR/missing-password.log" 2>&1; then
  echo "Expected a PostgreSQL restore without RESTORE_POSTGRES_PASSWORD to fail" >&2
  exit 1
fi
grep -F "RESTORE_POSTGRES_PASSWORD is required for postgres.dump" "$TEMP_DIR/missing-password.log"
if grep -F "exec" "$TEMP_DIR/docker.log"; then
  echo "pg_restore ran without a password" >&2
  exit 1
fi

printf 'RESTORE_POSTGRES_PASSWORD=test-only-password\n' >> "$TEMP_DIR/restore.env"
: > "$TEMP_DIR/docker.log"
PATH="$TEMP_DIR/mock-bin:$PATH" \
  MOCK_ARCHIVE="$TEMP_DIR/recovery.tar.gz" \
  MOCK_MANIFEST="$TEMP_DIR/recovery.manifest" \
  MOCK_DOCKER_LOG="$TEMP_DIR/docker.log" \
  "$ROOT/scripts/restore-compose-app.sh" --apply "$TEMP_DIR/restore.env"

grep -Fx "volume create recovered_app_data" "$TEMP_DIR/docker.log"
grep -F "exec -e PGPASSWORD -i fresh-postgres pg_restore -U app --no-owner --clean --if-exists -d app" "$TEMP_DIR/docker.log"
if grep -F "test-only-password" "$TEMP_DIR/docker.log" "$TEMP_DIR/missing-password.log"; then
  echo "A PostgreSQL password appeared in test output" >&2
  exit 1
fi
