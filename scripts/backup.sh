#!/usr/bin/env sh
set -eu

ROOT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
ENV_FILE="$ROOT_DIR/.env"

if [ ! -f "$ENV_FILE" ]; then
    echo ".env is missing." >&2
    exit 1
fi

set -a
# .env is a trusted file generated and owned by the deploy user.
# shellcheck source=/dev/null
. "$ENV_FILE"
set +a

case ${BACKUP_PATH:-} in
    ""|/)
        echo "BACKUP_PATH is empty or unsafe." >&2
        exit 1
        ;;
esac

case ${WWW_PATH:-} in
    ""|/)
        echo "WWW_PATH is empty or unsafe." >&2
        exit 1
        ;;
esac

resolve_path() {
    case "$1" in
        /*) printf '%s\n' "$1" ;;
        *) printf '%s/%s\n' "$ROOT_DIR" "${1#./}" ;;
    esac
}

BACKUP_DIR=$(resolve_path "$BACKUP_PATH")
SITE_DIR=$(resolve_path "$WWW_PATH")
TIMESTAMP=$(date -u +%Y%m%dT%H%M%SZ)
DB_FILE="$BACKUP_DIR/mysql-$TIMESTAMP.sql.gz"
FILES_FILE="$BACKUP_DIR/www-$TIMESTAMP.tar.gz"

mkdir -p "$BACKUP_DIR"
cd "$ROOT_DIR"

# Expanded by the shell inside the Percona container.
# shellcheck disable=SC2016
"$ROOT_DIR/scripts/compose.sh" exec -T mysql sh -ec '
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
    | gzip -9 > "$DB_FILE"

tar \
    --exclude='./public_html/bitrix/cache/*' \
    --exclude='./public_html/bitrix/managed_cache/*' \
    --exclude='./public_html/bitrix/stack_cache/*' \
    --exclude='./public_html/upload/tmp/*' \
    -C "$SITE_DIR" -czf "$FILES_FILE" .

if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$DB_FILE" "$FILES_FILE" > "$BACKUP_DIR/sha256-$TIMESTAMP.txt"
fi

echo "Database backup: $DB_FILE"
echo "Files backup:    $FILES_FILE"
echo "Copy these files to storage outside this server."
