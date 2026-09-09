#!/usr/bin/env bash
set -euo pipefail

CONFIG_FILE=${1:?Usage: backup-compose-app.sh /path/to/config.env}
test -r "$CONFIG_FILE"
set -a
. "$CONFIG_FILE"
set +a

: "${APP_DIR:?APP_DIR is required}"
: "${BUCKET:?BUCKET is required}"
: "${REGION:?REGION is required}"
: "${AGE_RECIPIENT:?AGE_RECIPIENT is required}"
: "${VOLUME_NAMES:?VOLUME_NAMES is required}"
: "${AWS_ACCESS_KEY_ID:?AWS_ACCESS_KEY_ID is required}"
: "${AWS_SECRET_ACCESS_KEY:?AWS_SECRET_ACCESS_KEY is required}"

PREFIX=${PREFIX:-compose-recovery}
STAMP=$(date -u +%Y-%m-%dT%H-%M-%SZ)
WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR"' EXIT
export AWS_DEFAULT_REGION=us-east-1

test -f "$APP_DIR/compose.yml" || test -f "$APP_DIR/docker-compose.yml" || {
  echo "No Compose file found in $APP_DIR" >&2
  exit 1
}

cd "$APP_DIR"
umask 077
# External writers must already be paused for the entire capture window.
RUNNING=()
while IFS= read -r service; do
  [[ -n "$service" ]] && RUNNING+=("$service")
done < <(sudo docker compose ps --services --status running)
((${#RUNNING[@]})) || { echo "No running services to back up" >&2; exit 1; }
WRITERS=()
postgres_running=false
for service in "${RUNNING[@]}"; do
  if [[ "$service" == "${POSTGRES_SERVICE:-}" ]]; then
    postgres_running=true
  else
    WRITERS+=("$service")
  fi
done
if [[ -n "${POSTGRES_SERVICE:-}" ]]; then
  : "${POSTGRES_DATABASE:?POSTGRES_DATABASE is required}"
  : "${POSTGRES_USER:?POSTGRES_USER is required}"
  $postgres_running || { echo "PostgreSQL service must already be running" >&2; exit 1; }
fi
resume_needed=false
cleanup() {
  result=$?
  trap - EXIT
  if $resume_needed; then
    sudo docker compose start "${WRITERS[@]}" || { echo "Failed to resume application services" >&2; result=1; }
  fi
  rm -rf "$WORK_DIR"
  exit "$result"
}
trap cleanup EXIT
if ((${#WRITERS[@]})); then
  resume_needed=true
  sudo docker compose stop "${WRITERS[@]}"
fi
mkdir -p "$WORK_DIR/config" "$WORK_DIR/volumes"
for file in compose.yml docker-compose.yml .env Caddyfile; do
  test -e "$file" && cp -a "$file" "$WORK_DIR/config/"
done
if [[ -n "${POSTGRES_SERVICE:-}" ]]; then
  sudo docker compose exec -T "$POSTGRES_SERVICE" \
    pg_dump -U "$POSTGRES_USER" -Fc "$POSTGRES_DATABASE" > "$WORK_DIR/postgres.dump"
fi
for volume in $VOLUME_NAMES; do
  sudo docker volume inspect "$volume" >/dev/null
  sudo docker run --rm -v "$volume":/data:ro -v "$WORK_DIR/volumes":/backup alpine \
    sh -c "tar -C /data -czf /backup/$volume.tar.gz ."
done
if $resume_needed; then
  sudo docker compose start "${WRITERS[@]}"
  resume_needed=false
fi

tar -C "$WORK_DIR" -czf "$WORK_DIR/$STAMP.tar.gz" config volumes ${POSTGRES_SERVICE:+postgres.dump}
age -r "$AGE_RECIPIENT" -o "$WORK_DIR/$STAMP.tar.gz.age" "$WORK_DIR/$STAMP.tar.gz"
printf 'timestamp=%s\narchive=%s.tar.gz.age\nvolumes=%s\npostgres=%s\n' \
  "$STAMP" "$STAMP" "$VOLUME_NAMES" "${POSTGRES_SERVICE:-none}" > "$WORK_DIR/$STAMP.manifest"

for file in "$WORK_DIR/$STAMP.tar.gz.age" "$WORK_DIR/$STAMP.manifest"; do
  aws s3 cp "$file" "s3://$BUCKET/$PREFIX/" \
    --endpoint-url "https://$REGION.digitaloceanspaces.com" --only-show-errors
done
echo "Uploaded recovery set $STAMP"
