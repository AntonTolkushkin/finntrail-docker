#!/usr/bin/env bash
set -Eeuo pipefail

umask 077

ROOT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
ENV_FILE="$ROOT_DIR/.env"
COMPOSE="$ROOT_DIR/scripts/compose.sh"
NORMALIZER="$ROOT_DIR/scripts/sql/normalize-red-dump.awk"
AFTER_IMPORT_SQL="$ROOT_DIR/scripts/sql/red-to-prod-after-import.sql.dist"

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

SOURCE_DB=${RED_SYNC_SOURCE_DB:-redfinntrail}
case "$SOURCE_DB" in
    ""|*[!A-Za-z0-9_]*) echo "Unsafe source database name: $SOURCE_DB" >&2; exit 1 ;;
esac
case ${MYSQL_DATABASE:-} in
    ""|*[!A-Za-z0-9_]*) echo "Unsafe destination MYSQL_DATABASE." >&2; exit 1 ;;
esac

for required_command in mariadb-dump awk gzip; do
    if ! command -v "$required_command" >/dev/null 2>&1; then
        echo "Required command is missing: $required_command" >&2
        exit 1
    fi
done

if [[ -z ${SYNC_RUN_DIR:-} ]]; then
    case ${BACKUP_PATH:-} in
        ""|/) echo "BACKUP_PATH is empty or unsafe." >&2; exit 1 ;;
        /*) backup_root=${BACKUP_PATH%/} ;;
        *) backup_root="$ROOT_DIR/${BACKUP_PATH#./}" ;;
    esac
    SYNC_RUN_DIR="$backup_root/red-to-prod/$(date -u +%Y%m%dT%H%M%SZ)"
fi

install -d -o root -g root -m 0700 "$SYNC_RUN_DIR"

DUMP_FILE="$SYNC_RUN_DIR/${SOURCE_DB}-normalized.sql.gz"
DUMP_PART="$DUMP_FILE.partial"

dump_command=(mariadb-dump)
if [[ -n ${RED_SYNC_DB_DEFAULTS_FILE:-} ]]; then
    if [[ ! -f "$RED_SYNC_DB_DEFAULTS_FILE" ]]; then
        echo "MariaDB defaults file is missing: $RED_SYNC_DB_DEFAULTS_FILE" >&2
        exit 1
    fi
    dump_command+=("--defaults-extra-file=$RED_SYNC_DB_DEFAULTS_FILE")
fi
dump_command+=(
    --single-transaction
    --quick
    --skip-lock-tables
    --hex-blob
    --routines
    --triggers
    --events
    --default-character-set=utf8mb4
    "$SOURCE_DB"
)

cleanup_partial_dump() {
    rm -f -- "$DUMP_PART"
}
trap cleanup_partial_dump EXIT HUP INT TERM

echo "Creating normalized source dump: $DUMP_FILE"
"${dump_command[@]}" \
    | awk -f "$NORMALIZER" \
    | gzip -1 > "$DUMP_PART"

mv -- "$DUMP_PART" "$DUMP_FILE"
trap - EXIT HUP INT TERM

echo "Replacing Docker database: $MYSQL_DATABASE"
"$COMPOSE" up -d --wait mysql >/dev/null

# MYSQL_DATABASE was restricted to a safe SQL identifier above.
# shellcheck disable=SC2016
"$COMPOSE" exec -T mysql sh -ec '
    export MYSQL_PWD="$MYSQL_ROOT_PASSWORD"
    mysql --protocol=socket -uroot -e \
      "DROP DATABASE IF EXISTS \`$MYSQL_DATABASE\`; CREATE DATABASE \`$MYSQL_DATABASE\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"
'

gzip -dc "$DUMP_FILE" \
    | "$COMPOSE" exec -T mysql sh -ec \
        'export MYSQL_PWD="$MYSQL_ROOT_PASSWORD"; exec mysql --protocol=socket -uroot "$MYSQL_DATABASE"'

# shellcheck disable=SC2016
"$COMPOSE" exec -T mysql sh -ec \
    'export MYSQL_PWD="$MYSQL_ROOT_PASSWORD"; exec mysql --protocol=socket -uroot "$MYSQL_DATABASE"' \
    < "$AFTER_IMPORT_SQL"

# One inexpensive guard prevents starting the site with a partly normalized DB.
# shellcheck disable=SC2016
legacy_columns=$("$COMPOSE" exec -T mysql sh -ec '
    export MYSQL_PWD="$MYSQL_ROOT_PASSWORD"
    mysql --protocol=socket -uroot "$MYSQL_DATABASE" --batch --skip-column-names -e \
      "SELECT COUNT(*) FROM information_schema.COLUMNS WHERE TABLE_SCHEMA = DATABASE() AND CHARACTER_SET_NAME IN ('"'"'utf8'"'"', '"'"'utf8mb3'"'"');"
')

if [[ $legacy_columns != 0 ]]; then
    echo "Database still contains $legacy_columns utf8/utf8mb3 columns." >&2
    exit 1
fi

echo "Database synchronization completed. Normalized source dump: $DUMP_FILE"
