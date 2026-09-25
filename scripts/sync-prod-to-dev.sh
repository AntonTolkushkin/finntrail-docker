#!/usr/bin/env sh
set -eu

ROOT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
PROD_ROOT=/srv/bitrix-prod/env-docker
WITH_UPLOAD=0
ASSUME_YES=0
ALLOW_UNSANITIZED=0

usage() {
    echo "Usage: $0 [--prod-root PATH] [--with-upload] [--allow-unsanitized] [--yes]" >&2
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --prod-root)
            [ "$#" -ge 2 ] || { usage; exit 2; }
            PROD_ROOT=$2
            shift 2
            ;;
        --with-upload)
            WITH_UPLOAD=1
            shift
            ;;
        --yes)
            ASSUME_YES=1
            shift
            ;;
        --allow-unsanitized)
            ALLOW_UNSANITIZED=1
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            usage
            exit 2
            ;;
    esac
done

if [ ! -f "$ROOT_DIR/.env" ] || [ ! -f "$PROD_ROOT/.env" ]; then
    echo "Both development and production .env files are required." >&2
    exit 1
fi

if [ ! -x "$ROOT_DIR/scripts/hooks/post-sync-dev.sh" ] && [ "$ALLOW_UNSANITIZED" -ne 1 ]; then
    echo "Missing executable scripts/hooks/post-sync-dev.sh." >&2
    echo "Create it from the example to disable production SMTP, payments and webhooks." >&2
    echo "Use --allow-unsanitized only for a deliberate isolated test." >&2
    exit 1
fi

dev_mode=$(sed -n 's/^APP_ENV=//p' "$ROOT_DIR/.env" | tail -n 1 | tr -d '\r' | tr -d "'\"")
prod_mode=$(sed -n 's/^APP_ENV=//p' "$PROD_ROOT/.env" | tail -n 1 | tr -d '\r' | tr -d "'\"")
case "$dev_mode" in development|dev) ;; *) echo "Current project is not development." >&2; exit 1 ;; esac
case "$prod_mode" in production|prod) ;; *) echo "--prod-root is not a production project." >&2; exit 1 ;; esac

dev_project=$(sed -n 's/^COMPOSE_PROJECT_NAME=//p' "$ROOT_DIR/.env" | tail -n 1 | tr -d '\r' | tr -d "'\"")
prod_project=$(sed -n 's/^COMPOSE_PROJECT_NAME=//p' "$PROD_ROOT/.env" | tail -n 1 | tr -d '\r' | tr -d "'\"")
if [ -z "$dev_project" ] || [ -z "$prod_project" ] || [ "$dev_project" = "$prod_project" ]; then
    echo "Production and development COMPOSE_PROJECT_NAME values must be non-empty and different." >&2
    exit 1
fi

if [ "$ASSUME_YES" -ne 1 ]; then
    printf 'Replace development DB %s from production %s? [y/N] ' "$dev_project" "$prod_project"
    read -r answer
    case "$answer" in y|Y|yes|YES) ;; *) echo "Cancelled."; exit 1 ;; esac
fi

if command -v flock >/dev/null 2>&1; then
    lock_file=/tmp/finntrail-prod-to-dev.lock
    exec 9>"$lock_file"
    if ! flock -n 9; then
        echo "Another synchronization is already running." >&2
        exit 1
    fi
fi

echo "Creating a rollback dump of the current development database..."
dev_rollback_dump=$("$ROOT_DIR/scripts/backup-db.sh")
echo "Development rollback dump: $dev_rollback_dump"

dev_backup_path=$(sed -n 's/^BACKUP_PATH=//p' "$ROOT_DIR/.env" | tail -n 1 | tr -d '\r' | tr -d "'\"")
case "$dev_backup_path" in
    ""|/) echo "Development BACKUP_PATH is unsafe." >&2; exit 1 ;;
    /*) sync_dir="$dev_backup_path/sync" ;;
    *) sync_dir="$ROOT_DIR/${dev_backup_path#./}/sync" ;;
esac
mkdir -p "$sync_dir"
prod_dump="$sync_dir/prod-$(date -u +%Y%m%dT%H%M%SZ).sql.gz"

echo "Dumping production database..."
"$PROD_ROOT/scripts/compose.sh" up -d --wait mysql >/dev/null
# shellcheck disable=SC2016
"$PROD_ROOT/scripts/compose.sh" exec -T mysql sh -ec '
    export MYSQL_PWD="$MYSQL_ROOT_PASSWORD"
    exec mysqldump \
        --protocol=socket \
        --single-transaction \
        --quick \
        --routines \
        --triggers \
        --events \
        --hex-blob \
        --no-tablespaces \
        --set-gtid-purged=OFF \
        -uroot \
        "$MYSQL_DATABASE"
' \
    | gzip -6 > "$prod_dump"

cron_stopped=0
restart_cron_on_error() {
    if [ "$cron_stopped" -eq 1 ]; then
        "$ROOT_DIR/scripts/compose.sh" up -d cron >/dev/null 2>&1 || true
    fi
}
trap restart_cron_on_error EXIT HUP INT TERM

"$ROOT_DIR/scripts/compose.sh" stop cron >/dev/null 2>&1 || true
cron_stopped=1
"$ROOT_DIR/scripts/restore-db.sh" --yes --replace-database "$prod_dump"

if [ "$WITH_UPLOAD" -eq 1 ]; then
    if ! command -v rsync >/dev/null 2>&1; then
        echo "rsync is required for --with-upload." >&2
        exit 1
    fi
    prod_www=$(sed -n 's/^WWW_PATH=//p' "$PROD_ROOT/.env" | tail -n 1 | tr -d '\r' | tr -d "'\"")
    dev_www=$(sed -n 's/^WWW_PATH=//p' "$ROOT_DIR/.env" | tail -n 1 | tr -d '\r' | tr -d "'\"")
    case "$prod_www:$dev_www" in *:|:*|/:*|*:/) echo "Unsafe WWW_PATH." >&2; exit 1 ;; esac
    case "$prod_www" in /*) ;; *) prod_www="$PROD_ROOT/${prod_www#./}" ;; esac
    case "$dev_www" in /*) ;; *) dev_www="$ROOT_DIR/${dev_www#./}" ;; esac
    mkdir -p "$dev_www/dev/public_html/upload"
    rsync -a --exclude='tmp/' "$prod_www/public_html/upload/" "$dev_www/dev/public_html/upload/"
fi

dev_www=$(sed -n 's/^WWW_PATH=//p' "$ROOT_DIR/.env" | tail -n 1 | tr -d '\r' | tr -d "'\"")
case "$dev_www" in /*) ;; *) dev_www="$ROOT_DIR/${dev_www#./}" ;; esac
for cache_dir in \
    "$dev_www/dev/public_html/bitrix/cache" \
    "$dev_www/dev/public_html/bitrix/managed_cache" \
    "$dev_www/dev/public_html/bitrix/stack_cache"; do
    if [ -d "$cache_dir" ]; then
        find "$cache_dir" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +
    fi
done

# This Redis belongs only to development; clear Bitrix cache and PHP sessions.
# shellcheck disable=SC2016
"$ROOT_DIR/scripts/compose.sh" exec -T redis sh -ec \
    'redis-cli --no-auth-warning -a "$REDIS_PASSWORD" FLUSHALL' >/dev/null

if [ -x "$ROOT_DIR/scripts/hooks/post-sync-dev.sh" ]; then
    "$ROOT_DIR/scripts/hooks/post-sync-dev.sh"
else
    echo "WARNING: synchronization was explicitly allowed without a sanitization hook." >&2
fi

"$ROOT_DIR/scripts/compose.sh" up -d php nginx
"$ROOT_DIR/scripts/compose.sh" run --rm --no-deps nginx nginx -t
"$ROOT_DIR/scripts/compose.sh" up -d cron
cron_stopped=0
trap - EXIT HUP INT TERM
"$ROOT_DIR/scripts/compose.sh" ps

echo "Production-to-development synchronization completed."
