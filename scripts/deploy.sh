#!/usr/bin/env sh
set -eu

ROOT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
if [ ! -f "$ROOT_DIR/.env" ]; then
    echo ".env is missing. Run scripts/init-env.sh first." >&2
    exit 1
fi
configured_mode=$(sed -n 's/^APP_ENV=//p' "$ROOT_DIR/.env" | tail -n 1 | tr -d '\r' | tr -d "'\"")
case "$configured_mode" in
    production|prod) validation_mode=production ;;
    development|dev) validation_mode=development ;;
    *)
        echo "deploy.sh is only for production or development server deployments." >&2
        exit 1
        ;;
esac

"$ROOT_DIR/scripts/validate.sh" "$validation_mode"
"$ROOT_DIR/scripts/compose.sh" pull
"$ROOT_DIR/scripts/compose.sh" run --rm --no-deps php php-fpm -t
"$ROOT_DIR/scripts/compose.sh" up -d mysql redis php
"$ROOT_DIR/scripts/compose.sh" run --rm --no-deps nginx nginx -t
"$ROOT_DIR/scripts/compose.sh" up -d --remove-orphans
"$ROOT_DIR/scripts/compose.sh" ps
