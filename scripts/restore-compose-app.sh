#!/usr/bin/env bash
set -euo pipefail

APPLY=false
if test "${1:-}" = "--apply"; then APPLY=true; shift; fi
CONFIG_FILE=${1:?Usage: restore-compose-app.sh [--apply] /path/to/config.env}
test -r "$CONFIG_FILE"
set -a
. "$CONFIG_FILE"
set +a

: "${RESTORE_ENV:?RESTORE_ENV is required}"
: "${APP_DIR:?APP_DIR is required}"
: "${TIMESTAMP:?TIMESTAMP is required}"
: "${BUCKET:?BUCKET is required}"
: "${REGION:?REGION is required}"
: "${PREFIX:?PREFIX is required}"
: "${RESTORE_DIR:?RESTORE_DIR is required}"
: "${AGE_IDENTITY:?AGE_IDENTITY is required}"
test "$RESTORE_ENV" = test || { echo "Refusing a non-test restore" >&2; exit 1; }
test "$RESTORE_DIR" != "$APP_DIR" || { echo "Restore directory must not be APP_DIR" >&2; exit 1; }

OBJECT="s3://$BUCKET/$PREFIX/$TIMESTAMP.tar.gz.age"
MANIFEST_OBJECT="s3://$BUCKET/$PREFIX/$TIMESTAMP.manifest"
if ! $APPLY; then
  echo "Dry run: would download $OBJECT into $RESTORE_DIR after confirming a test-only server."
  echo "Review the object, block outbound traffic, then rerun with --apply."
  exit 0
fi

test -f "$AGE_IDENTITY" || { echo "Missing AGE_IDENTITY" >&2; exit 1; }
umask 077
install -d -m 700 "$RESTORE_DIR"
export AWS_DEFAULT_REGION=us-east-1
aws s3 cp "$OBJECT" "$RESTORE_DIR/$TIMESTAMP.tar.gz.age" \
  --endpoint-url "https://$REGION.digitaloceanspaces.com" --only-show-errors
aws s3 cp "$MANIFEST_OBJECT" "$RESTORE_DIR/$TIMESTAMP.manifest" \
  --endpoint-url "https://$REGION.digitaloceanspaces.com" --only-show-errors
grep -Fx "timestamp=$TIMESTAMP" "$RESTORE_DIR/$TIMESTAMP.manifest" >/dev/null
grep -Fx "archive=$TIMESTAMP.tar.gz.age" "$RESTORE_DIR/$TIMESTAMP.manifest" >/dev/null
age -d -i "$AGE_IDENTITY" -o "$RESTORE_DIR/$TIMESTAMP.tar.gz" "$RESTORE_DIR/$TIMESTAMP.tar.gz.age"
tar -tzf "$RESTORE_DIR/$TIMESTAMP.tar.gz" | sed -n '1,80p'
tar -xzf "$RESTORE_DIR/$TIMESTAMP.tar.gz" -C "$RESTORE_DIR"

RESTORE_VOLUME_PREFIX=${RESTORE_VOLUME_PREFIX:-recovered}
for archive in "$RESTORE_DIR"/volumes/*.tar.gz; do
  test -e "$archive" || break
  source_volume=$(basename "$archive" .tar.gz)
  target_volume="${RESTORE_VOLUME_PREFIX}_${source_volume}"
  if docker volume inspect "$target_volume" >/dev/null 2>&1; then
    echo "Refusing to overwrite existing volume $target_volume" >&2
    exit 1
  fi
  docker volume create "$target_volume" >/dev/null
  docker run --rm -v "$target_volume":/data -v "$RESTORE_DIR/volumes":/backup:ro alpine \
    tar -C /data -xzf "/backup/$source_volume.tar.gz"
  echo "Restored $source_volume into new volume $target_volume"
done

if test -f "$RESTORE_DIR/postgres.dump"; then
  : "${RESTORE_POSTGRES_CONTAINER:?RESTORE_POSTGRES_CONTAINER is required for postgres.dump}"
  : "${RESTORE_POSTGRES_DATABASE:?RESTORE_POSTGRES_DATABASE is required for postgres.dump}"
  : "${RESTORE_POSTGRES_USER:?RESTORE_POSTGRES_USER is required for postgres.dump}"
  docker exec -i "$RESTORE_POSTGRES_CONTAINER" \
    pg_restore -U "$RESTORE_POSTGRES_USER" --clean --if-exists \
    -d "$RESTORE_POSTGRES_DATABASE" < "$RESTORE_DIR/postgres.dump"
  echo "Restored postgres.dump into $RESTORE_POSTGRES_CONTAINER/$RESTORE_POSTGRES_DATABASE"
fi

echo "Recovered files are in $RESTORE_DIR. Review the recovered Compose files, use a test hostname, and start only the test stack."
