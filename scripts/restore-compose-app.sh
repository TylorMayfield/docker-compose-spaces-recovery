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
: "${TIMESTAMP:?TIMESTAMP is required}"
: "${BUCKET:?BUCKET is required}"
: "${REGION:?REGION is required}"
: "${PREFIX:?PREFIX is required}"
: "${RESTORE_DIR:?RESTORE_DIR is required}"
: "${AGE_IDENTITY:?AGE_IDENTITY is required}"
test "$RESTORE_ENV" = test || { echo "Refusing a non-test restore" >&2; exit 1; }
test "$RESTORE_DIR" != "$APP_DIR" || { echo "Restore directory must not be APP_DIR" >&2; exit 1; }

OBJECT="s3://$BUCKET/$PREFIX/$TIMESTAMP.tar.gz.age"
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
age -d -i "$AGE_IDENTITY" -o "$RESTORE_DIR/$TIMESTAMP.tar.gz" "$RESTORE_DIR/$TIMESTAMP.tar.gz.age"
tar -tzf "$RESTORE_DIR/$TIMESTAMP.tar.gz" | sed -n '1,80p'
tar -xzf "$RESTORE_DIR/$TIMESTAMP.tar.gz" -C "$RESTORE_DIR"
echo "Recovered files are in $RESTORE_DIR. Create new Docker volumes, restore only after reviewing the configuration, and use a test hostname."
