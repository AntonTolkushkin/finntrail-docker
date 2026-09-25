#!/usr/bin/env sh
set -eu

ROOT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)

"$ROOT_DIR/scripts/validate.sh" local
"$ROOT_DIR/scripts/compose.sh" pull

"$ROOT_DIR/scripts/compose.sh" run --rm --no-deps php php-fpm -t

# Start PHP and its dependencies so the "php" hostname exists in Docker DNS.
"$ROOT_DIR/scripts/compose.sh" up -d mysql redis php

"$ROOT_DIR/scripts/compose.sh" run --rm --no-deps nginx nginx -t

"$ROOT_DIR/scripts/compose.sh" up -d --remove-orphans
"$ROOT_DIR/scripts/compose.sh" ps
