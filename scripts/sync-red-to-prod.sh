#!/usr/bin/env bash
set -Eeuo pipefail

umask 077

ROOT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
ENV_FILE="$ROOT_DIR/.env"
COMPOSE="$ROOT_DIR/scripts/compose.sh"

if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
    echo "Run this script as root: sudo $0" >&2
    exit 1
fi

if [[ ! -f "$ENV_FILE" ]]; then
    echo ".env is missing: $ENV_FILE" >&2
    exit 1
fi

set -a
# shellcheck source=/dev/null
source "$ENV_FILE"
set +a

case ${APP_ENV:-} in
    production|prod) ;;
    *) echo "This script is only for APP_ENV=production." >&2; exit 1 ;;
esac

if ! command -v flock >/dev/null 2>&1; then
    echo "flock is required (Debian package: util-linux)." >&2
    exit 1
fi

exec 9>/run/lock/finntrail-red-to-prod.lock
if ! flock -n 9; then
    echo "Another red-to-production synchronization is already running." >&2
    exit 1
fi

case ${BACKUP_PATH:-} in
    ""|/) echo "BACKUP_PATH is empty or unsafe." >&2; exit 1 ;;
    /*) backup_root=${BACKUP_PATH%/} ;;
    *) backup_root="$ROOT_DIR/${BACKUP_PATH#./}" ;;
esac

SYNC_RUN_DIR="$backup_root/red-to-prod/$(date -u +%Y%m%dT%H%M%SZ)"
export SYNC_RUN_DIR
install -d -o root -g root -m 0700 "$SYNC_RUN_DIR"

exec > >(tee -a "$SYNC_RUN_DIR/sync.log") 2>&1

web_stopped=0
report_failure() {
    status=$?
    if [[ $status -ne 0 ]]; then
        echo "Synchronization failed with exit code $status." >&2
        if [[ $web_stopped -eq 1 ]]; then
            echo "Docker nginx/php/cron remain stopped. Fix the error and rerun the same command." >&2
        fi
    fi
}
trap report_failure EXIT

echo "Synchronization started: $(date --iso-8601=seconds)"
echo "Run directory: $SYNC_RUN_DIR"

"$COMPOSE" up -d --wait mysql redis
"$COMPOSE" stop -t 60 cron nginx php
web_stopped=1

"$ROOT_DIR/scripts/sync-red-files.sh"
"$ROOT_DIR/scripts/sync-red-db.sh"

case ${WWW_PATH:-} in
    /*) www_root=${WWW_PATH%/} ;;
    *) www_root="$ROOT_DIR/${WWW_PATH#./}" ;;
esac
dest_root="$www_root/public_html"
target_uid=${TOOLS_UID:-979}
target_gid=${TOOLS_GID:-979}

echo "Clearing filesystem and Redis caches..."
for relative_path in \
    bitrix/cache \
    bitrix/managed_cache \
    bitrix/stack_cache \
    bitrix/html_pages
do
    cache_path="$dest_root/$relative_path"
    install -d -o "$target_uid" -g "$target_gid" -m 0775 "$cache_path"
    find "$cache_path" -xdev -mindepth 1 -delete
done

# These Redis databases belong only to this Docker project:
# DB 0 is Bitrix cache, DB 1 is PHP sessions.
# shellcheck disable=SC2016
"$COMPOSE" exec -T redis sh -ec '
    for database in 0 1; do
        redis-cli --no-auth-warning -a "$REDIS_PASSWORD" -n "$database" FLUSHDB >/dev/null
    done
'

echo "Starting production containers..."
"$COMPOSE" up -d --wait php nginx
"$COMPOSE" up -d --wait cron
web_stopped=0

"$COMPOSE" ps -a

trap - EXIT
echo "Synchronization completed: $(date --iso-8601=seconds)"
echo "Logs and normalized database dump: $SYNC_RUN_DIR"
