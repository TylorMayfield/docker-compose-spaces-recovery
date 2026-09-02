# Docker Compose recovery to private Spaces storage

This companion backs up one Docker Compose application's protected configuration, selected named volumes, and an optional PostgreSQL logical dump. It encrypts the timestamped set before upload. The restore command is dry-run by default and refuses any environment except `RESTORE_ENV=test`.

Read the guide: [Back Up a Docker Compose App and Test the Restore](https://www.tylor.nz/content/back-up-docker-compose-app-and-test-restore)

## Disclosure

This README includes a DigitalOcean affiliate link. If you use it, I may earn a commission at no additional cost to you.

[Create a private DigitalOcean Spaces bucket](https://www.awin1.com/cread.php?s=4757508&v=123996&q=601070&r=3054551)

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

The apply command creates new volumes with the `RESTORE_VOLUME_PREFIX` and restores their archives. If the set includes PostgreSQL, first start a fresh test-only PostgreSQL container and set `RESTORE_POSTGRES_CONTAINER`, `RESTORE_POSTGRES_DATABASE`, and `RESTORE_POSTGRES_USER`. The command refuses a non-test environment or an existing target volume. Review the recovered Compose files, use a test hostname, and confirm one harmless read-only check before treating the recovery set as usable.

## Test the safe default

```sh
./scripts/test-restore-dry-run.sh
./scripts/test-restore-apply.sh
```

These tests do not call Spaces or need credentials. The second test uses fake AWS, age, and Docker commands to confirm that an apply run creates a new recovery volume and targets the configured PostgreSQL container.
