#!/usr/bin/env sh
set -eu

ROOT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
ENV_FILE="$ROOT_DIR/.env"

if [ ! -f "$ENV_FILE" ]; then
    echo ".env is missing. Run scripts/init-env.sh first." >&2
    exit 1
fi

APP_ENV=$(sed -n 's/^APP_ENV=//p' "$ENV_FILE" | tail -n 1 | tr -d '\r' | tr -d "'\"")
EDGE_MODE=$(sed -n 's/^EDGE_MODE=//p' "$ENV_FILE" | tail -n 1 | tr -d '\r' | tr -d "'\"")
case "${APP_ENV:-local}" in
    local)
        set -- \
            --env-file "$ENV_FILE" \
            -f "$ROOT_DIR/docker-compose.yml" \
            -f "$ROOT_DIR/docker-compose.override.yml" \
            "$@"
        ;;
    production|prod)
        case "${EDGE_MODE:-host-nginx}" in
            host-nginx)
                set -- \
                    --env-file "$ENV_FILE" \
                    -f "$ROOT_DIR/docker-compose.yml" \
                    -f "$ROOT_DIR/docker-compose.prod.yml" \
                    "$@"
                ;;
            traefik)
                set -- \
                    --env-file "$ENV_FILE" \
                    -f "$ROOT_DIR/docker-compose.yml" \
                    -f "$ROOT_DIR/docker-compose.prod.yml" \
                    -f "$ROOT_DIR/docker-compose.traefik.yml" \
                    "$@"
                ;;
            *)
                echo "Unsupported EDGE_MODE in .env: $EDGE_MODE" >&2
                exit 1
                ;;
        esac
        ;;
    development|dev)
        case "${EDGE_MODE:-host-nginx}" in
            host-nginx)
                set -- \
                    --env-file "$ENV_FILE" \
                    -f "$ROOT_DIR/docker-compose.yml" \
                    -f "$ROOT_DIR/docker-compose.dev.yml" \
                    "$@"
                ;;
            traefik)
                set -- \
                    --env-file "$ENV_FILE" \
                    -f "$ROOT_DIR/docker-compose.yml" \
                    -f "$ROOT_DIR/docker-compose.dev.yml" \
                    -f "$ROOT_DIR/docker-compose.traefik.yml" \
                    "$@"
                ;;
            *)
                echo "Unsupported EDGE_MODE in .env: $EDGE_MODE" >&2
                exit 1
                ;;
        esac
        ;;
    *)
        echo "Unsupported APP_ENV in .env: $APP_ENV (expected local, production or development)" >&2
        exit 1
        ;;
esac

cd "$ROOT_DIR"
exec docker compose "$@"
