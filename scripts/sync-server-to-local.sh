#!/usr/bin/env bash

set -Eeuo pipefail

ROOT_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)

REMOTE_HOST=${FINNTRAIL_SYNC_HOST:-217.114.11.188}
REMOTE_PORT=${FINNTRAIL_SYNC_PORT:-22}
REMOTE_USER=${FINNTRAIL_SYNC_USER:-finntraildeploy}
REMOTE_PROJECT_ROOT=${FINNTRAIL_SYNC_PROJECT_ROOT:-/srv/finntrail/prod/env-docker}
REMOTE_SITE_ROOT=${FINNTRAIL_SYNC_SITE_ROOT:-/srv/bitrix-prod/www/public_html}
EXPECTED_FINGERPRINT=${FINNTRAIL_SYNC_HOST_FINGERPRINT:-SHA256:DYfuONj+srGjzTaBq9uW07ccYHD0swtBeQLWeOb1DhA}
KEEP_DAYS=${FINNTRAIL_SYNC_KEEP_DAYS:-7}

WITH_UPLOAD=0
ASSUME_YES=0

usage() {
    cat <<'EOF'
Usage: ./scripts/sync-server-to-local.sh [options]

Synchronize production into a local WSL or macOS Docker environment.
SSH public-key authentication is disabled intentionally: the server password is
requested once, then one temporary multiplexed SSH connection is reused by rsync.

Options:
  --with-upload         Also synchronize upload/ (can be tens of gigabytes).
  --host HOST           SSH host (default: 217.114.11.188).
  --port PORT           SSH port (default: 22).
  --user USER           SSH user (default: finntraildeploy).
  --keep-days N         Retain server SQL snapshots for N days (default: 7).
  --yes                 Do not ask before replacing local files and database.
  -h, --help            Show this help.

Environment overrides:
  FINNTRAIL_SYNC_HOST, FINNTRAIL_SYNC_PORT, FINNTRAIL_SYNC_USER,
  FINNTRAIL_SYNC_PROJECT_ROOT, FINNTRAIL_SYNC_SITE_ROOT,
  FINNTRAIL_SYNC_HOST_FINGERPRINT, FINNTRAIL_SYNC_KEEP_DAYS.
EOF
}

while (($#)); do
    case "$1" in
        --with-upload) WITH_UPLOAD=1; shift ;;
        --host) [[ $# -ge 2 ]] || { usage >&2; exit 2; }; REMOTE_HOST=$2; shift 2 ;;
        --port) [[ $# -ge 2 ]] || { usage >&2; exit 2; }; REMOTE_PORT=$2; shift 2 ;;
        --user) [[ $# -ge 2 ]] || { usage >&2; exit 2; }; REMOTE_USER=$2; shift 2 ;;
        --keep-days) [[ $# -ge 2 ]] || { usage >&2; exit 2; }; KEEP_DAYS=$2; shift 2 ;;
        --yes) ASSUME_YES=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
    esac
done

case "$(uname -s)" in
    Darwin) platform=macOS ;;
    Linux)
        if grep -Eqi '(microsoft|wsl)' /proc/sys/kernel/osrelease /proc/version 2>/dev/null; then
            platform=WSL
        else
            echo "This script supports only WSL and macOS." >&2
            exit 1
        fi
        ;;
    *) echo "This script supports only WSL and macOS." >&2; exit 1 ;;
esac

for command_name in docker rsync ssh ssh-keyscan ssh-keygen gzip; do
    command -v "$command_name" >/dev/null 2>&1 || {
        echo "Required command is missing: $command_name" >&2
        exit 1
    }
done

[[ "$REMOTE_HOST" =~ ^[A-Za-z0-9.-]+$ ]] || { echo "Unsafe SSH host." >&2; exit 2; }
[[ "$REMOTE_USER" =~ ^[A-Za-z0-9._-]+$ ]] || { echo "Unsafe SSH user." >&2; exit 2; }
[[ "$REMOTE_PORT" =~ ^[0-9]+$ ]] || { echo "Unsafe SSH port." >&2; exit 2; }
[[ "$KEEP_DAYS" =~ ^[0-9]+$ ]] || { echo "--keep-days must be an integer." >&2; exit 2; }
for remote_path in "$REMOTE_PROJECT_ROOT" "$REMOTE_SITE_ROOT"; do
    [[ "$remote_path" =~ ^/[A-Za-z0-9._/-]+$ ]] || {
        echo "Unsafe remote path: $remote_path" >&2
        exit 2
    }
done

if [[ ! -f "$ROOT_DIR/.env" ]]; then
    echo "Initializing the local environment..."
    "$ROOT_DIR/scripts/init-env.sh" local
fi

env_value() {
    local name=$1
    sed -n "s/^${name}=//p" "$ROOT_DIR/.env" | tail -n 1 | tr -d '\r' | tr -d "'\""
}

app_env=$(env_value APP_ENV)
[[ "$app_env" == local ]] || {
    echo "The current .env must contain APP_ENV=local." >&2
    exit 1
}

www_path=$(env_value WWW_PATH)
backup_path=$(env_value BACKUP_PATH)
case "$www_path:$backup_path" in
    :*|*:|/:*|*:/) echo "WWW_PATH or BACKUP_PATH is empty/unsafe." >&2; exit 1 ;;
esac
case "$www_path" in /*) local_www=$www_path ;; *) local_www="$ROOT_DIR/${www_path#./}" ;; esac
case "$backup_path" in /*) local_backups=$backup_path ;; *) local_backups="$ROOT_DIR/${backup_path#./}" ;; esac
LOCAL_SITE_ROOT="$local_www/public_html"

if ((ASSUME_YES == 0)); then
    printf 'Replace local database and files in %s from %s@%s? [y/N] ' \
        "$LOCAL_SITE_ROOT" "$REMOTE_USER" "$REMOTE_HOST"
    read -r answer
    case "$answer" in y|Y|yes|YES) ;; *) echo "Cancelled."; exit 1 ;; esac
fi

# Keep ControlPath short enough for the macOS Unix-domain socket limit.
work_dir=$(mktemp -d /tmp/finntrail-sync.XXXXXX)
control_socket="$work_dir/ssh.sock"
known_hosts="$work_dir/known_hosts"

cleanup() {
    status=$?
    trap - EXIT HUP INT TERM
    ssh \
        -p "$REMOTE_PORT" \
        -o "ControlPath=$control_socket" \
        -O exit \
        "$REMOTE_USER@$REMOTE_HOST" >/dev/null 2>&1 || true
    rm -rf -- "$work_dir"
    exit "$status"
}
trap cleanup EXIT HUP INT TERM

ssh-keyscan -T 10 -p "$REMOTE_PORT" -t ed25519 "$REMOTE_HOST" 2>/dev/null > "$known_hosts"
[[ -s "$known_hosts" ]] || {
    echo "Could not read the server ED25519 host key." >&2
    exit 1
}

actual_fingerprint=$(ssh-keygen -E sha256 -lf "$known_hosts" | awk 'NR == 1 { print $2 }')
[[ "$actual_fingerprint" == "$EXPECTED_FINGERPRINT" ]] || {
    echo "SSH host fingerprint mismatch." >&2
    echo "Expected: $EXPECTED_FINGERPRINT" >&2
    echo "Received: $actual_fingerprint" >&2
    exit 1
}

SSH_OPTIONS=(
    -p "$REMOTE_PORT"
    -o "UserKnownHostsFile=$known_hosts"
    -o StrictHostKeyChecking=yes
    -o PubkeyAuthentication=no
    -o PreferredAuthentications=keyboard-interactive,password
    -o NumberOfPasswordPrompts=3
    -o ServerAliveInterval=15
    -o ServerAliveCountMax=20
    -o ControlMaster=auto
    -o ControlPersist=10m
    -o "ControlPath=$control_socket"
)

echo "Opening password-authenticated SSH connection to $REMOTE_USER@$REMOTE_HOST..."
ssh "${SSH_OPTIONS[@]}" -N -f "$REMOTE_USER@$REMOTE_HOST"

snapshot_log="$work_dir/snapshot.log"
echo "Creating a fresh database backup on the server..."
ssh "${SSH_OPTIONS[@]}" "$REMOTE_USER@$REMOTE_HOST" \
    bash -s -- \
        --project-root "$REMOTE_PROJECT_ROOT" \
        --site-root "$REMOTE_SITE_ROOT" \
        --keep-days "$KEEP_DAYS" \
    < "$ROOT_DIR/scripts/create-local-sync-snapshot.sh" | tee "$snapshot_log"

remote_snapshot=$(sed -n 's/^SNAPSHOT_DIR=//p' "$snapshot_log" | tail -n 1)
case "$remote_snapshot" in
    "$REMOTE_PROJECT_ROOT"/backups/local-sync/*) ;;
    *) echo "The server returned an unsafe snapshot path: $remote_snapshot" >&2; exit 1 ;;
esac

snapshot_id=${remote_snapshot##*/}
local_snapshot="$local_backups/local-sync/$snapshot_id"
mkdir -p "$local_snapshot" "$LOCAL_SITE_ROOT"

RSYNC_RSH="ssh -p $REMOTE_PORT -o UserKnownHostsFile=$known_hosts -o StrictHostKeyChecking=yes -o PubkeyAuthentication=no -o PreferredAuthentications=keyboard-interactive,password -o ServerAliveInterval=15 -o ServerAliveCountMax=20 -o ControlMaster=no -o ControlPath=$control_socket"

progress_option=--progress
if rsync --help 2>&1 | grep -q -- '--info'; then
    progress_option=--info=progress2
fi

echo "Downloading SQL backup..."
rsync \
    -rlpt \
    --partial \
    --human-readable \
    "$progress_option" \
    -e "$RSYNC_RSH" \
    "$REMOTE_USER@$REMOTE_HOST:$remote_snapshot/" \
    "$local_snapshot/"

expected_checksum=$(awk 'NR == 1 { print $1 }' "$local_snapshot/database.sql.gz.sha256")
if command -v sha256sum >/dev/null 2>&1; then
    actual_checksum=$(sha256sum "$local_snapshot/database.sql.gz" | awk '{ print $1 }')
else
    actual_checksum=$(shasum -a 256 "$local_snapshot/database.sql.gz" | awk '{ print $1 }')
fi
[[ "$actual_checksum" == "$expected_checksum" ]] || {
    echo "Downloaded SQL backup checksum mismatch." >&2
    exit 1
}

exclude_file="$work_dir/rsync-excludes.txt"
cat > "$exclude_file" <<'EOF'
/.git/
/.env
/.env.*
/bitrix/backup/
/bitrix/cache/
/bitrix/html_pages/
/bitrix/managed_cache/
/bitrix/stack_cache/
/bitrix/tmp/
/bitrix/.settings.php.*
/bitrix/.settings_extra.php.*
/bitrix/php_interface/dbconn.php.*
/local/php_interface/include/constants.php
/upload/catalog.xml
/upload/catalog_files/
/upload/resize_cache/
/upload/tmp/
EOF
if ((WITH_UPLOAD == 0)); then
    printf '/upload/\n' >> "$exclude_file"
fi

echo "Stopping local web and cron containers..."
"$ROOT_DIR/scripts/compose.sh" stop cron nginx php >/dev/null 2>&1 || true

echo "Synchronizing production files with rsync..."
rsync \
    -rlptH \
    --delete-after \
    --partial \
    --human-readable \
    "$progress_option" \
    --exclude-from="$exclude_file" \
    -e "$RSYNC_RSH" \
    "$REMOTE_USER@$REMOTE_HOST:$REMOTE_SITE_ROOT/" \
    "$LOCAL_SITE_ROOT/"

constants_file="$LOCAL_SITE_ROOT/local/php_interface/include/constants.php"
constants_example="$LOCAL_SITE_ROOT/local/php_interface/include/constants.example.php"
if [[ ! -e "$constants_file" && -f "$constants_example" ]]; then
    cp -p "$constants_example" "$constants_file"
    echo "Created local constants.php from constants.example.php."
fi

echo "Applying local development permissions..."
find "$LOCAL_SITE_ROOT" -xdev \
    -path "$LOCAL_SITE_ROOT/.git" -prune -o \
    -type d -exec chmod a+rwx {} +
find "$LOCAL_SITE_ROOT" -xdev \
    -path "$LOCAL_SITE_ROOT/.git" -prune -o \
    -type f -exec chmod a+rw {} +

mysql_database=$(env_value MYSQL_DATABASE)
mysql_user=$(env_value MYSQL_USER)
mysql_password=$(env_value MYSQL_PASSWORD)
redis_password=$(env_value REDIS_PASSWORD)

for value_name in mysql_database mysql_user mysql_password redis_password; do
    [[ -n "${!value_name}" ]] || {
        echo "Required local setting is empty: $value_name" >&2
        exit 1
    }
done

echo "Starting the local database and Redis..."
"$ROOT_DIR/scripts/compose.sh" up -d --wait mysql redis

echo "Replacing the local database..."
"$ROOT_DIR/scripts/compose.sh" exec -T mysql sh -ec '
    database=${MYSQL_DATABASE:-${MARIADB_DATABASE:-}}
    root_password=${MYSQL_ROOT_PASSWORD:-${MARIADB_ROOT_PASSWORD:-}}
    case "$database" in
        ""|*[!A-Za-z0-9_]*) echo "Unsafe database name." >&2; exit 1 ;;
    esac
    [ -n "$root_password" ] || { echo "Root password is unavailable." >&2; exit 1; }
    export MYSQL_PWD=$root_password
    if command -v mysql >/dev/null 2>&1; then
        exec mysql --protocol=socket -uroot -e "DROP DATABASE IF EXISTS \`$database\`; CREATE DATABASE \`$database\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"
    fi
    exec mariadb --protocol=socket -uroot -e "DROP DATABASE IF EXISTS \`$database\`; CREATE DATABASE \`$database\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"
'

gzip -dc "$local_snapshot/database.sql.gz" | \
    "$ROOT_DIR/scripts/compose.sh" exec -T mysql sh -ec '
        database=${MYSQL_DATABASE:-${MARIADB_DATABASE:-}}
        root_password=${MYSQL_ROOT_PASSWORD:-${MARIADB_ROOT_PASSWORD:-}}
        export MYSQL_PWD=$root_password
        if command -v mysql >/dev/null 2>&1; then
            exec mysql --protocol=socket -uroot "$database"
        fi
        exec mariadb --protocol=socket -uroot "$database"
    '

echo "Applying local Bitrix connection settings..."
"$ROOT_DIR/scripts/compose.sh" run --rm --no-deps \
    --user "$(id -u):$(id -g)" \
    -e "LOCAL_DB_NAME=$mysql_database" \
    -e "LOCAL_DB_USER=$mysql_user" \
    -e "LOCAL_DB_PASSWORD=$mysql_password" \
    -e "LOCAL_REDIS_PASSWORD=$redis_password" \
    -v "$ROOT_DIR/scripts/configure-local-bitrix.php:/tmp/configure-local-bitrix.php:ro" \
    php php /tmp/configure-local-bitrix.php /opt/www/public_html

clear_directory() {
    local directory=$1
    local entry
    shopt -s nullglob dotglob
    for entry in "$directory"/*; do
        rm -rf -- "$entry"
    done
    shopt -u nullglob dotglob
}

for cache_dir in \
    "$LOCAL_SITE_ROOT/bitrix/cache" \
    "$LOCAL_SITE_ROOT/bitrix/managed_cache" \
    "$LOCAL_SITE_ROOT/bitrix/stack_cache" \
    "$LOCAL_SITE_ROOT/bitrix/html_pages"; do
    mkdir -p "$cache_dir"
    clear_directory "$cache_dir"
    chmod 0777 "$cache_dir"
done

"$ROOT_DIR/scripts/compose.sh" exec -T redis sh -ec \
    'redis-cli --no-auth-warning -a "$REDIS_PASSWORD" FLUSHALL' >/dev/null

if [[ -x "$ROOT_DIR/scripts/hooks/post-sync-local.sh" ]]; then
    FINNTRAIL_LOCAL_SITE_ROOT=$LOCAL_SITE_ROOT \
    FINNTRAIL_LOCAL_SNAPSHOT_DIR=$local_snapshot \
        "$ROOT_DIR/scripts/hooks/post-sync-local.sh"
fi

echo "Starting the local site (cron remains stopped intentionally)..."
"$ROOT_DIR/scripts/compose.sh" up -d mysql redis mailpit php nginx
"$ROOT_DIR/scripts/compose.sh" stop cron >/dev/null 2>&1 || true
"$ROOT_DIR/scripts/compose.sh" ps

trap - EXIT HUP INT TERM
ssh \
    -p "$REMOTE_PORT" \
    -o "ControlPath=$control_socket" \
    -O exit \
    "$REMOTE_USER@$REMOTE_HOST" >/dev/null 2>&1 || true
rm -rf -- "$work_dir"

echo
echo "Synchronization completed on $platform."
echo "Local URL: https://finntrail.local"
echo "Mailpit URL: http://127.0.0.1:8025"
echo "SQL snapshot: $local_snapshot/database.sql.gz"
if ((WITH_UPLOAD == 0)); then
    echo "upload/ was left unchanged. Use --with-upload for the full media sync."
fi
