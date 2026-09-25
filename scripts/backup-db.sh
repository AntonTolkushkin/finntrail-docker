#!/usr/bin/env sh
set -eu

ROOT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
ENV_FILE="$ROOT_DIR/.env"

if [ ! -f "$ENV_FILE" ]; then
    echo ".env is missing." >&2
    exit 1
fi

backup_path=$(sed -n 's/^BACKUP_PATH=//p' "$ENV_FILE" | tail -n 1 | tr -d '\r' | tr -d "'\"")
case "$backup_path" in
    ""|/)
        echo "BACKUP_PATH is empty or unsafe." >&2
        exit 1
        ;;
    /*) backup_dir=$backup_path ;;
    *) backup_dir="$ROOT_DIR/${backup_path#./}" ;;
esac

timestamp=$(date -u +%Y%m%dT%H%M%SZ)
dump_file="$backup_dir/mysql-$timestamp.sql.gz"
mkdir -p "$backup_dir"

"$ROOT_DIR/scripts/compose.sh" up -d --wait mysql >/dev/null
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
    | gzip -6 > "$dump_file"

if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$dump_file" > "$dump_file.sha256"
fi

printf '%s\n' "$dump_file"
