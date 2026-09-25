#!/usr/bin/env sh
set -eu

ROOT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
ENV_FILE="$ROOT_DIR/.env"

if [ ! -f "$ENV_FILE" ]; then
    echo ".env is missing." >&2
    exit 1
fi

set -a
# shellcheck source=/dev/null
. "$ENV_FILE"
set +a

case ${WWW_PATH:-} in
    ""|/|/srv|/srv/)
        echo "WWW_PATH is empty or too broad; refusing to change ownership." >&2
        exit 1
        ;;
esac

case "$WWW_PATH" in
    /*) SITE_DIR=$WWW_PATH ;;
    *) SITE_DIR="$ROOT_DIR/${WWW_PATH#./}" ;;
esac

if [ ! -d "$SITE_DIR" ]; then
    echo "Site directory does not exist: $SITE_DIR" >&2
    exit 1
fi

echo "Site directory: $SITE_DIR"
target_uid=${TOOLS_UID:-979}
target_gid=${TOOLS_GID:-979}
case "$target_uid:$target_gid" in
    *[!0-9:]*) echo "TOOLS_UID/TOOLS_GID must be numeric." >&2; exit 1 ;;
esac
printf 'Recursively set owner to container UID/GID %s:%s? [y/N] ' "$target_uid" "$target_gid"
read -r answer
case "$answer" in
    y|Y|yes|YES) ;;
    *) echo "Cancelled."; exit 1 ;;
esac

chown -R "$target_uid:$target_gid" "$SITE_DIR"
find "$SITE_DIR" -type d -exec chmod 0755 {} +
find "$SITE_DIR" -type f -exec chmod 0644 {} +
echo "Permissions updated."
