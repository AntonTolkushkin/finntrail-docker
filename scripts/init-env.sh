#!/usr/bin/env sh
set -eu

ROOT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
MODE=${1:-local}

case "$MODE" in
    local)
        TEMPLATE="$ROOT_DIR/.env.example"
        ;;
    production|prod)
        TEMPLATE="$ROOT_DIR/.env.production.example"
        ;;
    development|dev)
        TEMPLATE="$ROOT_DIR/.env.development.example"
        ;;
    *)
        echo "Usage: $0 [local|production|development]" >&2
        exit 2
        ;;
esac

TARGET="$ROOT_DIR/.env"
if [ -e "$TARGET" ]; then
    echo "$TARGET already exists; it was not overwritten." >&2
    exit 1
fi

initialization_complete=0
cleanup_failed_initialization() {
    status=$?
    trap - 0
    if [ "$status" -ne 0 ] && [ "$initialization_complete" -eq 0 ]; then
        rm -f "$TARGET"
        if [ "$MODE" = "development" ] || [ "$MODE" = "dev" ]; then
            rm -f "$ROOT_DIR/confs/nginx/auth/dev.htpasswd"
        fi
        echo "Initialization failed; generated environment files were removed. Fix the error and run the command again." >&2
    fi
    exit "$status"
}
trap cleanup_failed_initialization 0

if ! command -v openssl >/dev/null 2>&1; then
    echo "openssl is required to generate secrets." >&2
    exit 1
fi

cp "$TEMPLATE" "$TARGET"

replace_value() {
    key=$1
    value=$2
    temp_file="${TARGET}.tmp"
    awk -v key="$key" -v value="$value" '
        index($0, key "=") == 1 { print key "=" value; next }
        { print }
    ' "$TARGET" > "$temp_file"
    mv "$temp_file" "$TARGET"
}

replace_value MYSQL_PASSWORD "$(openssl rand -hex 24)"
replace_value MYSQL_ROOT_PASSWORD "$(openssl rand -hex 24)"
replace_value REDIS_PASSWORD "$(openssl rand -hex 24)"
if [ "$MODE" = "development" ] || [ "$MODE" = "dev" ]; then
    dev_password=$(openssl rand -hex 16)
    replace_value DEV_BASIC_AUTH_PASSWORD "$dev_password"
    dev_auth_user=$(sed -n 's/^DEV_BASIC_AUTH_USER=//p' "$TARGET" | tail -n 1 | tr -d '\r' | tr -d "'\"")
    case "$dev_auth_user" in
        ""|*[!A-Za-z0-9_.-]*)
            echo "DEV_BASIC_AUTH_USER contains unsupported characters." >&2
            exit 1
            ;;
    esac
    mkdir -p "$ROOT_DIR/confs/nginx/auth"
    printf '%s:%s\n' "$dev_auth_user" "$(openssl passwd -apr1 "$dev_password")" \
        > "$ROOT_DIR/confs/nginx/auth/dev.htpasswd"
    chmod 644 "$ROOT_DIR/confs/nginx/auth/dev.htpasswd"
fi
chmod 600 "$TARGET" 2>/dev/null || true

if [ "$MODE" = "local" ]; then
    mkdir -p "$ROOT_DIR/www/public_html" "$ROOT_DIR/backups"
    if [ "${SKIP_LOCAL_CERT:-0}" != "1" ]; then
        "$ROOT_DIR/scripts/setup-local-cert.sh"
    fi
fi

if [ "$MODE" = "development" ] || [ "$MODE" = "dev" ]; then
    "$ROOT_DIR/scripts/init-dev-sites.sh"
fi

initialization_complete=1
trap - 0
echo "Created $TARGET for $MODE mode."
if [ "$MODE" != "local" ]; then
    echo "Review EDGE_MODE, paths, database sizing and resource limits before deployment."
fi
