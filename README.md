# Docker Compose recovery to private Spaces storage

This companion backs up one Docker Compose application's protected configuration, selected named volumes, and an optional PostgreSQL logical dump. It encrypts the timestamped set before upload. The restore command is dry-run by default and refuses any environment except `RESTORE_ENV=test`.

Read the guide: [Back Up a Docker Compose App and Test the Restore](https://www.tylor.nz/content/back-up-docker-compose-app-and-test-restore)

## Disclosure

This README includes a DigitalOcean affiliate link. If you use it, I may earn a commission at no additional cost to you.

[Create a private DigitalOcean Spaces bucket](https://www.awin1.com/cread.php?s=4757508&v=123996&q=601070&r=3054551)

## Configure the backup

Copy `.env.example` outside this repository, for example to `/etc/compose-recovery.env`, then restrict it to mode `0600`.

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

After checking the object timestamp and test-server controls, extract the set:

```sh
sudo ./scripts/restore-compose-app.sh --apply /etc/compose-recovery-restore.env
```

Review the recovered Compose files, create new Docker volumes, restore the selected archives, and start only under the test hostname. Confirm one harmless read-only check before treating the recovery set as usable.

## Test the safe default

```sh
./scripts/test-restore-dry-run.sh
```

This test does not call Spaces or need credentials.
