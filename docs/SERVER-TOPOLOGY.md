# Production and development topology

## Isolation

Run two clones of this repository:

```text
/srv/bitrix-prod/env-docker  -> bitrix-prod -> 127.0.0.1:8588
/srv/bitrix-dev/env-docker   -> bitrix-dev  -> 127.0.0.1:8589
```

Different `COMPOSE_PROJECT_NAME` values create different containers, networks,
Percona volumes and Redis volumes. Never point both clones at the same
`WWW_PATH`, `BACKUP_PATH` or Compose project name.

The existing host Nginx remains on public ports `80/443`. It proxies only the
Finntrail domains to the loopback ports above; unrelated host sites remain
untouched. Do not run Traefik on the same public IP and ports while the host
Nginx is listening there.

## Development file layout

`scripts/init-dev-sites.sh` creates:

```text
/srv/bitrix-dev/www/
├── dev/public_html/
│   ├── bitrix/
│   ├── upload/
│   └── local/
├── dev1/public_html/
│   ├── bitrix -> ../../dev/public_html/bitrix
│   ├── upload -> ../../dev/public_html/upload
│   └── local/
└── dev2/public_html/
    ├── bitrix -> ../../dev/public_html/bitrix
    ├── upload -> ../../dev/public_html/upload
    └── local/
```

All three names use the same development Percona and Redis. Only the primary
`dev` site runs cron agents. `dev1` and `dev2` can have separate application
code under their own `local` directories.

## Synchronization direction

Synchronization is intentionally one-way: production to development.

```bash
cd /srv/bitrix-dev/env-docker
./scripts/sync-prod-to-dev.sh --prod-root /srv/bitrix-prod/env-docker
./scripts/sync-prod-to-dev.sh --prod-root /srv/bitrix-prod/env-docker --with-upload
```

The script creates a rollback dump of development, dumps production with a
consistent transaction, replaces only the development database, optionally
copies `upload` without deleting development-only files, clears development
caches/Redis and starts cron last.

Create an executable, untracked `scripts/hooks/post-sync-dev.sh` from the
provided example. It must disable or replace production SMTP, payment gateways,
SMS, CRM callbacks and webhooks after every database refresh. This part is
project-specific and therefore cannot safely be guessed by the infrastructure
repository.

Without this executable hook the sync command fails before changing the
development database. `--allow-unsanitized` is available only for a deliberate,
network-isolated test and must not be used for normal refreshes.
