#!/usr/bin/env bash
set -Eeuo pipefail

umask 077

ROOT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
ENV_FILE="$ROOT_DIR/.env"

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

SOURCE_ROOT=${RED_SYNC_SOURCE_ROOT:-/var/www/red.finntrail.ru/public_html}

case ${WWW_PATH:-} in
    ""|/|/srv|/srv/)
        echo "WWW_PATH is empty or unsafe." >&2
        exit 1
        ;;
    /*) WWW_ROOT=${WWW_PATH%/} ;;
    *) WWW_ROOT="$ROOT_DIR/${WWW_PATH#./}" ;;
esac

DEST_ROOT="$WWW_ROOT/public_html"

if [[ ! -d "$SOURCE_ROOT/bitrix" ]]; then
    echo "Source Bitrix directory is missing: $SOURCE_ROOT/bitrix" >&2
    exit 1
fi

if [[ ! -f "$DEST_ROOT/bitrix/.settings.php" ]]; then
    echo "Destination Docker settings are missing: $DEST_ROOT/bitrix/.settings.php" >&2
    exit 1
fi

SOURCE_ROOT=$(readlink -f -- "$SOURCE_ROOT")
DEST_ROOT=$(readlink -f -- "$DEST_ROOT")
EXPECTED_DEST_ROOT=${RED_SYNC_EXPECTED_DEST_ROOT:-/srv/bitrix-prod/www/public_html}
EXPECTED_DEST_ROOT=$(readlink -f -- "$EXPECTED_DEST_ROOT")

if [[ $DEST_ROOT != "$EXPECTED_DEST_ROOT" ]]; then
    echo "Refusing an unexpected destination: $DEST_ROOT" >&2
    echo "Expected destination: $EXPECTED_DEST_ROOT" >&2
    exit 1
fi

case "$SOURCE_ROOT:$DEST_ROOT" in
    /:*|*:/|/srv:*|*:/srv|"$SOURCE_ROOT:$SOURCE_ROOT")
        echo "Unsafe or identical synchronization paths: $SOURCE_ROOT -> $DEST_ROOT" >&2
        exit 1
        ;;
esac

target_uid=${TOOLS_UID:-979}
target_gid=${TOOLS_GID:-979}
case "$target_uid:$target_gid" in
    *[!0-9:]*) echo "TOOLS_UID/TOOLS_GID must be numeric." >&2; exit 1 ;;
esac

if ! command -v rsync >/dev/null 2>&1; then
    echo "rsync is required." >&2
    exit 1
fi

if [[ -z ${SYNC_RUN_DIR:-} ]]; then
    case ${BACKUP_PATH:-} in
        ""|/) echo "BACKUP_PATH is empty or unsafe." >&2; exit 1 ;;
        /*) backup_root=${BACKUP_PATH%/} ;;
        *) backup_root="$ROOT_DIR/${BACKUP_PATH#./}" ;;
    esac
    SYNC_RUN_DIR="$backup_root/red-to-prod/$(date -u +%Y%m%dT%H%M%SZ)"
fi

install -d -o root -g root -m 0700 "$SYNC_RUN_DIR"
install -d -o "$target_uid" -g "$target_gid" -m 0755 "$DEST_ROOT/upload"

common_options=(
    --archive
    --hard-links
    --numeric-ids
    --delete-delay
    --chown="$target_uid:$target_gid"
    --info=progress2
    --stats
)

echo "Synchronizing site files: $SOURCE_ROOT -> $DEST_ROOT"

rsync "${common_options[@]}" \
    --log-file="$SYNC_RUN_DIR/rsync-code.log" \
    --exclude='/upload/' \
    --exclude='/bitrix/cache/' \
    --exclude='/bitrix/managed_cache/' \
    --exclude='/bitrix/stack_cache/' \
    --exclude='/bitrix/html_pages/' \
    --exclude='/bitrix/.settings.php' \
    --exclude='/bitrix/.settings_extra.php' \
    --exclude='/bitrix/php_interface/dbconn.php' \
    --exclude='/bitrix/php_interface/after_connect.php' \
    --exclude='/bitrix/php_interface/after_connect_d7.php' \
    "$SOURCE_ROOT/" \
    "$DEST_ROOT/"

echo "Synchronizing upload..."

rsync "${common_options[@]}" \
    --log-file="$SYNC_RUN_DIR/rsync-upload.log" \
    --exclude='/catalog_files/' \
    --exclude='/catalog.xml' \
    --exclude='/tmp/' \
    "$SOURCE_ROOT/upload/" \
    "$DEST_ROOT/upload/"

echo "File synchronization completed. Logs: $SYNC_RUN_DIR"
