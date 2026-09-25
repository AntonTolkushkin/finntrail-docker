#!/usr/bin/env sh
set -eu

ROOT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
MODE=${1:-local}
ENV_FILE="$ROOT_DIR/.env"

if [ ! -f "$ENV_FILE" ]; then
    echo ".env is missing. Run scripts/init-env.sh $MODE first." >&2
    exit 1
fi

if grep -q 'CHANGE_ME_' "$ENV_FILE"; then
    echo ".env still contains placeholder secrets." >&2
    exit 1
fi

configured_mode=$(sed -n 's/^APP_ENV=//p' "$ENV_FILE" | tail -n 1 | tr -d '\r' | tr -d "'\"")
edge_mode=$(sed -n 's/^EDGE_MODE=//p' "$ENV_FILE" | tail -n 1 | tr -d '\r' | tr -d "'\"")
bind_address=$(sed -n 's/^NGINX_BIND_ADDRESS=//p' "$ENV_FILE" | tail -n 1 | tr -d '\r' | tr -d "'\"")

if ! command -v docker >/dev/null 2>&1; then
    echo "Docker is not installed or is not available in PATH." >&2
    exit 1
fi

cd "$ROOT_DIR"

case "$MODE" in
    local)
        if [ "${configured_mode:-local}" != "local" ]; then
            echo "APP_ENV must be local for a local deployment." >&2
            exit 1
        fi
        if [ ! -r "$ROOT_DIR/confs/nginx/certs/finntrail.local/fullchain.pem" ] || \
           [ ! -r "$ROOT_DIR/confs/nginx/certs/finntrail.local/privkey.pem" ]; then
            echo "Local TLS certificate is missing. Run scripts/setup-local-cert.sh." >&2
            exit 1
        fi
        if [ ! -d "$ROOT_DIR/www/public_html" ]; then
            echo "Local document root is missing: $ROOT_DIR/www/public_html" >&2
            exit 1
        fi
        "$ROOT_DIR/scripts/compose.sh" config --quiet
        ;;
    production|prod|development|dev)
        if [ "$MODE" = "production" ] || [ "$MODE" = "prod" ]; then
            expected_a=production
            expected_b=prod
        else
            expected_a=development
            expected_b=dev
        fi
        if [ "$configured_mode" != "$expected_a" ] && [ "$configured_mode" != "$expected_b" ]; then
            echo "APP_ENV must be $expected_a for this deployment." >&2
            exit 1
        fi
        if [ "${bind_address:-127.0.0.1}" != "127.0.0.1" ]; then
            echo "Server deployments must bind Nginx to 127.0.0.1 so they do not replace the existing public web server." >&2
            exit 1
        fi
        "$ROOT_DIR/scripts/compose.sh" config --quiet
        case "${edge_mode:-host-nginx}" in
            host-nginx) ;;
            traefik)
                traefik_network=$(sed -n 's/^TRAEFIK_NETWORK=//p' "$ENV_FILE" | tail -n 1 | tr -d '\r' | tr -d "'\"")
                if [ -z "$traefik_network" ]; then
                    echo "TRAEFIK_NETWORK is empty." >&2
                    exit 1
                fi
                if ! docker network inspect "$traefik_network" >/dev/null 2>&1; then
                    echo "External Traefik network '$traefik_network' does not exist." >&2
                    exit 1
                fi
                ;;
            *)
                echo "EDGE_MODE must be host-nginx or traefik." >&2
                exit 1
                ;;
        esac
        if [ "$expected_a" = "development" ]; then
            if [ ! -r "$ROOT_DIR/confs/nginx/auth/dev.htpasswd" ]; then
                echo "Development Basic Auth file is missing. Run scripts/init-env.sh development." >&2
                exit 1
            fi
            "$ROOT_DIR/scripts/init-dev-sites.sh"
        fi
        ;;
    *)
        echo "Usage: $0 [local|production|development]" >&2
        exit 2
        ;;
esac

echo "Configuration for $MODE mode is valid."
