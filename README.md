# Docker Compose recovery to private Spaces storage

This companion backs up one Docker Compose application's protected configuration, selected named volumes, and an optional PostgreSQL logical dump. It encrypts the timestamped set before upload. The restore command is dry-run by default and refuses any environment except `RESTORE_ENV=test`.

Read the guide: [Back Up a Docker Compose App and Test the Restore](https://www.tylor.nz/content/back-up-docker-compose-app-and-test-restore?utm_source=github&utm_medium=referral&utm_campaign=digitalocean-guides&utm_content=companion-readme)

## Disclosure

This README includes a DigitalOcean affiliate link. If you use it, I may earn a commission at no additional cost to you.

[Create a private DigitalOcean Spaces bucket](https://www.tylor.nz/go/digitalocean?utm_source=github&utm_medium=affiliate&utm_campaign=digitalocean-guides&utm_content=back-up-docker-compose-app-and-test-restore&product=spaces&placement=companion-readme&variant=readme-primary&locale=en)

## Configure the backup

Copy `.env.example` outside this repository, for example with `sudo install -m 600 .env.example /etc/compose-recovery.env`. Install `awscli`, `age`, Docker Engine, and the Docker Compose plugin before running the scripts.

`VOLUME_NAMES` must name only application volumes. Do not archive a live PostgreSQL data volume. When the Compose stack includes PostgreSQL, set `POSTGRES_SERVICE`, `POSTGRES_DATABASE`, and `POSTGRES_USER` so the script runs `pg_dump` before stopping services.

Run the backup by hand first:

```sh
sudo ./scripts/backup-compose-app.sh /etc/compose-recovery.env
```

Check the private bucket for a matching encrypted archive and manifest before scheduling the command.

## Test the restore somewhere else

Use a fresh server, a test hostname, a firewall restricted to the recovery administrator, and blocked outbound traffic. Configure a separate, limited read key in `/etc/compose-recovery-restore.env`.

The first command changes nothing:

```sh
sudo ./scripts/restore-compose-app.sh /etc/compose-recovery-restore.env
```

After checking the object timestamp, matching manifest, and test-server controls, restore the set:

```sh
sudo ./scripts/restore-compose-app.sh --apply /etc/compose-recovery-restore.env
```

The apply command creates new volumes with the `RESTORE_VOLUME_PREFIX` and restores their archives. It writes only to those new recovery volumes and to the test-only database you name; it does not write to production.

### PostgreSQL restore values

If the set includes `postgres.dump`, start a fresh test-only PostgreSQL container **and create its empty test database** before applying the restore. In the root-only `/etc/compose-recovery-restore.env` file, set all four values:

- `RESTORE_POSTGRES_CONTAINER`: the fresh test container's name.
- `RESTORE_POSTGRES_DATABASE`: the new, empty database inside that container.
- `RESTORE_POSTGRES_USER`: the database user allowed to restore into that database.
- `RESTORE_POSTGRES_PASSWORD`: that user's password. It stays in the mode-0600 config file and is forwarded only to `pg_restore`; do not add it to this repository or a shell command.

The command refuses a non-test environment, an existing target volume, or a PostgreSQL restore with a missing setting. Review the recovered Compose files, use a test hostname, and confirm one harmless read-only check before treating the recovery set as usable.

## Test the safe default

```sh
./scripts/test-restore-dry-run.sh
./scripts/test-restore-apply.sh
./scripts/test-postgres-restore.sh
```

These tests do not call Spaces or need real Spaces credentials. The second test uses fake AWS, age, and Docker commands to confirm that a password is required without exposing it, an apply run creates a new recovery volume, and PostgreSQL receives the configured environment variable. The third test uses throwaway local PostgreSQL containers to prove a password-protected restore preserves a known record.
