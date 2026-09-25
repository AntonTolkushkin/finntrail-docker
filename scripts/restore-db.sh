#!/usr/bin/env sh
set -eu

ROOT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
ASSUME_YES=0
REPLACE_DATABASE=0

while [ "$#" -gt 0 ]; do
    case "$1" in
        --yes) ASSUME_YES=1; shift ;;
        --replace-database) REPLACE_DATABASE=1; shift ;;
        --) shift; break ;;
        -*) echo "Unknown option: $1" >&2; exit 2 ;;
        *) break ;;
    esac
done

DUMP_FILE=${1:-}
if [ -z "$DUMP_FILE" ] || [ ! -f "$DUMP_FILE" ]; then
    echo "Usage: $0 [--yes] [--replace-database] /path/to/dump.sql[.gz]" >&2
    exit 2
fi

if [ ! -f "$ROOT_DIR/.env" ]; then
    echo ".env is missing." >&2
    exit 1
fi

if [ "$ASSUME_YES" -ne 1 ]; then
    printf 'This will overwrite data in the configured Bitrix database. Continue? [y/N] '
    read -r answer
    case "$answer" in
        y|Y|yes|YES) ;;
        *) echo "Cancelled."; exit 1 ;;
    esac
fi

cd "$ROOT_DIR"
"$ROOT_DIR/scripts/compose.sh" up -d --wait mysql

if [ "$REPLACE_DATABASE" -eq 1 ]; then
    # A strict identifier check makes the quoted DROP/CREATE operation safe.
    # shellcheck disable=SC2016
    "$ROOT_DIR/scripts/compose.sh" exec -T mysql sh -ec '
        case "$MYSQL_DATABASE" in
            ""|*[!A-Za-z0-9_]*) echo "Unsafe MYSQL_DATABASE" >&2; exit 1 ;;
        esac
        export MYSQL_PWD="$MYSQL_ROOT_PASSWORD"
        mysql --protocol=socket -uroot -e \
          "DROP DATABASE IF EXISTS \`$MYSQL_DATABASE\`; CREATE DATABASE \`$MYSQL_DATABASE\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"
    '
fi

case "$DUMP_FILE" in
    *.gz)
        # Expanded by the shell inside the Percona container.
        # shellcheck disable=SC2016
        gzip -dc "$DUMP_FILE" | "$ROOT_DIR/scripts/compose.sh" exec -T mysql sh -ec \
            'export MYSQL_PWD="$MYSQL_ROOT_PASSWORD"; exec mysql --protocol=socket -uroot "$MYSQL_DATABASE"'
        ;;
    *)
        # Expanded by the shell inside the Percona container.
        # shellcheck disable=SC2016
        "$ROOT_DIR/scripts/compose.sh" exec -T mysql sh -ec \
            'export MYSQL_PWD="$MYSQL_ROOT_PASSWORD"; exec mysql --protocol=socket -uroot "$MYSQL_DATABASE"' < "$DUMP_FILE"
        ;;
esac

echo "Database restore completed."
