#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
TEMP_DIR=$(mktemp -d)
SUFFIX=$(LC_ALL=C tr -dc 'a-z0-9' </dev/urandom | head -c 8)
SOURCE_CONTAINER="compose-recovery-source-$SUFFIX"
TARGET_CONTAINER="compose-recovery-target-$SUFFIX"
trap 'docker rm -f "$SOURCE_CONTAINER" "$TARGET_CONTAINER" >/dev/null 2>&1 || true; rm -rf "$TEMP_DIR"' EXIT

docker info >/dev/null
docker image inspect postgres:16-alpine >/dev/null 2>&1 || docker pull postgres:16-alpine >/dev/null

wait_for_postgres() {
  local container=$1
  local user=$2
  local password=$3
  for _ in $(seq 1 30); do
    if docker exec -e PGPASSWORD="$password" "$container" pg_isready -U "$user" >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done
  echo "PostgreSQL container $container did not become ready" >&2
  return 1
}

docker run -d --rm --name "$SOURCE_CONTAINER" \
  -e POSTGRES_USER=source_user -e POSTGRES_PASSWORD=source-password -e POSTGRES_DB=source_db \
  postgres:16-alpine >/dev/null
wait_for_postgres "$SOURCE_CONTAINER" source_user source-password
docker exec -e PGPASSWORD=source-password "$SOURCE_CONTAINER" \
  psql -U source_user -d source_db -c "CREATE TABLE recovery_check (label text); INSERT INTO recovery_check VALUES ('known recovery record');" >/dev/null

mkdir -p "$TEMP_DIR/payload/config" "$TEMP_DIR/mock-bin"
printf 'test configuration\n' > "$TEMP_DIR/payload/config/compose.yml"
docker exec -e PGPASSWORD=source-password "$SOURCE_CONTAINER" \
  pg_dump -U source_user -Fc source_db > "$TEMP_DIR/payload/postgres.dump"
tar -C "$TEMP_DIR/payload" -czf "$TEMP_DIR/recovery.tar.gz" config postgres.dump
printf 'timestamp=2026-09-02T00-00-00Z\narchive=2026-09-02T00-00-00Z.tar.gz.age\n' > "$TEMP_DIR/recovery.manifest"
printf 'test identity\n' > "$TEMP_DIR/recovery-key.txt"

docker run -d --rm --name "$TARGET_CONTAINER" \
  -e POSTGRES_USER=restore_user -e POSTGRES_PASSWORD=restore-password -e POSTGRES_DB=restore_db \
  postgres:16-alpine >/dev/null
wait_for_postgres "$TARGET_CONTAINER" restore_user restore-password

cat > "$TEMP_DIR/mock-bin/aws" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "$3" == *.manifest ]]; then cp "$MOCK_MANIFEST" "$4"; else cp "$MOCK_ARCHIVE" "$4"; fi
EOF
cat > "$TEMP_DIR/mock-bin/age" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
while [[ "$1" != "-o" ]]; do shift; done
cp "${@: -1}" "$2"
EOF
chmod 700 "$TEMP_DIR/mock-bin/aws" "$TEMP_DIR/mock-bin/age"

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
RESTORE_POSTGRES_CONTAINER=$TARGET_CONTAINER
RESTORE_POSTGRES_DATABASE=restore_db
RESTORE_POSTGRES_USER=restore_user
RESTORE_POSTGRES_PASSWORD=restore-password
EOF

PATH="$TEMP_DIR/mock-bin:$PATH" \
  MOCK_ARCHIVE="$TEMP_DIR/recovery.tar.gz" \
  MOCK_MANIFEST="$TEMP_DIR/recovery.manifest" \
  "$ROOT/scripts/restore-compose-app.sh" --apply "$TEMP_DIR/restore.env"

docker exec -e PGPASSWORD=restore-password "$TARGET_CONTAINER" \
  psql -U restore_user -d restore_db -tAc "SELECT label FROM recovery_check" | grep -Fx "known recovery record"
