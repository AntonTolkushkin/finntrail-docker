#!/usr/bin/env bash

set -Eeuo pipefail

PROJECT_ROOT=/srv/finntrail/prod/env-docker
SITE_ROOT=/srv/bitrix-prod/www/public_html
KEEP_DAYS=7
OUTPUT_ROOT=

usage() {
    cat <<'EOF'
Usage: create-local-sync-snapshot.sh [options]

Create a consistent SQL snapshot for scripts/sync-server-to-local.sh.

Options:
  --project-root PATH  Production env-docker checkout.
  --site-root PATH     Production Bitrix document root (metadata only).
  --output-root PATH   Snapshot directory (default: PROJECT_ROOT/backups/local-sync).
  --keep-days N        Remove successful snapshots older than N days; 0 disables cleanup.
  -h, --help           Show this help.
EOF
}

while (($#)); do
    case "$1" in
        --project-root)
            [[ $# -ge 2 ]] || { usage >&2; exit 2; }
            PROJECT_ROOT=$2
            shift 2
            ;;
        --site-root)
            [[ $# -ge 2 ]] || { usage >&2; exit 2; }
            SITE_ROOT=$2
            shift 2
            ;;
        --output-root)
            [[ $# -ge 2 ]] || { usage >&2; exit 2; }
            OUTPUT_ROOT=$2
            shift 2
            ;;
        --keep-days)
            [[ $# -ge 2 ]] || { usage >&2; exit 2; }
            KEEP_DAYS=$2
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Unknown option: $1" >&2
            usage >&2
            exit 2
            ;;
    esac
done

case "$PROJECT_ROOT:$SITE_ROOT" in
    /*:/*) ;;
    *) echo "Project and site roots must be absolute paths." >&2; exit 2 ;;
esac

[[ "$KEEP_DAYS" =~ ^[0-9]+$ ]] || {
    echo "--keep-days must be a non-negative integer." >&2
    exit 2
}

[[ -x "$PROJECT_ROOT/scripts/compose.sh" ]] || {
    echo "Compose wrapper not found: $PROJECT_ROOT/scripts/compose.sh" >&2
    exit 1
}
[[ -f "$PROJECT_ROOT/.env" ]] || {
    echo "Production .env not found: $PROJECT_ROOT/.env" >&2
    exit 1
}
[[ -d "$SITE_ROOT" ]] || {
    echo "Site root not found: $SITE_ROOT" >&2
    exit 1
}

app_env=$(sed -n 's/^APP_ENV=//p' "$PROJECT_ROOT/.env" | tail -n 1 | tr -d '\r' | tr -d "'\"")
case "$app_env" in
    production|prod) ;;
    *) echo "Refusing to dump a non-production project (APP_ENV=$app_env)." >&2; exit 1 ;;
esac

OUTPUT_ROOT=${OUTPUT_ROOT:-$PROJECT_ROOT/backups/local-sync}
case "$OUTPUT_ROOT" in
    /|"$PROJECT_ROOT")
        echo "Unsafe snapshot output path: $OUTPUT_ROOT" >&2
        exit 1
        ;;
    /*) ;;
    *) echo "--output-root must be an absolute path." >&2; exit 2 ;;
esac

umask 077
mkdir -p "$OUTPUT_ROOT"

if command -v flock >/dev/null 2>&1; then
    exec 9>"$OUTPUT_ROOT/.snapshot.lock"
    flock -n 9 || {
        echo "Another local-sync snapshot is already running." >&2
        exit 1
    }
fi

snapshot_id="$(date -u +%Y%m%dT%H%M%SZ)-$$"
snapshot_dir="$OUTPUT_ROOT/$snapshot_id"
dump_file="$snapshot_dir/database.sql.gz"
snapshot_complete=0

cleanup() {
    status=${1:-$?}
    trap - EXIT HUP INT TERM
    if ((status != 0 || snapshot_complete == 0)); then
        case "$snapshot_dir" in
            "$OUTPUT_ROOT"/*) rm -rf -- "$snapshot_dir" ;;
        esac
    fi
    exit "$status"
}
trap 'cleanup $?' EXIT
trap 'cleanup 129' HUP
trap 'cleanup 130' INT
trap 'cleanup 143' TERM

mkdir -p "$snapshot_dir"
cd "$PROJECT_ROOT"

echo "Creating production SQL snapshot: $dump_file"
"$PROJECT_ROOT/scripts/compose.sh" up -d --wait mysql >/dev/null

"$PROJECT_ROOT/scripts/compose.sh" exec -T mysql sh -ec '
    database=${MYSQL_DATABASE:-${MARIADB_DATABASE:-}}
    root_password=${MYSQL_ROOT_PASSWORD:-${MARIADB_ROOT_PASSWORD:-}}

    [ -n "$database" ] || {
        echo "Database name is unavailable in the mysql container." >&2
        exit 1
    }
    [ -n "$root_password" ] || {
        echo "Root password is unavailable in the mysql container." >&2
        exit 1
    }

    export MYSQL_PWD=$root_password

    if command -v mysqldump >/dev/null 2>&1; then
        exec mysqldump \
            --protocol=socket \
            --single-transaction \
            --quick \
            --hex-blob \
            --routines \
            --triggers \
            --events \
            --no-tablespaces \
            --set-gtid-purged=OFF \
            -uroot \
            "$database"
    fi

    if command -v mariadb-dump >/dev/null 2>&1; then
        exec mariadb-dump \
            --single-transaction \
            --quick \
            --hex-blob \
            --routines \
            --triggers \
            --events \
            -uroot \
            "$database"
    fi

    echo "Neither mysqldump nor mariadb-dump exists in the mysql container." >&2
    exit 1
' </dev/null | gzip -1 > "$dump_file"

gzip -t "$dump_file"

(
    cd "$snapshot_dir"
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum database.sql.gz > database.sql.gz.sha256
    else
        shasum -a 256 database.sql.gz > database.sql.gz.sha256
    fi
)

infra_commit=$(git -c safe.directory="$PROJECT_ROOT" -C "$PROJECT_ROOT" rev-parse HEAD 2>/dev/null || printf unknown)
site_commit=$(git -c safe.directory="$SITE_ROOT" -C "$SITE_ROOT" rev-parse HEAD 2>/dev/null || printf unknown)

cat > "$snapshot_dir/snapshot.env" <<EOF
SNAPSHOT_ID=$snapshot_id
CREATED_UTC=$(date -u +%Y-%m-%dT%H:%M:%SZ)
PROJECT_ROOT=$PROJECT_ROOT
SITE_ROOT=$SITE_ROOT
INFRA_COMMIT=$infra_commit
SITE_COMMIT=$site_commit
DUMP_FILE=database.sql.gz
EOF

snapshot_complete=1

if ((KEEP_DAYS > 0)); then
    find "$OUTPUT_ROOT" \
        -mindepth 1 \
        -maxdepth 1 \
        -type d \
        -name '20*T*-*' \
        -mtime "+$KEEP_DAYS" \
        -exec rm -rf -- {} +
fi

trap - EXIT HUP INT TERM
printf 'SNAPSHOT_DIR=%s\n' "$snapshot_dir"
