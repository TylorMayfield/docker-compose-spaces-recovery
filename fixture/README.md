# Disposable backup fixture

Use a test server, never an existing production project. The database password is deliberately public and the database has no published port.

From this folder:

```sh
docker compose up -d --wait
docker compose exec -T postgres psql -U fixture -d fixture -v ON_ERROR_STOP=1 -c "CREATE TABLE IF NOT EXISTS documents (id integer PRIMARY KEY, path text NOT NULL); INSERT INTO documents VALUES (42, 'uploads/record-42.txt') ON CONFLICT DO NOTHING;"
docker compose exec -T app cat /data/uploads/record-42.txt
```

Expected file contents: `record-42`. The database record points to that exact relative path.

In a root-only backup config, set APP_DIR to the absolute path of this fixture directory, VOLUME_NAMES=recovery-fixture_app_data, POSTGRES_SERVICE=postgres, POSTGRES_DATABASE=fixture, and POSTGRES_USER=fixture. Set the remaining Spaces and age fields using `.env.example`. The database is recovered from its logical dump; do not add the raw PostgreSQL volume to VOLUME_NAMES.

Run the backup script with that config. Use the main README's isolated restore steps and rewrite the app volume to the newly restored volume before starting the app. Check the imported database row with `SELECT path FROM documents WHERE id=42;` and read that path inside the restored application volume. Both must match. A successful upload alone does not pass this check.

When finished, from this fixture folder, `docker compose down` stops its containers. Retain the volumes until the recovery check passes. Remove only the fixture volumes and backup objects after confirming they contain no data you need. A test server continues billing until destroyed.
